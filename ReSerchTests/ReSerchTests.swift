import Testing
import AVFoundation
@testable import ReSerch

// MARK: - Helpers

/// Builds a minimal fragmented MP4 (fMP4) in memory — the same container format Instagram
/// serves as DASH audio segments. The key property: `movieFragmentInterval` makes AVAssetWriter
/// emit `moof+mdat` boxes instead of a single `moov` block, which is what causes
/// AVAssetExportSession to throw "Invalid sample cursor" (it needs a seekable moov to build
/// its export pipeline; AVAssetReader does not).
private func makeFragmentedMP4(at url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    // Fragment every 200ms — forces fMP4 box structure
    writer.movieFragmentInterval = CMTime(value: 1, timescale: 5)

    let audioSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: Float(44100),
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000
    ]
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
    input.expectsMediaDataInRealTime = false
    writer.add(input)

    writer.startWriting()
    writer.startSession(atSourceTime: .zero)

    // Feed 0.5 seconds of silence at 44.1kHz
    let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: 44100, channels: 1, interleaved: false)!
    let sampleCount = AVAudioFrameCount(44100 / 2)
    let audioBuf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: sampleCount)!
    audioBuf.frameLength = sampleCount
    // floatChannelData is zero-initialised (silence)

    // Convert PCM buffer → CMSampleBuffer
    var formatDesc: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                   asbd: pcmFormat.streamDescription,
                                   layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil,
                                   extensions: nil,
                                   formatDescriptionOut: &formatDesc)
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 2),
                                    presentationTimeStamp: .zero,
                                    decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    CMSampleBufferCreate(allocator: kCFAllocatorDefault,
                         dataBuffer: nil, dataReady: false,
                         makeDataReadyCallback: nil, refcon: nil,
                         formatDescription: formatDesc,
                         sampleCount: Int(sampleCount),
                         sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                         sampleSizeEntryCount: 0, sampleSizeArray: nil,
                         sampleBufferOut: &sb)

    if let sampleBuffer = sb {
        // Attach the raw PCM bytes to the sample buffer
        let byteCount = Int(sampleCount) * MemoryLayout<Float>.size
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                           memoryBlock: nil,
                                           blockLength: byteCount,
                                           blockAllocator: kCFAllocatorDefault,
                                           customBlockSource: nil,
                                           offsetToData: 0,
                                           dataLength: byteCount,
                                           flags: 0,
                                           blockBufferOut: &blockBuffer)
        if let bb = blockBuffer {
            CMSampleBufferSetDataBuffer(sampleBuffer, newValue: bb)
            CMSampleBufferSetDataReady(sampleBuffer)
            input.append(sampleBuffer)
        }
    }

    input.markAsFinished()
    await writer.finishWriting()

    if let error = writer.error {
        throw error
    }
}

/// Returns a plain (non-fragmented) m4a at `url` using AVAudioFile — for comparison baseline.
private func makePlainM4A(at url: URL) throws {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: 44100, channels: 1, interleaved: false)!
    let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: Float(44100),
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 64_000
    ]
    let outFile = try AVAudioFile(forWriting: url, settings: settings)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
    buf.frameLength = 4410
    try outFile.write(from: buf)
}

// MARK: - Tests

struct ReSerchTests {

    // MARK: The bug being fixed

    /// RED → GREEN: AVAssetExportSession fails on fragmented MP4 with "Invalid sample cursor"
    /// (NSOSStatusErrorDomain -12109). extractAudioWithReader must succeed where
    /// the old extractAudio path fails.
    ///
    /// This test is the automated proof that the AVAssetReader path correctly handles
    /// DASH/fMP4 audio segments — the exact format Instagram serves from its CDN.
    @Test func extractAudioWithReader_succeedsOnFragmentedMP4() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let fmp4 = tmp.appendingPathComponent("test-fixture-\(UUID()).mp4")
        let outM4A = tmp.appendingPathComponent("output-\(UUID()).m4a")
        defer {
            try? FileManager.default.removeItem(at: fmp4)
            // wav extension — extractAudioWithReader writes .wav
            let wav = outM4A.deletingPathExtension().appendingPathExtension("wav")
            try? FileManager.default.removeItem(at: wav)
        }

        // Build the fMP4 fixture
        try await makeFragmentedMP4(at: fmp4)
        #expect(FileManager.default.fileExists(atPath: fmp4.path),
                "Fixture creation failed — test setup issue, not the bug")

        // The function under test must produce a non-empty WAV
        let result = try await VideoExtractor.extractAudioWithReader(from: fmp4, to: outM4A)
        let attrs = try FileManager.default.attributesOfItem(atPath: result.path)
        let size = attrs[.size] as? Int ?? 0

        #expect(result.pathExtension == "wav", "Expected a WAV output file")
        #expect(size > 1000, "Output file is too small — likely empty or header-only (\(size) bytes)")
    }

    // MARK: Regression — plain M4A still works

    /// Ensure the AVAssetReader path also handles ordinary (non-fragmented) M4A,
    /// so we haven't broken anything for non-Instagram audio sources.
    @Test func extractAudioWithReader_succeedsOnPlainM4A() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let m4a = tmp.appendingPathComponent("plain-\(UUID()).m4a")
        let outM4A = tmp.appendingPathComponent("output-plain-\(UUID()).m4a")
        defer {
            try? FileManager.default.removeItem(at: m4a)
            let wav = outM4A.deletingPathExtension().appendingPathExtension("wav")
            try? FileManager.default.removeItem(at: wav)
        }

        try makePlainM4A(at: m4a)
        let result = try await VideoExtractor.extractAudioWithReader(from: m4a, to: outM4A)
        let attrs = try FileManager.default.attributesOfItem(atPath: result.path)
        let size = attrs[.size] as? Int ?? 0

        #expect(size > 1000, "Plain M4A regression: output too small (\(size) bytes)")
    }

    @Test func example() async throws {
        // placeholder — original template test
    }
}
