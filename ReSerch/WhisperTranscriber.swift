import Foundation
import WhisperKit

@MainActor
final class WhisperTranscriber {
    private var pipe: WhisperKit?
    private(set) var modelReady = false

    /// Coalesces concurrent load attempts onto a single WhisperKit load, so a
    /// share-triggered transcription and the launch-time `initializeIfCached`
    /// can't kick off two Core ML compiles at once — the race that surfaced as
    /// spurious "re-download the engine" prompts.
    private var loadTask: Task<Bool, Never>?

    private let modelName = "openai_whisper-base.en"

    func isModelReady() -> Bool { modelReady }

    /// Where WhisperKit downloads this model: <Documents>/huggingface/models/...
    /// Mirrors swift-transformers' HubApi default `downloadBase` (Documents/huggingface)
    /// + `localRepoLocation` (models/<repo>) + the model variant subfolder.
    private var modelFolderURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            .appendingPathComponent(modelName)
    }

    /// True when the model folder exists and is non-empty. This only separates
    /// "absent" (genuinely needs a download) from "present" — actual loadability
    /// is decided by WhisperKit itself in `loadFromDisk()`.
    func isModelInstalledOnDisk() -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: modelFolderURL.path) else {
            return false
        }
        return !contents.isEmpty
    }

    /// Availability of the on-device transcription engine, for the fetch gate.
    enum ModelAvailability: Equatable {
        case ready         // loaded and usable
        case missing       // no files on disk → legitimately needs a download
        case loadFailed    // files on disk but the pipeline wouldn't load → retry/repair, NOT re-download
    }

    /// Single async readiness entry point. `.ready` if the pipeline is (or becomes)
    /// loaded, `.missing` ONLY when the files are absent, `.loadFailed` when files
    /// are present but the load didn't succeed. Concurrent callers share one load.
    func prepareForTranscription() async -> ModelAvailability {
        if modelReady { return .ready }
        guard isModelInstalledOnDisk() else { return .missing }

        // Reuse an in-flight load if one exists; otherwise start one. There is no
        // await between reading and assigning `loadTask`, so this is race-free on
        // the main actor — a second caller always sees the first caller's task.
        let task: Task<Bool, Never>
        if let existing = loadTask {
            task = existing
        } else {
            task = Task { await self.loadFromDisk() }
            loadTask = task
        }
        let ok = await task.value
        loadTask = nil
        return ok ? .ready : .loadFailed
    }

    /// Loads the already-downloaded model from disk. `download: false` guarantees
    /// no network call, so a present-but-unloaded engine never triggers a re-download.
    private func loadFromDisk() async -> Bool {
        do {
            let whisper = try await WhisperKit(
                model: modelName,
                modelFolder: modelFolderURL.path,
                verbose: false,
                download: false
            )
            self.pipe = whisper
            self.modelReady = true
            return true
        } catch {
            print("[ReSerch][Whisper] load from disk failed: \(error)")
            return false
        }
    }

    /// Called at app launch — loads from disk if already downloaded, does nothing if not.
    func initializeIfCached() async {
        guard !modelReady, isModelInstalledOnDisk() else { return }
        _ = await prepareForTranscription()
    }

    nonisolated func downloadModel() -> AsyncStream<Double> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let modelName = await self.modelName
                    let whisper = try await WhisperKit(model: modelName, verbose: false)
                    await MainActor.run { self.pipe = whisper; self.modelReady = true }
                    continuation.yield(1.0)
                } catch {
                    print("[ReSerch][Whisper] model download failed: \(error)")
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
            // Never implicitly download here — the fetch gate owns downloads.
            // Load from disk if present; otherwise fail clearly.
            guard await prepareForTranscription() == .ready else {
                throw TranscribeError.modelNotLoaded
            }
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
