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

/// Per-slide payload kept on a TranscriptResult when the source was a carousel post
/// (Instagram carousel, TikTok photo set). Lets the detail view re-render the original
/// images as a swipeable strip + show clean per-slide OCR text instead of the raw
/// markdown that's stored in `TranscriptResult.transcript` for export purposes.
struct TranscriptCarouselSlide: Codable, Identifiable, Hashable {
    let index: Int
    let imageURL: URL?       // remote CDN URL — survives across reinstalls
    let localImagePath: URL? // app's Documents copy when "Embed images" was on; nil otherwise
    let recognizedText: String?  // empty string if OCR ran but found nothing; nil if OCR failed

    var id: Int { index }

    /// Best-available image URL: prefers the local file if it still exists on disk,
    /// otherwise falls back to the remote URL. Local files get wiped on app reinstall;
    /// the remote URL keeps working until the platform CDN expires (months).
    var displayURL: URL? {
        if let local = localImagePath, FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        return imageURL
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
    /// Populated for carousel results (Instagram carousels, TikTok photo posts). Drives
    /// the swipeable image strip + clean per-slide rendering in TranscriptDetailView.
    /// Nil for everything else (regular videos, audio imports, captions-based YT, etc.).
    var carouselSlides: [TranscriptCarouselSlide]?

    enum CodingKeys: String, CodingKey {
        case title, editableTitle, author, handle, platform, url, caption
        case transcript, annotations
        case viewCount, likeCount, commentCount, shareCount
        case duration, postedDate, thumbnailURL
        case carouselSlides
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
        thumbnailURL: URL? = nil,
        carouselSlides: [TranscriptCarouselSlide]? = nil
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
        self.carouselSlides = carouselSlides
    }

    // Custom decode so older entries (saved before annotations / carouselSlides existed)
    // fall back to safe defaults instead of failing the whole load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title         = try c.decode(String.self,    forKey: .title)
        // Older entries (pre-build with editableTitle field) fall back to title
        editableTitle = (try? c.decode(String.self, forKey: .editableTitle)) ?? title
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
        carouselSlides = try c.decodeIfPresent([TranscriptCarouselSlide].self, forKey: .carouselSlides)
    }
}

struct TranscriptEntry: Identifiable, Hashable, Codable {
    let id: UUID
    var result: TranscriptResult
    let date: Date

    /// Optional notebook membership. References `Notebook.id`. Nil = "Unfiled".
    /// Resolved to a `Notebook` by `TranscriptViewModel` from its loaded notebooks.
    var notebookID: UUID?

    /// Free-text note attached to the whole transcript, separate from inline annotations.
    /// Renders in markdown export as `## Notes` above the caption.
    var documentNote: String?

    enum CodingKeys: String, CodingKey {
        case id, result, date, notebookID, documentNote
    }

    init(result: TranscriptResult) {
        self.id = UUID()
        self.result = result
        self.date = Date()
        self.notebookID = nil
        self.documentNote = nil
    }

    // Custom decode so older entries (saved before notebookID/documentNote existed)
    // still load with nil for the new fields rather than failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        result = try c.decode(TranscriptResult.self, forKey: .result)
        date = try c.decode(Date.self, forKey: .date)
        notebookID = try c.decodeIfPresent(UUID.self, forKey: .notebookID)
        documentNote = try c.decodeIfPresent(String.self, forKey: .documentNote)
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
