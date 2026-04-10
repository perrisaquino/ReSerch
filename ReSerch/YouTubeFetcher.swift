import Foundation

enum YouTubeFetcher {
    enum FetchError: LocalizedError {
        case noCaptionsAvailable
        case invalidResponse
        case networkError(String)

        var errorDescription: String? {
            switch self {
            case .noCaptionsAvailable:
                return "No captions found. This video may not have auto-generated subtitles."
            case .invalidResponse:
                return "Could not parse YouTube response."
            case .networkError(let msg):
                return "Network error: \(msg)"
            }
        }
    }

    static func fetch(videoId: String, originalURL: String) async throws -> TranscriptResult {
        let pageURL = URL(string: "https://www.youtube.com/watch?v=\(videoId)")!
        rLog(step: "YouTube", "Fetching page: \(pageURL)")

        var request = URLRequest(url: pageURL)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        rLog(status == 200 ? .ok : .fail, step: "YouTube", "HTTP \(status), \(data.count) bytes")

        guard status == 200, let html = String(data: data, encoding: .utf8) else {
            throw FetchError.networkError("HTTP \(status)")
        }

        rLog(step: "YouTube", "hasCaptions:\(html.contains("captionTracks")) hasPlayerResponse:\(html.contains("ytInitialPlayerResponse"))")

        let meta = extractMetadata(from: html, videoId: videoId, originalURL: originalURL)
        let captionURL = try extractCaptionURL(from: html)
        rLog(.ok, step: "YouTube", "Caption URL found")
        let transcript = try await fetchAndParseCaptions(from: captionURL)
        rLog(.ok, step: "YouTube", "Transcript: \(transcript.count) chars")

        return TranscriptResult(
            title: meta.title,
            author: meta.author,
            handle: meta.handle,
            platform: "YouTube",
            url: originalURL,
            caption: meta.description,
            transcript: transcript,
            viewCount: meta.viewCount,
            likeCount: nil,
            duration: meta.duration,
            postedDate: meta.postedDate,
            thumbnailURL: URL(string: "https://img.youtube.com/vi/\(videoId)/maxresdefault.jpg")
        )
    }

    // MARK: - Metadata

    private struct YouTubeMeta {
        var title = "Untitled"
        var author = "Unknown"
        var handle = ""
        var description = ""
        var viewCount: Int? = nil
        var duration: String? = nil
        var postedDate: Date? = nil
    }

    private static func extractMetadata(from html: String, videoId: String, originalURL: String) -> YouTubeMeta {
        var meta = YouTubeMeta()

        // ytInitialPlayerResponse contains videoDetails
        if let range = html.range(of: "ytInitialPlayerResponse\\s*=\\s*", options: .regularExpression),
           let jsonStart = html[range.upperBound...].firstIndex(of: "{") {
            let from = String(html[jsonStart...])
            if let jsonData = extractBalancedJSON(from: from),
               let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let videoDetails = dict["videoDetails"] as? [String: Any] {
                meta.title = videoDetails["title"] as? String ?? meta.title
                meta.author = videoDetails["author"] as? String ?? meta.author
                meta.description = (videoDetails["shortDescription"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let vc = videoDetails["viewCount"] as? String { meta.viewCount = Int(vc) }
                if let ls = videoDetails["lengthSeconds"] as? String, let secs = Int(ls) {
                    meta.duration = formatSeconds(secs)
                }
            }
        }

        // Upload date from microformat
        if let range = html.range(of: "\"publishDate\":\"") {
            let after = String(html[range.upperBound...])
            if let end = after.firstIndex(of: "\"") {
                let dateStr = String(after[..<end])
                meta.postedDate = ISO8601DateFormatter().date(from: dateStr)
            }
        }

        // Channel handle
        if let range = html.range(of: "\"vanityUrls\":[\"@") {
            let after = String(html[range.upperBound...])
            if let end = after.firstIndex(of: "\"") {
                meta.handle = "@" + String(after[..<end])
            }
        } else if let range = html.range(of: "\"channelId\":\"") {
            let after = String(html[range.upperBound...])
            if let end = after.firstIndex(of: "\"") {
                meta.handle = String(after[..<end])
            }
        }

        return meta
    }

    private static func extractBalancedJSON(from string: String) -> Data? {
        var depth = 0
        var inString = false
        var escaped = false
        var endIndex = string.startIndex

        for (i, char) in string.enumerated() {
            let idx = string.index(string.startIndex, offsetBy: i)
            if escaped { escaped = false; endIndex = idx; continue }
            if char == "\\" && inString { escaped = true; endIndex = idx; continue }
            if char == "\"" { inString.toggle(); endIndex = idx; continue }
            if !inString {
                if char == "{" { depth += 1 }
                else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = string.index(after: idx)
                        let jsonStr = String(string[..<endIndex])
                        return jsonStr.data(using: .utf8)
                    }
                }
            }
            endIndex = idx
        }
        return nil
    }

