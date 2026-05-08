import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Sheet for importing a local audio or video file. Two-stage flow:
///   1. Source picker (Photos library / Files app for video; Files-only for audio)
///   2. Progress UI while extraction + Whisper transcription run
/// Auto-dismisses on completion. Stays open if the user backs out of the system picker.
struct ImportMediaSheet: View {
    enum Kind: String, Identifiable {
        case audio, video
        var id: String { rawValue }
        var title: String { self == .audio ? "Import Audio" : "Import Video" }
        var emptyHelper: String {
            self == .audio
                ? "Pick a voice memo, podcast episode, or any audio file from your Files."
                : "Pick a video from your Photos library or Files app."
        }
    }

    let kind: Kind
    var vm: TranscriptViewModel
    /// When non-nil, the imported transcript is auto-assigned to this notebook
    /// the moment vm.status hits .done. Used by NotebookDetailView's "Add New"
    /// flow so imported audio/video lands in the open notebook.
    var destinationNotebook: Notebook? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var showPhotosPicker = false
    @State private var showFilesPicker = false
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var importStarted = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea()

                if importStarted {
                    progressView
                } else {
                    sourcePicker
                }
            }
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        vm.cancelCurrentTask()
                        dismiss()
                    }
                }
            }
            .preferredColorScheme(.dark)
            .photosPicker(
                isPresented: $showPhotosPicker,
                selection: $photoItem,
                matching: .videos,
                preferredItemEncoding: .current
            )
            .fileImporter(
                isPresented: $showFilesPicker,
                allowedContentTypes: kind == .audio
                    ? [.audio, .mp3, .mpeg4Audio, .wav]
                    : [.movie, .mpeg4Movie, .quickTimeMovie]
            ) { result in
                handleFileImport(result)
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task { await handlePhotosPick(newItem) }
            }
            .onChange(of: vm.status) { _, newStatus in
                if case .done = newStatus, importStarted {
                    // Auto-assign to the destination notebook (if any) before
                    // the success-state delay + dismiss. saveToHistory inserts
                    // at index 0 so vm.history.first is the just-imported entry.
                    if let nb = destinationNotebook, let new = vm.history.first {
                        vm.assignNotebook(new, to: nb)
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(0.8))
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Source picker

    private var sourcePicker: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 8)

            Image(systemName: kind == .audio ? "waveform" : "video")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .padding(.top, 24)

            Text(kind.emptyHelper)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            VStack(spacing: 12) {
                if kind == .video {
                    sourceCard(
                        icon: "photo.on.rectangle.angled",
                        title: "Photos Library",
                        subtitle: "Pick a video you've recorded or saved"
                    ) { showPhotosPicker = true }
                }
                sourceCard(
                    icon: "folder",
                    title: "Files App",
                    subtitle: kind == .audio
                        ? "iCloud Drive, On My iPhone, or any synced location"
                        : "iCloud Drive, On My iPhone, or any synced location"
                ) { showFilesPicker = true }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
    }

    private func sourceCard(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36, height: 36)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Progress view

    private var progressView: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 8)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 84, height: 84)
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(Color.accentColor)
                    .scaleEffect(1.4)
            }

            VStack(spacing: 8) {
                Text(statusHeadline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(statusSubline)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if let progress = currentProgress {
                ProgressView(value: progress)
                    .tint(Color.accentColor)
                    .frame(maxWidth: 220)
                    .padding(.horizontal, 32)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.55))
            }

            Spacer()

            if case .done = vm.status {
                successMark
                    .padding(.bottom, 32)
            }
        }
    }

    private var successMark: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)
            Text("Done")
                .font(.headline)
                .foregroundStyle(.white)
        }
    }

    private var statusHeadline: String {
        switch vm.status {
        case .downloadingVideo: return "Preparing audio"
        case .transcribing: return "Transcribing"
        case .done: return "Done"
        case .error: return "Couldn't transcribe"
        default: return "Working..."
        }
    }

    private var statusSubline: String {
        switch vm.status {
        case .downloadingVideo:
            return kind == .video
                ? "Pulling the audio track out of your video"
                : "Reading the audio file"
        case .transcribing(let p):
            if p < 0.05 { return "Listening very carefully..." }
            if p < 0.5 { return "Catching every word..." }
            if p < 0.95 { return "Polishing punctuation..." }
            return "Wrapping up..."
        case .done: return "Saved to your feed"
        case .error(let msg): return msg
        default: return "Hang tight"
        }
    }

    private var currentProgress: Double? {
        switch vm.status {
        case .downloadingVideo(let p): return p
        case .transcribing(let p): return p
        default: return nil
        }
    }

    // MARK: - File handling

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

            let tempDir = FileManager.default.temporaryDirectory
            let copyURL = tempDir.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: copyURL)
            } catch {
                print("[Import] failed to copy from Files: \(error)")
                return
            }

            let displayName = url.deletingPathExtension().lastPathComponent
            importStarted = true
            Task {
                await vm.transcribeLocalFile(copyURL, displayName: displayName, isVideo: kind == .video)
            }
        case .failure(let error):
            print("[Import] file picker failed: \(error)")
        }
    }

    private func handlePhotosPick(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            print("[Import] PhotosPicker returned no data")
            return
        }
        let tempDir = FileManager.default.temporaryDirectory
        let copyURL = tempDir.appendingPathComponent(UUID().uuidString + ".mov")
        do {
            try data.write(to: copyURL, options: .atomic)
        } catch {
            print("[Import] failed to write Photos video to temp: \(error)")
            return
        }
        let displayName = "Photos Video"
        importStarted = true
        await vm.transcribeLocalFile(copyURL, displayName: displayName, isVideo: true)
    }
}
