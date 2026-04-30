import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ContentView: View {
    var vm: TranscriptViewModel
    @State private var showAdd = false
    @State private var selectedEntry: TranscriptEntry? = nil
    @State private var showSettings = false
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showMoveToNotebook = false
    @State private var singleMoveEntry: TranscriptEntry? = nil
    @State private var showImportSourceChooser = false
    @State private var showPhotosPicker = false
    @State private var showFilesPicker = false
    @State private var photoItem: PhotosPickerItem? = nil
    @State private var gate = ExportGate.shared
    @State private var showPaywall = false
    @State private var showOnboarding = !OnboardingView.hasCompleted

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                feedView
                if !selectionMode { addButton }
            }
            .navigationTitle("ReSerch")
            .navigationBarTitleDisplayMode(.large)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) {
                if selectionMode && !selectedIDs.isEmpty { bulkBar }
            }
            .sheet(isPresented: $showAdd) {
                AddTranscriptView(vm: vm)
            }
            .sheet(item: $selectedEntry) { entry in
                TranscriptDetailView(entry: entry, vm: vm)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showMoveToNotebook) {
                MoveToNotebookSheet(
                    vm: vm,
                    selectedIDs: selectedIDs,
                    onMoved: {
                        selectionMode = false
                        selectedIDs.removeAll()
                    }
                )
            }
            .sheet(item: $singleMoveEntry) { entry in
                MoveToNotebookSheet(vm: vm, selectedIDs: [entry.id])
            }
            .confirmationDialog("Import from", isPresented: $showImportSourceChooser, titleVisibility: .visible) {
                Button("Photos Library") { showPhotosPicker = true }
                Button("Files App") { showFilesPicker = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(
                isPresented: $showPhotosPicker,
                selection: $photoItem,
                matching: .videos,
                preferredItemEncoding: .current
            )
            .fileImporter(
                isPresented: $showFilesPicker,
                allowedContentTypes: [.audio, .movie, .mp3, .mpeg4Movie, .quickTimeMovie, .mpeg4Audio, .wav]
            ) { result in
                handleFileImport(result)
            }
            .onChange(of: photoItem) { _, newItem in
                guard let newItem else { return }
                Task { await handlePhotosPick(newItem) }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
        }
        .onChange(of: showPaywall) { _, newValue in
            NSLog("[ContentView] showPaywall → \(newValue)")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPaywall)) { _ in
            NSLog("[ContentView] received showPaywall notification (current=\(showPaywall))")
            guard !showPaywall else {
                NSLog("[ContentView] paywall already shown, ignoring")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NSLog("[ContentView] setting showPaywall = true")
                showPaywall = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in
            print("[ContentView] received showOnboarding notification")
            guard !showOnboarding else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                showOnboarding = true
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button(selectionMode ? "Cancel" : "Select") {
                selectionMode.toggle()
                selectedIDs.removeAll()
            }
            .foregroundStyle(selectionMode ? Color.accentColor : .secondary)
        }
    }

    private var bulkBar: some View {
        HStack(spacing: 12) {
                Button {
                    guard gate.canExport() else {
                        PaywallPresenter.present()
                        return
                    }
                    let markdown = vm.history
                        .filter { selectedIDs.contains($0.id) }
                        .map { vm.markdownFor($0) }
                        .joined(separator: "\n\n---\n\n")
                    UIPasteboard.general.string = markdown
                    gate.recordExport()
                    selectionMode = false
                    selectedIDs.removeAll()
                } label: {
                    Label("Copy \(selectedIDs.count) Transcript\(selectedIDs.count == 1 ? "" : "s")", systemImage: "doc.on.doc")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                }

                Button {
                    showMoveToNotebook = true
                } label: {
                    Image(systemName: "folder")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                        )
                }

                Button {
                    selectedIDs.forEach { id in
                        if let entry = vm.history.first(where: { $0.id == id }) {
                            vm.deleteEntry(entry)
                        }
                    }
                    selectionMode = false
                    selectedIDs.removeAll()
                } label: {
                    Image(systemName: "trash")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Feed

    private var feedView: some View {
        Group {
            if vm.history.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(vm.history) { entry in
                            TranscriptRow(
                                entry: entry,
                                isSelected: selectedIDs.contains(entry.id),
                                selectionMode: selectionMode,
                                notebook: vm.notebook(for: entry.notebookID),
                                onTap: {
                                    if selectionMode {
                                        if selectedIDs.contains(entry.id) {
                                            selectedIDs.remove(entry.id)
                                        } else {
                                            selectedIDs.insert(entry.id)
                                        }
                                    } else {
                                        selectedEntry = entry
                                    }
                                },
                                onCopy: { copyMarkdown(for: entry) },
                                onDelete: { vm.deleteEntry(entry) },
                                onRename: { vm.renameEntry(entry, to: $0) },
                                onMoveToNotebook: { singleMoveEntry = entry }
                            )
                            Divider()
                                .background(Color.white.opacity(0.08))
                        }
                    }
                }
            }
        }
        .background(Color(red: 0.07, green: 0.09, blue: 0.13))
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "text.quote")
                .font(.system(size: 56))
                .foregroundStyle(.quaternary)
            VStack(spacing: 8) {
                Text("No transcripts yet")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("Tap + to add a YouTube, TikTok, or Instagram link")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.07, green: 0.09, blue: 0.13))
    }

    // MARK: - Add Button

    private var addButton: some View {
        Menu {
            Button {
                showAdd = true
            } label: {
                Label("Paste URL", systemImage: "link")
            }
            Button {
                showImportSourceChooser = true
            } label: {
                Label("Import Audio or Video", systemImage: "waveform")
            }
        } label: {
            Image(systemName: "plus")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        }
        .padding(24)
        .sensoryFeedback(.selection, trigger: showAdd)
        .sensoryFeedback(.selection, trigger: showImportSourceChooser)
    }

    // MARK: - Local File Import

    /// Handles a `.fileImporter` selection. The Files-app URL is security-scoped, so we
    /// copy the file to our temp directory before handing it to the transcribe pipeline,
    /// then release the scope immediately.
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
            Task { await vm.transcribeLocalFile(copyURL, displayName: displayName) }
        case .failure(let error):
            print("[Import] file picker failed: \(error)")
        }
    }

    /// Handles a `PhotosPicker` selection. Loads the picked video as Data and writes it
    /// to a temp file before handing it to the transcribe pipeline.
    private func handlePhotosPick(_ item: PhotosPickerItem) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else {
            print("[Import] PhotosPicker returned no data")
            return
        }
        // PhotosPicker .videos returns a video; extension defaults to mov for Apple-captured video.
        // Use the item's suggestedName + supported types when available, otherwise fall back to .mov.
        let ext = "mov"
        let displayName = item.itemIdentifier.flatMap { _ in "Photos Video" } ?? "Photos Video"
        let tempDir = FileManager.default.temporaryDirectory
        let copyURL = tempDir.appendingPathComponent(UUID().uuidString + "." + ext)
        do {
            try data.write(to: copyURL, options: .atomic)
        } catch {
            print("[Import] failed to write Photos video to temp: \(error)")
            return
        }
        await vm.transcribeLocalFile(copyURL, displayName: displayName)
    }

    // MARK: - Actions

    private func copyMarkdown(for entry: TranscriptEntry) {
        print("[Copy] row copy tapped")
        guard gate.canExport() else {
            print("[Copy] gate blocked → showing paywall")
            PaywallPresenter.present()
            return
        }
        UIPasteboard.general.string = vm.markdownFor(entry)
        gate.recordExport()
    }

}

