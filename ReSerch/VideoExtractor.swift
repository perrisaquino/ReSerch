import Foundation
import AVFoundation
import Photos
import WebKit

enum VideoExtractor {
    enum ExtractError: LocalizedError {
        case noVideoFound
        case downloadFailed(String)
        case audioExportFailed

        var errorDescription: String? {
            switch self {
            case .noVideoFound:
                return "Could not find video URL. The post may be private or require login."
            case .downloadFailed(let msg):
                return "Download failed: \(msg)"
            case .audioExportFailed:
                return "Could not extract audio from video."
            }
        }
    }

    static func extractVideoMetadata(from pageURL: URL, platform: Platform) async throws -> VideoMetadata {
        rLog(step: "Extract", "Fetching page: \(pageURL.absoluteString)")
        switch platform {
        case .tiktok:
            let (html, finalURL) = try await fetchPage(pageURL, headers: tiktokHeaders())
            rLog(step: "Extract", "TikTok HTML \(html.count) bytes | final: \(finalURL.absoluteString)")
            return try extractTikTokMetadata(from: html, pageURL: finalURL, originalURL: pageURL.absoluteString)
        case .instagram:
            return try await fetchInstagramMetadata(pageURL: pageURL, originalURL: pageURL.absoluteString)
        case .twitter:
            return try await fetchTwitterMetadata(pageURL: pageURL, originalURL: pageURL.absoluteString)
        case .threads:
            // Threads is a Meta product — uses the same CDN as Instagram
            return try await fetchInstagramMetadata(pageURL: pageURL, originalURL: pageURL.absoluteString)
        case .youtubeShorts(let videoId):
            return try await fetchYouTubeShortsMetadata(videoId: videoId, originalURL: pageURL.absoluteString)
        default:
            throw ExtractError.noVideoFound
        }
    }

    private static func fetchYouTubeShortsMetadata(videoId: String, originalURL: String) async throws -> VideoMetadata {
        guard let result = await YouTubeShortsExtractor.extract(videoId: videoId) else {
            throw ExtractError.noVideoFound
        }
        return VideoMetadata(
            videoURL: result.audioURL,
            title: result.title,
            author: result.author,
            handle: result.handle,
            caption: result.description,
            viewCount: result.viewCount,
            likeCount: result.likeCount,
            commentCount: nil,
            shareCount: nil,
            durationSeconds: parseDurationSeconds(result.duration),
            postedDate: result.postedDate,
            thumbnailURL: result.thumbnailURL
        )
    }

    private static func parseDurationSeconds(_ formatted: String?) -> Int? {
        guard let f = formatted else { return nil }
        let parts = f.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return nil
    }

    /// Fetches a TikTok page with the same headers/cookies the single-video path uses.
    /// Exposed for `TikTokPlaylistExtractor` so it doesn't have to duplicate header setup.
    static func fetchTikTokPage(_ url: URL) async throws -> (String, URL) {
        try await fetchPage(url, headers: tiktokHeaders())
    }

    private static func tiktokHeaders() -> [String: String] {
        let fakeCookie = (0..<80).map { _ in String(format: "%02x", Int.random(in: 0...255)) }.joined()
        return [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Accept-Encoding": "gzip, deflate, br",
            "Referer": "https://www.tiktok.com/",
            "Cookie": "odin_tt=\(fakeCookie)",
        ]
    }

    private static func instagramHeaders() -> [String: String] {
        [
            // Mobile UA gets a more complete HTML response than desktop on Instagram
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.5",
            "Accept-Encoding": "gzip, deflate, br",
            "Referer": "https://www.instagram.com/",
        ]
    }

