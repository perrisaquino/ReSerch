import Foundation
import AVFoundation
import Photos

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
        default:
            throw ExtractError.noVideoFound
        }
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

        // Strategy 0: WKWebView with shared Safari session — works when user is logged into Instagram in Safari
        let webVideoURL: URL? = await Task { @MainActor in
            let e = InstagramWebExtractor()
            return await e.extract(from: pageURL)
        }.value
        if let videoURL = webVideoURL {
            rLog(.ok, step: "Instagram", "WKWebView: \(videoURL.absoluteString.prefix(60))...")
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
    private static func fetchInstagramFromAPI(mediaID: Int64, originalURL: String) async throws -> VideoMetadata {
        guard let apiURL = URL(string: "https://i.instagram.com/api/v1/media/\(mediaID)/info/") else {
            throw ExtractError.noVideoFound
        }
        var request = URLRequest(url: apiURL)
        request.setValue(
            "Instagram 275.0.0.27.98 Android (33/13; 420dpi; 1080x2400; samsung; SM-G998B; p3q; qcom; en_US; 458229258)",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        request.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        rLog(status == 200 ? .ok : .fail, step: "Instagram", "API \(status), \(data.count) bytes")

        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]],
              let item = items.first else {
            throw ExtractError.noVideoFound
        }

        // Video URL
        guard let videoVersions = item["video_versions"] as? [[String: Any]],
              let first = videoVersions.first,
              let urlStr = first["url"] as? String,
              let resolvedURL = URL(string: urlStr) else {
            throw ExtractError.noVideoFound
        }

        // Author
        let user = item["user"] as? [String: Any]
        let author = user?["full_name"] as? String ?? "Instagram"
        let rawHandle = user?["username"] as? String ?? ""
        let handle = rawHandle.isEmpty ? "" : "@\(rawHandle)"

        // Caption + title
        let caption = (item["caption"] as? [String: Any])?["text"] as? String ?? ""
        let title = caption.isEmpty ? "Instagram Reel" : String(caption.prefix(60))

        // Stats
        let likeCount    = item["like_count"] as? Int
        let commentCount = item["comment_count"] as? Int
        let viewCount    = item["play_count"] as? Int ?? item["view_count"] as? Int

        // Duration
        let durationSeconds: Int?
        if let dur = item["video_duration"] as? Double { durationSeconds = Int(dur) }
        else if let dur = item["video_duration"] as? Int { durationSeconds = dur }
        else { durationSeconds = nil }

        // Posted date
        let postedDate: Date?
        if let ts = item["taken_at"] as? TimeInterval { postedDate = Date(timeIntervalSince1970: ts) }
        else if let ts = item["taken_at"] as? Int { postedDate = Date(timeIntervalSince1970: TimeInterval(ts)) }
        else { postedDate = nil }

        // Thumbnail
        let thumbnailURL: URL?
        if let imageSets = item["image_versions2"] as? [String: Any],
           let candidates = imageSets["candidates"] as? [[String: Any]],
           let firstImg = candidates.first,
           let imgStr = firstImg["url"] as? String {
            thumbnailURL = URL(string: imgStr)
        } else {
            thumbnailURL = nil
        }

        rLog(.ok, step: "Instagram", "API: \(author) | dur:\(durationSeconds ?? 0)s")
        return VideoMetadata(
            videoURL: resolvedURL, title: title, author: author, handle: handle,
            caption: caption, viewCount: viewCount, likeCount: likeCount,
            commentCount: commentCount, shareCount: nil,
            durationSeconds: durationSeconds, postedDate: postedDate, thumbnailURL: thumbnailURL
        )
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

        let videoFile = tempDir.appendingPathComponent(UUID().uuidString + ".mp4")

        var request = URLRequest(url: videoURL)
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        let host = videoURL.host ?? ""
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
        let (tmpURL, response) = try await URLSession.shared.download(for: request)

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

    // Returns the URL of the file actually written — may differ from audioURL if fallback path was used.
    @discardableResult
    private static func extractAudio(from videoURL: URL, to audioURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
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
