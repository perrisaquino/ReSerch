import UIKit
import UniformTypeIdentifiers
import SwiftUI

// MARK: - RichTextFormatter

enum RichTextFormatter {

    /// Builds a styled NSAttributedString from a TranscriptResult.
    /// Reuses MarkdownStyling for the transcript body — bold, italic, highlights, footnotes all render correctly.
    /// YAML frontmatter is omitted (Obsidian-specific).
    static func build(_ result: TranscriptResult) -> NSAttributedString? {
        let output = NSMutableAttributedString()

        let title = result.editableTitle.isEmpty ? result.title : result.editableTitle

        // ── Title ──────────────────────────────────────────
        output.append(attributed(
            title + "\n",
            font: .systemFont(ofSize: 20, weight: .bold),
            color: UIColor(white: 0.95, alpha: 1)
        ))

        // ── Metadata line ──────────────────────────────────
        var metaParts = [result.author]
        if !result.handle.isEmpty { metaParts.append(result.handle) }
        metaParts.append(result.platform)
        if let posted = result.postedDate {
            metaParts.append(DateFormatter.isoDate.string(from: posted))
        }
        if let dur = result.duration { metaParts.append(dur) }

        output.append(attributed(
            metaParts.joined(separator: " · ") + "\n\n",
            font: .systemFont(ofSize: 13, weight: .regular),
            color: UIColor(white: 0.55, alpha: 1)
        ))

        // ── Caption ────────────────────────────────────────
        if !result.caption.isEmpty {
            output.append(attributed(
                "Caption\n",
                font: .systemFont(ofSize: 14, weight: .semibold),
                color: UIColor(white: 0.75, alpha: 1)
            ))
            output.append(attributed(
                result.caption + "\n\n",
                font: .systemFont(ofSize: 15, weight: .regular),
                color: UIColor(white: 0.80, alpha: 1)
            ))
        }

        // ── Transcript ─────────────────────────────────────
        if !result.transcript.isEmpty {
            output.append(attributed(
                "Transcript\n",
                font: .systemFont(ofSize: 14, weight: .semibold),
                color: UIColor(white: 0.75, alpha: 1)
            ))
            // Run through the existing markdown styling — hides markers, applies bold/italic/highlights/etc.
            let (styledTranscript, _) = MarkdownStyling.attributedWithRanges(result.transcript)
            output.append(styledTranscript)
        }

        return output
    }

    /// Converts the attributed string to RTF Data for sharing.
    static func rtfData(from attrStr: NSAttributedString) -> Data? {
        try? attrStr.data(
            from: NSRange(location: 0, length: attrStr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    // MARK: Private

    private static func attributed(_ string: String, font: UIFont, color: UIColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: font,
            .foregroundColor: color
        ])
    }
}

// MARK: - RichText Transferable (for ShareLink)

struct RichText: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .rtf) { $0.data }
    }
}
