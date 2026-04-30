import Foundation

/// Scrapes a TikTok user-created playlist page into a list of videos + playlist name.
///
/// TikTok embeds the full rehydration payload inside a
/// `<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__">{...}</script>` block.
/// For playlist URLs the payload includes a `playlistDetail` section with a mixlist
/// (item list) that carries per-video metadata (id, desc, video.cover, video.duration,
/// author).
enum TikTokPlaylistExtractor {
    enum Error: LocalizedError {
        case pageFetchFailed(String)
        case payloadNotFound
        case emptyPlaylist

        var errorDescription: String? {
            switch self {
            case .pageFetchFailed(let msg): return "Could not load playlist page: \(msg)"
            case .payloadNotFound:          return "TikTok did not return playlist data. The playlist may be private or the URL format may have changed."
            case .emptyPlaylist:            return "Playlist appears to have no videos."
            }
        }
    }

    static func fetch(playlistURL url: URL) async throws -> TikTokPlaylistSummary {
        rLog(step: "Playlist", "Fetching: \(url.absoluteString)")
        let (html, finalURL): (String, URL)
        do {
            (html, finalURL) = try await VideoExtractor.fetchTikTokPage(url)
        } catch {
            throw Error.pageFetchFailed(error.localizedDescription)
        }
        rLog(step: "Playlist", "HTML \(html.count) bytes | final: \(finalURL.absoluteString)")

        guard let payload = universalDataPayload(from: html) else {
            throw Error.payloadNotFound
        }

        return try parse(payload: payload, fallbackURL: finalURL)
    }

    // MARK: - HTML slice

    private static func universalDataPayload(from html: String) -> [String: Any]? {
        guard let scriptStart = html.range(of: "id=\"__UNIVERSAL_DATA_FOR_REHYDRATION__") else {
            return nil
        }
        let after = html[scriptStart.upperBound...]
        guard let open = after.range(of: ">"),
              let close = after.range(of: "</script>") else { return nil }
        let jsonSlice = after[open.upperBound..<close.lowerBound]
        guard let data = String(jsonSlice).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Payload walk

    private static func parse(payload: [String: Any], fallbackURL: URL) throws -> TikTokPlaylistSummary {
        // Drill into the scope that carries the playlist payload. TikTok shifts the exact
        // nesting occasionally — search a handful of likely paths.
        let defaultScope = (payload["__DEFAULT_SCOPE__"] as? [String: Any]) ?? payload

        let playlistDetail: [String: Any]? =
            (defaultScope["webapp.playlist-detail"] as? [String: Any])
            ?? (defaultScope["webapp.playlist"] as? [String: Any])
            ?? (defaultScope["playlistDetail"] as? [String: Any])

        let detail = playlistDetail ?? defaultScope  // last-resort: scan defaultScope directly

        let items: [[String: Any]]
        if let mixList = detail["mixList"] as? [[String: Any]] { items = mixList }
        else if let list = detail["itemList"] as? [[String: Any]] { items = list }
        else if let list = detail["items"] as? [[String: Any]] { items = list }
        else {
            rLog(.fail, step: "Playlist", "No mixList/itemList in payload. Keys: \(detail.keys.joined(separator: ","))")
            throw Error.payloadNotFound
        }

        guard !items.isEmpty else { throw Error.emptyPlaylist }

        let playlistInfo = (detail["playlistInfo"] as? [String: Any])
            ?? (detail["mixInfo"] as? [String: Any])
        let playlistName = (playlistInfo?["mixName"] as? String)
            ?? (playlistInfo?["name"] as? String)
            ?? (detail["name"] as? String)
            ?? "TikTok Playlist"
        let playlistID = (playlistInfo?["mixId"] as? String)
            ?? (playlistInfo?["id"] as? String)
            ?? (detail["id"] as? String)
            ?? ""

        // Creator handle is usually on the first item's author, but some payloads hoist it.
        var ownerHandle = ""
        if let author = items.first?["author"] as? [String: Any],
           let unique = author["uniqueId"] as? String, !unique.isEmpty {
            ownerHandle = "@\(unique)"
        } else if let ownerAuthor = detail["userInfo"] as? [String: Any],
                  let user = ownerAuthor["user"] as? [String: Any],
                  let unique = user["uniqueId"] as? String {
            ownerHandle = "@\(unique)"
        }

        let entries: [PlaylistVideoEntry] = items.compactMap { entry(from: $0) }
        guard !entries.isEmpty else { throw Error.emptyPlaylist }

        rLog(.ok, step: "Playlist", "Parsed \(entries.count) videos | name: \(playlistName)")
        return TikTokPlaylistSummary(
            playlistID: playlistID,
            playlistName: playlistName,
            ownerHandle: ownerHandle,
            videos: entries
        )
    }

    private static func entry(from item: [String: Any]) -> PlaylistVideoEntry? {
        guard let id = item["id"] as? String, !id.isEmpty else { return nil }

        let authorDict = item["author"] as? [String: Any]
        let author = authorDict?["nickname"] as? String ?? ""
        let handle: String
        if let u = authorDict?["uniqueId"] as? String, !u.isEmpty { handle = "@\(u)" }
        else { handle = "" }

        let video = item["video"] as? [String: Any]
        let thumbStr = (video?["cover"] as? String)
            ?? (video?["originCover"] as? String)
            ?? (video?["dynamicCover"] as? String)
        let thumbnailURL = thumbStr.flatMap(URL.init(string:))

        let duration: Int?
        if let d = video?["duration"] as? Int { duration = d }
        else if let d = video?["duration"] as? Double { duration = Int(d) }
        else { duration = nil }

        let caption = (item["desc"] as? String) ?? ""
        let captionPreview = caption.isEmpty ? "" : String(caption.prefix(80))

        // Canonical page URL — use author handle if present, else a stable fallback
        // that TikTok's redirect layer accepts.
        let pageURL: URL
        if !handle.isEmpty,
           let u = URL(string: "https://www.tiktok.com/\(handle)/video/\(id)") {
            pageURL = u
        } else if let u = URL(string: "https://www.tiktok.com/@placeholder/video/\(id)") {
            pageURL = u
        } else {
            return nil
        }

        return PlaylistVideoEntry(
            id: id,
            videoPageURL: pageURL,
            captionPreview: captionPreview,
            thumbnailURL: thumbnailURL,
            durationSeconds: duration,
            author: author,
            handle: handle
        )
    }
}
