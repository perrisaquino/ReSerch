import Foundation

enum InstagramCarouselExtractor {

    enum Kind: Equatable {
        case carousel
        case mixedCarousel
        case notCarousel
    }

    enum ParseError: Error {
        case notASidecar
        case noChildren
        case missingOwner
    }

    static func detectKind(from json: [String: Any]) -> Kind {
        let edges = sidecarEdges(json)
        guard !edges.isEmpty else { return .notCarousel }
        let hasVideo = edges.contains { node in
            (node["is_video"] as? Bool == true)
                || (node["__typename"] as? String == "GraphVideo")
        }
        return hasVideo ? .mixedCarousel : .carousel
    }

    static func parse(json: [String: Any], postURL: URL) throws -> CarouselPayload {
        let edges = sidecarEdges(json)
        guard !edges.isEmpty else { throw ParseError.notASidecar }

        guard let owner = json["owner"] as? [String: Any],
              let handle = owner["username"] as? String,
              !handle.isEmpty else {
            throw ParseError.missingOwner
        }
        let displayName = (owner["full_name"] as? String) ?? handle
        let profileURL = URL(string: "https://www.instagram.com/\(handle)/")!

        let caption = (((json["edge_media_to_caption"] as? [String: Any])?["edges"] as? [[String: Any]])?
            .first?["node"] as? [String: Any])?["text"] as? String ?? ""
        let likeCount = (json["edge_media_preview_like"] as? [String: Any])?["count"] as? Int
        let postedTs = json["taken_at_timestamp"] as? TimeInterval
        let postedDate = postedTs.map { Date(timeIntervalSince1970: $0) }

        var slides: [CarouselSlide] = []
        for (i, node) in edges.enumerated() {
            guard let imageURL = imageURL(from: node) else { continue }
            slides.append(CarouselSlide(index: i, imageURL: imageURL))
        }
        guard !slides.isEmpty else { throw ParseError.noChildren }

        return CarouselPayload(
            platform: .instagram,
            postURL: postURL,
            creatorHandle: handle,
            creatorDisplayName: displayName,
            creatorProfileURL: profileURL,
            caption: caption,
            likeCount: likeCount,
            postedDate: postedDate,
            slides: slides
        )
    }

    private static func sidecarEdges(_ json: [String: Any]) -> [[String: Any]] {
        guard let sidecar = json["edge_sidecar_to_children"] as? [String: Any],
              let edges = sidecar["edges"] as? [[String: Any]] else { return [] }
        return edges.compactMap { $0["node"] as? [String: Any] }
    }

    private static func imageURL(from node: [String: Any]) -> URL? {
        if let s = node["display_url"] as? String, let u = URL(string: s) { return u }
        if let versions = node["image_versions2"] as? [String: Any],
           let candidates = versions["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let s = first["url"] as? String,
           let u = URL(string: s) { return u }
        return nil
    }
}
