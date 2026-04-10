import Foundation

enum Platform {
    case youtube(videoId: String)
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
