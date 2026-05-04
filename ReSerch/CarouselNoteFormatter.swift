import Foundation

/// Emits ONLY the per-slide body that lives inside `## Transcript` of the final
/// exported note. All wrapper metadata (title, author/handle hyperlinks, source link,
/// caption, stats) is owned by `MarkdownFormatter` so carousel exports match every
/// other transcript format exactly. Duplicating any of it here will show up twice
/// in Obsidian.
///
/// Images are deliberately NOT embedded — the in-app reader shows them via
/// `CarouselSlidesStripView`. Export is text-only so paste behaves the same in
/// Obsidian, Apple Notes, Notion, or any plain-text destination.
enum CarouselNoteFormatter {
    static func format(_ payload: CarouselPayload, embedImages: Bool) -> String {
        var lines: [String] = []

        for slide in payload.slides {
            lines.append("### Slide \(slide.index + 1)")
            let text = reflow(slide.recognizedText)
            lines.append(text.isEmpty ? "*[no text detected]*" : text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// Collapses OCR's mid-sentence wraps into spaces while preserving paragraph
    /// breaks (blank lines). OCR returns text broken at the image's visual line
    /// wrap; those breaks are layout noise, not real sentence boundaries. Without
    /// this pass, "sometimes you will be\nthe one who" pastes broken in Apple Notes.
    private static func reflow(_ raw: String?) -> String {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return raw
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
