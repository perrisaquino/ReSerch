import SwiftUI

struct AddTranscriptView: View {
    @Bindable var vm: TranscriptViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var entryToShow: TranscriptEntry? = nil
    @State private var playlistURLToPreview: IdentifiedURL? = nil
    @FocusState private var fieldFocused: Bool

    // Parse valid URLs from the text field (one per line)
    private var detectedURLs: [String] {
        urlText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && URL(string: $0) != nil }
    }

    private var isBatch: Bool { detectedURLs.count > 1 }

    private var isDone: Bool {
        if case .done = vm.status, vm.result != nil { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea()

                VStack(spacing: 20) {
                    // URL input — hidden in done state so the success screen has full focus
                    if !isDone && !vm.isBatchProcessing {
                        HStack(alignment: .top, spacing: 10) {
                            TextField(
                                "Paste one or more links (one per line)...",
                                text: $urlText,
                                axis: .vertical
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .foregroundStyle(.white)
                            .lineLimit(1...6)
                            .focused($fieldFocused)
                            .onSubmit { if !isBatch { submit() } }

                            Button {
                                if let str = UIPasteboard.general.string {
                                    urlText = str.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            } label: {
                                Image(systemName: "doc.on.clipboard")
                                    .foregroundStyle(.gray)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 12))

                        // Badge when multiple links are detected
                        if isBatch {
                            HStack(spacing: 6) {
                                Image(systemName: "link.badge.plus")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Text("\(detectedURLs.count) links detected")
                                    .font(.caption)
                                    .foregroundStyle(Color.accentColor)
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            .offset(y: -8)
                        }
                    }

                    // Status / action area — isolated so the text field never re-renders
                    AddTranscriptStatusView(
                        vm: vm,
                        urlText: urlText,
                        isBatch: isBatch,
                        batchCount: detectedURLs.count,
                        onSubmit: submit,
                        onDismiss: {
                            vm.status = .idle
                            vm.result = nil
                            urlText = ""
                            dismiss()
                        },
                        onSeeTranscript: {
                            guard let entry = vm.history.first else { return }
                            vm.status = .idle
                            vm.result = nil
                            urlText = ""
                            entryToShow = entry
                        },
                        onAddAnother: {
                            vm.status = .idle
                            vm.result = nil
                            urlText = ""
                            fieldFocused = true
                        }
                    )

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .onAppear { fieldFocused = true }
                .onChange(of: vm.status) { _, newStatus in
                    // Dismiss keyboard when transcription finishes
                    if case .done = newStatus { fieldFocused = false }
                }
            }
            .navigationTitle(isDone ? "" : "Add Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isDone ? "Close" : "Cancel") {
                        vm.cancel()
                        vm.status = .idle
                        vm.result = nil
                        dismiss()
                    }
                    .foregroundStyle(.gray)
                }
            }
            .preferredColorScheme(.dark)
            .sheet(item: $entryToShow) { entry in
                TranscriptDetailView(entry: entry, vm: vm)
                    .onDisappear { dismiss() }
            }
            .sheet(item: $playlistURLToPreview) { wrapped in
                PlaylistPreviewView(
                    playlistURL: wrapped.url,
                    vm: vm,
                    onEnqueue: {
                        // Batch is running; dismiss the Add sheet so user returns to history
                        urlText = ""
                        playlistURLToPreview = nil
                        dismiss()
                    },
                    onCancel: {
                        playlistURLToPreview = nil
                    }
                )
            }
        }
    }

    private func submit() {
        if isBatch {
            Task { await vm.fetchBatch(rawText: urlText) }
            return
        }
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), PlatformRouter.isTikTokPlaylist(url) {
            playlistURLToPreview = IdentifiedURL(url: url)
            return
        }
        vm.urlInput = urlText
        Task { await vm.fetchTranscript() }
    }
}

// Identifiable wrapper so a URL can drive `.sheet(item:)`.
private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

// MARK: - Status child view

struct AddTranscriptStatusView: View {
    @Bindable var vm: TranscriptViewModel
    let urlText: String
    let isBatch: Bool
    let batchCount: Int
    let onSubmit: () -> Void
    let onDismiss: () -> Void
    let onSeeTranscript: () -> Void
    let onAddAnother: () -> Void

    @State private var quirkyIndex = 0
    @State private var signInProvider: TranscriptViewModel.SafariProvider? = nil

