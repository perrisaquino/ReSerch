import Foundation

enum TikTokPhotoExtractor {

    enum ParseError: Error {
        case notPhotoPost
        case noImages
        case missingAuthor
    }

    static func isPhotoPost(itemStruct: [String: Any]) -> Bool {
        guard let imagePost = itemStruct["imagePost"] as? [String: Any],
              let images = imagePost["images"] as? [[String: Any]],
              !images.isEmpty else {
            return false
        }
        return true
    }

    static func parse(itemStruct: [String: Any], postURL: URL) throws -> CarouselPayload {
        guard isPhotoPost(itemStruct: itemStruct) else { throw ParseError.notPhotoPost }
        guard let imagePost = itemStruct["imagePost"] as? [String: Any],
              let images = imagePost["images"] as? [[String: Any]] else {
            throw ParseError.noImages
        }
        guard let author = itemStruct["author"] as? [String: Any],
              let handle = author["uniqueId"] as? String,
              !handle.isEmpty else {
            throw ParseError.missingAuthor
        }
        let displayName = (author["nickname"] as? String) ?? handle
        let profileURL = URL(string: "https://www.tiktok.com/@\(handle)")!

        let caption = (itemStruct["desc"] as? String) ?? ""
        let stats = itemStruct["stats"] as? [String: Any]
        let likeCount    = stats?["diggCount"] as? Int
        let viewCount    = stats?["playCount"] as? Int
        let commentCount = stats?["commentCount"] as? Int
        let shareCount   = stats?["shareCount"] as? Int
        let saveCount    = stats?["collectCount"] as? Int
        let createTime = itemStruct["createTime"] as? TimeInterval
        let postedDate = createTime.map { Date(timeIntervalSince1970: $0) }

        var slides: [CarouselSlide] = []
        for (i, image) in images.enumerated() {
            guard let imageURL = imageURL(from: image) else { continue }
            slides.append(CarouselSlide(index: i, imageURL: imageURL))
        }
        guard !slides.isEmpty else { throw ParseError.noImages }

        return CarouselPayload(
            platform: .tiktok,
            postURL: postURL,
            creatorHandle: handle,
            creatorDisplayName: displayName,
            creatorProfileURL: profileURL,
            caption: caption,
            viewCount: viewCount,
            likeCount: likeCount,
            commentCount: commentCount,
            shareCount: shareCount,
            saveCount: saveCount,
            postedDate: postedDate,
            slides: slides
        )
    }

    private static func imageURL(from image: [String: Any]) -> URL? {
        guard let imageDict = image["imageURL"] as? [String: Any],
              let list = imageDict["urlList"] as? [String],
              let first = list.first(where: { URL(string: $0)?.scheme != nil }) else { return nil }
        return URL(string: first)
    }
}
