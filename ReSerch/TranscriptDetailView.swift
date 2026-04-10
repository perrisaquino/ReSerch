import SwiftUI
import UIKit

struct TranscriptDetailView: View {
    @State var entry: TranscriptEntry
    var vm: TranscriptViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var isEditing = false
    @State private var editingText = ""
    @State private var editorActions = MarkdownEditorActions()
    @State private var videoHeight: CGFloat = 220
    @State private var dragBaseHeight: CGFloat = 220
    // @State on an @Observable object registers it as a dependency — view re-renders when colors change
    @State private var stylePrefs = MarkdownStylePrefs.shared
    @State private var showAnnotations = false
    @State private var pendingHighlightText: String?
    @State private var pendingHighlightOffset: Int?
    @State private var showNoteInput = false
    @State private var showEditorComment = false

    private var youTubeVideoId: String? {
        guard let url = URL(string: entry.result.url) else { return nil }
        if case .youtube(let id) = PlatformRouter.detect(url) { return id }
        return nil
    }

    private var tikTokVideoId: String? {
        guard let url = URL(string: entry.result.url) else { return nil }
        if case .tiktok = PlatformRouter.detect(url) {
            return PlatformRouter.extractTikTokID(from: url)
        }
        return nil
    }

    private var editableTitleBinding: Binding<String> {
        Binding(
            get: { entry.result.editableTitle },
            set: { entry.result.editableTitle = $0; vm.updateEntry(entry) }
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if isEditing {
                    focusedEditorView
                } else {
                    normalDetailView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { if !isEditing { bottomBar } }
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showAnnotations) {
                AnnotationsPanel(annotations: $entry.result.annotations, transcriptText: entry.result.transcript)
                    .onDisappear { vm.updateEntry(entry) }
            }
            .sheet(isPresented: $showNoteInput) {
                NoteInputSheet(highlightedText: pendingHighlightText ?? "") { comment in
                    let ann = Annotation(
                        text: pendingHighlightText ?? "",
                        comment: comment,
                        offset: pendingHighlightOffset ?? 0
                    )
                    entry.result.annotations.append(ann)
                    vm.updateEntry(entry)
                }
            }
            .sheet(isPresented: $showEditorComment) {
                NoteInputSheet(highlightedText: editorActions.pendingCommentText) { comment in
                    editorActions.insertComment(comment)
                }
            }
            .onChange(of: isEditing) { _, editing in
                if editing {
                    editorActions.onRequestComment = { showEditorComment = true }
                } else {
                    editorActions.onRequestComment = nil
                }
            }
        }
    }

    // Full-screen editor — nothing above it blocking scroll/editing
    private var focusedEditorView: some View {
        VStack(spacing: 0) {
            // Compact header so user knows what they're editing
            HStack {
                Text(entry.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text("\(editingText.split(separator: " ").count) words")
                    .font(.caption2)
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(red: 0.09, green: 0.11, blue: 0.15))

            Divider().background(Color.white.opacity(0.08))

            MarkdownTextEditor(text: $editingText, actions: editorActions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.07, green: 0.09, blue: 0.13))
        }
        .background(Color(red: 0.07, green: 0.09, blue: 0.13))
        .ignoresSafeArea(.container, edges: .bottom)
    }