    private let fetchMessages = [
        "Looking up the video...",
        "Finding the good parts...",
        "Pulling things together...",
        "Tracking it down...",
        "Working on it...",
        "Almost there...",
        "Fetching the details...",
        "Getting everything ready...",
        "Just a moment...",
        "Pulling the metadata...",
        "One sec...",
        "Hold tight...",
        "Lining things up...",
        "Loading the video info...",
        "Setting things up...",
        "Closing in on it...",
    ]

    private let transcribeMessages = [
        "Listening very carefully...",
        "Cleaning up the audio...",
        "Catching every word...",
        "Reading between the lines...",
        "Spelling things out...",
        "Untangling the sentences...",
        "Polishing the punctuation...",
        "Sorting noise from signal...",
        "Almost got it...",
        "Getting the good parts...",
        "Hearing it out...",
        "Writing it down properly...",
        "Double-checking the tricky bits...",
        "Making sure nothing slipped through...",
        "Finding the rhythm of it...",
        "Tightening the loose words...",
        "Tidying things up...",
        "Letting it cook...",
        "Stitching it together...",
        "Nearly there...",
        "Reading it back to itself...",
        "Lining up the words...",
        "Just a sec, this part's interesting...",
        "Crossing the t's...",
        "Settling in...",
        "Wrapping up...",
    ]

