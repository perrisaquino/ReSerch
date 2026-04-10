import Foundation

struct Annotation: Codable, Identifiable {
    let id: UUID
    var text: String
    var comment: String
    var offset: Int
    let createdAt: Date

    init(text: String, comment: String = "", offset: Int) {
        self.id = UUID()
        self.text = text
        self.comment = comment
        self.offset = offset
        self.createdAt = Date()
    }
}

struct TranscriptResult: Codable {
    var title: String
    var editableTitle: String
    let author: String
    let handle: String
    let platform: String
    let url: String
    let caption: String
    var transcript: String
    var annotations: [Annotation] = []
    let viewCount: Int?
    let likeCount: Int?
    let commentCount: Int?
    let shareCount: Int?
    let duration: String?
    let postedDate: Date?
    let thumbnailURL: URL?

    enum CodingKeys: String, CodingKey {
        case title, editableTitle, author, handle, platform, url, caption
        case transcript, annotations
        case viewCount, likeCount, commentCount, shareCount
        case duration, postedDate, thumbnailURL
    }

    init(
        title: String,
        author: String,
        handle: String = "",
        platform: String,
        url: String,
        caption: String = "",
        transcript: String,
        viewCount: Int? = nil,
        likeCount: Int? = nil,
        commentCount: Int? = nil,
        shareCount: Int? = nil,
        duration: String? = nil,
        postedDate: Date? = nil,
        thumbnailURL: URL? = nil
    ) {
        self.title = title
        self.editableTitle = title
        self.author = author
        self.handle = handle
        self.platform = platform
        self.url = url
        self.caption = caption
        self.transcript = transcript
        self.viewCount = viewCount
        self.likeCount = likeCount
        self.commentCount = commentCount
        self.shareCount = shareCount
        self.duration = duration
        self.postedDate = postedDate
        self.thumbnailURL = thumbnailURL
    }

    // Custom decode so `annotations` defaults to [] for entries saved before this field existed
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title         = try c.decode(String.self,    forKey: .title)
        editableTitle = try c.decode(String.self,    forKey: .editableTitle)
        author        = try c.decode(String.self,    forKey: .author)
        handle        = try c.decode(String.self,    forKey: .handle)
        platform      = try c.decode(String.self,    forKey: .platform)
        url           = try c.decode(String.self,    forKey: .url)
        caption       = try c.decode(String.self,    forKey: .caption)
        transcript    = try c.decode(String.self,    forKey: .transcript)
        annotations   = (try? c.decode([Annotation].self, forKey: .annotations)) ?? []
        viewCount     = try c.decodeIfPresent(Int.self,    forKey: .viewCount)
        likeCount     = try c.decodeIfPresent(Int.self,    forKey: .likeCount)
        commentCount  = try c.decodeIfPresent(Int.self,    forKey: .commentCount)
        shareCount    = try c.decodeIfPresent(Int.self,    forKey: .shareCount)
        duration      = try c.decodeIfPresent(String.self, forKey: .duration)
        postedDate    = try c.decodeIfPresent(Date.self,   forKey: .postedDate)
        thumbnailURL  = try c.decodeIfPresent(URL.self,    forKey: .thumbnailURL)
    }
}

struct TranscriptEntry: Identifiable, Hashable, Codable {
    let id: UUID
    var result: TranscriptResult
    let date: Date

    init(result: TranscriptResult) {
        self.id = UUID()
        self.result = result
        self.date = Date()
    }

    var url: String { result.url }
    var title: String { result.editableTitle.isEmpty ? result.title : result.editableTitle }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: TranscriptEntry, rhs: TranscriptEntry) -> Bool { lhs.id == rhs.id }
}

struct VideoMetadata {
    let videoURL: URL
    let title: String
    let author: String
    let handle: String
    let caption: String
    let viewCount: Int?
    let likeCount: Int?
    let commentCount: Int?
    let shareCount: Int?
    let durationSeconds: Int?
    let postedDate: Date?
    let thumbnailURL: URL?

    var formattedDuration: String? {
        guard let s = durationSeconds, s > 0 else { return nil }
        let m = s / 60
        let sec = s % 60
        return String(format: "%d:%02d", m, sec)
    }
}
