import Foundation
import WhisperKit

final class WhisperTranscriber {
    private var pipe: WhisperKit?
    private(set) var modelReady = false

    private let modelName = "openai_whisper-base.en"

    func isModelReady() -> Bool { modelReady }

    /// Called at app launch — loads from disk if already downloaded, silently does nothing if not.
    func initializeIfCached() async {
        guard !modelReady else { return }
        // WhisperKit stores models under <Documents>/huggingface/models/...
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let modelFolder = docs
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(modelName)
        guard FileManager.default.fileExists(atPath: modelFolder.path) else { return }
        do {
            let whisper = try await WhisperKit(model: modelName, verbose: false)
            self.pipe = whisper
            self.modelReady = true
        } catch {
            // Files exist but load failed — fall through to show download prompt
        }
    }

    func downloadModel() -> AsyncStream<Double> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let whisper = try await WhisperKit(model: self.modelName, verbose: false)
                    await MainActor.run { self.pipe = whisper; self.modelReady = true }
                    continuation.yield(1.0)
                } catch {
                    // model load failed
                }
                continuation.finish()
            }
        }
    }

    func transcribe(
        audioURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> String {
        if pipe == nil {
            pipe = try await WhisperKit(model: modelName, verbose: false)
            modelReady = true
        }

        guard let pipe else {
            throw TranscribeError.modelNotLoaded
        }

        let results = try await pipe.transcribe(audioPath: audioURL.path)
        let text = results.map { $0.text }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return text
    }

    enum TranscribeError: LocalizedError {
        case modelNotLoaded

        var errorDescription: String? {
            "Whisper model is not loaded. Please download it first."
        }
    }
}
