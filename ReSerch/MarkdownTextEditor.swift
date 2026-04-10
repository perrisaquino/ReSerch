import SwiftUI
import UIKit

// MARK: - MarkdownStyling

enum MarkdownStyling {

    // Compiled once per process
    fileprivate static let rxBold        = try? NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#,                       options: .dotMatchesLineSeparators)
    fileprivate static let rxItalic      = try? NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, options: .dotMatchesLineSeparators)
    fileprivate static let rxHL          = try? NSRegularExpression(pattern: #"==(.+?)=="#,                            options: .dotMatchesLineSeparators)
    fileprivate static let rxCode        = try? NSRegularExpression(pattern: #"`(.+?)`"#,                             options: .dotMatchesLineSeparators)
    fileprivate static let rxStrike      = try? NSRegularExpression(pattern: #"~~(.+?)~~"#,                           options: .dotMatchesLineSeparators)
    fileprivate static let rxWiki        = try? NSRegularExpression(pattern: #"\[\[(.+?)\]\]"#,                       options: .dotMatchesLineSeparators)
    // Footnote inline ref [^1] — hides when cursor not nearby, like other markers
    fileprivate static let rxFootnoteRef = try? NSRegularExpression(pattern: #"\[\^(\d+)\]"#,                         options: [])
    // Footnote definition [^1]: text — dims in editor, hides in read-only
    fileprivate static let rxFootnoteDef = try? NSRegularExpression(pattern: #"\[\^(\d+)\]: .+"#,                     options: .anchorsMatchLines)

    /// Build styled attributed string + collect all match ranges in a single regex pass.
    /// Returns (attributedString, allMatchRanges) so callers don't need a second pass
    /// to build the cache for cursor-proximity detection.
    static func attributedWithRanges(
        _ raw: String,
        cursorAt cursor: Int? = nil
    ) -> (NSAttributedString, [NSRange]) {
        let attr  = NSMutableAttributedString(string: raw)
        let full  = NSRange(location: 0, length: (raw as NSString).length)
        var allRanges: [NSRange] = []

        attr.addAttribute(.font,            value: UIFont.systemFont(ofSize: 16, weight: .regular), range: full)
        attr.addAttribute(.foregroundColor, value: UIColor(white: 0.85, alpha: 1),                  range: full)

        let boldFont   = UIFont.systemFont(ofSize: 16, weight: .bold)
        let italicFont = UIFont.systemFont(ofSize: 16, weight: .regular).fontDescriptor
                           .withSymbolicTraits(.traitItalic)
                           .map { UIFont(descriptor: $0, size: 16) } ?? UIFont.italicSystemFont(ofSize: 16)
        let monoFont   = UIFont.monospacedSystemFont(ofSize: 15, weight: .regular)
        let dimMarker  = UIColor(white: 0.4, alpha: 1)
        let prefs      = MarkdownStylePrefs.shared

        func apply(_ regex: NSRegularExpression?, content: [NSAttributedString.Key: Any]) {
            guard let regex else { return }
            let matches = regex.matches(in: raw, range: full)
            // Collect for match-range cache
            for m in matches { allRanges.append(m.range(at: 0)) }
            // Apply in reverse so earlier indices aren't invalidated
            for match in matches.reversed() {
                guard match.numberOfRanges >= 2 else { continue }
                let matchRange   = match.range(at: 0)
                let contentRange = match.range(at: 1)
                guard contentRange.location != NSNotFound,
                      matchRange.location   != NSNotFound else { continue }

                for (key, val) in content {
                    attr.addAttribute(key, value: val, range: contentRange)
                }

                let cursorInside = cursor.map {
                    $0 >= matchRange.location && $0 <= matchRange.location + matchRange.length
                } ?? false

                // Hidden: zero-width font so markers take no horizontal space.
                // Visible (cursor inside): dim color at normal 16pt so they're editable.
                let markerColor: UIColor = cursorInside ? dimMarker : .clear
                let markerFont: UIFont   = cursorInside
                    ? UIFont.systemFont(ofSize: 16, weight: .regular)
                    : UIFont.systemFont(ofSize: 0.001, weight: .regular)

                let prefixLen = contentRange.location - matchRange.location
                if prefixLen > 0 {
                    let r = NSRange(location: matchRange.location, length: prefixLen)
                    attr.addAttribute(.foregroundColor, value: markerColor, range: r)
                    attr.addAttribute(.font,            value: markerFont,  range: r)
                }
                let suffixStart = contentRange.location + contentRange.length
                let suffixLen   = (matchRange.location + matchRange.length) - suffixStart
                if suffixLen > 0 {
                    let r = NSRange(location: suffixStart, length: suffixLen)
                    attr.addAttribute(.foregroundColor, value: markerColor, range: r)
                    attr.addAttribute(.font,            value: markerFont,  range: r)
                }
            }
        }

        apply(rxBold,   content: [.font: boldFont, .foregroundColor: prefs.boldColor])
        apply(rxItalic, content: [.font: italicFont])
        apply(rxHL,     content: [.backgroundColor: prefs.highlightColor.withAlphaComponent(0.30)])
        apply(rxCode,   content: [.font: monoFont, .foregroundColor: UIColor(red: 0.3, green: 0.8, blue: 0.75, alpha: 1)])
        apply(rxStrike, content: [.strikethroughStyle: 1, .strikethroughColor: UIColor(white: 0.85, alpha: 1)])
        apply(rxWiki,   content: [.foregroundColor: prefs.wikilinkColor])

        // Footnote inline refs [^N] — hide entire token when cursor not inside.
        // rxFootnoteDef is applied after so it overrides [^1] hiding inside definition lines.
        if let rx = rxFootnoteRef {
            for m in rx.matches(in: raw, range: full).reversed() {
                let r = m.range(at: 0)
                guard r.location != NSNotFound else { continue }
                allRanges.append(r)
                let inside = cursor.map { $0 >= r.location && $0 <= r.location + r.length } ?? false
                attr.addAttribute(.foregroundColor, value: inside ? dimMarker : UIColor.clear, range: r)
                attr.addAttribute(.font, value: UIFont.systemFont(ofSize: inside ? 11 : 0.001, weight: .regular), range: r)
            }
        }

        // Footnote definitions [^N]: text — dim in editor, hide in read-only view.
        // Applied after rxFootnoteRef so it overrides the hiding on the [^N] prefix of each definition.
        if let rx = rxFootnoteDef {
            for m in rx.matches(in: raw, range: full) {
                let r = m.range(at: 0)
                guard r.location != NSNotFound else { continue }
                if cursor != nil {
                    // Editor: show dimmed so user can see/edit their notes
                    attr.addAttribute(.foregroundColor, value: UIColor(white: 0.35, alpha: 1), range: r)
                    attr.addAttribute(.font, value: UIFont.systemFont(ofSize: 14, weight: .regular), range: r)
                } else {
                    // Read-only transcript: hide — they're shown in the annotations panel instead
                    attr.addAttribute(.foregroundColor, value: UIColor.clear, range: r)
                    attr.addAttribute(.font, value: UIFont.systemFont(ofSize: 0.001, weight: .regular), range: r)
                }
            }
        }

        return (attr, allRanges)
    }

    /// Convenience for the read-only transcript view — no cursor, always hide markers.
    /// Pass `prefs` so SwiftUI tracks the dependency and re-renders when colors change.
    static func swiftUIAttributed(_ raw: String, prefs: MarkdownStylePrefs = .shared) -> AttributedString {
        let (ns, _) = attributedWithRanges(raw)
        return (try? AttributedString(ns, including: \.uiKit)) ?? AttributedString(raw)
    }
}

// MARK: - Editor Actions

@Observable
final class MarkdownEditorActions {
    weak var textView: UITextView?
    var canUndo: Bool = false
    var canRedo: Bool = false

    func wrap(prefix: String, suffix: String) {
        guard let tv = textView,
              let range = tv.selectedTextRange else { return }
        if range.isEmpty {
            tv.replace(range, withText: prefix + suffix)
            if let cur = tv.selectedTextRange,
               let pos = tv.position(from: cur.start, offset: -suffix.count) {
                tv.selectedTextRange = tv.textRange(from: pos, to: pos)
            }
        } else {
            let selected = tv.text(in: range) ?? ""
            tv.replace(range, withText: prefix + selected + suffix)
        }
        refreshUndoState()
    }

    func undo() {
        textView?.undoManager?.undo()
        refreshUndoState()
    }

    func redo() {
        textView?.undoManager?.redo()
        refreshUndoState()
    }

    var onRequestComment: (() -> Void)?
    var pendingCommentText: String = ""
    private var pendingCommentInsertPosition: Int? = nil

    func requestComment() {
        guard let tv = textView, let range = tv.selectedTextRange,
              !range.isEmpty else { return }
        let selectedText = tv.text(in: range) ?? ""
        guard !selectedText.isEmpty else { return }
        tv.replace(range, withText: "==\(selectedText)==")
        // Store the position immediately after ==text== — footnote ref goes here
        pendingCommentInsertPosition = tv.selectedRange.location
        pendingCommentText = selectedText
        refreshUndoState()
        onRequestComment?()
    }

    func insertComment(_ comment: String) {
        defer {
            pendingCommentInsertPosition = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.textView?.becomeFirstResponder()
            }
        }
        guard let tv = textView, !comment.isEmpty,
              let refInsertPos = pendingCommentInsertPosition else { return }

        let n = nextFootnoteNumber(in: tv.text ?? "")

        // Step 1: insert [^N] right after ==text==
        guard let refStart = tv.position(from: tv.beginningOfDocument, offset: refInsertPos),
              let refRange  = tv.textRange(from: refStart, to: refStart) else { return }
        tv.replace(refRange, withText: "[^\(n)]")

        // Step 2: append [^N]: comment at the end of the document
        let updatedText = tv.text ?? ""
        let endOffset   = (updatedText as NSString).length
        guard let endPos   = tv.position(from: tv.beginningOfDocument, offset: endOffset),
              let endRange = tv.textRange(from: endPos, to: endPos) else { return }

        let prefix: String
        if updatedText.hasSuffix("\n\n") { prefix = "" }
        else if updatedText.hasSuffix("\n") { prefix = "\n" }
        else { prefix = "\n\n" }

        tv.replace(endRange, withText: "\(prefix)[^\(n)]: \(comment)")
        refreshUndoState()
    }

    private func nextFootnoteNumber(in text: String) -> Int {
        guard let rx = try? NSRegularExpression(pattern: #"\[\^(\d+)\]:"#) else { return 1 }
        let ns      = text as NSString
        let matches = rx.matches(in: text, range: NSRange(location: 0, length: ns.length))
        let numbers = matches.compactMap { m -> Int? in
            let r = m.range(at: 1)
            guard r.location != NSNotFound else { return nil }
            return Int(ns.substring(with: r))
        }
        return (numbers.max() ?? 0) + 1
    }

    func dismissKeyboard() { textView?.resignFirstResponder() }

    func refreshUndoState() {
        canUndo = textView?.undoManager?.canUndo ?? false
        canRedo = textView?.undoManager?.canRedo ?? false
    }
}

// MARK: - UIViewRepresentable

struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    var actions: MarkdownEditorActions

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.backgroundColor = .clear
        tv.isScrollEnabled = true
        tv.isEditable = true
        tv.isSelectable = true
        tv.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        tv.textContainer.lineFragmentPadding = 0
        tv.autocorrectionType = .default
        tv.autocapitalizationType = .sentences
        tv.smartQuotesType = .no

        let (attributed, ranges) = MarkdownStyling.attributedWithRanges(text)
        tv.attributedText = attributed
        context.coordinator.cachedMatchRanges = ranges

        let toolbarVC = UIHostingController(
            rootView: MarkdownToolbar(actions: actions).preferredColorScheme(.dark)
        )
        toolbarVC.view.frame = CGRect(x: 0, y: 0, width: UIScreen.screens.first?.bounds.width ?? 390, height: 52)
        toolbarVC.view.backgroundColor = UIColor(red: 0.09, green: 0.11, blue: 0.15, alpha: 1)
        tv.inputAccessoryView = toolbarVC.view
        context.coordinator.toolbarVC = toolbarVC

        actions.textView = tv
        DispatchQueue.main.async { tv.becomeFirstResponder() }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // Never touch textStorage while applyFormatting has an open beginEditing transaction
        guard !context.coordinator.isUpdatingAttributes else {
            actions.textView = uiView
            return
        }
        context.coordinator.actions = actions
        if uiView.text != text {
            let saved = uiView.selectedRange
            let (attributed, ranges) = MarkdownStyling.attributedWithRanges(text, cursorAt: saved.location)
            uiView.attributedText = attributed
            context.coordinator.cachedMatchRanges = ranges
            let len = (uiView.text as NSString).length
            uiView.selectedRange = NSRange(location: min(saved.location, len), length: 0)
        }
        actions.textView = uiView
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, actions: actions) }

    // MARK: Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var actions: MarkdownEditorActions
        var toolbarVC: AnyObject?
        var cachedMatchRanges: [NSRange] = []

        var isUpdatingAttributes = false
        private var isHandlingSelectionChange = false
        private var lastActiveRange: NSRange? = nil
        private var formatTimer: Timer?

        init(text: Binding<String>, actions: MarkdownEditorActions) {
            self.text = text
            self.actions = actions
        }

        deinit {
            formatTimer?.invalidate()
            formatTimer = nil
        }

        func textViewDidChange(_ textView: UITextView) {
            // Sync binding immediately — zero keystroke lag
            text.wrappedValue = textView.text ?? ""
            actions.refreshUndoState()

            // Debounce formatting: only runs 250ms after typing stops
            formatTimer?.invalidate()
            formatTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self, weak textView] _ in
                self?.formatTimer = nil
                guard let tv = textView else { return }
                self?.applyFormatting(to: tv)
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdatingAttributes && !isHandlingSelectionChange else { return }
            guard formatTimer == nil else { return } // actively typing, let debounce handle it

            isHandlingSelectionChange = true
            defer { isHandlingSelectionChange = false }

            let cursor = textView.selectedRange.location
            let active = activeRange(at: cursor)
            let unchanged = active?.location == lastActiveRange?.location
                         && active?.length   == lastActiveRange?.length
            guard !unchanged else { return }
            lastActiveRange = active
            applyFormatting(to: textView)
        }

        // textStorage.setAttributes doesn't reset cursor — much faster than attributedText setter
        private func applyFormatting(to textView: UITextView) {
            guard !isUpdatingAttributes else { return }
            let raw    = textView.text ?? ""
            let nsLen  = (raw as NSString).length
            // Guard: textStorage and our string must agree on length before we touch it
            guard textView.textStorage.length == nsLen else { return }

            isUpdatingAttributes = true
            let cursor = textView.selectedRange.location
            let (attributed, ranges) = MarkdownStyling.attributedWithRanges(raw, cursorAt: cursor)
            let fullRange = NSRange(location: 0, length: nsLen)
            textView.textStorage.beginEditing()
            attributed.enumerateAttributes(in: fullRange, options: []) { attrs, range, _ in
                textView.textStorage.setAttributes(attrs, range: range)
            }
            textView.textStorage.endEditing()
            cachedMatchRanges = ranges
            lastActiveRange   = activeRange(at: cursor)
            isUpdatingAttributes = false
        }

        private func activeRange(at cursor: Int) -> NSRange? {
            cachedMatchRanges.first { r in
                cursor >= r.location && cursor <= r.location + r.length
            }
        }
    }
}

