import Foundation

@MainActor
final class CarouselCoordinator {

    private let ocr = CarouselOCRService()

    func makeTranscriptResult(
        from payload: CarouselPayload,
        embedImages: Bool,
        progress: @escaping (String) -> Void
    ) async -> TranscriptResult {
        progress("Extracting slide 1 of \(payload.slideCount)…")
        let processed = await ocr.process(payload, embedImages: embedImages) { done, total in
            progress("Extracting slide \(done) of \(total)…")
        }
        let markdown = CarouselNoteFormatter.format(processed, embedImages: embedImages)

        // Single-slide "carousels" are just regular photo posts — Instagram or TikTok
        // sometimes return media_type=8 / imagePost shapes for single images. Don't
        // call those a "Carousel" in the title or platform field.
        let isMultiSlide = processed.slideCount > 1
        let title: String
        if isMultiSlide {
            title = "\(processed.creatorDisplayName) — Carousel (\(processed.slideCount) slides)"
        } else {
            // Mirror the regular video extractors' pattern: first 60 chars of caption,
            // fallback to a generic "Photo post" label when caption is empty.
            let captionPrefix = processed.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            if captionPrefix.isEmpty {
                title = "\(processed.creatorDisplayName) — Photo post"
            } else {
                title = String(captionPrefix.prefix(60))
            }
        }
        // Platform string — drop the "(Carousel)" / "(Photos)" suffix on single-slide posts
        // so YAML frontmatter and in-app platform badge read as plain "Instagram" / "TikTok".
        let platformString: String
        if isMultiSlide {
            platformString = processed.platform.rawValue
        } else {
            switch processed.platform {
            case .instagram: platformString = "Instagram"
            case .tiktok:    platformString = "TikTok"
            }
        }

        // Persist the structured slide payload alongside the markdown so TranscriptDetailView
        // can re-render the original images as a swipeable strip + render OCR text per slide
        // without fighting the markdown export format.
        let displaySlides = processed.slides.map { slide in
            TranscriptCarouselSlide(
                index: slide.index,
                imageURL: slide.imageURL,
                localImageFilename: slide.localImagePath?.lastPathComponent,
                recognizedText: slide.recognizedText
            )
        }

        return TranscriptResult(
            title: title,
            author: processed.creatorDisplayName,
            handle: processed.creatorHandle,
            platform: platformString,
            url: processed.postURL.absoluteString,
            caption: processed.caption,
            transcript: markdown,
            viewCount: processed.viewCount,
            likeCount: processed.likeCount,
            commentCount: processed.commentCount,
            shareCount: processed.shareCount,
            saveCount: processed.saveCount,
            postedDate: processed.postedDate,
            thumbnailURL: processed.slides.first?.imageURL,
            carouselSlides: displaySlides
        )
    }
}
