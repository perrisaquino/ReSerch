import Foundation

struct CarouselSlide: Equatable {
    let index: Int               // zero-based
    let imageURL: URL
    var localImagePath: URL?     // set by OCR service if image embedding is on
    var recognizedText: String?  // nil = OCR failed/timed out, "" = ran but found nothing
    var imageDownloadFailed: Bool = false
}

struct CarouselPayload: Equatable {
    let platform: CarouselPlatform
    let postURL: URL
    let creatorHandle: String
    let creatorDisplayName: String
    let creatorProfileURL: URL
    let caption: String
    let viewCount: Int?
    let likeCount: Int?
    let commentCount: Int?
    let shareCount: Int?
    let saveCount: Int?
    let postedDate: Date?
    var slides: [CarouselSlide]

    var slideCount: Int { slides.count }
}

enum CarouselPlatform: String, Equatable {
    case instagram = "Instagram (Carousel)"
    case tiktok = "TikTok (Photos)"
}
