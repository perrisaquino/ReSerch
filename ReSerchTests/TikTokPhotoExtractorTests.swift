import XCTest
@testable import ReSerch

final class TikTokPhotoExtractorTests: XCTestCase {
    private func loadFixture(_ name: String) throws -> [String: Any] {
        let bundle = Bundle(for: type(of: self))
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "json")
        guard let url else {
            XCTFail("Fixture \(name).json not found")
            return [:]
        }
        let data = try Data(contentsOf: url)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    func test_detectsPhotoPost() throws {
        let json = try loadFixture("tiktok_photo_post")
        XCTAssertTrue(TikTokPhotoExtractor.isPhotoPost(itemStruct: json))
    }

    func test_videoPostIsNotPhotoPost() throws {
        let json = try loadFixture("tiktok_video_post")
        XCTAssertFalse(TikTokPhotoExtractor.isPhotoPost(itemStruct: json))
    }

    func test_parsesPhotoPostIntoPayload() throws {
        let json = try loadFixture("tiktok_photo_post")
        let postURL = URL(string: "https://www.tiktok.com/@alice_tt/photo/7234567890")!
        let payload = try TikTokPhotoExtractor.parse(itemStruct: json, postURL: postURL)

        XCTAssertEqual(payload.platform, .tiktok)
        XCTAssertEqual(payload.creatorHandle, "alice_tt")
        XCTAssertEqual(payload.creatorDisplayName, "Alice TT")
        XCTAssertEqual(payload.creatorProfileURL.absoluteString, "https://www.tiktok.com/@alice_tt")
        XCTAssertEqual(payload.caption, "tiktok photo caption")
        XCTAssertEqual(payload.likeCount, 100)
        XCTAssertEqual(payload.slides.count, 3)
        XCTAssertEqual(payload.slides[0].index, 0)
        XCTAssertEqual(payload.slides[0].imageURL.absoluteString, "https://cdn.tiktok.example/0.jpg")
        XCTAssertEqual(payload.slides[2].imageURL.absoluteString, "https://cdn.tiktok.example/2.jpg")
    }
}
