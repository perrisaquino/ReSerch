import SwiftUI
import UIKit

// MARK: - AnnotableTranscriptView

struct AnnotableTranscriptView: UIViewRepresentable {
    let text: String
    let annotations: [Annotation]
    var onHighlight: ((String, Int) -> Void)?
    var onAddNote: ((String, Int) -> Void)?
    /// Fires on a single tap when there's no active selection. Used by the
    /// transcript detail view to enter edit mode without forcing the user to
    /// hit the tiny pencil icon.
    var onTap: (() -> Void)?

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
        // Tap gesture for "tap-to-edit". Delegate allows simultaneous recognition
        // so UIKit's long-press-based text selection still works.
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.numberOfTapsRequired = 1
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)
        applyContent(to: tv)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.onHighlight = onHighlight
        context.coordinator.onAddNote   = onAddNote
        context.coordinator.onTap       = onTap
        context.coordinator.annotations = annotations
        applyContent(to: uiView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 390
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onHighlight: onHighlight, onAddNote: onAddNote, onTap: onTap, annotations: annotations)
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
        guard !ann.text.isEmpty, ns.length > 0 else { return nil }
        let searchStart = max(0, ann.offset - 300)
        let maxEnd      = ns.length
        if searchStart < maxEnd {
            let searchLen = min(maxEnd - searchStart, ann.text.count + 600)
            if searchLen > 0 {
                let searchRange = NSRange(location: searchStart, length: searchLen)
                let found = ns.range(of: ann.text, options: [], range: searchRange)
                if found.location != NSNotFound { return found }
            }
        }
        // Fallback: search full string (handles edited/shifted transcripts)
        let full = ns.range(of: ann.text, options: [])
        return full.location != NSNotFound ? full : nil
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        weak var textView: UITextView?
        var onHighlight: ((String, Int) -> Void)?
        var onAddNote: ((String, Int) -> Void)?
        var onTap: (() -> Void)?
        var annotations: [Annotation]

        init(onHighlight: ((String, Int) -> Void)?, onAddNote: ((String, Int) -> Void)?, onTap: (() -> Void)?, annotations: [Annotation]) {
            self.onHighlight = onHighlight
            self.onAddNote   = onAddNote
            self.onTap       = onTap
            self.annotations = annotations
        }

        // MARK: - Tap-to-edit

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            // Suppress tap-to-edit while text is selected — that tap is the user
            // dismissing the selection menu, not asking to enter edit mode.
            if let tv = textView,
               let range = tv.selectedTextRange,
               !range.isEmpty {
                return
            }
            onTap?()
        }

        // Allow our tap to coexist with UIKit's long-press selection gestures.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            return true
        }

        @available(iOS 16.0, *)
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0,
                  let tv = textView as UITextView?,
                  let fullText = tv.text else {
                return UIMenu(children: suggestedActions)
            }
            let selectedText = (fullText as NSString).substring(with: range)
            guard !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return UIMenu(children: suggestedActions)
            }

            let commentAction = UIAction(
                title: "Comment",
                image: UIImage(systemName: "text.bubble")
            ) { [weak self] _ in
                self?.onHighlight?(selectedText, range.location)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            let noteAction = UIAction(
                title: "Add Note",
                image: UIImage(systemName: "note.text.badge.plus")
            ) { [weak self] _ in
                self?.onAddNote?(selectedText, range.location)
            }

            return UIMenu(children: [commentAction, noteAction] + suggestedActions)
        }
    }
}
