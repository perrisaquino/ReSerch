import SwiftUI
import Combine
import UIKit

@MainActor
@Observable
final class TranscriptViewModel {
    var urlInput: String = ""
    var result: TranscriptResult? = nil
    var status: FetchStatus = .idle
    var history: [TranscriptEntry] = []
    var notebooks: [Notebook] = []
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

    private var notebooksFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("reserch_notebooks.json")
    }

    init() {
        print("[ReSerch] TranscriptViewModel.init started")
        loadHistory()
        loadNotebooks()
        Task { await whisperTranscriber.initializeIfCached() }
    }

    enum FetchStatus: Equatable {
        case idle
        case needsModel
        case needsSafariSignIn(SafariProvider)
        case fetchingCaptions
        case downloadingVideo(Double)
        case transcribing(Double)
        case done
        case error(String)
    }

    /// Platforms whose extractors depend on the app's WKWebsiteDataStore.default() cookie store.
    /// Drives the pre-flight in-app sign-in sheet so users don't wait 20 seconds for an
    /// extractor timeout.
    enum SafariProvider: Equatable, Identifiable {
        case instagram
        case youtube

        var id: String {
            switch self {
            case .instagram: return "instagram"
            case .youtube: return "youtube"
            }
        }

        var displayName: String {
            switch self {
            case .instagram: return "Instagram"
            case .youtube: return "YouTube"
            }
        }

        /// Deep-links into Safari at the platform's sign-in screen, not the homepage,
        /// so the user lands one tap away from logging in.
        var safariURL: URL {
            switch self {
            case .instagram:
                return URL(string: "https://www.instagram.com/accounts/login/")!
            case .youtube:
                // Google's accounts flow with continue=youtube → after sign-in Safari lands
                // on youtube.com with the auth cookies set, exactly what ReSerch needs.
                return URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!
            }
        }
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

    /// Bypass the Safari sign-in pre-flight. Used by the "Try anyway" secondary action
    /// on the `needsSafariSignIn` banner so power users with edge-case cookie state can
    /// still attempt transcription.
    func fetchTranscriptBypassingPreflight() async {
        skipNextPreflight = true
        await fetchTranscript()
    }

    private var skipNextPreflight = false

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

                case .tiktok, .instagram, .twitter, .threads, .youtubeShorts, .unknown:
                    rLog(step: "Whisper", "Model ready: \(whisperTranscriber.isModelReady())")
                    guard whisperTranscriber.isModelReady() else {
                        status = .needsModel
                        return
                    }

                    // Pre-flight cookie check — surfaces a clean "Sign in to Safari" banner
                    // immediately instead of letting the extractor run for 20s and time out.
                    let bypass = self.skipNextPreflight
                    self.skipNextPreflight = false
                    if !bypass {
                        switch platform {
                        case .instagram, .threads:
                            if await !CookieChecker.hasInstagramSession() {
                                rLog(.warn, step: "Pre-flight", "No Instagram session in Safari")
                                status = .needsSafariSignIn(.instagram)
                                return
                            }
                        // YouTube Shorts uses YouTubeKit (yt-dlp port) which fetches the
                        // public player API directly — no sign-in required.
                        default:
                            break
                        }
                    }

                    rLog(step: "Extract", "Fetching page + extracting video URL...")
                    let tExtract = Date()
                    let meta = try await VideoExtractor.extractVideoMetadata(from: url, platform: platform)
                    rLog(.ok, step: "Extract", "Got video URL ⏱ \(elapsed(since: tExtract))")
                    rLog(step: "Extract", "URL: \(meta.videoURL.absoluteString.prefix(80))...")

                    status = .downloadingVideo(0)
                    rLog(step: "Download", "Downloading video...")
                    let tDownload = Date()
                    let audioURL = try await VideoExtractor.downloadAudio(from: meta.videoURL) { p in
                        Task { @MainActor [weak self] in self?.status = .downloadingVideo(p) }
                    }
                    rLog(.ok, step: "Download", "Audio ready ⏱ \(elapsed(since: tDownload)) — \(audioURL.lastPathComponent)")

                    status = .transcribing(0)
                    rLog(step: "Whisper", "Starting transcription...")
                    let tWhisper = Date()
                    let transcript = try await whisperTranscriber.transcribe(audioURL: audioURL) { p in
                        Task { @MainActor [weak self] in self?.status = .transcribing(p) }
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
                    case .youtubeShorts: platformName = "YouTube Shorts"
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

        await fetchBatch(urls: urls, playlistName: nil)
    }

    /// Bulk-transcribe a specific list of URLs. When `playlistName` is set, the completion
    /// notification is scoped to that playlist ("Playlist 'Foo' — N transcripts saved").
    func fetchBatch(urls: [String], playlistName: String?) async {
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

        NotificationManager.sendBatchComplete(count: saved, failed: failed, playlistName: playlistName)
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
        let nb = notebook(for: entry.notebookID)
        return MarkdownFormatter.format(entry.result, notebook: nb, documentNote: entry.documentNote)
    }

    /// Compiles every transcript in `notebook` into a single markdown document, separated by `---`.
    /// Useful for piping a research topic into a single Obsidian note.
    func combinedMarkdown(for notebook: Notebook) -> String {
        let entries = transcripts(in: notebook)
        guard !entries.isEmpty else {
            return "# \(notebook.name)\n\n(No transcripts in this notebook yet.)\n"
        }
        let header = "# \(notebook.name)\n\n_\(entries.count) transcript\(entries.count == 1 ? "" : "s")_\n\n---\n\n"
        let body = entries.map { markdownFor($0) }.joined(separator: "\n\n---\n\n")
        return header + body
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

    // MARK: - Notebooks

    /// Returns transcripts that belong to the given notebook, newest-first.
    func transcripts(in notebook: Notebook) -> [TranscriptEntry] {
        history.filter { $0.notebookID == notebook.id }
    }

    /// Returns transcripts not assigned to any notebook, newest-first.
    var unfiledTranscripts: [TranscriptEntry] {
        history.filter { $0.notebookID == nil }
    }

    /// Looks up a notebook by ID. Returns nil if the notebook was deleted.
    func notebook(for id: UUID?) -> Notebook? {
        guard let id else { return nil }
        return notebooks.first { $0.id == id }
    }

    @discardableResult
    func createNotebook(name: String, colorHex: String? = nil) -> Notebook {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let nb = Notebook(name: trimmed, colorHex: colorHex)
        notebooks.append(nb)
        sortNotebooks()
        saveNotebooksAsync()
        return nb
    }

    func renameNotebook(_ notebook: Notebook, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = notebooks.firstIndex(where: { $0.id == notebook.id }) else { return }
        notebooks[idx].name = trimmed
        sortNotebooks()
        saveNotebooksAsync()
    }

    func recolorNotebook(_ notebook: Notebook, to colorHex: String?) {
        guard let idx = notebooks.firstIndex(where: { $0.id == notebook.id }) else { return }
        notebooks[idx].colorHex = colorHex
        saveNotebooksAsync()
    }

    /// Deletes a notebook. Transcripts inside it move back to Unfiled (notebookID = nil).
    func deleteNotebook(_ notebook: Notebook) {
        notebooks.removeAll { $0.id == notebook.id }
        for idx in history.indices where history[idx].notebookID == notebook.id {
            history[idx].notebookID = nil
        }
        saveNotebooksAsync()
        saveHistoryAsync()
    }

    /// Moves a transcript into a notebook (or to Unfiled when notebook is nil).
    func assignNotebook(_ entry: TranscriptEntry, to notebook: Notebook?) {
        guard let idx = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[idx].notebookID = notebook?.id
        saveHistoryAsync()
    }

    /// Bulk-move version. Used by the multi-select bulkBar.
    func assignNotebook(_ entries: [TranscriptEntry], to notebook: Notebook?) {
        for entry in entries {
            if let idx = history.firstIndex(where: { $0.id == entry.id }) {
                history[idx].notebookID = notebook?.id
            }
        }
        saveHistoryAsync()
    }

    func setDocumentNote(_ entry: TranscriptEntry, to note: String) {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[idx].documentNote = trimmed.isEmpty ? nil : note
        saveHistoryAsync()
    }

    /// Alphabetical, case-insensitive. Stable ordering for the Notebooks tab list.
    private func sortNotebooks() {
        notebooks.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Notebook persistence

    func saveNotebooks() {
        guard let data = try? JSONEncoder().encode(notebooks) else { return }
        try? data.write(to: notebooksFileURL, options: .atomic)
    }

    private func saveNotebooksAsync() {
        let snapshot = notebooks
        let url = notebooksFileURL
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadNotebooks() {
        guard let data = try? Data(contentsOf: notebooksFileURL) else {
            print("[ReSerch] loadNotebooks — no file, starting fresh")
            return
        }
        do {
            notebooks = try JSONDecoder().decode([Notebook].self, from: data)
            sortNotebooks()
            print("[ReSerch] loadNotebooks — loaded \(notebooks.count) notebooks")
        } catch {
            print("[ReSerch] loadNotebooks — decode FAILED: \(error)")
            try? FileManager.default.removeItem(at: notebooksFileURL)
            notebooks = []
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
