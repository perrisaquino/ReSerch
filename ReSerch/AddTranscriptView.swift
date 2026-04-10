import SwiftUI

struct AddTranscriptView: View {
    @Bindable var vm: TranscriptViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var entryToShow: TranscriptEntry? = nil
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
        }
    }

    private func submit() {
        if isBatch {
            Task { await vm.fetchBatch(rawText: urlText) }
        } else {
            vm.urlInput = urlText
            Task { await vm.fetchTranscript() }
        }
    }
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

    private let fetchMessages = [
        "Knocking on the server's door...",
        "Asking the internet nicely...",
        "Convincing the CDN to cooperate...",
        "Untangling the HTML soup...",
        "Extracting the good stuff...",
        "Locating the video data...",
        "Bribing the algorithm with compliments...",
        "Speed-reading the entire page...",
        "Pretending to be a browser, don't tell anyone...",
        "Parsing JSON with my bare hands...",
        "Following the redirects down the rabbit hole...",
        "Decrypting the URL they really didn't want me to find...",
        "The server is thinking. Servers need time too.",
        "Negotiating with the Content Delivery Network...",
        "Squinting at the page source...",
        "Copy-pasting from the internet, professionally...",
    ]

    private let transcribeMessages = [
        "Listening very carefully...",
        "Turning mouth sounds into words...",
        "Bribing the attention heads...",
        "82 million parameters doing their thing...",
        "Running mel spectrograms, whatever those are...",
        "Tokenizing your content...",
        "The model is concentrating, please hold...",
        "Decoding human speech soup...",
        "Finding the words between the words...",
        "WhisperKit is on it, promise...",
        "Converting vibes to text...",
        "Definitely not just making this up...",
        "Performing audio alchemy...",
        "Asking the transformer to transformer harder...",
        "Isolating syllables from background vibes...",
        "Turning waveforms into opinions...",
        "The GPU is sweating a little...",
        "Each token costs a tiny piece of my soul...",
        "Arguing with the beam search...",
        "The model read that part three times just to be sure...",
        "Speech recognition, but make it philosophical...",
        "Your words are being reconstructed from math...",
        "Counting spectrogram pixels like it's my job...",
        "At least it's not video captioning from 2014...",
        "Whisper says it's almost done. Whisper always says that.",
        "Assembling your transcript one hallucination at a time. Kidding. Mostly.",
        "This part usually goes faster. Usually.",
        "Some say the model still transcribes in there to this day...",
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
    }

    // MARK: Batch progress

    private var batchProgressArea: some View {
        VStack(spacing: 16) {
            ProgressView(value: Double(vm.batchCurrent), total: Double(vm.batchTotal))
                .tint(.accentColor)

            Text("Transcribing \(vm.batchCurrent) of \(vm.batchTotal)...")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if vm.isLoading {
                Text(phaseLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Text("You can background the app — you'll get a notification when done.")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
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
            Text("TikTok / Instagram needs a one-time transcription engine download (~150MB)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await vm.downloadWhisperModel() }
            } label: {
                HStack(spacing: 8) {
                    if vm.isDownloadingModel {
                        ProgressView().tint(.white).scaleEffect(0.85)
                        Text("Downloading... don't close the app")
                    } else {
                        Image(systemName: "arrow.down.circle")
                        Text("Download Transcription Engine (~150MB)")
                    }
                }
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.orange, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .disabled(vm.isDownloadingModel)
        }
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(msg).font(.footnote).foregroundStyle(.white)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }
}
