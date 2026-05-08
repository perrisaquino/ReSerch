import Foundation

/// Builds a single ZIP archive of all the user's ReSerch data — full structured
/// JSON backup + per-transcript Markdown files + notebook folder structure +
/// embedded carousel images. Returns a URL the caller hands to a share sheet.
///
/// The archive layout is intentionally human-browsable: someone can unzip it on
/// any machine and read their transcripts in plain Markdown without ReSerch.
/// The `reserch-data.json` file is the canonical source if we ever ship import.
@MainActor
struct DataExportService {

    enum ExportError: Error {
        case zipFailed(Error?)
    }

    /// Builds the archive and returns the URL of the generated `.zip` file in
    /// the app's tmp directory. Caller should hand this to a share sheet and
    /// optionally delete it afterwards.
    static func makeArchive(
        history: [TranscriptEntry],
        notebooks: [Notebook]
    ) throws -> URL {
        let stage = try makeStagingDirectory()

        // 1. Full structured JSON dump (re-importable in a future v2).
        try writeStructuredBackup(history: history, notebooks: notebooks, into: stage)

        // 2. Human-readable Markdown per transcript.
        try writeTranscriptMarkdown(history: history, into: stage)

        // 3. Notebook folder structure with .md copies.
        try writeNotebookFolders(history: history, notebooks: notebooks, into: stage)

        // 4. Carousel images.
        try copyCarouselImages(history: history, into: stage)

        // 5. README explaining the layout.
        try writeReadme(history: history, notebooks: notebooks, into: stage)

        return try zipDirectory(stage)
    }

    // MARK: - Staging

