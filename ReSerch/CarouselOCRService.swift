import Foundation
@preconcurrency import Vision
import UIKit

@MainActor
final class CarouselOCRService {

    /// Where downloaded images go when the embed-images setting is on.
    /// Goes through `iCloudSyncService` so the directory is the iCloud ubiquity container
    /// when sync is on, otherwise local Documents/CarouselImages. Either way the on-disk
    /// directory exists by the time this returns.
    @MainActor
    static func imagesDirectory() throws -> URL {
        let dir = iCloudSyncService.shared.activeURL(for: .carouselImages)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Process every slide. Returns the same payload with `recognizedText`,
    /// `localImagePath`, and `imageDownloadFailed` filled in.
    func process(
        _ payload: CarouselPayload,
        embedImages: Bool,
        progress: @escaping (Int, Int) -> Void
    ) async -> CarouselPayload {
        var payload = payload
        let total = payload.slides.count
        let postSlug = postSlug(for: payload.postURL)
        let dir = try? Self.imagesDirectory()

        await withTaskGroup(of: (Int, Data?).self) { group in
            var iterator = payload.slides.makeIterator()
            var completed = 0

            func enqueueNext() {
                guard let slide = iterator.next() else { return }
                let imageURL = slide.imageURL
                let index = slide.index
                group.addTask {
                    let data = try? await Self.download(imageURL)
                    return (index, data)
                }
            }
            for _ in 0..<min(4, total) { enqueueNext() }

            while let (index, data) = await group.next() {
                completed += 1
                progress(completed, total)

                guard let data, let image = UIImage(data: data) else {
                    payload.slides[index].imageDownloadFailed = true
                    enqueueNext()
                    continue
                }

                if embedImages, let dir {
                    let filename = String(format: "%@-%02d.jpg", postSlug, index)
                    let dest = dir.appendingPathComponent(filename)
                    try? data.write(to: dest)
                    payload.slides[index].localImagePath = dest
                }

                let text = await Self.runOCR(on: image)
                payload.slides[index].recognizedText = text

                enqueueNext()
            }
        }

        return payload
    }

    private static func download(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    /// Returns concatenated recognized text. Empty string if Vision found nothing.
    /// Nil if Vision errored or the timeout fired before any text came back.
    ///
    /// Three concurrent paths can complete this OCR call: the Vision callback (success
    /// or cancellation surfaces here), the `perform()` throw path (when the request
    /// can't even start), and the 10s timeout. Without idempotent resume the
    /// `CheckedContinuation` would be resumed twice on cancellation paths and Apple's
    /// runtime would `fatalError(SWIFT TASK CONTINUATION MISUSE)`. The `ResumeOnce`
    /// box below is locked so only the first path wins; subsequent attempts no-op.
    private static func runOCR(on image: UIImage) async -> String? {
        guard let cgImage = image.cgImage else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let resumer = ResumeOnce(continuation: cont)

            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                resumer.resume(with: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let cancelTask = Task.detached {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                request.cancel()
                // Belt-and-suspenders: if the Vision callback doesn't fire after cancel(),
                // we still need to unblock the continuation. ResumeOnce makes this safe.
                resumer.resume(with: nil)
            }
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    resumer.resume(with: nil)
                }
                cancelTask.cancel()
            }
        }
    }
}

/// Lock-protected single-use continuation resumer. Used wherever multiple concurrent
/// paths might all try to resume the same `CheckedContinuation` (e.g. callback + throw +
/// timeout). The first resume wins; subsequent calls no-op silently.
///
/// `@unchecked Sendable` because we manage thread safety manually with the NSLock.
private final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private let continuation: CheckedContinuation<T, Never>

    init(continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(with value: T) {
        lock.lock()
        let alreadyResumed = didResume
        didResume = true
        lock.unlock()
        guard !alreadyResumed else { return }
        continuation.resume(returning: value)
    }
}

extension CarouselOCRService {
    fileprivate func postSlug(for url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        let raw = parts.last ?? "carousel"
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).replacingOccurrences(of: "--", with: "-")
    }
}
