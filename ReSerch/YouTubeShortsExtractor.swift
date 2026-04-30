import Foundation
import YouTubeKit

struct YouTubeShortsResult {
    let audioURL: URL
    let title: String
    let author: String
    let handle: String
    let description: String
    let viewCount: Int?
    let likeCount: Int?
    let duration: String?
    let postedDate: Date?
    let thumbnailURL: URL?
}

/// YouTube Shorts audio extraction via YouTubeKit — a maintained Swift port of yt-dlp's
/// extraction logic. Handles signatureCipher decoding via an embedded JS runtime, returns
/// a direct audio stream URL the existing `VideoExtractor.downloadAudio` pipeline can fetch.
///
/// Why this replaced the old WKWebView-based extractor: modern YouTube ciphers most stream
/// URLs in `signatureCipher`. Our own JS interception worked maybe 30% of the time, even
/// after sign-in. YouTubeKit handles the cipher properly and works without any sign-in.
@MainActor
enum YouTubeShortsExtractor {
    static func extract(videoId: String) async -> YouTubeShortsResult? {
        // Run YouTubeKit audio extraction and watch-page metadata fetch in parallel.
        // Watch-page metadata gives us author/handle/viewCount/postedDate that YouTubeKit lacks.
        // If metadata fetch fails, we fall back to YouTubeKit's partial meta — partial info beats no transcript.
        async let ytkResult = extractAudioStream(videoId: videoId)
        async let watchPageMeta = fetchWatchPageMetadata(videoId: videoId)

        let (ytkOpt, pageMeta) = await (ytkResult, watchPageMeta)

        guard let ytk = ytkOpt else { return nil }

        return YouTubeShortsResult(
            audioURL: ytk.stream.url,
            title: pageMeta?.title ?? ytk.meta?.title ?? "YouTube Short",
            author: pageMeta?.author ?? "",
            handle: pageMeta?.handle ?? "",
            description: pageMeta?.description ?? ytk.meta?.description ?? "",
            viewCount: pageMeta?.viewCount,
            likeCount: nil,
            duration: pageMeta?.duration,
            postedDate: pageMeta?.postedDate,
            thumbnailURL: ytk.meta?.thumbnail?.url ?? URL(string: "https://img.youtube.com/vi/\(videoId)/maxresdefault.jpg")
        )
    }

    private struct YTKResult {
        let stream: YouTubeKit.Stream
        let meta: YouTubeKit.YouTubeMetadata?
    }

    private static func extractAudioStream(videoId: String) async -> YTKResult? {
        do {
            let yt = YouTube(videoID: videoId)
            let streams = try await yt.streams
            let meta = try? await yt.metadata

            let audioStream =
                streams.filterAudioOnly()
                    .filter { $0.fileExtension == .m4a }
                    .highestAudioBitrateStream()
                ?? streams.filterAudioOnly().highestAudioBitrateStream()

            guard let stream = audioStream else {
                rLog(.fail, step: "Shorts/YTKit", "No audio stream found")
                return nil
            }

            rLog(.ok, step: "Shorts/YTKit", "Got audio stream: \(stream.fileExtension) @ \(stream.bitrate ?? 0)bps")
            return YTKResult(stream: stream, meta: meta)
        } catch {
            rLog(.fail, step: "Shorts/YTKit", "Extraction failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fetches the watch page HTML and runs the same metadata extractor used by the captions path,
    /// so Shorts cards get author/handle/viewCount/postedDate/duration parity with TikTok and Instagram.
    /// Returns nil on any failure — caller falls back to YouTubeKit's partial meta.
    private static func fetchWatchPageMetadata(videoId: String) async -> YouTubeFetcher.YouTubeMeta? {
        guard let pageURL = URL(string: "https://www.youtube.com/watch?v=\(videoId)") else { return nil }
        var request = URLRequest(url: pageURL)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("CONSENT=YES+cb; SOCS=CAI", forHTTPHeaderField: "Cookie")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let html = String(data: data, encoding: .utf8) else {
                rLog(.fail, step: "Shorts/Meta", "Watch page HTTP \(status), falling back to YTKit meta")
                return nil
            }
            // Detect consent/captcha gates served with 200
            if html.contains("recaptcha") || html.contains("/sorry/") || html.contains("Before you continue to YouTube") {
                rLog(.fail, step: "Shorts/Meta", "Consent gate, falling back to YTKit meta")
                return nil
            }
            let meta = YouTubeFetcher.extractMetadata(from: html, videoId: videoId, originalURL: pageURL.absoluteString)
            rLog(.ok, step: "Shorts/Meta", "Got author=\(meta.author) views=\(meta.viewCount ?? 0)")
            return meta
        } catch {
            rLog(.fail, step: "Shorts/Meta", "Watch page fetch failed: \(error.localizedDescription)")
            return nil
        }
    }
}
