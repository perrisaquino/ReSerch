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

        let title = "\(processed.creatorDisplayName) — Carousel (\(processed.slideCount) slides)"

        // Persist the structured slide payload alongside the markdown so TranscriptDetailView
        // can re-render the original images as a swipeable strip + render OCR text per slide
        // without fighting the markdown export format.
        let displaySlides = processed.slides.map { slide in
            TranscriptCarouselSlide(
                index: slide.index,
                imageURL: slide.imageURL,
                localImagePath: slide.localImagePath,
                recognizedText: slide.recognizedText
            )
        }

        return TranscriptResult(
            title: title,
            author: processed.creatorDisplayName,
            handle: processed.creatorHandle,
            platform: processed.platform.rawValue,
            url: processed.postURL.absoluteString,
            caption: processed.caption,
            transcript: markdown,
            likeCount: processed.likeCount,
            postedDate: processed.postedDate,
            thumbnailURL: processed.slides.first?.imageURL,
            carouselSlides: displaySlides
        )
    }
}
