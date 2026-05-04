import Foundation

/// Parses Instagram carousel JSON in two parallel schemas:
///
/// 1. **Legacy GraphQL** (`web_profile_info` etc.) — `__typename == "GraphSidecar"`,
///    `edge_sidecar_to_children.edges[].node`, `owner.username`, `edge_media_to_caption`.
///
/// 2. **Modern app/private API** (`/api/v1/media/{id}/info/`) — wrapper `{"items": [...]}`,
///    item has `media_type == 8` for carousels, `carousel_media[]` array, `user.username`,
///    `caption.text`, `like_count`, `taken_at`.
///
/// Both shapes can arrive via `WKWebView` intercept depending on which endpoint Instagram's
/// frontend chose at request time. The dispatcher below tries the modern shape first
/// (it's what production serves more often in 2026), then falls back to GraphQL.
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

    // MARK: - Public API

    static func detectKind(from json: [String: Any]) -> Kind {
        // Try modern shape first (preferred — what production serves most often now)
        if let kind = detectModern(from: json) { return kind }
        // Fall back to legacy GraphQL shape
        return detectLegacy(from: json)
    }

    static func parse(json: [String: Any], postURL: URL) throws -> CarouselPayload {
        // Try modern shape first
        if let payload = try? parseModern(json: json, postURL: postURL) {
            return payload
        }
        // Fall back to legacy GraphQL shape — surfaces its own errors
        return try parseLegacy(json: json, postURL: postURL)
    }

    // MARK: - Modern shape (items[0].carousel_media)

    /// Returns nil if the JSON isn't in modern shape (caller should try legacy).
    /// Returns .notCarousel if it IS modern shape but the post is a single image/video.
    private static func detectModern(from json: [String: Any]) -> Kind? {
        guard let item = unwrapItem(json) else { return nil }
        // media_type 8 = carousel album. carousel_media must also be present.
        guard (item["media_type"] as? Int) == 8 else { return nil }
        guard let media = item["carousel_media"] as? [[String: Any]], !media.isEmpty else {
            return .notCarousel
        }
        let hasVideo = media.contains { ($0["media_type"] as? Int) == 2 }
        return hasVideo ? .mixedCarousel : .carousel
    }

    private static func parseModern(json: [String: Any], postURL: URL) throws -> CarouselPayload {
        guard let item = unwrapItem(json),
              (item["media_type"] as? Int) == 8,
              let media = item["carousel_media"] as? [[String: Any]],
              !media.isEmpty else {
            throw ParseError.notASidecar
        }

        guard let user = item["user"] as? [String: Any],
              let handle = user["username"] as? String,
              !handle.isEmpty else {
            throw ParseError.missingOwner
        }
        let displayName = (user["full_name"] as? String) ?? handle
        let profileURL = URL(string: "https://www.instagram.com/\(handle)/")!

        let caption = (item["caption"] as? [String: Any])?["text"] as? String ?? ""
        let likeCount    = item["like_count"] as? Int
        let commentCount = item["comment_count"] as? Int
        let viewCount    = item["play_count"] as? Int ?? item["view_count"] as? Int
        // Instagram does NOT expose save counts to non-owners. Confirmed: no `save_count`
        // in either the modern items API or the legacy GraphQL shortcode_media response.
        let postedTs = item["taken_at"] as? TimeInterval
        let postedDate = postedTs.map { Date(timeIntervalSince1970: $0) }

        var slides: [CarouselSlide] = []
        for (i, node) in media.enumerated() {
            // Only image slides go to OCR. Video slides in mixed carousels are skipped here;
            // the parent caller surfaces `mixedCarouselHasVideo` for messaging.
            guard (node["media_type"] as? Int) != 2 else { continue }
            guard let url = imageURLModern(from: node) else { continue }
            slides.append(CarouselSlide(index: i, imageURL: url))
        }
        guard !slides.isEmpty else { throw ParseError.noChildren }

        return CarouselPayload(
            platform: .instagram,
            postURL: postURL,
            creatorHandle: handle,
            creatorDisplayName: displayName,
            creatorProfileURL: profileURL,
            caption: caption,
            viewCount: viewCount,
            likeCount: likeCount,
            commentCount: commentCount,
            shareCount: nil,
            saveCount: nil,
            postedDate: postedDate,
            slides: slides
        )
    }

    /// Modern shape: `image_versions2.candidates[]` with full URLs.
    private static func imageURLModern(from node: [String: Any]) -> URL? {
        if let versions = node["image_versions2"] as? [String: Any],
           let candidates = versions["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let s = first["url"] as? String,
           let u = URL(string: s) {
            return u
        }
        return nil
    }

    // MARK: - Legacy GraphQL shape (edge_sidecar_to_children)

    private static func detectLegacy(from json: [String: Any]) -> Kind {
        let edges = sidecarEdges(json)
        guard !edges.isEmpty else { return .notCarousel }
        let hasVideo = edges.contains { node in
            (node["is_video"] as? Bool == true)
                || (node["__typename"] as? String == "GraphVideo")
        }
        return hasVideo ? .mixedCarousel : .carousel
    }

    private static func parseLegacy(json: [String: Any], postURL: URL) throws -> CarouselPayload {
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
        let likeCount    = (json["edge_media_preview_like"] as? [String: Any])?["count"] as? Int
        let commentCount = (json["edge_media_to_parent_comment"] as? [String: Any])?["count"] as? Int
            ?? (json["edge_media_to_comment"] as? [String: Any])?["count"] as? Int
        let viewCount    = json["video_view_count"] as? Int
        let postedTs = json["taken_at_timestamp"] as? TimeInterval
        let postedDate = postedTs.map { Date(timeIntervalSince1970: $0) }

        var slides: [CarouselSlide] = []
        for (i, node) in edges.enumerated() {
            guard let imageURL = imageURLLegacy(from: node) else { continue }
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
            viewCount: viewCount,
            likeCount: likeCount,
            commentCount: commentCount,
            shareCount: nil,
            saveCount: nil,
            postedDate: postedDate,
            slides: slides
        )
    }

    private static func sidecarEdges(_ json: [String: Any]) -> [[String: Any]] {
        guard let sidecar = json["edge_sidecar_to_children"] as? [String: Any],
              let edges = sidecar["edges"] as? [[String: Any]] else { return [] }
        return edges.compactMap { $0["node"] as? [String: Any] }
    }

    /// Legacy node shape: `display_url` first, then `image_versions2.candidates[]`.
    private static func imageURLLegacy(from node: [String: Any]) -> URL? {
        if let s = node["display_url"] as? String, let u = URL(string: s) { return u }
        if let versions = node["image_versions2"] as? [String: Any],
           let candidates = versions["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let s = first["url"] as? String,
           let u = URL(string: s) { return u }
        return nil
    }

    // MARK: - Shared

    /// If the JSON is wrapped (`{"items": [...]}`), returns `items[0]`. Otherwise nil.
    /// The wrapper shape is what `/api/v1/media/{id}/info/` returns; the unwrapped shape
    /// is what older GraphQL `web_profile_info` returns at the post root.
    private static func unwrapItem(_ json: [String: Any]) -> [String: Any]? {
        guard let items = json["items"] as? [[String: Any]] else { return nil }
        return items.first
    }
}
