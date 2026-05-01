import Foundation

enum CarouselNoteFormatter {
    static func format(_ payload: CarouselPayload, embedImages: Bool) -> String {
        var lines: [String] = []
        let profile = payload.creatorProfileURL.absoluteString

        lines.append("# [\(payload.creatorDisplayName)](\(profile)) — Carousel")
        lines.append("")
        if !payload.caption.isEmpty {
            lines.append("> \(payload.caption.replacingOccurrences(of: "\n", with: "\n> "))")
            lines.append("")
        }
        lines.append("**Creator:** [@\(payload.creatorHandle)](\(profile))")
        if let likes = payload.likeCount {
            lines.append("**Likes:** \(likes)")
        }
        lines.append("**Slides:** \(payload.slideCount)")
        lines.append("**Source:** [See post](\(payload.postURL.absoluteString))")
        lines.append("")
        lines.append("---")
        lines.append("")

        for slide in payload.slides {
            lines.append("## Slide \(slide.index + 1)")
            if embedImages {
                if slide.imageDownloadFailed {
                    lines.append("*[image unavailable]*")
                } else if let local = slide.localImagePath {
                    lines.append("![[\(local.lastPathComponent)]]")
                }
            }
            let text = (slide.recognizedText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(text.isEmpty ? "*[no text detected]*" : text)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