    private var normalDetailView: some View {
        // ZStack lets the black background bleed to the bottom edge independently
        // of the content VStack, which must stay safe-area-aware so safeAreaInset
        // from the bottom bar actually pushes the ScrollView's content up.
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                if let videoId = youTubeVideoId {
                    YouTubePlayerView(videoId: videoId)
                        .frame(height: videoHeight)
                        .background(Color.black)
                    dragHandle
                } else if let videoId = tikTokVideoId {
                    TikTokPlayerView(videoId: videoId)
                        .frame(height: videoHeight)
                        .background(Color.black)
                    dragHandle
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if youTubeVideoId == nil && tikTokVideoId == nil { thumbnailSection }
                        contentSection
                    }
                }
                .scrollIndicators(.hidden)
                .background(Color(red: 0.07, green: 0.09, blue: 0.13))
            }
        }
    }

    private var dragHandle: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Color(white: 0.45))
                .frame(width: 40, height: 4)
            Spacer()
        }
        .frame(height: 22)
        .background(Color(red: 0.07, green: 0.09, blue: 0.13))
        .gesture(
            DragGesture()
                .onChanged { value in
                    let proposed = dragBaseHeight + value.translation.height
                    videoHeight = min(max(proposed, 160), 480)
                }
                .onEnded { _ in
                    dragBaseHeight = videoHeight
                }
        )
    }

    // MARK: - Thumbnail

    // Only used for non-YouTube entries (TikTok / Instagram thumbnail)
    private var thumbnailSection: some View {
        Group {
            if let url = entry.result.thumbnailURL {
                CachedAsyncImage(url: url) { img in
                    if let img {
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .frame(height: 220)
                            .clipped()
                    } else {
                        Color(white: 0.13).frame(height: 220)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    platformBadge.padding(12)
                }
                .overlay {
                    // Only show "Watch" overlay for Instagram (TikTok gets in-app player above)
                    if tikTokVideoId == nil, let videoURL = URL(string: entry.result.url) {
                        Button {
                            UIApplication.shared.open(videoURL)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 52))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .shadow(color: .black.opacity(0.5), radius: 8)
                                Text("Watch on \(entry.result.platform)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .shadow(color: .black.opacity(0.6), radius: 4)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contentShape(Rectangle())
            }
        }
    }

    private var platformBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: platformIcon)
                .font(.caption2)
            Text(entry.result.platform)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var platformIcon: String {
        switch entry.result.platform.lowercased() {
        case "youtube": return "play.rectangle.fill"
        case "tiktok": return "music.note.tv.fill"
        case "instagram": return "camera.fill"
        default: return "link"
        }
    }

    // MARK: - Content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Editable title
            TextField("Title", text: editableTitleBinding, axis: .vertical)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .lineLimit(3)

            // Author row — tap to open profile
            Button {
                if let url = profileURL { UIApplication.shared.open(url) }
            } label: {
                HStack(spacing: 8) {
                    Text(entry.result.author)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                    if !entry.result.handle.isEmpty {
                        Text(entry.result.handle)
                            .foregroundStyle(.gray)
                    }
                    if profileURL != nil {
                        Image(systemName: "arrow.up.right")
                            .font(.caption2)
                            .foregroundStyle(.gray)
                    }
                }
                .font(.subheadline)
            }
            .buttonStyle(.plain)

            // Stats row
            statsRow

            // Tappable video URL
            if let videoURL = URL(string: entry.result.url) {
                HStack(spacing: 10) {
                    Button {
                        UIApplication.shared.open(videoURL)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.circle")
                                .font(.caption)
                            Text("See Post")
                                .font(.caption)
                                .fontWeight(.medium)
                            Image(systemName: "arrow.up.right")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color.accentColor.opacity(0.9))
                    }
                    .buttonStyle(.plain)

                    Button {
                        UIPasteboard.general.string = entry.result.url
                    } label: {
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .padding(5)
                            .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }

            if !entry.result.caption.isEmpty {
                Divider().background(Color.white.opacity(0.1))
                captionSection
            }

            Divider().background(Color.white.opacity(0.1))
            transcriptSection
        }
        .padding(20)
    }

    private var statsRow: some View {
        HStack(spacing: 16) {
            if let posted = entry.result.postedDate {
                Label(DateFormatter.isoDate.string(from: posted), systemImage: "calendar")
            }
            if let dur = entry.result.duration {
                Label(dur, systemImage: "clock")
            }
            if let v = entry.result.viewCount {
                Label(shortCount(v), systemImage: "eye")
            }
            if let l = entry.result.likeCount {
                Label(shortCount(l), systemImage: "heart")
            }
            if let c = entry.result.commentCount {
                Label(shortCount(c), systemImage: "bubble.right")
            }
            if let s = entry.result.shareCount {
                Label(shortCount(s), systemImage: "bookmark")
            }
        }
        .font(.caption2)
        .foregroundStyle(.gray)
        .lineLimit(1)
    }

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Caption")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.gray)
                .textCase(.uppercase)
            Text(entry.result.caption)
                .font(.subheadline)
                .foregroundStyle(Color(white: 0.7))
                .textSelection(.enabled)
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transcript")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.gray)
                    .textCase(.uppercase)
                Spacer()
                Text("\(entry.result.transcript.split(separator: " ").count) words")
                    .font(.caption2)
                    .foregroundStyle(.gray)
                // Highlights button with count badge
                Button {
                    showAnnotations = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "highlighter")
                        if !entry.result.annotations.isEmpty {
                            Text("\(entry.result.annotations.count)")
                                .font(.caption2)
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(entry.result.annotations.isEmpty ? Color(white: 0.5) : Color.yellow.opacity(0.9))
                    .padding(6)
                    .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 6))
                }
                // Pencil edit button
                Button {
                    editingText = entry.result.transcript
                    isEditing = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.5))
                        .padding(6)
                        .background(Color(white: 0.15), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            AnnotableTranscriptView(
                text: entry.result.transcript,
                annotations: entry.result.annotations,
                onHighlight: { text, offset in
                    entry.result.annotations.append(Annotation(text: text, offset: offset))
                    vm.updateEntry(entry)
                },
                onAddNote: { text, offset in
                    pendingHighlightText   = text
                    pendingHighlightOffset = offset
                    showNoteInput = true
                }
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { dismiss() }
                .foregroundStyle(Color.accentColor)
        }
        if isEditing {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorActions.dismissKeyboard()
                    entry.result.transcript = editingText
                    vm.updateEntry(entry)
                    isEditing = false
                } label: {
                    Text("Done Editing")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 10) {
            // MD / Rich mode pill
            HStack(spacing: 0) {
                modeTab(label: "MD",   active: !stylePrefs.richTextMode) {
                    stylePrefs.richTextMode = false; stylePrefs.save()
                }
                modeTab(label: "Rich", active: stylePrefs.richTextMode) {
                    stylePrefs.richTextMode = true; stylePrefs.save()
                }
            }
            .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 8))

            // Copy button — full-width, proper button shape
            Button {
                if stylePrefs.richTextMode,
                   let attrStr = RichTextFormatter.build(entry.result) {
                    UIPasteboard.general.setObjects([attrStr])
                } else {
                    UIPasteboard.general.string = vm.markdownFor(entry)
                }
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(
                    copied ? "Copied!" : (stylePrefs.richTextMode ? "Copy Rich Text" : "Copy Markdown"),
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                )
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    copied ? Color.green.opacity(0.85) : Color(red: 0.10, green: 0.13, blue: 0.20),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(.white)
                .animation(.easeInOut(duration: 0.18), value: copied)
            }

            // Share button
            if stylePrefs.richTextMode,
               let attrStr = RichTextFormatter.build(entry.result),
               let rtfData = RichTextFormatter.rtfData(from: attrStr) {
                ShareLink(
                    item: RichText(data: rtfData),
                    preview: SharePreview(entry.title, image: Image(systemName: "doc.richtext"))
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.72))
                        .frame(width: 40, height: 40)
                        .background(Color(white: 0.14), in: Circle())
                }
            } else {
                ShareLink(
                    item: vm.markdownFor(entry),
                    preview: SharePreview(entry.title, image: Image(systemName: "doc.text"))
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.72))
                        .frame(width: 40, height: 40)
                        .background(Color(white: 0.14), in: Circle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    private func modeTab(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? .white : Color(white: 0.40))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    active ? Color(red: 0.10, green: 0.13, blue: 0.20) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: active)
    }

    private func shortCount(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    // Constructs a profile URL from handle + platform
    private var profileURL: URL? {
        let handle = entry.result.handle
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "@", with: "")
        guard !handle.isEmpty else { return nil }
        switch entry.result.platform.lowercased() {
        case "youtube":   return URL(string: "https://www.youtube.com/@\(handle)")
        case "tiktok":    return URL(string: "https://www.tiktok.com/@\(handle)")
        case "instagram": return URL(string: "https://www.instagram.com/\(handle)")
        default:          return nil
        }
    }
}