    var body: some View {
        VStack(spacing: 16) {
            if vm.isBatchProcessing {
                batchProgressArea
            } else if case .needsModel = vm.status {
                modelBanner
            } else if case .done = vm.status, vm.result != nil {
                doneArea
            } else if vm.isLoading {
                // Exclusive loading branch — no competing fetch button
                singleLoadingArea
            } else {
                fetchButton
                if case .error(let msg) = vm.status {
                    errorBanner(msg)
                } else if case .needsSafariSignIn(let provider) = vm.status {
                    safariSignInBanner(provider)
                }
            }
        }
        .task(id: vm.isLoading) {
            guard vm.isLoading else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                quirkyIndex += 1
            }
        }
        .sheet(item: $signInProvider) { provider in
            InAppSignInSheet(provider: provider) {
                // After the sheet closes, immediately retry — pre-flight will pass if
                // the user actually signed in, or re-show the banner if they cancelled.
                Task { await vm.fetchTranscript() }
            }
        }
    }

    // MARK: Batch progress

    private var batchProgressArea: some View {
        VStack(spacing: 28) {
            // Step pills
            batchStepPills

            // Big "N of M" header
            VStack(spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(vm.batchCurrent)")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white)
                    Text("of")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("\(vm.batchTotal)")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Text("transcripts in flight")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .tracking(0.3)
            }

            // Current phase progress
            VStack(spacing: 10) {
                ProgressView(value: phaseProgress)
                    .tint(.accentColor)
                    .scaleEffect(x: 1, y: 1.2, anchor: .center)
                    .animation(.linear(duration: 0.3), value: phaseProgress)

                HStack {
                    Text(phaseTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    if phaseProgress > 0 {
                        Text("\(Int(phaseProgress * 100))%")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .padding(.horizontal, 4)

            // Cycled witty message
            Text(batchQuirkyMessage)
                .font(.system(size: 14, weight: .regular))
                .italic()
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .frame(minHeight: 44)
                .id("batch-\(quirkyIndex)-\(vm.batchCurrent)")
                .transition(.opacity)

            // Helper text
            HStack(spacing: 6) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 11))
                Text("Background the app — we'll ping you when it's done.")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.32))
            .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: quirkyIndex)
    }

    private var batchStepPills: some View {
        HStack(spacing: 6) {
            if vm.batchTotal <= 8 {
                ForEach(0..<vm.batchTotal, id: \.self) { i in
                    Capsule()
                        .fill(pillColor(forIndex: i))
                        .frame(width: i == vm.batchCurrent - 1 ? 24 : 8, height: 8)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: vm.batchCurrent)
                }
            } else {
                Capsule()
                    .fill(.white.opacity(0.08))
                    .overlay(
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * CGFloat(vm.batchCurrent) / CGFloat(vm.batchTotal))
                                .animation(.linear(duration: 0.3), value: vm.batchCurrent)
                        }
                    )
                    .frame(height: 6)
            }
        }
        .frame(height: 12)
    }

    private func pillColor(forIndex i: Int) -> Color {
        let current = vm.batchCurrent - 1
        if i < current { return .accentColor }
        if i == current { return .accentColor }
        return .white.opacity(0.12)
    }

    private var phaseProgress: Double {
        switch vm.status {
        case .downloadingVideo(let p): return p
        case .transcribing(let p): return p
        default: return 0
        }
    }

    private var phaseTitle: String {
        switch vm.status {
        case .fetchingCaptions: return "Fetching captions"
        case .downloadingVideo: return "Downloading video"
        case .transcribing: return "Transcribing audio"
        default: return "Working"
        }
    }

    private var batchQuirkyMessage: String {
        switch vm.status {
        case .fetchingCaptions, .downloadingVideo:
            return fetchMessages[quirkyIndex % fetchMessages.count]
        case .transcribing:
            return transcribeMessages[quirkyIndex % transcribeMessages.count]
        default:
            return fetchMessages[quirkyIndex % fetchMessages.count]
        }
    }

    private var phaseLabel: String {
        switch vm.status {
        case .fetchingCaptions: return "Fetching captions..."
        case .downloadingVideo(let p): return "Downloading \(Int(p * 100))%"
        case .transcribing(let p): return p > 0 ? "Transcribing \(Int(p * 100))%..." : "Transcribing..."
        default: return "Processing..."
        }
    }

    // MARK: Single loading card — replaces the double-spinner pattern

    private var singleLoadingArea: some View {
        VStack(spacing: 28) {
            // Phase step indicator (only for TikTok/Instagram which have 2 stages)
            if case .downloadingVideo = vm.status {
                phaseStepRow(phases: ["Download", "Transcribe"], activeIndex: 0)
            } else if case .transcribing = vm.status {
                phaseStepRow(phases: ["Download", "Transcribe"], activeIndex: 1)
            }

            // Progress + label
            VStack(spacing: 14) {
                switch vm.status {
                case .fetchingCaptions:
                    ProgressView().scaleEffect(1.1).tint(.accentColor)
                    Text(fetchMessages[quirkyIndex % fetchMessages.count])
                        .font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .id("fetch-\(quirkyIndex)")
                        .transition(.opacity)

                case .downloadingVideo(let p):
                    VStack(spacing: 8) {
                        ProgressView(value: p)
                            .tint(.accentColor)
                            .animation(.linear(duration: 0.3), value: p)
                        HStack {
                            Text("Downloading video")
                            Spacer()
                            Text("\(Int(p * 100))%")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                case .transcribing(let p):
                    VStack(spacing: 8) {
                        if p > 0 {
                            ProgressView(value: p)
                                .tint(Color(red: 0.3, green: 0.8, blue: 0.75))
                                .animation(.linear(duration: 0.3), value: p)
                            HStack {
                                Text("Transcribing audio")
                                Spacer()
                                Text("\(Int(p * 100))%")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        } else {
                            ProgressView().scaleEffect(1.1)
                                .tint(Color(red: 0.3, green: 0.8, blue: 0.75))
                            Text(transcribeMessages[quirkyIndex % transcribeMessages.count])
                                .font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .id("transcribe-\(quirkyIndex)")
                                .transition(.opacity)
                        }
                    }

                default:
                    ProgressView().scaleEffect(1.1).tint(.accentColor)
                }
            }
            .padding(.horizontal, 4)

            // Cancel — quiet text link, not a competing button
            Button("Cancel") { vm.cancel() }
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.4))
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private func phaseStepRow(phases: [String], activeIndex: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(phases.enumerated()), id: \.offset) { i, phase in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(i < activeIndex ? Color.green.opacity(0.25) : (i == activeIndex ? Color.accentColor.opacity(0.2) : Color(white: 0.15)))
                            .frame(width: 22, height: 22)
                        if i < activeIndex {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                        } else if i == activeIndex {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                        } else {
                            Circle()
                                .fill(Color(white: 0.3))
                                .frame(width: 7, height: 7)
                        }
                    }
                    Text(phase)
                        .font(.caption)
                        .fontWeight(i == activeIndex ? .semibold : .regular)
                        .foregroundStyle(i == activeIndex ? .white : Color(white: 0.4))
                }
                if i < phases.count - 1 {
                    Rectangle()
                        .fill(i < activeIndex ? Color.green.opacity(0.4) : Color(white: 0.15))
                        .frame(height: 1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                }
            }
        }
        .padding(.horizontal, 8)
    }

    // MARK: Single fetch button

    private var fetchButton: some View {
        Button {
            onSubmit()
        } label: {
            Text(buttonLabel)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var buttonLabel: String {
        if isBatch { return "Transcribe \(batchCount) Links" }
        switch vm.status {
        case .idle, .done: return "Get Transcript"
        case .error: return "Try Again"
        default: return "Get Transcript"
        }
    }

    private var doneArea: some View {
        VStack(spacing: 28) {
            // Success icon — centered, large, unambiguous
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 80, height: 80)
                    Image(systemName: "checkmark")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.green)
                }

                VStack(spacing: 6) {
                    Text("Transcript Saved")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                    Text("Ready in your feed")
                        .font(.subheadline)
                        .foregroundStyle(Color(white: 0.5))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)

            // Single primary CTA
            Button { onSeeTranscript() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                    Text("See Transcript").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }

            // Secondary action -- clearly lower weight
            Button { onAddAnother() } label: {
                Text("Add Another")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var modelBanner: some View {
        VStack(spacing: 10) {
            Text("TikTok, Instagram, and YouTube Shorts need a one-time engine download (~150MB). Stays on your phone after that.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await vm.downloadWhisperModel() }
            } label: {
                Group {
                    if vm.isDownloadingModel {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Downloading transcription engine")
                                    .font(.callout.weight(.semibold))
                                Spacer()
                                Text("\(Int(vm.modelDownloadProgress * 100))%")
                                    .font(.callout.monospacedDigit().weight(.semibold))
                            }
                            ProgressView(value: vm.modelDownloadProgress)
                                .tint(.white)
                            Text("Don't close the app — this is a one-time download")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle")
                            Text("Download Transcription Engine (~150MB)")
                                .fontWeight(.semibold)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .padding(.horizontal, 16)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .disabled(vm.isDownloadingModel)
        }
    }

    @ViewBuilder
    private func errorBanner(_ msg: String) -> some View {
        let recovery = recoveryActions(for: msg)
        EducationalBanner(
            tone: .warning,
            icon: "exclamationmark.triangle.fill",
            title: "Couldn't transcribe",
            message: msg,
            primary: recovery.primary,
            secondary: recovery.secondary
        )
    }

    private func safariSignInBanner(_ provider: TranscriptViewModel.SafariProvider) -> some View {
        EducationalBanner(
            tone: .info,
            icon: "person.badge.key.fill",
            title: "Sign in to \(provider.displayName)",
            message: "ReSerch needs an in-app sign-in so it can read \(provider.displayName) on your device. Your password never leaves the secure system sign-in form. One tap, and every link after that just works.",
            primary: .init(label: "Sign in") {
                signInProvider = provider
            },
            secondary: .init(label: "Try anyway") {
                Task { await vm.fetchTranscriptBypassingPreflight() }
            }
        )
    }

    /// Maps the raw error message string back to a contextual recovery pair. Stays simple
    /// (substring match) because `FetchStatus.error(String)` doesn't carry a typed error
    /// — the underlying errors live in different enums (`ExtractError`, `FetchError`, etc).
    private func recoveryActions(for message: String) -> (primary: EducationalBanner.Action?, secondary: EducationalBanner.Action?) {
        let lower = message.lowercased()
        let retry = EducationalBanner.Action(label: "Try again") {
            Task { await vm.fetchTranscript() }
        }

        // YouTube-specific paths first — these messages explicitly mention captions / blocking
        if lower.contains("captions") {
            return (
                EducationalBanner.Action(label: "Try a Shorts link") {},
                retry
            )
        }
        if lower.contains("rate-limiting") || lower.contains("blocked this request") {
            return (retry, nil)
        }

        // Cookie-related failures (post-pre-flight, e.g. expired session) — re-present the
        // in-app sign-in sheet for the platform the user is trying to transcribe.
        // The error description string is generic ("post may be private or require login"),
        // so we MUST inspect the URL host to pick the right provider — falling back to a
        // default would have offered Instagram sign-in for failed TikTok URLs.
        if lower.contains("private") || lower.contains("require login") || lower.contains("login") {
            let host = URL(string: vm.urlInput)?.host?.lowercased() ?? ""

            // TikTok and YouTube short URLs don't require auth in this app — TikTok scrapes
            // the public page; YouTube short URLs hit the public player. A "private/login"
            // failure on these domains is a parsing problem (e.g. unsupported post type),
            // not a session problem. Offer plain retry, never sign-in.
            if host.contains("tiktok.com") {
                return (retry, nil)
            }

            let provider: TranscriptViewModel.SafariProvider
            if host.contains("youtube.com") || host.contains("youtu.be") {
                provider = .youtube
            } else if host.contains("instagram.com") || host.contains("threads.net") {
                provider = .instagram
            } else {
                // Unknown host — don't guess. Just retry.
                return (retry, nil)
            }
            return (
                EducationalBanner.Action(label: "Sign in again") {
                    signInProvider = provider
                },
                retry
            )
        }

        // Network / generic
        if lower.contains("connection") || lower.contains("network") {
            return (retry, nil)
        }

        return (retry, nil)
    }
}