    private static func fetchPage(_ url: URL, headers: [String: String]) async throws -> (String, URL) {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = headers
        let session = URLSession(configuration: config)
        let (data, response) = try await session.data(from: url)
        let finalURL = response.url ?? url
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        rLog(status == 200 ? .ok : .fail, step: "Extract", "HTTP \(status), \(data.count) bytes, final: \(finalURL.absoluteString)")
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ExtractError.noVideoFound
        }
        return (html, finalURL)
    }

    // MARK: - TikTok

    private static func extractTikTokMetadata(from html: String, pageURL: URL, originalURL: String) throws -> VideoMetadata {
        if let meta = try? extractTikTokFromUniversalData(html: html, originalURL: originalURL) { return meta }
        // Fallback: extract just the URL with no metadata
        let videoURL = try extractTikTokVideoURLFallback(from: html)
        return VideoMetadata(
            videoURL: videoURL, title: "TikTok Video", author: "Unknown", handle: "",
            caption: "", viewCount: nil, likeCount: nil, commentCount: nil, shareCount: nil,
            durationSeconds: nil, postedDate: nil, thumbnailURL: nil
        )
    }

    private static func extractTikTokFromUniversalData(html: String, originalURL: String) throws -> VideoMetadata {
        guard let scriptStart = html.range(of: "id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__") else {
            throw ExtractError.noVideoFound
        }
        let afterTag = String(html[scriptStart.upperBound...])
        guard let jsonStart = afterTag.range(of: ">") else { throw ExtractError.noVideoFound }
        let fromJson = String(afterTag[jsonStart.upperBound...])
        guard let jsonEnd = fromJson.range(of: "</script>") else { throw ExtractError.noVideoFound }
        let jsonStr = String(fromJson[..<jsonEnd.lowerBound])

        guard let data = jsonStr.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultScope = root["__DEFAULT_SCOPE__"] as? [String: Any] else {
            rLog(.fail, step: "Extract", "Could not parse UNIVERSAL JSON root")
            throw ExtractError.noVideoFound
        }

        rLog(step: "Extract", "DEFAULT_SCOPE keys: \(defaultScope.keys.joined(separator: ", "))")

        // TikTok has used several key names for the video detail object
        let videoDetail = defaultScope["webapp.video-detail"]
            ?? defaultScope["webapp.video-detail-ssr"]
            ?? defaultScope.values.first(where: { ($0 as? [String: Any])?["itemInfo"] != nil })

        guard let videoDetailDict = videoDetail as? [String: Any] else {
            rLog(.fail, step: "Extract", "Could not find video-detail in scope")
            throw ExtractError.noVideoFound
        }

        rLog(step: "Extract", "videoDetail keys: \(videoDetailDict.keys.joined(separator: ", "))")

        // itemStruct can be at different depths
        let itemStruct: [String: Any]?
        if let itemInfo = videoDetailDict["itemInfo"] as? [String: Any] {
            itemStruct = itemInfo["itemStruct"] as? [String: Any]
        } else if let videoData = videoDetailDict["videoData"] as? [String: Any] {
            itemStruct = videoData["itemInfos"] as? [String: Any]
                ?? videoData["itemStruct"] as? [String: Any]
        } else {
            itemStruct = nil
        }

        guard let itemStruct else {
            rLog(.fail, step: "Extract", "Could not find itemStruct. videoDetail keys: \(videoDetailDict.keys.joined(separator: ", "))")
            throw ExtractError.noVideoFound
        }

        guard let video = itemStruct["video"] as? [String: Any] else {
            rLog(.fail, step: "Extract", "No 'video' key in itemStruct. Keys: \(itemStruct.keys.joined(separator: ", "))")
            throw ExtractError.noVideoFound
        }

        rLog(step: "Extract", "video keys: \(video.keys.joined(separator: ", "))")

        // Video URL — TikTok has shifted between several field names over time
        let videoURL: URL
        var candidates: [String] = []

        // Direct string fields
        for key in ["playAddr", "downloadAddr", "play_addr", "download_addr"] {
            if let s = video[key] as? String, !s.isEmpty { candidates.append(s) }
        }

        // bitrateInfo[].PlayAddr.UrlList[] — newer TikTok format
        if let bitrateInfo = video["bitrateInfo"] as? [[String: Any]] {
            for bitrate in bitrateInfo {
                if let playAddr = bitrate["PlayAddr"] as? [String: Any],
                   let urlList = playAddr["UrlList"] as? [String],
                   let first = urlList.first(where: { !$0.isEmpty }) {
                    candidates.append(first)
                    break
                }
            }
        }

        // play_addr as dict with url_list
        for key in ["play_addr", "playAddr"] {
            if let addrDict = video[key] as? [String: Any] {
                if let urlList = addrDict["url_list"] as? [String],
                   let first = urlList.first(where: { !$0.isEmpty }) {
                    candidates.append(first)
                }
                if let urlList = addrDict["UrlList"] as? [String],
                   let first = urlList.first(where: { !$0.isEmpty }) {
                    candidates.append(first)
                }
            }
        }

        rLog(step: "Extract", "video URL candidates: \(candidates.count)")

        guard let urlStr = candidates.first(where: { !$0.isEmpty }),
              let resolvedURL = URL(string: urlStr) else {
            rLog(.fail, step: "Extract", "No valid video URL found among \(candidates.count) candidates")
            throw ExtractError.noVideoFound
        }
        videoURL = resolvedURL

        // Author
        let authorDict = itemStruct["author"] as? [String: Any]
        let author = authorDict?["nickname"] as? String ?? "Unknown"
        let handle = (authorDict?["uniqueId"] as? String).map { "@\($0)" } ?? ""

        // Caption
        let caption = itemStruct["desc"] as? String ?? ""

        // Stats
        let stats = itemStruct["stats"] as? [String: Any]
        let viewCount = stats?["playCount"] as? Int
        let likeCount = stats?["diggCount"] as? Int
        let commentCount = stats?["commentCount"] as? Int
        let shareCount = stats?["shareCount"] as? Int

        // Duration
        let durationSeconds: Int?
        if let dur = video["duration"] as? Int, dur > 0 { durationSeconds = dur }
        else if let dur = video["duration"] as? Double, dur > 0 { durationSeconds = Int(dur) }
        else { durationSeconds = nil }

        // Posted date
        let postedDate: Date?
        if let ts = itemStruct["createTime"] as? TimeInterval {
            postedDate = Date(timeIntervalSince1970: ts)
        } else if let ts = itemStruct["createTime"] as? Int {
            postedDate = Date(timeIntervalSince1970: TimeInterval(ts))
        } else {
            postedDate = nil
        }

        // Thumbnail
        let thumbnailURL: URL?
        if let cover = video["cover"] as? String { thumbnailURL = URL(string: cover) }
        else if let cover = video["originCover"] as? String { thumbnailURL = URL(string: cover) }
        else { thumbnailURL = nil }

        // Title: TikTok doesn't have a real title -- use first 60 chars of caption
        let title = caption.isEmpty ? "TikTok Video" : String(caption.prefix(60))

        rLog(.ok, step: "Extract", "TikTok meta: \(author) | views:\(viewCount ?? 0) | dur:\(durationSeconds ?? 0)s")

        return VideoMetadata(
            videoURL: videoURL, title: title, author: author, handle: handle,
            caption: caption, viewCount: viewCount, likeCount: likeCount,
            commentCount: commentCount, shareCount: shareCount,
            durationSeconds: durationSeconds, postedDate: postedDate, thumbnailURL: thumbnailURL
        )
    }

    private static func extractTikTokVideoURLFallback(from html: String) throws -> URL {
        if let url = try? extractFromSIGIState(html: html) { return url }
        let patterns = ["\"playAddr\":\"", "\"play_addr\":\"", "\"downloadAddr\":\""]
        for pattern in patterns {
            if let range = html.range(of: pattern) {
                let after = String(html[range.upperBound...])
                if let end = after.firstIndex(of: "\"") {
                    let raw = String(after[..<end])
                        .replacingOccurrences(of: "\\u002F", with: "/")
                        .replacingOccurrences(of: "\\/", with: "/")
                    if let url = URL(string: raw), url.scheme == "https" { return url }
                }
            }
        }
        throw ExtractError.noVideoFound
    }

    private static func extractFromSIGIState(html: String) throws -> URL {
        guard let range = html.range(of: "SIGI_STATE\">") ?? html.range(of: "SIGI_STATE\" >") else {
            throw ExtractError.noVideoFound
        }
        let after = String(html[range.upperBound...])
        guard let end = after.range(of: "</script>") else { throw ExtractError.noVideoFound }
        let jsonStr = String(after[..<end.lowerBound])
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ExtractError.noVideoFound
        }
        return try findVideoURLInDict(json)
    }

    private static func findVideoURLInDict(_ dict: [String: Any]) throws -> URL {
        for (key, value) in dict {
            if key == "playAddr" || key == "downloadAddr" || key == "playUrl" {
                if let urlStr = value as? String, let url = URL(string: urlStr) { return url }
            }
            if let nested = value as? [String: Any] {
                if let found = try? findVideoURLInDict(nested) { return found }
            }
            if let arr = value as? [[String: Any]] {
                for item in arr {
                    if let found = try? findVideoURLInDict(item) { return found }
                }
            }
        }
        throw ExtractError.noVideoFound
    }

    // MARK: - Instagram

    private static func extractInstagramShortcode(from url: URL) -> String? {
        let path = url.pathComponents
        for segment in ["reel", "reels", "p", "tv"] {
            if let idx = path.firstIndex(of: segment), idx + 1 < path.count {
                let code = path[idx + 1]
                if !code.isEmpty && code != "/" { return code }
            }
        }
        return nil
    }

    private static func fetchInstagramMetadata(pageURL: URL, originalURL: String) async throws -> VideoMetadata {
        let shortcode = extractInstagramShortcode(from: pageURL)
        rLog(step: "Instagram", "Shortcode: \(shortcode ?? "none")")

        // Strategy 0: WKWebView with shared Safari session — works when user is logged into Instagram in Safari.
        // Pass mediaID so the extractor can call the private API from within the page context,
        // getting both a direct MP4 URL AND the full metadata JSON (caption, thumbnail, author,
        // stats, duration). The in-page fetch runs with Safari cookies, which the URLSession-based
        // fetchInstagramFromAPI call does not have — that's why the URLSession path was silently
        // returning empty metadata before.
        let apiMediaID = shortcode.flatMap { shortcodeToMediaID($0) }
        let webResult: InstagramWebResult? = await Task { @MainActor in
            let e = InstagramWebExtractor()
            return await e.extract(from: pageURL, mediaID: apiMediaID)
        }.value
        if let webResult {
            let videoURL = webResult.videoURL
            rLog(.ok, step: "Instagram", "WKWebView: \(videoURL.absoluteString.prefix(60))...")
            // Parse rich metadata from the API JSON the WKWebView captured.
            if let apiJSON = webResult.apiJSON,
               let item = firstAPIItem(from: apiJSON),
               let meta = parseInstagramAPIItem(item, fallbackVideoURL: videoURL) {
                let apiURLIsDirect = !meta.videoURL.absoluteString.contains("bytestart=")
                let bestVideoURL = apiURLIsDirect ? meta.videoURL : videoURL
                rLog(.ok, step: "Instagram", "WKWebView API metadata: \(meta.author) | \(meta.title.prefix(40))")
                return VideoMetadata(
                    videoURL: bestVideoURL, title: meta.title, author: meta.author, handle: meta.handle,
                    caption: meta.caption, viewCount: meta.viewCount, likeCount: meta.likeCount,
                    commentCount: meta.commentCount, shareCount: meta.shareCount,
                    durationSeconds: meta.durationSeconds, postedDate: meta.postedDate,
                    thumbnailURL: meta.thumbnailURL
                )
            }
            // WKWebView did not capture usable API JSON (usually because the in-page API call
            // also returned login_required). Fall back to the DOM metadata we scraped from
            // the already-loaded page.
            let domMetadata = webResult.domMeta.flatMap { makeMetadataFromDOM($0, videoURL: videoURL) }
            if let domMetadata, !domMetadata.caption.isEmpty && !domMetadata.handle.isEmpty {
                rLog(.ok, step: "Instagram", "DOM metadata (complete): \(domMetadata.author) | \(domMetadata.title.prefix(40))")
                return domMetadata
            }
            // DOM was thin (or missing caption/handle). The embed page is a public, login-free
            // HTML endpoint that reliably carries caption + @handle + avatar for public posts.
            if let code = shortcode,
               let embedMeta = try? await fetchInstagramEmbedMetadata(shortcode: code, videoURL: videoURL) {
                rLog(.ok, step: "Instagram", "Embed metadata: \(embedMeta.author) | \(embedMeta.title.prefix(40))")
                // Merge: prefer embed for caption/author/handle, keep DOM's stats if present.
                return VideoMetadata(
                    videoURL: embedMeta.videoURL,
                    title: embedMeta.title.isEmpty ? (domMetadata?.title ?? "Instagram Reel") : embedMeta.title,
                    author: embedMeta.author.isEmpty ? (domMetadata?.author ?? "Instagram") : embedMeta.author,
                    handle: embedMeta.handle.isEmpty ? (domMetadata?.handle ?? "") : embedMeta.handle,
                    caption: embedMeta.caption.isEmpty ? (domMetadata?.caption ?? "") : embedMeta.caption,
                    viewCount: domMetadata?.viewCount,
                    likeCount: domMetadata?.likeCount ?? embedMeta.likeCount,
                    commentCount: domMetadata?.commentCount ?? embedMeta.commentCount,
                    shareCount: nil,
                    durationSeconds: nil,
                    postedDate: domMetadata?.postedDate ?? embedMeta.postedDate,
                    thumbnailURL: embedMeta.thumbnailURL ?? domMetadata?.thumbnailURL
                )
            }
            if let domMetadata {
                rLog(.warn, step: "Instagram", "DOM-only metadata (embed page unavailable): \(domMetadata.author)")
                return domMetadata
            }
            // Try cookieless URLSession API as a last resort (often also 403s).
            if let mid = apiMediaID,
               let meta = try? await fetchInstagramFromAPI(mediaID: mid, originalURL: originalURL) {
                let apiURLIsDirect = !meta.videoURL.absoluteString.contains("bytestart=")
                let bestVideoURL = apiURLIsDirect ? meta.videoURL : videoURL
                rLog(.ok, step: "Instagram", "URLSession API metadata: \(meta.author) | \(meta.title.prefix(40))")
                return VideoMetadata(
                    videoURL: bestVideoURL, title: meta.title, author: meta.author, handle: meta.handle,
                    caption: meta.caption, viewCount: meta.viewCount, likeCount: meta.likeCount,
                    commentCount: meta.commentCount, shareCount: meta.shareCount,
                    durationSeconds: meta.durationSeconds, postedDate: meta.postedDate,
                    thumbnailURL: meta.thumbnailURL
                )
            }
            // Final fallback: scrape the page HTML via URLSession.
            if let (html, _) = try? await fetchPage(pageURL, headers: instagramHeaders()),
               let htmlMeta = try? extractInstagramMetadata(from: html, originalURL: originalURL) {
                rLog(.warn, step: "Instagram", "API unavailable — using HTML metadata fallback")
                return VideoMetadata(
                    videoURL: videoURL, title: htmlMeta.title, author: htmlMeta.author, handle: htmlMeta.handle,
                    caption: htmlMeta.caption, viewCount: htmlMeta.viewCount, likeCount: htmlMeta.likeCount,
                    commentCount: htmlMeta.commentCount, shareCount: htmlMeta.shareCount,
                    durationSeconds: htmlMeta.durationSeconds, postedDate: htmlMeta.postedDate,
                    thumbnailURL: htmlMeta.thumbnailURL
                )
            }
            rLog(.warn, step: "Instagram", "No metadata source — returning video with empty metadata")
            return VideoMetadata(
                videoURL: videoURL, title: "Instagram Reel",
                author: "Instagram", handle: "",
                caption: "", viewCount: nil, likeCount: nil, commentCount: nil, shareCount: nil,
                durationSeconds: nil, postedDate: nil, thumbnailURL: nil
            )
        }
        rLog(.warn, step: "Instagram", "WKWebView found no video — falling back to scraping")

        let headers = instagramHeaders()

        // Strategy 1: Fetch the reel page directly
        if let (html, _) = try? await fetchPage(pageURL, headers: headers) {
            rLog(step: "Instagram", "Page HTML \(html.count) bytes")
            // Log first 200 chars to see if we hit a login wall
            let preview = html.prefix(200).replacingOccurrences(of: "\n", with: " ")
            rLog(step: "Instagram", "HTML preview: \(preview)")
            let isLoginWall = html.contains("accounts/login") || html.contains("login_required") || html.count < 5000
            if isLoginWall { rLog(.warn, step: "Instagram", "Looks like a login wall (\(html.count) bytes)") }
            if let meta = try? extractInstagramMetadata(from: html, originalURL: originalURL) {
                return meta
            }
            rLog(.warn, step: "Instagram", "No video URL in page HTML — trying embed fallback")
        }

        // Strategy 2: Embed page — Instagram serves a simpler page with more video data
        if let code = shortcode {
            for embedPath in ["/reel/\(code)/embed/captioned/", "/p/\(code)/embed/captioned/"] {
                guard let embedURL = URL(string: "https://www.instagram.com\(embedPath)") else { continue }
                if let (html, _) = try? await fetchPage(embedURL, headers: headers) {
                    rLog(step: "Instagram", "Embed HTML \(html.count) bytes")
                    if let meta = try? extractInstagramMetadata(from: html, originalURL: originalURL) {
                        return meta
                    }
                }
            }
        }

        // Strategy 3: Private mobile API — public posts work without auth if we identify as the app
        if let code = shortcode, let mediaID = shortcodeToMediaID(code) {
            rLog(step: "Instagram", "Trying private API with mediaID: \(mediaID)")
            if let meta = try? await fetchInstagramFromAPI(mediaID: mediaID, originalURL: originalURL) {
                return meta
            }
        }

        rLog(.fail, step: "Instagram", "All strategies exhausted — Instagram may require login for this post")
        throw ExtractError.downloadFailed("Instagram did not return a video URL. The post may be private or Instagram may require login. Try copying the link from the Instagram app's share sheet.")
    }

    private static func extractInstagramMetadata(from html: String, originalURL: String) throws -> VideoMetadata {
        // --- Video URL: try multiple patterns in priority order ---
        var videoURL: URL?

        // og:video meta tags (public posts sometimes still have these)
        for pattern in ["property=\"og:video\" content=\"", "\"og:video\" content=\"",
                        "property=\"og:video:url\" content=\"", "\"og:video:url\" content=\""] {
            if let url = quotedURL(after: pattern, in: html, unescape: true) { videoURL = url; break }
        }

        // video_url / playback_url in embedded JSON (mobile HTML often has this)
        if videoURL == nil {
            for pattern in ["\"video_url\":\"", "\"playback_url\":\"", "\"video_versions\":[{\"url\":\""] {
                if let range = html.range(of: pattern) {
                    let after = String(html[range.upperBound...])
                    if let end = after.firstIndex(of: "\"") {
                        let raw = String(after[..<end])
                            .replacingOccurrences(of: "\\u0026", with: "&")
                            .replacingOccurrences(of: "\\/", with: "/")
                        if let url = URL(string: raw), url.scheme == "https" { videoURL = url; break }
                    }
                }
            }
        }

        // <video> / <source> tags in embed pages
        if videoURL == nil {
            for pattern in ["<video src=\"", "<source src=\"", "videoUrl:\"", "src: '"] {
                if let range = html.range(of: pattern) {
                    let after = String(html[range.upperBound...])
                    let terminator: Character = pattern.hasSuffix("'") ? "'" : "\""
                    if let end = after.firstIndex(of: terminator) {
                        let raw = String(after[..<end]).replacingOccurrences(of: "&amp;", with: "&")
                        if let url = URL(string: raw), url.scheme == "https",
                           url.absoluteString.contains("cdninstagram") || url.absoluteString.contains("fbcdn") {
                            videoURL = url; break
                        }
                    }
                }
            }
        }

        guard let resolvedURL = videoURL else { throw ExtractError.noVideoFound }

        // --- Title ---
        var title = "Instagram Reel"
        for pattern in ["property=\"og:title\" content=\"", "\"og:title\" content=\""] {
            if let range = html.range(of: pattern) {
                let after = String(html[range.upperBound...])
                if let end = after.firstIndex(of: "\"") { title = String(after[..<end]); break }
            }
        }

        // --- Author + handle ---
        var author = "Instagram"
        var handle = ""
        // og:description often reads "Name on Instagram: ..."
        for pattern in ["property=\"og:description\" content=\"", "\"og:description\" content=\""] {
            if let range = html.range(of: pattern) {
                let after = String(html[range.upperBound...])
                if let end = after.firstIndex(of: "\"") {
                    let desc = String(after[..<end])
                    if let onRange = desc.range(of: " on Instagram") {
                        author = String(desc[..<onRange.lowerBound])
                    }
                    break
                }
            }
        }
        if let range = html.range(of: "\"username\":\"") {
            let after = String(html[range.upperBound...])
            if let end = after.firstIndex(of: "\"") { handle = "@" + String(after[..<end]) }
        }

        // --- Thumbnail ---
        var thumbnailURL: URL?
        for pattern in ["property=\"og:image\" content=\"", "\"og:image\" content=\""] {
            if let url = quotedURL(after: pattern, in: html, unescape: true) { thumbnailURL = url; break }
        }

        rLog(.ok, step: "Instagram", "Resolved video URL: \(resolvedURL.absoluteString.prefix(80))...")
        return VideoMetadata(
            videoURL: resolvedURL, title: title, author: author, handle: handle,
            caption: "", viewCount: nil, likeCount: nil, commentCount: nil, shareCount: nil,
            durationSeconds: nil, postedDate: nil, thumbnailURL: thumbnailURL
        )
    }

    // Decodes an Instagram shortcode (e.g. "DW6ez4Wl3J7") to its numeric media ID
    // using Instagram's base64-variant alphabet (A-Z a-z 0-9 - _)
    private static func shortcodeToMediaID(_ shortcode: String) -> Int64? {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        var id: Int64 = 0
        for char in shortcode {
            guard let idx = alphabet.firstIndex(of: char) else { return nil }
            let value = Int64(alphabet.distance(from: alphabet.startIndex, to: idx))
            id = id * 64 + value
        }
        return id
    }

    // Hits Instagram's private mobile API — works for public posts without login cookies
    // Build VideoMetadata from the DOM scrape dict the WKWebView posts back.
    // Returns nil if the scrape produced nothing usable (no caption, author, or thumbnail).
    private static func makeMetadataFromDOM(_ dom: [String: Any], videoURL: URL) -> VideoMetadata? {
        let rawTitle = (dom["title"] as? String) ?? ""
        let author   = (dom["author"] as? String) ?? ""
        let handle   = (dom["handle"] as? String) ?? ""
        let caption  = (dom["caption"] as? String) ?? ""
        let thumbStr = (dom["thumbnailURL"] as? String) ?? ""
        let thumbnailURL = thumbStr.isEmpty ? nil : URL(string: thumbStr)

        let likeCount    = dom["likeCount"] as? Int
        let commentCount = dom["commentCount"] as? Int

        // Consider a scrape "usable" if we got at least one real field beyond a generic title.
        if author.isEmpty && caption.isEmpty && thumbnailURL == nil && likeCount == nil {
            return nil
        }

        let title = caption.isEmpty
            ? (rawTitle.isEmpty ? "Instagram Reel" : rawTitle)
            : String(caption.prefix(60))

        let postedDate: Date?
        if let iso = dom["uploadDate"] as? String, !iso.isEmpty {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            postedDate = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        } else {
            postedDate = nil
        }

        return VideoMetadata(
            videoURL: videoURL,
            title: title,
            author: author.isEmpty ? "Instagram" : author,
            handle: handle,
            caption: caption,
            viewCount: nil,
            likeCount: likeCount,
            commentCount: commentCount,
            shareCount: nil,
            durationSeconds: nil,
            postedDate: postedDate,
            thumbnailURL: thumbnailURL
        )
    }

    // Fetches Instagram's public /embed/captioned/ page for a reel/post shortcode and
    // pulls caption, author display name, @handle, and thumbnail. The embed endpoint
    // works without login for public posts and carries richer HTML than the JS-rendered
    // main reel page.
    private static func fetchInstagramEmbedMetadata(shortcode: String, videoURL: URL) async throws -> VideoMetadata {
        let headers = instagramHeaders()
        var html = ""
        for embedPath in ["/reel/\(shortcode)/embed/captioned/", "/p/\(shortcode)/embed/captioned/"] {
            guard let embedURL = URL(string: "https://www.instagram.com\(embedPath)") else { continue }
            if let (body, _) = try? await fetchPage(embedURL, headers: headers), body.count > 500 {
                html = body
                rLog(step: "Instagram/Embed", "HTML \(body.count) bytes from \(embedPath)")
                break
            }
        }
        guard !html.isEmpty else { throw ExtractError.noVideoFound }

        // --- @handle from the first <a ... href="https://www.instagram.com/{user}/">
        var handle = ""
        if let range = html.range(of: "instagram.com/", options: []) {
            let after = html[range.upperBound...]
            if let end = after.firstIndex(where: { $0 == "/" || $0 == "\"" || $0 == "?" }) {
                let user = String(after[..<end])
                let reserved: Set<String> = ["reel", "reels", "p", "tv", "explore", "accounts", "direct", "stories", "about", "embed"]
                if !user.isEmpty && !reserved.contains(user.lowercased()) {
                    handle = "@\(user)"
                }
            }
        }

        // --- Author display name: <span class="UsernameText">display name</span>
        // Embed pages use a few class names interchangeably across years; try several.
        var author = ""
        for pattern in ["class=\"UsernameText\">", "class=\"Username\"[^>]*>", "class=\"Nickname\">"] {
            if let r = html.range(of: pattern, options: .regularExpression) {
                let after = html[r.upperBound...]
                if let end = after.firstIndex(of: "<") {
                    let name = String(after[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { author = name; break }
                }
            }
        }
        // Fallback: og:title "username on Instagram:" pattern
        if author.isEmpty,
           let r = html.range(of: "property=\"og:title\" content=\""),
           let end = html[r.upperBound...].firstIndex(of: "\"") {
            let title = String(html[r.upperBound..<end])
            if let onRange = title.range(of: " on Instagram") {
                author = String(title[..<onRange.lowerBound])
            }
        }

        // --- Caption: <div class="Caption"> ... <span class="CaptionText">{caption}</span>
        var caption = ""
        for pattern in ["class=\"CaptionText\"[^>]*>", "class=\"Caption\"[^>]*>"] {
            if let r = html.range(of: pattern, options: .regularExpression) {
                let after = html[r.upperBound...]
                if let end = after.firstIndex(of: "<") {
                    let raw = String(after[..<end])
                    let cleaned = raw
                        .replacingOccurrences(of: "&#x27;", with: "'")
                        .replacingOccurrences(of: "&#39;", with: "'")
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { caption = cleaned; break }
                }
            }
        }
        // Fallback: og:description
        if caption.isEmpty,
           let r = html.range(of: "property=\"og:description\" content=\""),
           let end = html[r.upperBound...].firstIndex(of: "\"") {
            caption = String(html[r.upperBound..<end])
        }

        // --- Thumbnail: og:image
        var thumbnailURL: URL?
        if let r = html.range(of: "property=\"og:image\" content=\""),
           let end = html[r.upperBound...].firstIndex(of: "\"") {
            let raw = String(html[r.upperBound..<end])
                .replacingOccurrences(of: "&amp;", with: "&")
            thumbnailURL = URL(string: raw)
        }

        let title = caption.isEmpty ? "Instagram Reel" : String(caption.prefix(60))

        return VideoMetadata(
            videoURL: videoURL,
            title: title,
            author: author.isEmpty ? "Instagram" : author,
            handle: handle,
            caption: caption,
            viewCount: nil,
            likeCount: nil,
            commentCount: nil,
            shareCount: nil,
            durationSeconds: nil,
            postedDate: nil,
            thumbnailURL: thumbnailURL
        )
    }

    // Pulls the first `items[0]` dict out of an Instagram /media/{id}/info response.
    private static func firstAPIItem(from json: [String: Any]) -> [String: Any]? {
        guard let items = json["items"] as? [[String: Any]] else { return nil }
        return items.first
    }

    // Shared parser for an Instagram API item — used by both the in-WKWebView cookie-backed path
    // and the URLSession fallback. Returns nil if the item has no video_versions.
    // `fallbackVideoURL` is used only if the item itself doesn't expose a video_versions URL.
    private static func parseInstagramAPIItem(_ item: [String: Any], fallbackVideoURL: URL? = nil) -> VideoMetadata? {
        let resolvedURL: URL
        if let vs = item["video_versions"] as? [[String: Any]],
           let first = vs.first,
           let urlStr = first["url"] as? String,
           let u = URL(string: urlStr) {
            resolvedURL = u
        } else if let fallback = fallbackVideoURL {
            resolvedURL = fallback
        } else {
            return nil
        }

        let user = item["user"] as? [String: Any]
        let author = user?["full_name"] as? String ?? "Instagram"
        let rawHandle = user?["username"] as? String ?? ""
        let handle = rawHandle.isEmpty ? "" : "@\(rawHandle)"

        let caption = (item["caption"] as? [String: Any])?["text"] as? String ?? ""
        let title = caption.isEmpty ? "Instagram Reel" : String(caption.prefix(60))

        let likeCount    = item["like_count"] as? Int
        let commentCount = item["comment_count"] as? Int
        let viewCount    = item["play_count"] as? Int ?? item["view_count"] as? Int

        let durationSeconds: Int?
        if let dur = item["video_duration"] as? Double { durationSeconds = Int(dur) }
        else if let dur = item["video_duration"] as? Int { durationSeconds = dur }
        else { durationSeconds = nil }

        let postedDate: Date?
        if let ts = item["taken_at"] as? TimeInterval { postedDate = Date(timeIntervalSince1970: ts) }
        else if let ts = item["taken_at"] as? Int { postedDate = Date(timeIntervalSince1970: TimeInterval(ts)) }
        else { postedDate = nil }

        let thumbnailURL: URL?
        if let imageSets = item["image_versions2"] as? [String: Any],
           let candidates = imageSets["candidates"] as? [[String: Any]],
           let firstImg = candidates.first,
           let imgStr = firstImg["url"] as? String {
            thumbnailURL = URL(string: imgStr)
        } else {
            thumbnailURL = nil
        }

        return VideoMetadata(
            videoURL: resolvedURL, title: title, author: author, handle: handle,
            caption: caption, viewCount: viewCount, likeCount: likeCount,
            commentCount: commentCount, shareCount: nil,
            durationSeconds: durationSeconds, postedDate: postedDate, thumbnailURL: thumbnailURL
        )
    }

    private static func fetchInstagramFromAPI(mediaID: Int64, originalURL: String) async throws -> VideoMetadata {
        guard let apiURL = URL(string: "https://i.instagram.com/api/v1/media/\(mediaID)/info/") else {
            throw ExtractError.noVideoFound
        }
        var request = URLRequest(url: apiURL)
        request.setValue(
            "Instagram 350.0.0.31.100 Android (34/14; 420dpi; 1080x2400; samsung; SM-S918B; b0q; qcom; en_US; 628376847)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        rLog(status == 200 ? .ok : .fail, step: "Instagram", "API \(status), \(data.count) bytes")
        if status != 200, let snippet = String(data: data.prefix(300), encoding: .utf8) {
            rLog(.fail, step: "Instagram", "API error body: \(snippet)")
        }

        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = firstAPIItem(from: json),
              let meta = parseInstagramAPIItem(item) else {
            throw ExtractError.noVideoFound
        }

        rLog(.ok, step: "Instagram", "API: \(meta.author) | dur:\(meta.durationSeconds ?? 0)s")
        return meta
    }

    // MARK: - Twitter / X

    private static func fetchTwitterMetadata(pageURL: URL, originalURL: String) async throws -> VideoMetadata {
        rLog(step: "Twitter", "Loading page via WKWebView: \(pageURL.absoluteString.prefix(80))")

        let videoURL: URL? = await Task { @MainActor in
            let e = TwitterWebExtractor()
            return await e.extract(from: pageURL)
        }.value

        guard let resolvedURL = videoURL else {
            rLog(.fail, step: "Twitter", "WKWebView found no video — post may require login or has no video")
            throw ExtractError.downloadFailed(
                "Twitter/X did not return a video URL. The post may require login or contain no video. Make sure you're logged into Twitter in Safari."
            )
        }

        rLog(.ok, step: "Twitter", "Got video URL: \(resolvedURL.absoluteString.prefix(80))...")
        return VideoMetadata(
            videoURL: resolvedURL,
            title: "Twitter Video",
            author: "Twitter",
            handle: "",
            caption: "",
            viewCount: nil, likeCount: nil, commentCount: nil, shareCount: nil,
            durationSeconds: nil, postedDate: nil, thumbnailURL: nil
        )
    }

    private static func quotedURL(after pattern: String, in html: String, unescape: Bool) -> URL? {
        guard let range = html.range(of: pattern) else { return nil }
        let after = String(html[range.upperBound...])
        guard let end = after.firstIndex(of: "\"") else { return nil }
        var raw = String(after[..<end])
        if unescape { raw = raw.replacingOccurrences(of: "&amp;", with: "&") }
        return URL(string: raw)
    }

    // MARK: - Download + Audio

    static func downloadAudio(
        from videoURL: URL,
        progress: @escaping (Double) -> Void
    ) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory

        // Twitter's HLS player sets video.src to an .m3u8 manifest.
        // URLSession can't stream HLS natively — skip the download and export via AVFoundation.
        if videoURL.pathExtension.lowercased() == "m3u8" {
            rLog(step: "Download", "HLS manifest detected — exporting via AVFoundation...")
            progress(0.2)
            let audioFile = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
            let actualAudioFile = try await extractAudio(from: videoURL, to: audioFile)
            progress(1.0)
            return actualAudioFile
        }

        // All Instagram CDN URLs (scontent.cdninstagram.com and *.fna.fbcdn.net/o1/...)
        // use DASH byte-range params (bytestart/byteend) and require session cookies.
        // The intercepted URL is usually just the init segment (byteend ~823 bytes).
        // Strategy: expand byteend to 8MB and download via URLSession with cookies.
        // The CDN's HMAC signature (oh= param) covers path + expiry, not the byte range,
        // so expanding it should return the full audio data.
        let host = videoURL.host ?? ""
        let isInstagramCDN = host.contains("cdninstagram") || host.contains("fbcdn")
        if isInstagramCDN {
            let cookieHeader = await instagramCookieHeader()
            rLog(step: "Download", "Cookie header: \(cookieHeader.isEmpty ? "none" : "\(cookieHeader.count) chars")")

            // Build URL with expanded byte range (keep all other params including signature)
            var expandedURL = videoURL
            if var comps = URLComponents(url: videoURL, resolvingAgainstBaseURL: false) {
                var items = comps.queryItems ?? []
                items.removeAll { $0.name == "bytestart" || $0.name == "byteend" }
                items.append(URLQueryItem(name: "bytestart", value: "0"))
                items.append(URLQueryItem(name: "byteend", value: "104857599"))  // 100MB — covers even long Reels
                comps.queryItems = items
                expandedURL = comps.url ?? videoURL
            }
            rLog(step: "Download", "Instagram CDN — attempting full audio via URLSession (byteend expanded to 100MB)...")
            progress(0.1)

            var dlRequest = URLRequest(url: expandedURL)
            dlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            dlRequest.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
            dlRequest.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

            let (data, response) = try await URLSession.shared.data(for: dlRequest)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            rLog(step: "Download", "Instagram CDN response: \(statusCode), \(data.count) bytes")

            guard data.count > 10_000 else {
                throw ExtractError.downloadFailed("Instagram CDN returned too few bytes (\(data.count)) — URL may have expired or cookies are invalid")
            }

            let rawFile = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")
            try data.write(to: rawFile)
            defer { try? FileManager.default.removeItem(at: rawFile) }
            progress(0.5)
            rLog(.ok, step: "Download", "Instagram CDN download success — \(data.count) bytes — decoding with AVAssetReader...")

            let audioFile = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
            let actualAudioFile = try await extractAudioWithReader(from: rawFile, to: audioFile)
            progress(1.0)
            return actualAudioFile
        }

        let videoFile = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")

        var request = URLRequest(url: videoURL)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let referer: String
        if host.contains("cdninstagram") || host.contains("fbcdn") {
            referer = "https://www.instagram.com/"
        } else if host.contains("twimg.com") {
            referer = "https://twitter.com/"
        } else {
            referer = "https://www.tiktok.com/"
        }
        request.setValue(referer, forHTTPHeaderField: "Referer")
        request.setValue("video/mp4,video/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        progress(0.1)
        rLog(step: "Download", "Streaming video to disk (no RAM buffer)...")
        let tDL = Date()

        // download(for:) streams directly to a temp file — no full-video RAM buffer
        // One auto-retry on transient network failure (cell handoff, packet loss).
        let (tmpURL, response) = try await downloadWithRetry(request: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ExtractError.downloadFailed("Server returned \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        // Move from URLSession's temp location to our named file
        try FileManager.default.moveItem(at: tmpURL, to: videoFile)

        let fileSizeMB = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)[.size] as? Int)
            .map { String(format: "%.1f MB", Double($0) / 1_048_576) } ?? "unknown size"
        rLog(.ok, step: "Download", "Video on disk: \(fileSizeMB) in \(String(format: "%.2fs", Date().timeIntervalSince(tDL)))")
        progress(0.6)

        // Optionally save the downloaded video to Photos before it gets deleted
        if MarkdownStylePrefs.shared.saveVideoToCameraRoll {
            await saveVideoToPhotos(url: videoFile)
        }

        rLog(step: "Download", "Extracting audio track...")
        let tAudio = Date()
        let audioFile = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")
        let actualAudioFile = try await extractAudio(from: videoFile, to: audioFile)
        rLog(.ok, step: "Download", "Audio extracted in \(String(format: "%.2fs", Date().timeIntervalSince(tAudio))) — \(actualAudioFile.lastPathComponent)")
        try? FileManager.default.removeItem(at: videoFile)
        progress(1.0)

        return actualAudioFile
    }

    /// User-picked file path: handles both audio (passthrough copy to temp) and video
    /// (AVAssetExportSession to .m4a). Caller manages security-scoped resource access.
    static func extractAudioFromLocalFile(_ fileURL: URL) async throws -> URL {
        let ext = fileURL.pathExtension.lowercased()
        let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf", "mp4a"]
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".m4a")

        if audioExtensions.contains(ext) {
            // Audio file — copy to temp so the security-scoped original can be released
            // after this returns. Whisper reads from the copy.
            try FileManager.default.copyItem(at: fileURL, to: outputURL)
            rLog(.ok, step: "LocalFile", "Audio passthrough copied to \(outputURL.lastPathComponent)")
            return outputURL
        }

        // Video file — extract audio via AVAssetExportSession
        rLog(step: "LocalFile", "Extracting audio from video \(fileURL.lastPathComponent)")
        return try await extractAudio(from: fileURL, to: outputURL)
    }

    /// Single auto-retry on transient network errors (cell handoff, packet loss, brief drops).
    /// Catches connection-lost / timeout / not-connected and tries one more time after 1s.
    /// Other errors propagate immediately so real failures don't get masked by retries.
    private static func downloadWithRetry(request: URLRequest, maxAttempts: Int = 2) async throws -> (URL, URLResponse) {
        var lastError: Error = URLError(.unknown)
        for attempt in 1...maxAttempts {
            do {
                return try await URLSession.shared.download(for: request)
            } catch let error as URLError where [.networkConnectionLost, .timedOut, .notConnectedToInternet].contains(error.code) {
                rLog(step: "Download", "Attempt \(attempt) failed (\(error.code.rawValue)), retrying...")
                lastError = error
                try? await Task.sleep(for: .seconds(1))
                continue
            }
        }
        throw lastError
    }

    private static func saveVideoToPhotos(url: URL) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            rLog(.fail, step: "Photos", "Authorization denied — video not saved to camera roll")
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }
            rLog(.ok, step: "Photos", "Video saved to camera roll")
        } catch {
            rLog(.fail, step: "Photos", "Failed to save video: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func instagramCookieHeader() async -> String {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies
            .filter { $0.domain.contains("instagram.com") || $0.domain.contains("fbcdn.net") }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    /// Decodes audio from a fragmented MP4 (DASH segment) using AVAssetReader.
    // internal (not private) so the test target can reach it via @testable import
    /// AVAssetExportSession cannot seek across fMP4 fragment boundaries ("Invalid sample cursor"),
    /// but AVAssetReader reads linearly without seeking — making it the right tool for DASH audio.
    /// Output is a 16kHz mono WAV file, which WhisperKit accepts natively.
    static func extractAudioWithReader(from fileURL: URL, to outputURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            rLog(.fail, step: "Audio", "AVAssetReader: no audio tracks in downloaded file")
            throw ExtractError.audioExportFailed
        }

        let reader = try AVAssetReader(asset: asset)
        let pcmSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        guard reader.startReading() else {
            rLog(.fail, step: "Audio", "AVAssetReader: startReading failed — \(reader.error?.localizedDescription ?? "unknown")")
            throw ExtractError.audioExportFailed
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true) else {
            rLog(.fail, step: "Audio", "AVAudioFormat init returned nil")
            throw ExtractError.audioExportFailed
        }
        let wavURL = outputURL.deletingPathExtension().appendingPathExtension("wav")
        let outFile = try AVAudioFile(forWriting: wavURL, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)

        var totalFrames = 0
        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
            guard numSamples > 0, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuffer)
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else { continue }
            pcmBuffer.frameLength = AVAudioFrameCount(numSamples)
            guard let channelData = pcmBuffer.int16ChannelData else { continue }
            CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount,
                                       destination: UnsafeMutableRawPointer(channelData[0]))
            try outFile.write(from: pcmBuffer)
            totalFrames += numSamples
        }

        rLog(.ok, step: "Audio", "AVAssetReader: decoded \(totalFrames) samples → \(wavURL.lastPathComponent)")
        guard totalFrames > 0 else {
            throw ExtractError.audioExportFailed
        }
        return wavURL
    }

    // Returns the URL of the file actually written — may differ from audioURL if fallback path was used.
    @discardableResult
    /// Extracts a `.m4a` audio track from a video URL via AVAssetExportSession.
    /// Internal so the local-file import path can reuse it.
    static func extractAudio(from videoURL: URL, to audioURL: URL, httpHeaders: [String: String] = [:]) async throws -> URL {
        let assetOptions: [String: Any] = httpHeaders.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders]
        let asset = AVURLAsset(url: videoURL, options: assetOptions.isEmpty ? nil : assetOptions)
        let tracks = try await asset.loadTracks(withMediaType: .audio)

        if tracks.isEmpty {
            // No dedicated audio track detected. Try M4A anyway — some encoded formats
            // report zero audio tracks but still export fine. Fall back to passthrough MP4
            // only if that fails, and return whichever file actually exists.
            if let m4aSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) {
                do {
                    try await m4aSession.export(to: audioURL, as: .m4a)
                    if FileManager.default.fileExists(atPath: audioURL.path) {
                        rLog(.warn, step: "Audio", "No audio tracks detected but M4A export succeeded")
                        return audioURL
                    }
                } catch {
                    rLog(.warn, step: "Audio", "M4A export failed on no-track video: \(error.localizedDescription)")
                }
            }
            // Final fallback: passthrough to MP4
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
                throw ExtractError.audioExportFailed
            }
            let mp4URL = audioURL.deletingPathExtension().appendingPathExtension("mp4")
            try await exportSession.export(to: mp4URL, as: .mp4)
            guard FileManager.default.fileExists(atPath: mp4URL.path) else {
                throw ExtractError.audioExportFailed
            }
            rLog(.warn, step: "Audio", "Used passthrough MP4 export — no audio track")
            return mp4URL
        } else {
            guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                throw ExtractError.audioExportFailed
            }
            try await exportSession.export(to: audioURL, as: .m4a)
            return audioURL
        }
    }
}
