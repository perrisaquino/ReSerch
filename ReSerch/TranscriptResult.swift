import Foundation

struct Annotation: Codable, Identifiable {
    let id: UUID
    var text: String
    var comment: String
    /// Offset relative to the *enclosing* text. For regular video transcripts that's
    /// the full transcript string. For carousels (`slideIndex != nil`) it's that
    /// specific slide's recognized text. Without the slide index, the same offset
    /// would point at different positions in different slides.
    var offset: Int
    let createdAt: Date
    /// Carousel context. nil for regular video transcripts (legacy + non-carousel content).
    /// Set to the slide's `index` field when an annotation lives inside a carousel slide.
    var slideIndex: Int?

    init(text: String, comment: String = "", offset: Int, slideIndex: Int? = nil) {
        self.id = UUID()
        self.text = text
        self.comment = comment
        self.offset = offset
        self.createdAt = Date()
        self.slideIndex = slideIndex
    }

    enum CodingKeys: String, CodingKey {
        case id, text, comment, offset, createdAt, slideIndex
    }

    // Custom decode so existing annotations (no slideIndex field) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        comment = try c.decode(String.self, forKey: .comment)
        offset = try c.decode(Int.self, forKey: .offset)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        slideIndex = try c.decodeIfPresent(Int.self, forKey: .slideIndex)
    }
}

/// One entry in the per-transcript "mini journal." Multiple notes can be attached to
/// the same transcript over time — each with its own creation/update timestamps and
/// an optional `isPinned` flag. At most one note per transcript is pinned at a time;
/// the pinned note exports BEFORE the transcript as a summary, while non-pinned notes
/// export AFTER (clean Obsidian-friendly layout).
struct DocumentNote: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    let createdAt: Date
    var updatedAt: Date
    var isPinned: Bool

    init(text: String = "", isPinned: Bool = false) {
        self.id = UUID()
        self.text = text
        let now = Date()
        self.createdAt = now
        self.updatedAt = now
        self.isPinned = isPinned
    }

    /// Internal initializer used by `TranscriptEntry`'s legacy-string migration path
    /// so the migrated note inherits the entry's date instead of being stamped "now"
    /// (which would lie about when the note was actually written).
    static func migrating(text: String, timestamp: Date) -> DocumentNote {
        var note = DocumentNote(text: text, isPinned: false)
        note._setMigrationTimestamps(timestamp)
        return note
    }

    private mutating func _setMigrationTimestamps(_ when: Date) {
        // We have to use the memberwise initializer since createdAt is `let`, so
        // rebuild the struct in place.
        self = DocumentNote(_id: id, text: text, createdAt: when, updatedAt: when, isPinned: isPinned)
    }

    private init(_id: UUID, text: String, createdAt: Date, updatedAt: Date, isPinned: Bool) {
        self.id = _id
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
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
    /// Mutable so the pencil-edit flow can write back per-slide text after the user
    /// fixes OCR mistakes or adds **bold** / ==highlight== markdown syntax. Empty
    /// string = OCR ran but found nothing; nil = OCR failed.
    var recognizedText: String?

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

    /// Mini-journal of notes the user has captured for this transcript. Replaces the
    /// older single `documentNote: String?` field — see custom decoder below for the
    /// migration path. Order is irrelevant on disk; the UI layer sorts by pinned-state
    /// then `updatedAt`.
    var documentNotes: [DocumentNote] = []

    enum CodingKeys: String, CodingKey {
        case id, result, date, notebookID
        case documentNotes
        // Legacy field kept ONLY in the keys enum so the decoder can read it. Never
        // written by encode(). Idempotent re-saves naturally clean up old data.
        case documentNote
    }

    init(result: TranscriptResult) {
        self.id = UUID()
        self.result = result
        self.date = Date()
        self.notebookID = nil
        self.documentNotes = []
    }

    // Custom decode supports three shapes simultaneously:
    //   1. Brand new entries — only `documentNotes` is present.
    //   2. Older entries with a single `documentNote: String?` — migrate to a
    //      one-element `[DocumentNote]` if non-empty, else empty array. createdAt/
    //      updatedAt fall back to the entry's `date` since that's the only
    //      timestamp we have for legacy notes.
    //   3. Original entries with neither field present — empty array.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        result = try c.decode(TranscriptResult.self, forKey: .result)
        date = try c.decode(Date.self, forKey: .date)
        notebookID = try c.decodeIfPresent(UUID.self, forKey: .notebookID)

        if let notes = try c.decodeIfPresent([DocumentNote].self, forKey: .documentNotes) {
            documentNotes = notes
        } else if let legacy = try c.decodeIfPresent(String.self, forKey: .documentNote),
                  !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            documentNotes = [DocumentNote.migrating(text: legacy, timestamp: date)]
        } else {
            documentNotes = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(result, forKey: .result)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(notebookID, forKey: .notebookID)
        try c.encode(documentNotes, forKey: .documentNotes)
        // legacy `documentNote` deliberately not encoded
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
