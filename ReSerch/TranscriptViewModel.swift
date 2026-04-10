import SwiftUI
import Combine
import UIKit

@Observable
final class TranscriptViewModel {
    var urlInput: String = ""
    var result: TranscriptResult? = nil
    var status: FetchStatus = .idle
    var history: [TranscriptEntry] = []
    var copied: Bool = false
    var modelDownloadProgress: Double = 0
    var isDownloadingModel: Bool = false

    // Batch state
    var batchTotal: Int = 0
    var batchCurrent: Int = 0
    var isBatchProcessing: Bool = false

    var isLoading: Bool {
        switch status {
        case .fetchingCaptions, .downloadingVideo, .transcribing: return true
        default: return false
        }
    }

    var formattedMarkdown: String? {
        guard let r = result else { return nil }
        return MarkdownFormatter.format(r)
    }

    private var currentTask: Task<Void, Never>?
    private let whisperTranscriber = WhisperTranscriber()

    private var historyFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("reserch_history.json")
    }

    init() {
        print("[ReSerch] TranscriptViewModel.init started")
        loadHistory()
        Task { await whisperTranscriber.initializeIfCached() }
    }

    enum FetchStatus: Equatable {
        case idle
        case needsModel
        case fetchingCaptions
        case downloadingVideo(Double)
        case transcribing(Double)
        case done
        case error(String)
    }

    func cancel() {
        currentTask?.cancel()
        status = .idle
    }

    func showCopiedFeedback() {
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    func downloadWhisperModel() async {
        isDownloadingModel = true
        rLog(step: "Whisper", "Starting model download...")
        for await progress in whisperTranscriber.downloadModel() {
            modelDownloadProgress = progress
            rLog(step: "Whisper", "Download progress: \(Int(progress * 100))%")
        }
        isDownloadingModel = false
        modelDownloadProgress = 0
        rLog(.ok, step: "Whisper", "Model download complete, retrying transcript...")
        await fetchTranscript()
    }

    func fetchTranscript() async {
        let raw = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw) else {
            status = .error("Enter a valid URL")
            return
        }

        currentTask?.cancel()
        result = nil
        status = .fetchingCaptions

        currentTask = Task {
            do {
                DebugLogger.shared.clear()
                let t0 = Date()
                func elapsed(since start: Date) -> String { String(format: "%.2fs", Date().timeIntervalSince(start)) }

                rLog(step: "URL", "Input: \(raw)")

                let platform = PlatformRouter.detect(url)
                rLog(step: "Platform", "Detected: \(platform)")

                let transcriptResult: TranscriptResult

                switch platform {
                case .youtube(let videoId):
                    rLog(step: "YouTube", "Video ID: \(videoId)")
                    let tYT = Date()
                    transcriptResult = try await YouTubeFetcher.fetch(videoId: videoId, originalURL: raw)
                    rLog(.ok, step: "YouTube", "Got transcript: \(transcriptResult.transcript.count) chars ⏱ \(elapsed(since: tYT))")

                case .tiktok, .instagram, .twitter, .threads, .unknown:
                    rLog(step: "Whisper", "Model ready: \(whisperTranscriber.isModelReady())")
                    guard whisperTranscriber.isModelReady() else {
                        status = .needsModel
                        return
                    }
                    rLog(step: "Extract", "Fetching page + extracting video URL...")
                    let tExtract = Date()
                    let meta = try await VideoExtractor.extractVideoMetadata(from: url, platform: platform)
                    rLog(.ok, step: "Extract", "Got video URL ⏱ \(elapsed(since: tExtract))")
                    rLog(step: "Extract", "URL: \(meta.videoURL.absoluteString.prefix(80))...")

                    status = .downloadingVideo(0)
                    rLog(step: "Download", "Downloading video...")
                    let tDownload = Date()
                    let audioURL = try await VideoExtractor.downloadAudio(from: meta.videoURL) { [weak self] p in
                        self?.status = .downloadingVideo(p)
                    }
                    rLog(.ok, step: "Download", "Audio ready ⏱ \(elapsed(since: tDownload)) — \(audioURL.lastPathComponent)")

                    status = .transcribing(0)
                    rLog(step: "Whisper", "Starting transcription...")
                    let tWhisper = Date()
                    let transcript = try await whisperTranscriber.transcribe(audioURL: audioURL) { [weak self] p in
                        self?.status = .transcribing(p)
                    }
                    rLog(.ok, step: "Whisper", "Done ⏱ \(elapsed(since: tWhisper)) — \(transcript.count) chars")
                    try? FileManager.default.removeItem(at: audioURL)
                    let formattedTranscript = transcript.paragraphized()

                    let platformName: String
                    switch platform {
                    case .tiktok: platformName = "TikTok"
                    case .instagram: platformName = "Instagram"
                    case .twitter: platformName = "Twitter"
                    case .threads: platformName = "Threads"
                    default: platformName = "Video"
                    }

                    transcriptResult = TranscriptResult(
                        title: meta.title,
                        author: meta.author,
                        handle: meta.handle,
                        platform: platformName,
                        url: raw,
                        caption: meta.caption,
                        transcript: formattedTranscript,
                        viewCount: meta.viewCount,
                        likeCount: meta.likeCount,
                        commentCount: meta.commentCount,
                        shareCount: meta.shareCount,
                        duration: meta.formattedDuration,
                        postedDate: meta.postedDate,
                        thumbnailURL: meta.thumbnailURL
                    )
                }

                if Task.isCancelled { return }
                rLog(.ok, step: "Total", "Done in \(elapsed(since: t0))")
                result = transcriptResult
                status = .done
                saveToHistory(transcriptResult)

            } catch is CancellationError {
                rLog(.warn, step: "Task", "Cancelled")
                status = .idle
            } catch {
                rLog(.fail, step: "Error", "\(error)")
                status = .error(error.localizedDescription)
            }
        }

        await currentTask?.value
    }

    func fetchBatch(rawText: String) async {
        // Parse one URL per line, skip blanks
        let urls = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && URL(string: $0) != nil }

        guard !urls.isEmpty else { return }

        batchTotal = urls.count
        batchCurrent = 0
        isBatchProcessing = true

        // Ask iOS for extra time to keep running after user backgrounds the app
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "reserch.batch") {
            UIApplication.shared.endBackgroundTask(bgTask)
        }

        var saved = 0
        var failed = 0

        for url in urls {
            batchCurrent += 1
            urlInput = url
            await fetchTranscript()
            if case .done = status { saved += 1 } else { failed += 1 }
        }

        isBatchProcessing = false
        batchTotal = 0
        batchCurrent = 0
        UIApplication.shared.endBackgroundTask(bgTask)

        NotificationManager.sendBatchComplete(count: saved, failed: failed)
    }

    func saveToHistory(_ result: TranscriptResult) {
        let entry = TranscriptEntry(result: result)
        history.insert(entry, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        saveHistoryAsync()
    }

    func deleteEntry(_ entry: TranscriptEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistoryAsync()
    }

    func updateEntry(_ entry: TranscriptEntry) {
        if let idx = history.firstIndex(where: { $0.id == entry.id }) {
            history[idx] = entry
            saveHistoryAsync()
        }
    }

    func renameEntry(_ entry: TranscriptEntry, to newTitle: String) {
        var updated = entry
        updated.result.editableTitle = newTitle
        updateEntry(updated)
    }

    func markdownFor(_ entry: TranscriptEntry) -> String {
        MarkdownFormatter.format(entry.result)
    }

    // MARK: - Persistence

    // Used by scenePhase handler — blocks intentionally so data survives process kill
    func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: historyFileURL, options: .atomic)
    }

    // Used for interactive mutations — off main thread so UI stays instant
    private func saveHistoryAsync() {
        let snapshot = history
        let url = historyFileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadHistory() {
        print("[ReSerch] loadHistory called")
        guard let data = try? Data(contentsOf: historyFileURL) else {
            print("[ReSerch] loadHistory — no file, starting fresh")
            return
        }
        do {
            history = try JSONDecoder().decode([TranscriptEntry].self, from: data)
            print("[ReSerch] loadHistory — loaded \(history.count) entries")
        } catch {
            print("[ReSerch] loadHistory — decode FAILED: \(error)")
            rLog(.fail, step: "Load", "Decode failed: \(error)")
            // Delete corrupt file so next launch starts clean
            try? FileManager.default.removeItem(at: historyFileURL)
            history = []
        }
    }
}

enum DetectedPlatform {
    case youtube, tiktok, instagram

    var displayName: String {
        switch self {
        case .youtube: return "YouTube"
        case .tiktok: return "TikTok"
        case .instagram: return "Instagram"
        }
    }
}