    private static func makeStagingDirectory() throws -> URL {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let date = formatter.string(from: Date())
        let name = "ReSerch-Export-\(date)"

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        // Clean any prior staging dir so re-exports don't accumulate.
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    // MARK: - Writers

    private static func writeStructuredBackup(
        history: [TranscriptEntry],
        notebooks: [Notebook],
        into stage: URL
    ) throws {
        struct Backup: Codable {
            let version: Int
            let exportedAt: Date
            let history: [TranscriptEntry]
            let notebooks: [Notebook]
        }
        let payload = Backup(version: 1, exportedAt: Date(), history: history, notebooks: notebooks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        try data.write(to: stage.appendingPathComponent("reserch-data.json"))
    }

    private static func writeTranscriptMarkdown(history: [TranscriptEntry], into stage: URL) throws {
        let dir = stage.appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var usedNames = Set<String>()
        for entry in history {
            let filename = uniqueFilename(for: entry, used: &usedNames)
            let markdown = MarkdownFormatter.format(entry.result, notebook: nil, notes: entry.documentNotes, template: ExportTemplatePrefs.shared, capturedAt: entry.date)
            try markdown.write(to: dir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
    }

    private static func writeNotebookFolders(
        history: [TranscriptEntry],
        notebooks: [Notebook],
        into stage: URL
    ) throws {
        guard !notebooks.isEmpty else { return }
        let root = stage.appendingPathComponent("notebooks", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let byID: [UUID: Notebook] = Dictionary(uniqueKeysWithValues: notebooks.map { ($0.id, $0) })
        var perNotebookUsed: [UUID: Set<String>] = [:]

        for entry in history {
            guard let notebookID = entry.notebookID, let nb = byID[notebookID] else { continue }
            let folder = root.appendingPathComponent(safeFolderName(nb.name), isDirectory: true)
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            var used = perNotebookUsed[notebookID] ?? []
            let filename = uniqueFilename(for: entry, used: &used)
            perNotebookUsed[notebookID] = used

            let markdown = MarkdownFormatter.format(entry.result, notebook: nb, notes: entry.documentNotes, template: ExportTemplatePrefs.shared, capturedAt: entry.date)
            try markdown.write(to: folder.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
    }

    private static func copyCarouselImages(history: [TranscriptEntry], into stage: URL) throws {
        // Source dir = whatever the sync service is currently pointing at.
        let source = iCloudSyncService.shared.activeURL(for: .carouselImages)
        guard FileManager.default.fileExists(atPath: source.path) else { return }

        // Only copy filenames actually referenced by an exported entry to keep
        // archives tight and avoid leaking orphan images from deleted history.
        var referenced = Set<String>()
        for entry in history {
            for slide in entry.result.carouselSlides ?? [] {
                if let name = slide.localImageFilename { referenced.insert(name) }
            }
        }
        guard !referenced.isEmpty else { return }

        let dest = stage.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        for name in referenced {
            let src = source.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            try? FileManager.default.copyItem(at: src, to: dest.appendingPathComponent(name))
        }
    }

    private static func writeReadme(
        history: [TranscriptEntry],
        notebooks: [Notebook],
        into stage: URL
    ) throws {
        let body = """
        # ReSerch Export

        This archive contains all your ReSerch transcripts and notebooks as of \
        \(formattedDate(Date())).

        ## Contents

        - `reserch-data.json` — full structured backup. The canonical source for any
          future re-import. Includes annotations, notebook IDs, posted dates, and
          carousel slide metadata.
        - `transcripts/` — every transcript as a standalone Markdown file. Filenames
          follow `YYYY-MM-DD_platform_title.md`.
        - `notebooks/` — Markdown copies of transcripts grouped into folders by the
          notebook they belong to. Unfiled transcripts only appear in `transcripts/`.
        - `images/` — carousel slide images referenced by your notes. Filenames match
          the `![[...]]` embed references inside the Markdown files.

        ## Counts

        - Transcripts: \(history.count)
        - Notebooks: \(notebooks.count)
        - Carousels: \(history.filter { $0.result.carouselSlides != nil }.count)

        ## Tips

        - Drop the `transcripts/` or `notebooks/` folders straight into Obsidian or
          another Markdown app — links and headings should render correctly.
        - The `reserch-data.json` is the only file that round-trips perfectly. Markdown
          renders well but loses some metadata (annotation positions, etc.).
        """
        try body.write(to: stage.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    // MARK: - Naming

    private static func uniqueFilename(for entry: TranscriptEntry, used: inout Set<String>) -> String {
        let date = shortDate(entry.date)
        let platform = entry.result.platform.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let title = sanitizeForFilename(entry.title)
        var base = "\(date)_\(platform)_\(title)"
        if base.count > 60 { base = String(base.prefix(60)) }

        var name = "\(base).md"
        var counter = 1
        while used.contains(name) {
            counter += 1
            name = "\(base)-\(counter).md"
        }
        used.insert(name)
        return name
    }

    private static func sanitizeForFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).replacingOccurrences(of: "--", with: "-")
    }

    private static func safeFolderName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : sanitizeForFilename(trimmed)
    }

    private static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    private static func formattedDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: date)
    }

    // MARK: - Zip

    /// Uses `NSFileCoordinator` with the special "for zipping" item-replacement option,
    /// which is the no-third-party-dependency way to compress a folder on iOS. Apple's
    /// own File Provider extension uses the same mechanism.
    private static func zipDirectory(_ source: URL) throws -> URL {
        var coordinatorError: NSError?
        var resultURL: URL?
        var caughtError: Error?

        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: source,
            options: [.forUploading],
            error: &coordinatorError
        ) { zipURL in
            // The zipURL handed to us is a temporary file the coordinator created.
            // Move it next to the source dir with a stable filename so the share sheet
            // shows a sensible name to the user.
            let dest = source.deletingLastPathComponent()
                .appendingPathComponent("\(source.lastPathComponent).zip")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: zipURL, to: dest)
                resultURL = dest
            } catch {
                caughtError = error
            }
        }

        if let coordinatorError { throw ExportError.zipFailed(coordinatorError) }
        if let caughtError { throw ExportError.zipFailed(caughtError) }
        guard let url = resultURL else { throw ExportError.zipFailed(nil) }
        return url
    }
}
