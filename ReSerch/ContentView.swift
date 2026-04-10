import SwiftUI

struct ContentView: View {
    var vm: TranscriptViewModel
    @State private var showAdd = false
    @State private var selectedEntry: TranscriptEntry? = nil
    @State private var showDebug = false
    @State private var showSettings = false
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []

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
            .sheet(isPresented: $showDebug) {
                DebugView()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
        .preferredColorScheme(.dark)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showDebug = true } label: {
                Image(systemName: "ladybug")
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
                let markdown = vm.history
                    .filter { selectedIDs.contains($0.id) }
                    .map { vm.markdownFor($0) }
                    .joined(separator: "\n\n---\n\n")
                UIPasteboard.general.string = markdown
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
                                onRename: { vm.renameEntry(entry, to: $0) }
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
        Button {
            showAdd = true
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
    }

    // MARK: - Actions

    private func copyMarkdown(for entry: TranscriptEntry) {
        UIPasteboard.general.string = vm.markdownFor(entry)
    }

}

// MARK: - Row

struct TranscriptRow: View {
    let entry: TranscriptEntry
    var isSelected: Bool = false
    var selectionMode: Bool = false
    let onTap: () -> Void
    let onCopy: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void

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

            if let dur = entry.result.duration {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(dur)
                }
                .font(.caption2)
                .foregroundStyle(.gray)
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

            Button {
                let md = vm_markdown()
                let av = UIActivityViewController(activityItems: [md], applicationActivities: nil)
                if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let root = scene.windows.first?.rootViewController {
                    root.present(av, animated: true)
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