    private static func formatSeconds(_ s: Int) -> String {
        let m = s / 60; let sec = s % 60
        return String(format: "%d:%02d", m, sec)
    }

    // MARK: - Captions

    private static func extractCaptionURL(from html: String) throws -> URL {
        guard let captionRange = html.range(of: "\"captionTracks\":") else {
            throw FetchError.noCaptionsAvailable
        }
        let afterCaption = String(html[captionRange.upperBound...])
        guard let baseUrlRange = afterCaption.range(of: "\"baseUrl\":\"") else {
            throw FetchError.noCaptionsAvailable
        }
        let afterBaseUrl = String(afterCaption[baseUrlRange.upperBound...])
        guard let endQuote = afterBaseUrl.firstIndex(of: "\"") else {
            throw FetchError.noCaptionsAvailable
        }
        var rawURL = String(afterBaseUrl[..<endQuote])
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u003d", with: "=")
        if !rawURL.contains("fmt=") { rawURL += "&fmt=json3" }
        guard let url = URL(string: rawURL) else { throw FetchError.invalidResponse }
        return url
    }

    private static func fetchAndParseCaptions(from url: URL) async throws -> String {
        let (data, _) = try await URLSession.shared.data(from: url)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let events = json["events"] as? [[String: Any]] {
            return parseJSON3Events(events)
        }
        if let xml = String(data: data, encoding: .utf8) {
            return parseXMLCaptions(xml)
        }
        throw FetchError.invalidResponse
    }

    private static func parseJSON3Events(_ events: [[String: Any]]) -> String {
        var paragraphs: [String] = []
        var currentWords: [String] = []
        var lastEventEndMs: Int = 0

        for event in events {
            guard let segs = event["segs"] as? [[String: Any]] else { continue }
            let startMs = event["tStartMs"] as? Int ?? 0
            let durationMs = event["dDurationMs"] as? Int ?? 0

            let line = segs.compactMap { $0["utf8"] as? String }.joined()
            let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty || cleaned == "\n" { continue }

            // Gap > 2 seconds between events = natural pause, start new paragraph
            let gap = startMs - lastEventEndMs
            if lastEventEndMs > 0 && gap > 2000 && !currentWords.isEmpty {
                paragraphs.append(currentWords.joined(separator: " "))
                currentWords = []
            }

            currentWords.append(cleaned)
            lastEventEndMs = startMs + durationMs
        }

        if !currentWords.isEmpty {
            paragraphs.append(currentWords.joined(separator: " "))
        }

        return paragraphs.joined(separator: "\n\n")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseXMLCaptions(_ xml: String) -> String {
        var result = ""
        var remaining = xml
        while let textStart = remaining.range(of: "<text "),
              let contentStart = remaining[textStart.upperBound...].range(of: ">"),
              let contentEnd = remaining[contentStart.upperBound...].range(of: "</text>") {
            let content = String(remaining[contentStart.upperBound..<contentEnd.lowerBound])
            let decoded = htmlDecode(content)
            if !decoded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result += decoded + " "
            }
            remaining = String(remaining[contentEnd.upperBound...])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func htmlDecode(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
