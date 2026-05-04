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
    /// Filename inside the carousel-images directory (e.g. `post-slug-00.jpg`).
    /// Filename-only because the absolute Documents path embeds the app container's
    /// install UUID, which changes on reinstall — storing the absolute URL would break
    /// every image reference after a fresh install. Resolution to a real URL happens
    /// at display time via `displayURL`, which checks the active sync directory.
    let localImageFilename: String?
    let recognizedText: String?  // empty string if OCR ran but found nothing; nil if OCR failed

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, imageURL, localImageFilename, recognizedText
        // Legacy field — read on decode, never written. See custom init(from:).
        case localImagePath
    }

    init(index: Int, imageURL: URL?, localImageFilename: String?, recognizedText: String?) {
        self.index = index
        self.imageURL = imageURL
        self.localImageFilename = localImageFilename
        self.recognizedText = recognizedText
    }

    // Custom decode so entries saved before the filename refactor still load.
    // Old payloads stored `localImagePath: URL?` — we extract just the lastPathComponent
    // so the data lines up with the new field. New payloads only have `localImageFilename`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        imageURL = try c.decodeIfPresent(URL.self, forKey: .imageURL)
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText)
        if let filename = try c.decodeIfPresent(String.self, forKey: .localImageFilename) {
            localImageFilename = filename
        } else if let legacyURL = try c.decodeIfPresent(URL.self, forKey: .localImagePath) {
            localImageFilename = legacyURL.lastPathComponent
        } else {
            localImageFilename = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(index, forKey: .index)
        try c.encodeIfPresent(imageURL, forKey: .imageURL)
        try c.encodeIfPresent(localImageFilename, forKey: .localImageFilename)
        try c.encodeIfPresent(recognizedText, forKey: .recognizedText)
        // localImagePath intentionally not written — legacy field, lives only on read.
    }

    /// Best-available image URL: prefers the local file if it still exists on disk,
    /// otherwise falls back to the remote URL. Local files get wiped on app reinstall;
    /// the remote URL keeps working until the platform CDN expires (months).
    /// The local lookup goes through `CarouselImageDirectoryResolver`, which the sync
    /// service can override at runtime to point at the iCloud ubiquity container.
    var displayURL: URL? {
        if let filename = localImageFilename,
           let dir = CarouselImageDirectoryResolver.shared.currentDirectory(),
           case let candidate = dir.appendingPathComponent(filename),
           FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return imageURL
    }
}

/// Single source of truth for "where do carousel images currently live on disk."
/// Defaults to the app's local Documents/CarouselImages, but `iCloudSyncService` swaps
/// in the ubiquity container directory when sync is on. Keeping this dependency-free
/// means `TranscriptCarouselSlide` (a pure value type) doesn't need to know about
/// the sync service or take a constructor argument.
final class CarouselImageDirectoryResolver: @unchecked Sendable {
    static let shared = CarouselImageDirectoryResolver()
    private let lock = NSLock()
    private var override: URL?

    func setOverride(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        override = url
    }

    func currentDirectory() -> URL? {
        lock.lock()
        let o = override
        lock.unlock()
        if let o { return o }
        guard let docs = try? FileManager.default.url(for: .documentDirectory,
                                                      in: .userDomainMask,
                                                      appropriateFor: nil,
                                                      create: false) else {
            return nil
        }
        return docs.appendingPathComponent("CarouselImages", isDirectory: true)
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
    /// TikTok-only public metric (`collectCount` from the page's stats object).
    /// Instagram and YouTube don't expose save counts to non-owners.
    let saveCount: Int?
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
        case viewCount, likeCount, commentCount, shareCount, saveCount
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
        saveCount: Int? = nil,
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
        self.saveCount = saveCount
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
        saveCount     = try c.decodeIfPresent(Int.self,    forKey: .saveCount)
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
    let saveCount: Int?
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
