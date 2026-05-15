import SwiftUI

struct ContentView: View {
    var vm: TranscriptViewModel
    @State private var showAdd = false
    @State private var selectedEntry: TranscriptEntry? = nil
    @State private var showSettings = false
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var showMoveToNotebook = false
    @State private var singleMoveEntry: TranscriptEntry? = nil
    @State private var importKind: ImportMediaSheet.Kind? = nil
    @State private var showTestimonialOffer = false
    @State private var gate = ExportGate.shared
    @State private var showPaywall = false
    @State private var showOnboarding = !OnboardingView.hasCompleted
    @State private var searchQuery: String = ""
    @State private var searchIsPresented: Bool = false
    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottomTrailing) {
                feedView
                if !selectionMode { addButton }
            }
            .navigationTitle("Transcripts")
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
            .sheet(item: $importKind) { kind in
                ImportMediaSheet(kind: kind, vm: vm)
            }
            .sheet(isPresented: $showTestimonialOffer) {
                TestimonialOfferSheet()
                    .presentationDetents([.height(280)])
                    .presentationDragIndicator(.visible)
            }
            .onReceive(NotificationCenter.default.publisher(for: .offerTestimonial)) { _ in
                // Posted by ReviewPromptManager ~6s after a high-tier review prompt fires.
                // Soft secondary ask — opt-in path into the existing Submit Feedback form
                // pre-set to .testimonial.
                showTestimonialOffer = true
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
            HStack(spacing: 14) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        searchIsPresented = true
                    }
                    searchFieldFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItem(placement: .topBarLeading) {
            Button(selectionMode ? "Cancel" : "Select") {
                selectionMode.toggle()
                selectedIDs.removeAll()
            }
            .foregroundStyle(selectionMode ? Color.accentColor : .secondary)
        }
        if selectionMode {
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected {
                        selectedIDs.removeAll()
                    } else {
                        // Select across the currently visible filtered set so a
                        // search query scopes the bulk action to what the user
                        // can actually see — matches iOS Mail / Photos behavior.
                        selectedIDs = Set(filteredHistory.map { $0.id })
                    }
                }
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    /// True when every visible (filtered) row is selected. Drives the
    /// Select All ↔ Deselect All toggle label and behavior.
    private var allSelected: Bool {
        let visible = filteredHistory
        return !visible.isEmpty && visible.allSatisfy { selectedIDs.contains($0.id) }
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
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.black)
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
        VStack(spacing: 0) {
            if searchIsPresented {
                searchBar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                if vm.history.isEmpty {
                    emptyState
                } else if filteredHistory.isEmpty {
                    noSearchResults
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredHistory) { entry in
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
        }
        .background(Color(red: 0.07, green: 0.09, blue: 0.13))
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchQuery)
                .focused($searchFieldFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.primary)
                .submitLabel(.search)
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button("Cancel") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    searchQuery = ""
                    searchIsPresented = false
                }
                searchFieldFocused = false
            }
            .foregroundStyle(Color.accentColor)
        }
        .font(.body)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(red: 0.09, green: 0.11, blue: 0.15))
        .overlay(alignment: .bottom) {
            Divider().background(Color.white.opacity(0.08))
        }
    }

    /// History filtered by the current search query. Matches case-insensitively
    /// across every field a user might be searching for: title, author/handle,
    /// transcript body, caption, document notes, annotation highlights and their
    /// comments, the notebook name, and carousel slide OCR text. An empty query
    /// returns the full history unchanged so feed performance is unaffected when
    /// search isn't active.
    private var filteredHistory: [TranscriptEntry] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return vm.history }
        return vm.history.filter { entry in entryMatches(entry, query: q) }
    }

    private func entryMatches(_ entry: TranscriptEntry, query: String) -> Bool {
        let r = entry.result
        let haystacks: [String?] = [
            r.title,
            r.editableTitle,
            r.author,
            r.handle,
            r.transcript,
            r.caption,
            vm.notebook(for: entry.notebookID)?.name
        ]
        for hay in haystacks {
            if let hay, hay.localizedCaseInsensitiveContains(query) { return true }
        }
        for note in entry.documentNotes {
            if note.text.localizedCaseInsensitiveContains(query) { return true }
        }
        for ann in r.annotations {
            if ann.text.localizedCaseInsensitiveContains(query) { return true }
            if ann.comment.localizedCaseInsensitiveContains(query) { return true }
        }
        if let slides = r.carouselSlides {
            for slide in slides {
                if let t = slide.recognizedText, t.localizedCaseInsensitiveContains(query) { return true }
            }
        }
        return false
    }

    private var noSearchResults: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 44))
                .foregroundStyle(.quaternary)
            VStack(spacing: 6) {
                Text("No matches")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Try a different word or check spelling.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                importKind = .audio
            } label: {
                Label("Import Audio", systemImage: "waveform")
            }
            Button {
                importKind = .video
            } label: {
                Label("Import Video", systemImage: "video")
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
        .sensoryFeedback(.selection, trigger: importKind)
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
        if platform.contains("Carousel") || platform.contains("Photos") {
            return "square.stack"
        }
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
                renameText = entry.title
                showRenameAlert = true
            } label: {
                Label("Rename", systemImage: "pencil")
            }

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
