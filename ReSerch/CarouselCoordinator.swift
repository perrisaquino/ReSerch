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
            thumbnailURL: processed.slides.first?.imageURL
        )
    }
}
