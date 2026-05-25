import SwiftUI
import UIKit

// MARK: - AnnotableTranscriptView

struct AnnotableTranscriptView: UIViewRepresentable {
    let text: String
    let annotations: [Annotation]
    /// Fired when the user picks "Comment" from the text-selection menu.
    /// `clean` is the human-visible text exactly as rendered (markdown syntax
    /// characters like `==` and `**` already stripped). `raw` is the underlying
    /// substring including those characters — kept so we can re-locate the
    /// highlight in the raw transcript later. `offset` is the location in raw
    /// transcript coordinates.
    var onHighlight: ((_ clean: String, _ raw: String, _ offset: Int) -> Void)?
    var onAddNote: ((_ clean: String, _ raw: String, _ offset: Int) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.dataDetectorTypes = []
        context.coordinator.textView = tv
        applyContent(to: tv)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onHighlight = onHighlight
        context.coordinator.onAddNote   = onAddNote
        context.coordinator.annotations = annotations
        applyContent(to: uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 390
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onHighlight: onHighlight, onAddNote: onAddNote, annotations: annotations)
    }

    // MARK: - Private

    private func applyContent(to tv: UITextView) {
        let (attributed, _) = MarkdownStyling.attributedWithRanges(text)
        let mutable = NSMutableAttributedString(attributedString: attributed)

        // Overlay annotation backgrounds
        let ns = text as NSString
        for ann in annotations {
            guard let range = rangeForAnnotation(ann, in: ns) else { continue }
            let bg: UIColor = ann.comment.isEmpty
                ? UIColor.systemYellow.withAlphaComponent(0.30)
                : UIColor.systemOrange.withAlphaComponent(0.30)
            mutable.addAttribute(.backgroundColor, value: bg, range: range)
        }

        tv.attributedText = mutable
        tv.setNeedsDisplay()
    }

    private func rangeForAnnotation(_ ann: Annotation, in ns: NSString) -> NSRange? {
        // Prefer `rawText` (the underlying substring with markdown markers
        // intact) for matching against the raw transcript; fall back to `text`
        // for legacy annotations stored before `rawText` was added.
        let needle = ann.rawText ?? ann.text
        guard !needle.isEmpty, ns.length > 0 else { return nil }
        let searchStart = max(0, ann.offset - 300)
        let maxEnd      = ns.length
        if searchStart < maxEnd {
            let searchLen = min(maxEnd - searchStart, needle.count + 600)
            if searchLen > 0 {
                let searchRange = NSRange(location: searchStart, length: searchLen)
                let found = ns.range(of: needle, options: [], range: searchRange)
                if found.location != NSNotFound { return found }
            }
        }
        // Fallback: search full string (handles edited/shifted transcripts)
        let full = ns.range(of: needle, options: [])
        return full.location != NSNotFound ? full : nil
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        weak var textView: UITextView?
        var onHighlight: ((_ clean: String, _ raw: String, _ offset: Int) -> Void)?
        var onAddNote: ((_ clean: String, _ raw: String, _ offset: Int) -> Void)?
        var annotations: [Annotation]

        init(
            onHighlight: ((_ clean: String, _ raw: String, _ offset: Int) -> Void)?,
            onAddNote: ((_ clean: String, _ raw: String, _ offset: Int) -> Void)?,
            annotations: [Annotation]
        ) {
            self.onHighlight = onHighlight
            self.onAddNote   = onAddNote
            self.annotations = annotations
        }

        @available(iOS 16.0, *)
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0,
                  let tv = textView as UITextView?,
                  let fullText = tv.text else {
                return UIMenu(children: suggestedActions)
            }
            let rawSelected   = (fullText as NSString).substring(with: range)
            let attrSub       = tv.attributedText.attributedSubstring(from: range)
            let cleanSelected = Self.visibleText(in: attrSub)
            // Guard against empty selections post-clean (e.g., user selected
            // only marker characters that all got stripped).
            let trimmedClean = cleanSelected.trimmingCharacters(in: .whitespacesAndNewlines)
            let textToSend   = trimmedClean.isEmpty ? rawSelected : cleanSelected
            guard !textToSend.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return UIMenu(children: suggestedActions)
            }

            let commentAction = UIAction(
                title: "Comment",
                image: UIImage(systemName: "text.bubble")
            ) { [weak self] _ in
                self?.onHighlight?(textToSend, rawSelected, range.location)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            let noteAction = UIAction(
                title: "Add Note",
                image: UIImage(systemName: "note.text.badge.plus")
            ) { [weak self] _ in
                self?.onAddNote?(textToSend, rawSelected, range.location)
            }

            return UIMenu(children: [commentAction, noteAction] + suggestedActions)
        }

        /// Walks the attributed substring's `.foregroundColor` runs and skips
        /// any run whose color is effectively transparent — that's how
        /// `MarkdownStyling` flags hidden marker characters (it pairs clear
        /// foreground with a 0.001pt font so markers take no visual space).
        /// What's left is the human-rendered text exactly as the user saw it.
        ///
        /// We check alpha <= 0.01 rather than `color == .clear` because
        /// `UIColor.clear` equality is brittle across dynamic / trait-resolved
        /// color instances — two visually-identical transparent colors may
        /// not be `==` if one of them resolved through a UITraitCollection.
        /// Alpha is the load-bearing visual property and matches the intent.
        private static func visibleText(in attr: NSAttributedString) -> String {
            var out = ""
            let full = NSRange(location: 0, length: attr.length)
            let ns = attr.string as NSString
            attr.enumerateAttribute(.foregroundColor, in: full, options: []) { value, range, _ in
                if let color = value as? UIColor {
                    var alpha: CGFloat = 1
                    color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
                    if alpha <= 0.01 { return }
                }
                out += ns.substring(with: range)
            }
            return out
        }
    }
}
