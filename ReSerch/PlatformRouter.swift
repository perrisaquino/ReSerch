import Foundation

enum Platform {
    case youtube(videoId: String)
    case youtubeShorts(videoId: String)
    case tiktok(url: URL)
    case instagram(url: URL)
    case twitter(url: URL)
    case threads(url: URL)
    case unknown(url: URL)
}

enum PlatformRouter {
    static func detect(_ url: URL) -> Platform {
        let host = url.host?.lowercased() ?? ""

        if host.contains("youtube.com") || host.contains("youtu.be") {
            if let id = extractYouTubeID(from: url) {
                if isYouTubeShortsURL(url) {
                    return .youtubeShorts(videoId: id)
                }
                return .youtube(videoId: id)
            }
        }

        if host.contains("tiktok.com") {
            return .tiktok(url: url)
        }

        if host.contains("instagram.com") {
            return .instagram(url: url)
        }

        // t.co short URLs redirect to twitter.com/x.com — WKWebView follows them automatically
        if host.contains("twitter.com") || host.contains("x.com") || host == "t.co" {
            return .twitter(url: url)
        }

        if host.contains("threads.net") {
            return .threads(url: url)
        }

        return .unknown(url: url)
    }

    /// Returns true when the URL points at a user-created TikTok playlist, e.g.
    /// `https://www.tiktok.com/@someone/playlist/My%20Stuff-7234567890123456789`.
    /// Distinct from `.tiktok` (single video) — callers should intercept playlists
    /// *before* routing to single-video transcription.
    static func isTikTokPlaylist(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), host.contains("tiktok.com") else { return false }
        let parts = url.pathComponents
        guard let idx = parts.firstIndex(of: "playlist"), idx + 1 < parts.count else { return false }
        let slug = parts[idx + 1]
        // Slug shape is `{name}-{numericID}`. Require the trailing numeric ID to avoid
        // matching reserved or renamed paths.
        guard let dashRange = slug.range(of: "-", options: .backwards) else { return false }
        let trailingID = slug[dashRange.upperBound...]
        return !trailingID.isEmpty && trailingID.allSatisfy(\.isNumber)
    }

    /// Extracts the numeric playlist ID from a TikTok playlist URL. Returns nil if not a playlist.
    static func extractTikTokPlaylistID(from url: URL) -> String? {
        guard isTikTokPlaylist(url) else { return nil }
        let parts = url.pathComponents
        guard let idx = parts.firstIndex(of: "playlist"), idx + 1 < parts.count else { return nil }
        let slug = parts[idx + 1]
        guard let dashRange = slug.range(of: "-", options: .backwards) else { return nil }
        return String(slug[dashRange.upperBound...])
    }

    static func extractTikTokID(from url: URL) -> String? {
        // tiktok.com/@user/video/1234567890
        let parts = url.pathComponents
        if let idx = parts.firstIndex(of: "video"), idx + 1 < parts.count {
            let id = parts[idx + 1]
            if !id.isEmpty { return id }
        }
        // m.tiktok.com/v/1234567890.html
        if let first = parts.dropFirst().first {
            let id = first.replacingOccurrences(of: ".html", with: "")
            if id.allSatisfy(\.isNumber), !id.isEmpty { return id }
        }
        return nil
    }

    /// Detects YouTube Shorts URLs. Routes through audio + WhisperKit pipeline (not captions).
    static func isYouTubeShortsURL(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        guard host.contains("youtube.com") else { return false }
        return url.pathComponents.contains("shorts")
    }

    private static func extractYouTubeID(from url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""

        // youtu.be/VIDEO_ID
        if host.contains("youtu.be") {
            let id = url.pathComponents.dropFirst().first
            return id?.isEmpty == false ? id : nil
        }

        // youtube.com/watch?v=VIDEO_ID
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }

        // youtube.com/shorts/VIDEO_ID or youtube.com/embed/VIDEO_ID
        let path = url.pathComponents
        if let idx = path.firstIndex(where: { $0 == "shorts" || $0 == "embed" }),
           idx + 1 < path.count {
            return path[idx + 1]
        }

        return nil
    }
}
