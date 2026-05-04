import SwiftUI

/// Renders a carousel transcript as clean, readable per-slide blocks instead of the
/// raw markdown that's stored on `TranscriptResult.transcript`. The markdown is kept
/// as the export format; this view is for in-app reading.
///
/// Source of truth is `TranscriptResult.carouselSlides` (structured data), NOT the
/// markdown string. Avoids fragile re-parsing of the markdown back into structure.
///
/// Each slide renders as: "Slide N" header (no `## ` prefix) followed by recognized
/// text laid out as paragraphs with the same line-break normalization rules as the
/// markdown formatter — collapses awkward single-line wraps from OCR back into
/// readable paragraphs.
struct CarouselCleanTranscriptView: View {
    let slides: [TranscriptCarouselSlide]

    var body: some View {
        if slides.isEmpty {
            // Defensive fallback: should never hit because TranscriptDetailView's
            // isCarouselTranscript already guards against empty arrays, but keep a
            // visible message so a stray bug surfaces as a clear "nothing here" rather
            // than a layout-breaking blank section.
            Text("No slide content available.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.45))
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                ForEach(slides) { slide in
                    slideBlock(slide)
                }
            }
        }
    }

    @ViewBuilder
    private func slideBlock(_ slide: TranscriptCarouselSlide) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header recipe matches captionSection / transcriptSection / documentNoteSection
            // in TranscriptDetailView. Same .caption + semibold + .gray + uppercase. No
            // tracking, no divider — both were drift from the established pattern.
            Text("Slide \(slide.index + 1)")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.gray)
                .textCase(.uppercase)

            // Body recipe matches documentNoteSection (.font(.system(size: 15)),
            // .foregroundStyle(.white.opacity(0.85)), .textSelection(.enabled)).
            // No explicit lineSpacing — let SwiftUI handle line height per platform.
            if let cleaned = readableText(from: slide.recognizedText) {
                Text(cleaned)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(slide.imageDownloadDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.45))
                    .italic()
            }
        }
    }

    /// Returns nil if the slide has no usable text (OCR failed, image was blank, etc.).
    /// Otherwise: collapses excessive whitespace, joins single-newline soft wraps back
    /// into paragraphs, preserves blank-line paragraph breaks. Keeps the text easy to
    /// read in a phone screen width without the OCR's mid-sentence line breaks.
    private func readableText(from raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // Split on blank lines (paragraph breaks). Within each paragraph, collapse
        // OCR's mid-sentence newlines into spaces so wrapping is the layout's job,
        // not the OCR's.
        let paragraphs = raw
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }

        return paragraphs.joined(separator: "\n\n")
    }
}

private extension TranscriptCarouselSlide {
    var imageDownloadDescription: String {
        if displayURL == nil { return "(Image unavailable — no text extracted)" }
        if recognizedText == nil { return "(Text extraction failed)" }
        return "(No text on this slide)"
    }
}
