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
    /// nil for whole-transcript highlights (regular video). Set when the in-progress
    /// highlight came from a carousel slide so the eventual Annotation gets the
    /// matching slideIndex.
    @State private var pendingHighlightSlideIndex: Int?
    @State private var showNoteInput = false
    @State private var showEditorComment = false
    @State private var showDocNoteEditor = false
    @State private var gate = ExportGate.shared
    @State private var showPaywall = false

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
        // Top-level ZStack so the side-peek panel can render ABOVE the entire
        // NavigationStack (toolbar included). Putting the overlays inside the
        // NavigationStack as before constrained them to its content area and let
        // the parent's "Done" toolbar leak through next to the panel — that was
        // the "Done Done" double-button bug.
        ZStack(alignment: .trailing) {
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
                .fullScreenCover(isPresented: $showPaywall) { PaywallView() }
                .sheet(isPresented: $showAnnotations) {
                    AnnotationsPanel(annotations: $entry.result.annotations, transcriptText: entry.result.transcript)
                        .onDisappear { vm.updateEntry(entry) }
                }
                .sheet(isPresented: $showNoteInput) {
                    NoteInputSheet(highlightedText: pendingHighlightText ?? "") { comment in
                        let ann = Annotation(
                            text: pendingHighlightText ?? "",
                            comment: comment,
                            offset: pendingHighlightOffset ?? 0,
                            slideIndex: pendingHighlightSlideIndex
                        )
                        entry.result.annotations.append(ann)
                        vm.updateEntry(entry)
                        // Magic moment: first time the user makes a transcript "theirs" by
                        // highlighting + commenting. Strong review trigger — they're emotionally
                        // invested at this exact moment.
                        if entry.result.annotations.count == 1 {
                            ReviewPromptManager.shared.recordMilestone(.firstAnnotation)
                        }
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

            // Backdrop dim — fades in/out. Tap to dismiss.
            if showDocNoteEditor {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { showDocNoteEditor = false }
                    .transition(.opacity)
            }

            // The panel itself — slides in from the trailing edge. Lives at the
            // top z-level so it covers the parent's nav bar (no more "Done Done"
            // double-button), runs edge-to-edge top to bottom, and presents its
            // own custom top bar internally.
            if showDocNoteEditor {
                sidePeekPanel
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: showDocNoteEditor)
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

    /// True when this transcript came from an Instagram carousel or TikTok photo set —
    /// drives the swipeable image strip header + clean per-slide rendering instead of
    /// the regular video player / static thumbnail / raw-markdown body.
    private var isCarouselTranscript: Bool {
        (entry.result.carouselSlides?.isEmpty == false)
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
                } else if isCarouselTranscript, let slides = entry.result.carouselSlides {
                    // Carousel posts: swipeable strip in place of the static thumbnail.
                    // Bound to the same `videoHeight` state video players use so the
                    // dragHandle below resizes the carousel exactly the way it resizes
                    // a YouTube / TikTok player — single consistent gesture.
                    CarouselSlidesStripView(slides: slides)
                        .frame(height: videoHeight)
                        .background(Color.black)
                    dragHandle
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Static thumbnail only when we have no richer media to show
                        // (no video player, no carousel strip).
                        if youTubeVideoId == nil && tikTokVideoId == nil && !isCarouselTranscript {
                            thumbnailSection
                        }
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
        if entry.result.platform.contains("Carousel") || entry.result.platform.contains("Photos") {
            return "square.stack"
        }
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

            Divider().background(Color.white.opacity(0.1))
            documentNoteSection

            if !entry.result.caption.isEmpty {
                Divider().background(Color.white.opacity(0.1))
                captionSection
            }

            Divider().background(Color.white.opacity(0.1))
            transcriptSection
        }
        .padding(20)
    }

    // MARK: - Document Notes (mini journal)

    @ViewBuilder
    private var documentNoteSection: some View {
        let notes = entry.documentNotes
        let pinned = notes.first(where: { $0.isPinned })
        let count = notes.count

        VStack(alignment: .leading, spacing: 10) {
            // Pinned-note preview sits ABOVE the button so it reads as a summary the
            // user attached to this transcript, mirroring the markdown export order
            // where the pinned note exports above the transcript section.
            if let pin = pinned, !pin.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pinnedNotePreview(pin)
            }

            Button {
                showDocNoteEditor = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: count == 0 ? "square.and.pencil" : "note.text")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Text(count == 0 ? "Add a transcript note" : "See transcript notes (\(count))")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.25))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func pinnedNotePreview(_ note: DocumentNote) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.yellow.opacity(0.85))
                Text("Pinned")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.gray)
                    .textCase(.uppercase)
            }
            Text(note.text)
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.92))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.yellow.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.yellow.opacity(0.18), lineWidth: 1)
                )
        }
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
                // Highlights button with count badge — hidden on carousel transcripts
                // because AnnotableTranscriptView (which annotations live in) isn't shown.
                if !isCarouselTranscript {
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
                }
                // Pencil edit button — drops into raw markdown editor for both regular
                // transcripts and carousels (lets user fix OCR mistakes).
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

            // Carousels: render structured slide blocks (no markdown noise).
            // Everything else: existing annotatable transcript view.
            if isCarouselTranscript, let slides = entry.result.carouselSlides {
                CarouselCleanTranscriptView(
                    slides: slides,
                    annotations: entry.result.annotations,
                    onHighlight: { text, offset, slideIndex in
                        entry.result.annotations.append(
                            Annotation(text: text, offset: offset, slideIndex: slideIndex)
                        )
                        vm.updateEntry(entry)
                        if entry.result.annotations.count == 1 {
                            ReviewPromptManager.shared.recordMilestone(.firstAnnotation)
                        }
                    },
                    onAddNote: { text, offset, slideIndex in
                        pendingHighlightText = text
                        pendingHighlightOffset = offset
                        pendingHighlightSlideIndex = slideIndex
                        showNoteInput = true
                    }
                )
            } else {
                AnnotableTranscriptView(
                    text: entry.result.transcript,
                    annotations: entry.result.annotations.filter { $0.slideIndex == nil },
                    onHighlight: { text, offset in
                        entry.result.annotations.append(
                            Annotation(text: text, offset: offset, slideIndex: nil)
                        )
                        vm.updateEntry(entry)
                        if entry.result.annotations.count == 1 {
                            ReviewPromptManager.shared.recordMilestone(.firstAnnotation)
                        }
                    },
                    onAddNote: { text, offset in
                        pendingHighlightText   = text
                        pendingHighlightOffset = offset
                        pendingHighlightSlideIndex = nil
                        showNoteInput = true
                    }
                )
            }
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
                    saveEditedTranscript()
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

    /// The trailing peek panel. Width caps at 82% of screen / 380pt — leaves an
    /// ~18% strip of the transcript visible. No nested NavigationStack: the panel
    /// renders its own custom top bar so we can put a vertical drag indicator on
    /// the leading edge (Apple Notes-style affordance for "this slides off").
    /// Edges flush against the screen, no rounded corners — matches iPadOS's
    /// trailing inspector pane convention.
    @ViewBuilder
    private var sidePeekPanel: some View {
        GeometryReader { proxy in
            let panelWidth = min(proxy.size.width * 0.82, 380)
            HStack(spacing: 0) {
                Spacer()
                ZStack(alignment: .leading) {
                    // Body
                    VStack(spacing: 0) {
                        sidePeekTopBar
                        DocumentNotesJournalSheet(
                            entry: $entry,
                            vm: vm,
                            onDismiss: { showDocNoteEditor = false },
                            chromeless: true
                        )
                    }
                    .frame(width: panelWidth)
                    .frame(maxHeight: .infinity)
                    .background(Color(red: 0.10, green: 0.12, blue: 0.16))

                    // Vertical drag indicator on the leading edge — mirrors the
                    // horizontal handle iOS puts on the top of bottom sheets.
                    // Visually signals "this surface can be dismissed by dragging."
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: 4, height: 36)
                        .padding(.leading, 6)
                }
                .shadow(color: .black.opacity(0.4), radius: 18, x: -6, y: 0)
            }
            .ignoresSafeArea()  // covers status bar + parent nav bar — no leak
            .gesture(
                // Swipe-right anywhere on the panel dismisses it. Matches iOS's
                // sheet-dismiss feel (drag-the-handle).
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        if value.translation.width > 60 {
                            showDocNoteEditor = false
                        }
                    }
            )
        }
    }

    /// Custom top bar inside the panel — replaces the nested NavigationStack's
    /// nav bar so we control the layout precisely. Drag indicator sits inside
    /// `sidePeekPanel`'s ZStack on the leading edge, separately. This bar shows
    /// the title and the + button, nothing else (no "Done" — the swipe + tap-
    /// outside dismiss handles that, per Apple's modal-dismissal patterns).
    private var sidePeekTopBar: some View {
        HStack {
            Text("Notes")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
            Spacer()
            Button {
                NotificationCenter.default.post(name: .reserchAddNote, object: nil)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Add note")
        }
        .padding(.horizontal, 16)
        .padding(.top, statusBarTopInset() + 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(
            Color(red: 0.10, green: 0.12, blue: 0.16)
                .overlay(
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                )
        )
    }

    /// Best-effort top safe-area inset (status bar + dynamic island). Used to
    /// pad the custom top bar so its content doesn't slide under the system UI.
    private func statusBarTopInset() -> CGFloat {
        let scenes = UIApplication.shared.connectedScenes
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
            return 44
        }
        return max(window.safeAreaInsets.top, 20)
    }

    /// Persists the editor's contents. For regular video transcripts this just writes
    /// the markdown blob back to `entry.result.transcript`. For carousels we ALSO
    /// parse the blob into per-slide text and update each slide's `recognizedText` —
    /// the carousel detail view (CarouselCleanTranscriptView) renders from the
    /// per-slide field, so without this propagation the user's edits would silently
    /// vanish from the main view despite being saved to disk.
    private func saveEditedTranscript() {
        entry.result.transcript = editingText

        if isCarouselTranscript, let slides = entry.result.carouselSlides {
            let perSlide = Self.parseSlideTexts(from: editingText, expectedCount: slides.count)
            entry.result.carouselSlides = slides.map { slide in
                var copy = slide
                if let updated = perSlide[slide.index] {
                    copy.recognizedText = updated
                }
                return copy
            }
        }

        vm.updateEntry(entry)
    }

    /// Parses an edited carousel-transcript markdown blob back into a [slideIndex: text]
    /// map. The format CarouselNoteFormatter / migrateCarouselTranscriptsV2 produces
    /// is `### Slide N` headings followed by an optional `![[file.jpg]]` embed line
    /// followed by the slide's text until the next heading. This parser matches that
    /// shape and is idempotent against the formatter — round-tripping a transcript
    /// through edit + save yields the same per-slide content.
    private static func parseSlideTexts(from markdown: String, expectedCount: Int) -> [Int: String] {
        var result: [Int: String] = [:]
        // Split on the slide heading. The heading pattern is "### Slide N" with N a
        // 1-based number; we capture the number for the dictionary key.
        let lines = markdown.components(separatedBy: "\n")
        var currentIndex: Int?
        var buffer: [String] = []

        func flush() {
            guard let i = currentIndex else { return }
            let text = buffer
                .drop { $0.trimmingCharacters(in: .whitespaces).hasPrefix("![[") } // strip image embed
                .map { $0 }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // The "*[no text detected]*" placeholder shouldn't be persisted as recognized
            // text — leave the slide's text empty so future renders show the placeholder
            // again from CarouselCleanTranscriptView's empty-text path.
            if text == "*[no text detected]*" {
                result[i] = ""
            } else {
                result[i] = text
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("### slide ") {
                flush()
                let remainder = trimmed.dropFirst("### slide ".count).trimmingCharacters(in: .whitespaces)
                // 1-based "Slide 1" → 0-based dict key
                if let n = Int(remainder), n >= 1 {
                    currentIndex = n - 1
                    buffer.removeAll()
                } else {
                    currentIndex = nil
                }
            } else if currentIndex != nil {
                buffer.append(line)
            }
        }
        flush()
        return result
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
                guard gate.canExport() else {
                    showPaywall = true
                    return
                }
                if stylePrefs.richTextMode,
                   let attrStr = RichTextFormatter.build(entry.result) {
                    UIPasteboard.general.setObjects([attrStr])
                } else {
                    UIPasteboard.general.string = vm.markdownFor(entry)
                }
                gate.recordExport()
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

            // Share button — gated; presents activity sheet only after gate check
            Button {
                guard gate.canExport() else {
                    showPaywall = true
                    return
                }
                presentShareSheet()
                gate.recordExport()
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(white: 0.72))
                    .frame(width: 40, height: 40)
                    .background(Color(white: 0.14), in: Circle())
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

    private func presentShareSheet() {
        let activityItems: [Any]
        if stylePrefs.richTextMode,
           let attrStr = RichTextFormatter.build(entry.result) {
            activityItems = [attrStr]
        } else {
            activityItems = [vm.markdownFor(entry)]
        }
        let av = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        // iPad popover anchor — required on iPad, harmless on iPhone.
        if let popover = av.popoverPresentationController,
           let window = UIApplication.shared.keyForegroundWindow {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        guard let root = UIApplication.shared.keyForegroundWindow?.rootViewController else { return }
        root.topmostPresentedViewController.present(av, animated: true)
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

    // Constructs a profile URL from handle + platform.
    // Carousel results store platform as `"Instagram (Carousel)"` / `"TikTok (Photos)"`
    // — substring-match against the lowercased value so those map correctly to
    // their respective profile URLs alongside the plain video platforms.
    private var profileURL: URL? {
        let handle = entry.result.handle
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "@", with: "")
        guard !handle.isEmpty else { return nil }
        let p = entry.result.platform.lowercased()
        if p.contains("youtube") {
            return URL(string: "https://www.youtube.com/@\(handle)")
        }
        if p.contains("tiktok") {
            return URL(string: "https://www.tiktok.com/@\(handle)")
        }
        if p.contains("instagram") {
            return URL(string: "https://www.instagram.com/\(handle)")
        }
        if p.contains("threads") {
            return URL(string: "https://www.threads.net/@\(handle)")
        }
        if p.contains("twitter") || p.contains("x.com") {
            return URL(string: "https://x.com/\(handle)")
        }
        return nil
    }
}

// MARK: - Document Note Editor

private struct DocumentNoteEditor: View {
    let initialText: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .background(Color(red: 0.07, green: 0.09, blue: 0.13))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Your overall takeaway, the question you watched it for, the connection back to a project — anything that frames this whole transcript.")
                                .font(.system(size: 15))
                                .foregroundStyle(.white.opacity(0.35))
                                .padding(.horizontal, 22)
                                .padding(.top, 20)
                                .allowsHitTesting(false)
                        }
                    }

                HStack {
                    Text("\(text.count) characters")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color(red: 0.09, green: 0.11, blue: 0.15))
            }
            .background(Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea())
            .navigationTitle("Document Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(text)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .preferredColorScheme(.dark)
            .onAppear {
                text = initialText
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    focused = true
                }
            }
        }
    }
}