// MARK: - Row

struct TranscriptRow: View {
    let entry: TranscriptEntry
    var isSelected: Bool = false
    var selectionMode: Bool = false
    /// Optional notebook the entry belongs to. Drives the inline indicator chip.
    var notebook: Notebook? = nil
    let onTap: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    /// Triggered from the row's "..." menu. Caller decides how to present the move sheet.
    var onMoveToNotebook: (() -> Void)? = nil

    @State private var showCopied = false
    @State private var showRenameAlert = false
    @State private var renameText = ""

    private var platform: String { entry.result.platform }

    private var platformColor: Color {
        switch platform.lowercased() {
        case "youtube": return .red
        case "tiktok": return .pink
        case "instagram": return Color(red: 0.83, green: 0.25, blue: 0.75)
        default: return .blue
        }
    }

    private var platformIcon: String {
        switch platform.lowercased() {
        case "youtube": return "play.rectangle.fill"
        case "tiktok": return "music.note.tv.fill"
        case "instagram": return "camera.fill"
        default: return "link"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if selectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color.accentColor : Color(white: 0.35))
                    .padding(.top, 2)
            }
            thumbnail
            content
            Spacer(minLength: 0)
            if !selectionMode { menuButton }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color(red: 0.07, green: 0.09, blue: 0.13))
        .alert("Rename", isPresented: $showRenameAlert) {
            TextField("Title", text: $renameText)
            Button("Save") { if !renameText.trimmingCharacters(in: .whitespaces).isEmpty { onRename(renameText) } }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let url = entry.result.thumbnailURL {
                    CachedAsyncImage(url: url) { img in
                        if let img {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            placeholderThumb
                        }
                    }
                } else {
                    placeholderThumb
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // Video badge
            Image(systemName: "video.fill")
                .font(.system(size: 10))
                .foregroundStyle(.white)
                .padding(4)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .padding(4)
        }
    }

    private var placeholderThumb: some View {
        ZStack {
            platformColor.opacity(0.15)
            Image(systemName: platformIcon)
                .font(.system(size: 28))
                .foregroundStyle(platformColor.opacity(0.6))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Note title — primary
            Text(entry.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Author + platform — secondary
            HStack(spacing: 5) {
                Image(systemName: platformIcon)
                    .font(.system(size: 9))
                    .foregroundStyle(platformColor)
                Text(entry.result.author)
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.5))
                if !entry.result.handle.isEmpty {
                    Text(entry.result.handle)
                        .font(.caption)
                        .foregroundStyle(Color(white: 0.38))
                }
            }

            // Notebook chip + duration on one row when either is present
            if notebook != nil || entry.result.duration != nil {
                HStack(spacing: 8) {
                    if let nb = notebook {
                        HStack(spacing: 5) {
                            Capsule()
                                .fill(nb.color)
                                .frame(width: 3, height: 10)
                            Text(nb.name)
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.06), in: Capsule())
                    }
                    if let dur = entry.result.duration {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text(dur)
                        }
                        .font(.caption2)
                        .foregroundStyle(.gray)
                    }
                }
            }

            // Transcript preview
            if !entry.result.transcript.isEmpty {
                Text(entry.result.transcript)
                    .font(.caption)
                    .foregroundStyle(Color(white: 0.42))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var menuButton: some View {
        Menu {
            Button {
                onCopy()
                showCopied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    showCopied = false
                }
            } label: {
                Label(showCopied ? "Copied!" : "Copy Markdown", systemImage: showCopied ? "checkmark" : "doc.on.doc")
            }

            Button {
                renameText = entry.title
                showRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

            if let onMoveToNotebook {
                Button {
                    onMoveToNotebook()
                } label: {
                    Label(notebook == nil ? "Add to Notebook" : "Move to Notebook", systemImage: "folder")
                }
            }

            Button {
                let md = vm_markdown()
                let av = UIActivityViewController(activityItems: [md], applicationActivities: nil)
                if let popover = av.popoverPresentationController,
                   let window = UIApplication.shared.keyForegroundWindow {
                    popover.sourceView = window
                    popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.maxY - 60, width: 0, height: 0)
                    popover.permittedArrowDirections = []
                }
                if let root = UIApplication.shared.keyForegroundWindow?.rootViewController {
                    root.topmostPresentedViewController.present(av, animated: true)
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Divider()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16))
                .foregroundStyle(Color(white: 0.5))
                .padding(.vertical, 4)
        }
    }

    private func vm_markdown() -> String {
        MarkdownFormatter.format(entry.result)
    }
}
