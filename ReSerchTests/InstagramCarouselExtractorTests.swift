import XCTest
@testable import ReSerch

final class InstagramCarouselExtractorTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        guard let url else {
            XCTFail("Fixture \(name).json not found in bundle")
            return [:]
        }
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func test_detectsSidecar() throws {
        let json = try loadFixture("ig_sidecar")
        XCTAssertEqual(InstagramCarouselExtractor.detectKind(from: json), .carousel)
    }

    func test_detectsMixedAsCarouselWithVideoFlag() throws {
        let json = try loadFixture("ig_mixed_sidecar")
        XCTAssertEqual(InstagramCarouselExtractor.detectKind(from: json), .mixedCarousel)
    }

    func test_detectsSinglePhotoAsNotCarousel() throws {
        let json = try loadFixture("ig_single_photo")
        XCTAssertEqual(InstagramCarouselExtractor.detectKind(from: json), .notCarousel)
    }

    func test_parsesSidecarIntoPayload() throws {
        let json = try loadFixture("ig_sidecar")
        let postURL = URL(string: "https://www.instagram.com/p/ABC123/")!
        let payload = try InstagramCarouselExtractor.parse(json: json, postURL: postURL)

        XCTAssertEqual(payload.platform, .instagram)
        XCTAssertEqual(payload.postURL, postURL)
        XCTAssertEqual(payload.creatorHandle, "alice")
        XCTAssertEqual(payload.creatorDisplayName, "Alice Example")
        XCTAssertEqual(payload.creatorProfileURL.absoluteString, "https://www.instagram.com/alice/")
        XCTAssertEqual(payload.caption, "test caption")
        XCTAssertEqual(payload.likeCount, 42)
        XCTAssertEqual(payload.slides.count, 2)
        XCTAssertEqual(payload.slides[0].index, 0)
        XCTAssertEqual(payload.slides[1].index, 1)
        XCTAssertEqual(payload.slides[0].imageURL.absoluteString, "https://cdn.example.com/0.jpg")
        XCTAssertEqual(payload.slides[1].imageURL.absoluteString, "https://cdn.example.com/1.jpg")
    }
}