// MARK: - Markdown Toolbar

private struct MarkdownToolbar: View {
    var actions: MarkdownEditorActions

    private enum Icon {
        case systemImage(String)
        case wikilink
        case highlight
    }

    private struct FormatItem: Identifiable {
        let id = UUID()
        let icon: Icon
        let prefix: String
        let suffix: String
    }

    private let items: [FormatItem] = [
        FormatItem(icon: .wikilink,                                               prefix: "[[", suffix: "]]"),
        FormatItem(icon: .systemImage("bold"),                                    prefix: "**", suffix: "**"),
        FormatItem(icon: .highlight,                                               prefix: "==", suffix: "=="),
        FormatItem(icon: .systemImage("italic"),                                   prefix: "*",  suffix: "*"),
        FormatItem(icon: .systemImage("strikethrough"),                           prefix: "~~", suffix: "~~"),
        FormatItem(icon: .systemImage("chevron.left.forwardslash.chevron.right"), prefix: "`",  suffix: "`"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items) { item in
                        Button {
                            actions.wrap(prefix: item.prefix, suffix: item.suffix)
                        } label: {
                            iconView(for: item.icon)
                                .foregroundStyle(.white)
                                .frame(minWidth: 36, minHeight: 34)
                                .background(Color(white: 0.2), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }

            Divider()
                .background(Color.white.opacity(0.15))
                .frame(height: 30)
                .padding(.vertical, 8)

            Button { actions.requestComment() } label: {
                Image(systemName: "text.bubble")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(white: 0.85))
                    .frame(minWidth: 36, minHeight: 34)
            }
            .buttonStyle(.plain)

            Divider()
                .background(Color.white.opacity(0.15))
                .frame(height: 30)
                .padding(.vertical, 8)

            Button { actions.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(actions.canUndo ? Color(white: 0.85) : Color(white: 0.3))
                    .frame(minWidth: 36, minHeight: 34)
            }
            .buttonStyle(.plain)
            .disabled(!actions.canUndo)

            Button { actions.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(actions.canRedo ? Color(white: 0.85) : Color(white: 0.3))
                    .frame(minWidth: 36, minHeight: 34)
            }
            .buttonStyle(.plain)
            .disabled(!actions.canRedo)

            Divider()
                .background(Color.white.opacity(0.15))
                .frame(height: 30)
                .padding(.vertical, 8)

            Button { actions.dismissKeyboard() } label: {
                Image(systemName: "keyboard.chevron.compact.down")
                    .font(.system(size: 16))
                    .foregroundStyle(Color(white: 0.6))
                    .padding(.horizontal, 14)
            }
            .buttonStyle(.plain)
        }
        .frame(height: 52)
        .background(Color(red: 0.09, green: 0.11, blue: 0.15))
    }

    @ViewBuilder
    private func iconView(for icon: Icon) -> some View {
        switch icon {
        case .systemImage(let name):
            Image(systemName: name)
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        case .wikilink:
            Text("[[]]")
                .font(.system(size: 13, design: .monospaced))
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        case .highlight:
            Text("H")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.yellow.opacity(0.85), in: Capsule())
                .padding(.horizontal, 5)
                .padding(.vertical, 5)
        }
    }
}
