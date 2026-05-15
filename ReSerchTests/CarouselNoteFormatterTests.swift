import XCTest
@testable import ReSerch

final class CarouselNoteFormatterTests: XCTestCase {
    private func samplePayload(slideTexts: [String?], embedFilenames: [String?] = []) -> CarouselPayload {
        var slides: [CarouselSlide] = []
        for (i, t) in slideTexts.enumerated() {
            var slide = CarouselSlide(
                index: i,
                imageURL: URL(string: "https://cdn.example.com/\(i).jpg")!
            )
            slide.recognizedText = t
            if i < embedFilenames.count, let name = embedFilenames[i] {
                slide.localImagePath = URL(fileURLWithPath: "/tmp/\(name)")
            }
            slides.append(slide)
        }
        return CarouselPayload(
            platform: .instagram,
            postURL: URL(string: "https://www.instagram.com/p/ABC/")!,
            creatorHandle: "alice",
            creatorDisplayName: "Alice",
            creatorProfileURL: URL(string: "https://www.instagram.com/alice/")!,
            caption: "hello world",
            viewCount: nil,
            likeCount: 42,
            commentCount: nil,
            shareCount: nil,
            saveCount: nil,
            postedDate: nil,
            slides: slides
        )
    }

    func test_headerHasClickableLinks() {
        let md = CarouselNoteFormatter.format(samplePayload(slideTexts: ["a"]), embedImages: false)
        XCTAssertTrue(md.contains("[Alice](https://www.instagram.com/alice/)"))
        XCTAssertTrue(md.contains("[@alice](https://www.instagram.com/alice/)"))
        XCTAssertTrue(md.contains("[See post](https://www.instagram.com/p/ABC/)"))
    }

    func test_emptySlideRendersPlaceholder() {
        let md = CarouselNoteFormatter.format(samplePayload(slideTexts: ["text", nil]), embedImages: false)
        XCTAssertTrue(md.contains("## Slide 1"))
        XCTAssertTrue(md.contains("## Slide 2"))
        XCTAssertTrue(md.contains("*[no text detected]*"))
    }

    func test_embedImagesOnEmitsObsidianEmbed() {
        let payload = samplePayload(slideTexts: ["a", "b"], embedFilenames: ["abc-00.jpg", "abc-01.jpg"])
        let md = CarouselNoteFormatter.format(payload, embedImages: true)
        XCTAssertTrue(md.contains("![[abc-00.jpg]]"))
        XCTAssertTrue(md.contains("![[abc-01.jpg]]"))
    }

    func test_embedImagesOffOmitsEmbed() {
        let payload = samplePayload(slideTexts: ["a"], embedFilenames: ["abc-00.jpg"])
        let md = CarouselNoteFormatter.format(payload, embedImages: false)
        XCTAssertFalse(md.contains("![["))
    }

    func test_imageDownloadFailedRendersFallback() {
        var payload = samplePayload(slideTexts: ["a"])
        payload.slides[0].imageDownloadFailed = true
        let md = CarouselNoteFormatter.format(payload, embedImages: true)
        XCTAssertTrue(md.contains("*[image unavailable]*"))
    }

    func test_slideCountInHeader() {
        let md = CarouselNoteFormatter.format(samplePayload(slideTexts: ["a","b","c"]), embedImages: false)
        XCTAssertTrue(md.contains("**Slides:** 3"))
    }
}
