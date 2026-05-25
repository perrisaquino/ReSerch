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

    /// Transient analytics surface for the next fetch. Defaults to "paste" if unset.
    /// ReSerchApp drain sets this to "share_extension" before each share-queue call.
    var nextFetchSurface: String?

    /// Snapshot of in-flight share-extension jobs (queued + processing + failed).
    /// Refreshed by `ReSerchApp` around every queue mutation; renders as ghost rows
    /// at the top of the feed so users can see share-sheet ingests in progress.
    var pendingShareJobs: [ShareJob] = []

    /// The share-extension job currently being fetched, if any. Set immediately
    /// before the per-job `fetchTranscript` call in the drain loop and cleared
    /// immediately after. Ghost rows use this to know which one should mirror
    /// the live `status` value (progress %) vs show a static state label.
    var activeShareJobID: UUID?

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
        iCloudSyncService.shared.activeURL(for: .history)
    }

    private var notebooksFileURL: URL {
        iCloudSyncService.shared.activeURL(for: .notebooks)
    }

    init() {
        print("[ReSerch] TranscriptViewModel.init started")
        let tInit = Date()
        // Run the iCloud first-launch migration BEFORE the first read. Otherwise an
        // upgrader's local data sits in Documents/ while loadHistory() reads the
        // (still-empty) ubiquity container and shows an empty feed.
        iCloudSyncService.shared.migrateLocalToCloudIfNeededSync()
        let tHistory = Date()
        let historyLoadHealthy = loadHistory()
        print("[ReSerch] loadHistory ⏱ \(Int(Date().timeIntervalSince(tHistory) * 1000))ms")
        let tNotebooks = Date()
        let notebooksLoadHealthy = loadNotebooks()
        print("[ReSerch] loadNotebooks ⏱ \(Int(Date().timeIntervalSince(tNotebooks) * 1000))ms")
        if historyLoadHealthy && notebooksLoadHealthy && Self.suspendSaves {
            print("[ReSerch] persistence write lock cleared after healthy load")
            Self.suspendSaves = false
        }
        if Self.suspendSaves {
            print("[ReSerch] migrations skipped because persistence writes are suspended")
        } else {
            migrateLegacyCarouselTranscripts()
            migrateCarouselTranscriptsV2()
        }
        print("[ReSerch] TranscriptViewModel.init total ⏱ \(Int(Date().timeIntervalSince(tInit) * 1000))ms")
        Task { await whisperTranscriber.initializeIfCached() }
    }

    /// One-shot pass that rewrites the `transcript` field of carousel entries saved
    /// before CarouselNoteFormatter was slimmed down. Old entries had a duplicated
    /// metadata block at the top of the transcript (header, caption blockquote,
    /// creator/likes/source). New format is per-slide content only — wrapper metadata
    /// comes from MarkdownFormatter at export time. Migration is idempotent: it skips
    /// any entry that doesn't start with the legacy header signature, so re-runs are safe.
    private func migrateLegacyCarouselTranscripts() {
        let migrationKey = "carouselTranscriptMigratedV1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        var changed = 0
        for idx in history.indices {
            guard let slides = history[idx].result.carouselSlides, !slides.isEmpty else { continue }
            let transcript = history[idx].result.transcript
            // Legacy format started with `# [Name](url) — Carousel`. New format starts with `### Slide 1`.
            guard transcript.hasPrefix("# [") else { continue }

            var lines: [String] = []
            for slide in slides {
                lines.append("### Slide \(slide.index + 1)")
                if let filename = slide.localImageFilename {
                    lines.append("![[\(filename)]]")
                }
                let text = (slide.recognizedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(text.isEmpty ? "*[no text detected]*" : text)
                lines.append("")
            }
            history[idx].result.transcript = lines.joined(separator: "\n")
            changed += 1
        }

        if changed > 0 {
            saveHistoryAsync()
            print("[ReSerch] migrateLegacyCarouselTranscripts — rewrote \(changed) entries")
        }
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// V2: strip Obsidian image-embed lines (`![[file.jpg]]`) and reflow OCR text so
    /// hard mid-sentence newlines become spaces. Both fix the "weird paste" experience
    /// outside Obsidian — Apple Notes / Notion / iMessage all show the embed syntax as
    /// raw text and treat every newline as a hard break. Idempotent: re-running over
    /// a clean entry is a no-op because there'll be no embed lines and the reflow pass
    /// preserves already-clean paragraphs.
    private func migrateCarouselTranscriptsV2() {
        let migrationKey = "carouselTranscriptMigratedV2"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        var changed = 0
        for idx in history.indices {
            guard let slides = history[idx].result.carouselSlides, !slides.isEmpty else { continue }
            let original = history[idx].result.transcript

            var lines: [String] = []
            for slide in slides {
                lines.append("### Slide \(slide.index + 1)")
                let text = reflowOCR(slide.recognizedText)
                lines.append(text.isEmpty ? "*[no text detected]*" : text)
                lines.append("")
            }
            let rewritten = lines.joined(separator: "\n")
            if rewritten != original {
                history[idx].result.transcript = rewritten
                changed += 1
            }
        }

        if changed > 0 {
            saveHistoryAsync()
            print("[ReSerch] migrateCarouselTranscriptsV2 — rewrote \(changed) entries")
        }
        UserDefaults.standard.set(true, forKey: migrationKey)
    }

    /// Same reflow logic as `CarouselNoteFormatter.reflow`, duplicated locally so the
    /// migration doesn't need to import the formatter just for one helper. Single-newlines
    /// inside a paragraph collapse to spaces; double-newlines (paragraph breaks) survive.
    private func reflowOCR(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return raw
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    enum FetchStatus: Equatable {
        case idle
        case needsModel
        case needsSafariSignIn(SafariProvider)
        case fetchingCaptions
        case downloadingVideo(Double)
        case transcribing(Double)
        case extractingCarousel(message: String)
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
        await fetchTranscript(for: urlInput)
    }

    /// Pulls the current durable share-queue state into `pendingShareJobs`.
    /// Filters out `processing` jobs when no `activeShareJobID` is set — that
    /// state is stale until cold-start reset runs. Called by `ReSerchApp`
    /// around every queue mutation so failed-at-max-retry jobs stay visible.
    func refreshPendingShareJobs() {
        guard let queue = ShareJobQueue.shared else {
            pendingShareJobs = []
            return
        }
        pendingShareJobs = queue.allJobs()
    }

    func fetchTranscript(for input: String) async {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw) else {
            status = .error("Enter a valid URL")
            return
        }

        await withBackgroundTask(name: "reserch.fetch") {
            await fetchTranscriptInner(raw: raw, url: url)
        }
    }

    private func fetchTranscriptInner(raw: String, url: URL) async {
        currentTask?.cancel()
        result = nil
        status = .fetchingCaptions

        let platform = PlatformRouter.detect(url)
        let sourceKey = Self.analyticsSource(for: platform)
        let surface = nextFetchSurface ?? "paste"
        nextFetchSurface = nil
        Analytics.shared.track(.transcriptStarted, properties: [
            "source": sourceKey,
            "surface": surface
        ])

        currentTask = Task {
            do {
                DebugLogger.shared.clear()
                let t0 = Date()
                func elapsed(since start: Date) -> String { String(format: "%.2fs", Date().timeIntervalSince(start)) }

                rLog(step: "URL", "Input: \(raw)")
                rLog(step: "Platform", "Detected: \(platform)")

                let transcriptResult: TranscriptResult

                switch platform {
                case .youtube(let videoId):
                    rLog(step: "YouTube", "Video ID: \(videoId)")
                    let tYT = Date()
                    transcriptResult = try await YouTubeFetcher.fetch(videoId: videoId, originalURL: raw)
                    rLog(.ok, step: "YouTube", "Got transcript: \(transcriptResult.transcript.count) chars ⏱ \(elapsed(since: tYT))")

                case .localFile:
                    // .localFile is never produced by PlatformRouter.detect() — local files
                    // go through `vm.transcribeLocalFile(_:displayName:)` directly. This case
                    // exists only so the switch is exhaustive. Treat as unknown if it ever lands here.
                    fallthrough
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
                            // Trust marker: once the user has successfully extracted from
                            // Instagram in this app, skip the cookie pre-flight. WKWebView's
                            // cookie store is eventually-consistent, so a fresh check right
                            // after sign-in can return false even when cookies are landing.
                            // If the session has actually expired, the extractor will fail
                            // and we'll surface sign-in reactively at that point.
                            let trusted = UserDefaults.standard.bool(forKey: "instagramSessionTrusted")
                            if !trusted, await !CookieChecker.hasInstagramSession() {
                                rLog(.warn, step: "Pre-flight", "No Instagram session and no trust marker — prompting sign-in")
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
                    let meta: VideoMetadata
                    do {
                        meta = try await VideoExtractor.extractVideoMetadata(from: url, platform: platform)
                    } catch VideoExtractor.ExtractError.carouselDetected(let payload, let hasVideo) {
                        if hasVideo {
                            rLog(.warn, step: "Carousel", "Mixed carousel detected — videos in this post weren't transcribed.")
                        }
                        // Successful Instagram fetch — mark session as trusted so we don't
                        // re-prompt sign-in on subsequent carousels.
                        switch platform {
                        case .instagram, .threads:
                            UserDefaults.standard.set(true, forKey: "instagramSessionTrusted")
                        default:
                            break
                        }
                        rLog(step: "Carousel", "Routing to CarouselCoordinator for \(payload.slideCount) slides")
                        status = .extractingCarousel(message: "Extracting slide 1 of \(payload.slideCount)…")
                        let coord = CarouselCoordinator()
                        let embed = UserDefaults.standard.object(forKey: "embedCarouselImages") as? Bool ?? true
                        let carouselResult = await coord.makeTranscriptResult(from: payload, embedImages: embed) { [weak self] msg in
                            Task { @MainActor in self?.status = .extractingCarousel(message: msg) }
                        }
                        result = carouselResult
                        saveToHistory(carouselResult)
                        status = .done
                        return
                    }
                    // Successful Instagram video extraction — same trust marker logic.
                    switch platform {
                    case .instagram, .threads:
                        UserDefaults.standard.set(true, forKey: "instagramSessionTrusted")
                    default:
                        break
                    }
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
                    case .localFile, .youtube, .unknown: platformName = "Video"
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
                        saveCount: meta.saveCount,
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
                Analytics.shared.track(.transcriptCompleted, properties: [
                    "source": sourceKey,
                    "surface": surface,
                    "duration_seconds": Int(Date().timeIntervalSince(t0)),
                    "word_count": transcriptResult.transcript.split { $0.isWhitespace }.count
                ])

            } catch is CancellationError {
                rLog(.warn, step: "Task", "Cancelled")
                status = .idle
            } catch {
                rLog(.fail, step: "Error", "\(error)")
                status = .error(error.localizedDescription)
                Analytics.shared.track(.transcriptFailed, properties: [
                    "source": sourceKey,
                    "surface": surface,
                    "reason": String(describing: type(of: error))
                ])
            }
        }

        await currentTask?.value
    }

    static func analyticsSource(for platform: Platform) -> String {
        switch platform {
        case .youtube, .youtubeShorts: return "youtube"
        case .tiktok: return "tiktok"
        case .instagram: return "instagram"
        case .twitter: return "twitter"
        case .threads: return "threads"
        case .localFile: return "local_file"
        case .unknown: return "unknown"
        }
    }

    /// Transcribes a user-picked local audio or video file. Bypasses URL parsing
    /// and runs the same audio → Whisper → TranscriptResult tail as the social URL flow.
    /// Caller is responsible for ending security-scoped resource access AFTER this returns.
    /// `isVideo` controls whether we attempt thumbnail extraction.
    func transcribeLocalFile(_ fileURL: URL, displayName: String, isVideo: Bool) async {
        await withBackgroundTask(name: "reserch.localfile") {
            await transcribeLocalFileInner(fileURL, displayName: displayName, isVideo: isVideo)
        }
    }

    private func transcribeLocalFileInner(_ fileURL: URL, displayName: String, isVideo: Bool) async {
        currentTask?.cancel()
        result = nil

        currentTask = Task {
            do {
                DebugLogger.shared.clear()
                let t0 = Date()
                rLog(step: "LocalFile", "Importing: \(fileURL.lastPathComponent) (\(displayName))")

                // Whisper model must be ready — same gate as the social audio path
                guard whisperTranscriber.isModelReady() else {
                    status = .needsModel
                    return
                }

                // Extract thumbnail in parallel with audio extraction, when relevant.
                async let thumbnailURL: URL? = isVideo ? VideoExtractor.extractThumbnail(from: fileURL) : nil

                status = .downloadingVideo(0.1)
                rLog(step: "LocalFile", "Extracting audio (audio passthrough or video → m4a)")
                let audioURL = try await VideoExtractor.extractAudioFromLocalFile(fileURL)
                rLog(.ok, step: "LocalFile", "Audio ready: \(audioURL.lastPathComponent)")

                status = .transcribing(0)
                rLog(step: "Whisper", "Starting transcription")
                let transcript = try await whisperTranscriber.transcribe(audioURL: audioURL) { p in
                    Task { @MainActor [weak self] in self?.status = .transcribing(p) }
                }
                rLog(.ok, step: "Whisper", "Done — \(transcript.count) chars")

                try? FileManager.default.removeItem(at: audioURL)
                let formatted = transcript.paragraphized()
                let thumb = await thumbnailURL

                if Task.isCancelled { return }

                let elapsed = String(format: "%.2fs", Date().timeIntervalSince(t0))
                rLog(.ok, step: "Total", "Local-file transcribe done in \(elapsed)")

                let transcriptResult = TranscriptResult(
                    title: displayName,
                    author: "",
                    handle: "",
                    platform: "Local File",
                    url: "",
                    caption: "",
                    transcript: formatted,
                    thumbnailURL: thumb
                )
                result = transcriptResult
                status = .done
                saveToHistory(transcriptResult)

            } catch is CancellationError {
                rLog(.warn, step: "Task", "Local-file transcribe cancelled")
                status = .idle
            } catch {
                rLog(.fail, step: "Error", "Local-file transcribe failed: \(error)")
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

        // Ask iOS for extra time to keep running after user backgrounds the app.
        // Expiration handler MUST cancel in-flight work AND end the task — otherwise
        // iOS may force-kill the process instead of suspending cleanly.
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "reserch.batch") { [weak self] in
            self?.currentTask?.cancel()
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        var saved = 0
        var failed = 0

        for (idx, url) in urls.enumerated() {
            batchCurrent += 1
            urlInput = url
            rLog(step: "Batch", "[\(batchCurrent)/\(batchTotal)] Starting \(url)")

            // Snapshot history size before fetching so we can detect a successful save
            // independent of the .status race that previously over-counted failures.
            let sizeBefore = history.count
            await fetchTranscript()
            let didSave = history.count > sizeBefore

            if didSave {
                saved += 1
                rLog(.ok, step: "Batch", "[\(batchCurrent)/\(batchTotal)] Saved")
                let lastTitle = history.first?.title
                NotificationManager.sendBatchProgress(current: saved, total: batchTotal, lastTitle: lastTitle)
            } else {
                failed += 1
                rLog(.fail, step: "Batch", "[\(batchCurrent)/\(batchTotal)] Failed (status: \(status))")
            }

            // Brief pause between iterations: lets any platform-side rate limit /
            // cookie / connection state settle before the next request. Negligible
            // user impact (1s on a 30-60s transcribe each).
            if idx < urls.count - 1 {
                try? await Task.sleep(for: .seconds(1))
            }
        }

        isBatchProcessing = false
        batchTotal = 0
        batchCurrent = 0
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }

        NotificationManager.sendBatchComplete(count: saved, failed: failed, playlistName: playlistName)
    }

    /// Public cancellation hook — used by sheets that need to abort an in-flight transcribe
    /// when the user dismisses (e.g. ImportMediaSheet's Cancel button).
    func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
        if !isBatchProcessing {
            status = .idle
        }
    }

    /// Wraps work in a `UIBackgroundTask` so iOS gives the app ~3 minutes of background
    /// time after the user locks/backgrounds the device. The expiration handler cancels
    /// the in-flight currentTask AND ends the background task — both required for iOS
    /// to consider the app a good citizen. Without canceling the work, iOS may force-kill
    /// the process instead of suspending cleanly.
    @MainActor
    private func withBackgroundTask<T>(name: String, _ work: () async throws -> T) async rethrows -> T {
        var bgTask = UIBackgroundTaskIdentifier.invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // iOS is about to suspend us. Cancel the work so it doesn't run partially
            // and leave state in a half-saved condition.
            self?.currentTask?.cancel()
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }
        return try await work()
    }

    func saveToHistory(_ result: TranscriptResult) {
        let entry = TranscriptEntry(result: result)
        history.insert(entry, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        saveHistoryAsync()

        // Magic moment milestones — Apple throttles to 3 prompts/year, so these are safe
        // to fire whenever they qualify. Order matters: earlier (more impressive) milestone
        // wins because promptedThisSession blocks the rest until next launch.
        if result.platform == "Local File" {
            ReviewPromptManager.shared.recordMilestone(.firstLocalFile)
        }
        if history.count == 5 {
            ReviewPromptManager.shared.recordMilestone(.fifthTranscript)
        }
        if history.count >= 10 && history.contains(where: { $0.notebookID != nil }) {
            ReviewPromptManager.shared.recordMilestone(.tenthOrganizedTranscript)
        }
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
        return MarkdownFormatter.format(entry.result, notebook: nb, notes: entry.documentNotes, template: ExportTemplatePrefs.shared, capturedAt: entry.date)
    }

    /// Compiles every transcript in `notebook` into a single markdown document, separated by `---`.
    /// Useful for piping a research topic into a single Obsidian note.
    func combinedMarkdown(for notebook: Notebook) -> String {
        let entries = transcripts(in: notebook)
        guard !entries.isEmpty else {
            return "# \(notebook.name)\n\n(No transcripts in this notebook yet.)\n"
        }
        var header = "# \(notebook.name)\n\n_\(entries.count) transcript\(entries.count == 1 ? "" : "s")_\n\n"
        if let desc = notebook.notebookDescription, !desc.isEmpty {
            header += "> \(desc.replacingOccurrences(of: "\n", with: "\n> "))\n\n"
        }
        header += "---\n\n"
        let body = entries.map { markdownFor($0) }.joined(separator: "\n\n---\n\n")
        return header + body
    }

    // MARK: - Persistence

    // Used by scenePhase handler — blocks intentionally so data survives process kill
    func saveHistory() {
        // safeWrite handles suspendSaves, round-trip validation, and rolling
        // backup rotation before overwriting the live file.
        Self.safeWrite(history, to: historyFileURL)
    }

    // Used for interactive mutations — off main thread so UI stays instant
    private func saveHistoryAsync() {
        let snapshot = history
        let url = historyFileURL
        Task.detached(priority: .utility) {
            Self.safeWrite(snapshot, to: url)
        }
    }

    @discardableResult
    private func loadHistory() -> Bool {
        print("[ReSerch] loadHistory called")
        guard let data = try? Data(contentsOf: historyFileURL) else {
            if Self.suspendSaves {
                print("[ReSerch] loadHistory — no file while write lock is active; refusing to treat as fresh")
                return false
            }
            print("[ReSerch] loadHistory — no file, starting fresh")
            return true
        }
        do {
            history = try JSONDecoder().decode([TranscriptEntry].self, from: data)
            print("[ReSerch] loadHistory — loaded \(history.count) entries")
            return true
        } catch {
            print("[ReSerch] loadHistory — decode FAILED: \(error)")
            rLog(.fail, step: "Load", "Decode failed: \(error)")
            // Try to recover from the most recent rolling backup before giving up.
            if let recovered = Self.recoverFromBackups(originalURL: historyFileURL, decode: { try JSONDecoder().decode([TranscriptEntry].self, from: $0) }) {
                history = recovered.payload
                print("[ReSerch] loadHistory — RECOVERED \(history.count) entries from backup \(recovered.sourceFile)")
                Self.lastRecoveryNote = "Recovered \(history.count) transcripts from backup (\(recovered.sourceFile)). Original file was quarantined."
                preserveCorruptFile(at: historyFileURL, label: "history")
                Self.suspendSaves = false
                Self.safeWrite(history, to: historyFileURL)
                return true
            }
            // No backup worked. Preserve the corrupt file, suspend writes,
            // surface a visible error so the user sees something is wrong
            // instead of an empty feed with no explanation.
            Self.suspendSaves = true
            preserveCorruptFile(at: historyFileURL, label: "history")
            history = []
            Self.corruptionAlert = "Couldn't read your transcripts file. It was preserved as a .corrupt.* backup in the app's iCloud container. Writes are frozen until this is resolved. Tap to view path."
            return false
        }
    }

    /// When `true`, every persistence write becomes a no-op. Set by load paths
    /// after they detect file corruption so subsequent in-memory mutations
    /// don't cascade into overwriting the (possibly still-recoverable) cloud
    /// copy with an empty / partial snapshot. Reset to false by an explicit
    /// repair flow, not by app lifecycle.
    private static let suspendSavesKey = "reserch.persistence.suspendSavesAfterCorruption.v1"

    nonisolated fileprivate static var suspendSaves: Bool {
        get { UserDefaults.standard.bool(forKey: suspendSavesKey) }
        set { UserDefaults.standard.set(newValue, forKey: suspendSavesKey) }
    }

    /// Set when a load failed and no backup recovered. ContentView observes
    /// this and shows a persistent red banner so the user sees the data
    /// problem instead of an empty feed with no explanation.
    static var corruptionAlert: String?

    /// Set when a load failed BUT a backup recovered the data. Shown as a
    /// yellow banner so the user knows something happened and they may want
    /// to verify the recovered state.
    static var lastRecoveryNote: String?

    /// Renames a corrupt persistence file to `<name>.corrupt.<timestamp>.json`
    /// in the same directory so it survives for diagnostic / recovery use
    /// instead of being permanently deleted by an autoclean.
    fileprivate static func preserveCorruptFile(at url: URL, label: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let quarantine = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent).corrupt.\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: quarantine)
            print("[ReSerch] loadHistory — quarantined corrupt \(label) file to \(quarantine.lastPathComponent)")
        } catch {
            print("[ReSerch] loadHistory — quarantine failed for \(label): \(error)")
        }
    }

    private func preserveCorruptFile(at url: URL, label: String) {
        Self.preserveCorruptFile(at: url, label: label)
    }

    // MARK: - Defense-in-depth save pipeline
    //
    // Three protections on every write:
    //   1. Round-trip validation: encode → decode → only commit if decode
    //      succeeds. Refuses to write a file the decoder can't read back.
    //   2. Rolling backups: rotates the existing file into
    //      `<name>.backup.1.json` through `.backup.5.json` in a sibling
    //      `.backups/` directory before each save. If today's save somehow
    //      goes bad, the previous 5 generations are still on disk.
    //   3. Quarantine on load failure (above) — never deletes user data.
    //
    // None of these protect against the user explicitly deleting the app
    // (Remove App on iOS wipes the entire container), but they remove every
    // silent-data-loss path inside the app itself.

    /// Returns `Documents/.backups/` (per the active sync target's docs dir),
    /// creating it if needed.
    nonisolated fileprivate static func backupsDirectory(for fileURL: URL) -> URL {
        let dir = fileURL.deletingLastPathComponent().appendingPathComponent(".backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Rotates `name.backup.1.json` → `name.backup.2.json`, etc., dropping the
    /// oldest generation, then copies the current live file into slot 1.
    /// Safe to call when the live file doesn't exist yet (skips the copy).
    nonisolated fileprivate static func rotateBackups(for liveURL: URL, generations: Int = 5) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: liveURL.path) else { return }
        let dir = backupsDirectory(for: liveURL)
        let base = liveURL.deletingPathExtension().lastPathComponent
        // Shuffle existing N..1: backup.5 gets dropped, backup.4 → 5, …, backup.1 → 2.
        for i in stride(from: generations - 1, through: 1, by: -1) {
            let src = dir.appendingPathComponent("\(base).backup.\(i).json")
            let dst = dir.appendingPathComponent("\(base).backup.\(i + 1).json")
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: src, to: dst)
            }
        }
        // Live file becomes the new slot 1.
        let slot1 = dir.appendingPathComponent("\(base).backup.1.json")
        try? fm.removeItem(at: slot1)
        try? fm.copyItem(at: liveURL, to: slot1)
    }

    /// Encodes `value`, validates the encoded data round-trips through the
    /// decoder, rotates backups, then writes atomically to `url`. Returns
    /// true on success; false if any step fails — in which case the live
    /// file is NOT modified (so a buggy encoder can't clobber good data).
    @discardableResult
    nonisolated fileprivate static func safeWrite<T: Codable>(_ value: T, to url: URL, as: T.Type = T.self) -> Bool {
        guard !suspendSaves else {
            print("[ReSerch] safeWrite — skipped (suspendSaves=true after corruption)")
            return false
        }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else {
            print("[ReSerch] safeWrite — encode failed for \(url.lastPathComponent)")
            return false
        }
        // Round-trip: refuse to write a file we can't read back.
        do {
            _ = try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("[ReSerch] safeWrite — REFUSED \(url.lastPathComponent), round-trip decode failed: \(error)")
            return false
        }
        // Rotate the live copy into the backup chain BEFORE overwriting.
        rotateBackups(for: url)
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            print("[ReSerch] safeWrite — atomic write failed for \(url.lastPathComponent): \(error)")
            return false
        }
    }

    /// Recovery utility: walks `.backups/<name>.backup.1.json` through `.5.json`
    /// (newest to oldest), returning the first one that decodes successfully.
    nonisolated fileprivate static func recoverFromBackups<T>(
        originalURL: URL,
        decode: (Data) throws -> T,
        generations: Int = 5
    ) -> (payload: T, sourceFile: String)? {
        let dir = backupsDirectory(for: originalURL)
        let base = originalURL.deletingPathExtension().lastPathComponent
        for i in 1...generations {
            let candidate = dir.appendingPathComponent("\(base).backup.\(i).json")
            guard let data = try? Data(contentsOf: candidate) else { continue }
            if let decoded = try? decode(data) {
                return (decoded, candidate.lastPathComponent)
            }
        }
        return nil
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
    func createNotebook(name: String, colorHex: String? = nil, notebookDescription: String? = nil) -> Notebook {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = notebookDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nb = Notebook(
            name: trimmed,
            colorHex: colorHex,
            notebookDescription: (trimmedDesc?.isEmpty ?? true) ? nil : trimmedDesc
        )
        notebooks.append(nb)
        sortNotebooks()
        saveNotebooksAsync()
        Analytics.shared.track(.notebookCreated, properties: [
            "has_description": !((trimmedDesc?.isEmpty) ?? true),
            "has_color": colorHex != nil,
            "total_count": notebooks.count
        ])
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

    func setNotebookDescription(_ notebook: Notebook, to description: String) {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let idx = notebooks.firstIndex(where: { $0.id == notebook.id }) else { return }
        notebooks[idx].notebookDescription = trimmed.isEmpty ? nil : trimmed
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
    /// Bumps `updatedAt` on both the source notebook (if any) and the destination
    /// so the "Recently Edited" sort reflects attach/detach actions.
    func assignNotebook(_ entry: TranscriptEntry, to notebook: Notebook?) {
        guard let idx = history.firstIndex(where: { $0.id == entry.id }) else { return }
        let oldNotebookID = history[idx].notebookID
        history[idx].notebookID = notebook?.id
        saveHistoryAsync()
        var touched = Set<UUID>()
        if let oldID = oldNotebookID { touched.insert(oldID) }
        if let newID = notebook?.id { touched.insert(newID) }
        for id in touched { touchNotebook(id) }
        if !touched.isEmpty { saveNotebooksAsync() }
    }

    /// Bulk-move version. Used by the multi-select bulkBar.
    func assignNotebook(_ entries: [TranscriptEntry], to notebook: Notebook?) {
        var touched = Set<UUID>()
        for entry in entries {
            if let idx = history.firstIndex(where: { $0.id == entry.id }) {
                if let oldID = history[idx].notebookID { touched.insert(oldID) }
                history[idx].notebookID = notebook?.id
            }
        }
        if let newID = notebook?.id { touched.insert(newID) }
        saveHistoryAsync()
        for id in touched { touchNotebook(id) }
        if !touched.isEmpty { saveNotebooksAsync() }
    }

    /// Bumps `updatedAt` on a notebook. Caller is responsible for persistence —
    /// callers that touch in a loop should save once at the end.
    private func touchNotebook(_ id: UUID) {
        guard let idx = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[idx].updatedAt = Date()
    }

    // MARK: - Document Notes (mini journal)

    /// Appends a new note to the entry's mini-journal and returns its id so callers
    /// can immediately put it into edit mode in the journal sheet.
    @discardableResult
    func addDocumentNote(_ entry: TranscriptEntry, text: String = "") -> UUID? {
        guard let idx = history.firstIndex(where: { $0.id == entry.id }) else { return nil }
        let note = DocumentNote(text: text, isPinned: false)
        history[idx].documentNotes.append(note)
        saveHistoryAsync()
        Analytics.shared.track(.documentNoteAdded, properties: [
            "note_count": history[idx].documentNotes.count
        ])
        return note.id
    }

    func updateDocumentNote(_ entry: TranscriptEntry, noteID: UUID, text: String) {
        guard let entryIdx = history.firstIndex(where: { $0.id == entry.id }) else { return }
        guard let noteIdx = history[entryIdx].documentNotes.firstIndex(where: { $0.id == noteID }) else { return }
        let oldLen = history[entryIdx].documentNotes[noteIdx].text.count
        history[entryIdx].documentNotes[noteIdx].text = text
        history[entryIdx].documentNotes[noteIdx].updatedAt = Date()
        saveHistoryAsync()
        // Only fire on non-empty meaningful edits — the picker fires this constantly during typing,
        // but we just want to know the user actually wrote something.
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count != oldLen {
            Analytics.shared.track(.documentNoteEdited, properties: [
                "char_count": text.count
            ])
        }
    }

    func removeDocumentNote(_ entry: TranscriptEntry, noteID: UUID) {
        guard let entryIdx = history.firstIndex(where: { $0.id == entry.id }) else { return }
        history[entryIdx].documentNotes.removeAll { $0.id == noteID }
        saveHistoryAsync()
    }

    /// Pins the named note. Enforces the single-pin invariant by clearing every
    /// other note's `isPinned` flag in the same atomic operation — the journal
    /// can never end up with two pinned notes after this call.
    func pinDocumentNote(_ entry: TranscriptEntry, noteID: UUID) {
        guard let entryIdx = history.firstIndex(where: { $0.id == entry.id }) else { return }
        for i in history[entryIdx].documentNotes.indices {
            history[entryIdx].documentNotes[i].isPinned = (history[entryIdx].documentNotes[i].id == noteID)
        }
        saveHistoryAsync()
        Analytics.shared.track(.documentNotePinned, properties: ["pinned": true])
    }

    func unpinDocumentNote(_ entry: TranscriptEntry, noteID: UUID) {
        guard let entryIdx = history.firstIndex(where: { $0.id == entry.id }) else { return }
        guard let noteIdx = history[entryIdx].documentNotes.firstIndex(where: { $0.id == noteID }) else { return }
        history[entryIdx].documentNotes[noteIdx].isPinned = false
        saveHistoryAsync()
        Analytics.shared.track(.documentNotePinned, properties: ["pinned": false])
    }

    /// Sort key for the Notebooks tab. Persisted across launches.
    enum NotebooksSortMode: String {
        case recent
        case manual
    }

    private static let sortModeKey = "notebooks.sortMode"

    /// Observable so the tab's Menu re-renders when the user flips modes.
    /// Setting it persists to UserDefaults and re-sorts in place.
    var notebooksSortMode: NotebooksSortMode = {
        let raw = UserDefaults.standard.string(forKey: TranscriptViewModel.sortModeKey)
            ?? NotebooksSortMode.recent.rawValue
        return NotebooksSortMode(rawValue: raw) ?? .recent
    }() {
        didSet {
            UserDefaults.standard.set(notebooksSortMode.rawValue, forKey: Self.sortModeKey)
            if notebooksSortMode == .manual {
                initializeManualOrderIfNeeded()
            }
            sortNotebooks()
        }
    }

    /// Branches on `notebooksSortMode`. Both branches use stable tiebreakers so
    /// notebooks with clustered timestamps don't reshuffle on every save.
    private func sortNotebooks() {
        switch notebooksSortMode {
        case .recent:
            notebooks.sort { a, b in
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        case .manual:
            notebooks.sort { a, b in
                switch (a.manualOrder, b.manualOrder) {
                case let (l?, r?):
                    if l != r { return l < r }
                case (.some, .none): return true
                case (.none, .some): return false
                case (.none, .none): break
                }
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        }
    }

    /// When the user first switches to Custom Order, seed every notebook's
    /// `manualOrder` from the currently visible (recent-sorted) array so the
    /// initial Custom view matches what they were looking at.
    private func initializeManualOrderIfNeeded() {
        guard notebooks.contains(where: { $0.manualOrder == nil }) else { return }
        // Snapshot the current display order under `.recent` rules before mutating.
        let recentOrdered: [UUID] = notebooks.sorted { a, b in
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }.map(\.id)
        for (position, id) in recentOrdered.enumerated() {
            if let idx = notebooks.firstIndex(where: { $0.id == id }) {
                notebooks[idx].manualOrder = position
            }
        }
        saveNotebooksAsync()
    }

    /// Drag-and-drop reorder. `movedID` lands directly before `targetID` in the
    /// visible array. Switches mode to `.manual` if currently `.recent`, then
    /// rewrites every `manualOrder` to its new index and persists.
    func reorderNotebook(_ movedID: UUID, before targetID: UUID) {
        guard movedID != targetID else { return }
        if notebooksSortMode == .recent {
            // Seeds manualOrder from the currently displayed (recent) order,
            // then flips mode without re-sorting.
            initializeManualOrderIfNeeded()
            UserDefaults.standard.set(NotebooksSortMode.manual.rawValue, forKey: Self.sortModeKey)
            // Bypass didSet to avoid double work — we're about to rewrite the order.
            // Direct property write still triggers @Observable observers.
            notebooksSortMode = .manual
        }
        // Work on the currently sorted display array (notebooks is already sorted).
        var display = notebooks
        guard let fromIdx = display.firstIndex(where: { $0.id == movedID }),
              let toIdx = display.firstIndex(where: { $0.id == targetID }) else { return }
        let moved = display.remove(at: fromIdx)
        let insertIdx = display.firstIndex(where: { $0.id == targetID }) ?? toIdx
        display.insert(moved, at: insertIdx)
        for (position, nb) in display.enumerated() {
            if let idx = notebooks.firstIndex(where: { $0.id == nb.id }) {
                notebooks[idx].manualOrder = position
            }
        }
        sortNotebooks()
        saveNotebooksAsync()
    }

    // MARK: - Notebook persistence

    func saveNotebooks() {
        Self.safeWrite(notebooks, to: notebooksFileURL)
    }

    private func saveNotebooksAsync() {
        let snapshot = notebooks
        let url = notebooksFileURL
        Task.detached(priority: .utility) {
            Self.safeWrite(snapshot, to: url)
        }
    }

    @discardableResult
    private func loadNotebooks() -> Bool {
        guard let data = try? Data(contentsOf: notebooksFileURL) else {
            if Self.suspendSaves {
                print("[ReSerch] loadNotebooks — no file while write lock is active; refusing to treat as fresh")
                return false
            }
            print("[ReSerch] loadNotebooks — no file, starting fresh")
            return true
        }
        do {
            notebooks = try JSONDecoder().decode([Notebook].self, from: data)
            sortNotebooks()
            print("[ReSerch] loadNotebooks — loaded \(notebooks.count) notebooks")
            return true
        } catch {
            print("[ReSerch] loadNotebooks — decode FAILED: \(error)")
            // Try rolling backups before quarantining + freezing writes.
            if let recovered = Self.recoverFromBackups(originalURL: notebooksFileURL, decode: { try JSONDecoder().decode([Notebook].self, from: $0) }) {
                notebooks = recovered.payload
                sortNotebooks()
                print("[ReSerch] loadNotebooks — RECOVERED \(notebooks.count) from backup \(recovered.sourceFile)")
                Self.lastRecoveryNote = "Recovered \(notebooks.count) notebooks from backup (\(recovered.sourceFile)). Original file was quarantined."
                preserveCorruptFile(at: notebooksFileURL, label: "notebooks")
                Self.suspendSaves = false
                Self.safeWrite(notebooks, to: notebooksFileURL)
                return true
            }
            Self.suspendSaves = true
            preserveCorruptFile(at: notebooksFileURL, label: "notebooks")
            notebooks = []
            Self.corruptionAlert = (Self.corruptionAlert ?? "") + " Notebooks file also unreadable."
            return false
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
