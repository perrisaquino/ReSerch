import Foundation

enum MarkdownFormatter {
    /// Backwards-compatible entry — used where notebook + notes context isn't available.
    static func format(_ result: TranscriptResult) -> String {
        format(result, notebook: nil, notes: [])
    }

    static func format(_ result: TranscriptResult, notebook: Notebook?, notes: [DocumentNote]) -> String {
        let today = DateFormatter.obsidianDate.string(from: Date())
        let postedStr = result.postedDate.map { DateFormatter.isoDate.string(from: $0) }
        let title = result.editableTitle.isEmpty ? result.title : result.editableTitle
        let handle = result.handle.isEmpty ? "" : (result.handle.hasPrefix("@") ? result.handle : "@\(result.handle)")

        var lines: [String] = []

        // YAML frontmatter
        lines += ["---"]
        lines += ["title: \"\(title.replacingOccurrences(of: "\"", with: "'"))\""]
        lines += ["author: \"\(result.author)\""]
        if !handle.isEmpty { lines += ["username: \"\(handle)\""] }
        lines += ["platform: \(result.platform)"]
        lines += ["url: \"\(result.url)\""]
        if let nb = notebook {
            lines += ["notebook: \"\(nb.name.replacingOccurrences(of: "\"", with: "'"))\""]
        }
        lines += ["saved: [[\(today)]]"]
        if let posted = postedStr { lines += ["posted: \(posted)"] }
        if let dur = result.duration { lines += ["duration: \"\(dur)\""] }
        if let v = result.viewCount { lines += ["views: \(v)"] }
        if let l = result.likeCount { lines += ["likes: \(l)"] }
        if let c = result.commentCount { lines += ["comments: \(c)"] }
        if let s = result.shareCount { lines += ["shares: \(s)"] }
        if let sv = result.saveCount { lines += ["saves: \(sv)"] }
        lines += ["---", ""]

        // Header
        lines += ["# \(title)", ""]

        // Meta block
        let creatorURL = profileURL(for: result)
        let authorDisplay: String = {
            if let url = creatorURL {
                let label = handle.isEmpty ? result.author : "\(result.author) \(handle)"
                return "[\(label)](\(url))"
            }
            return handle.isEmpty ? result.author : "\(result.author) \(handle)"
        }()
        var metaParts = ["**Author:** \(authorDisplay)"]
        metaParts += ["**Platform:** \(result.platform)"]
        if let nb = notebook { metaParts += ["**Notebook:** \(nb.name)"] }
        if let posted = postedStr { metaParts += ["**Posted:** \(posted)"] }
        if let dur = result.duration { metaParts += ["**Duration:** \(dur)"] }

        // Stats line is fixed-order across every platform: views · likes · comments · shares · saves.
        // Missing fields are omitted (no fake zeros). TikTok exposes all five; Instagram and
        // YouTube don't expose `saves` publicly so theirs always max at four.
        var statParts: [String] = []
        if let v = result.viewCount    { statParts += ["\(formatCount(v)) views"] }
        if let l = result.likeCount    { statParts += ["\(formatCount(l)) likes"] }
        if let c = result.commentCount { statParts += ["\(formatCount(c)) comments"] }
        if let s = result.shareCount   { statParts += ["\(formatCount(s)) shares"] }
        if let sv = result.saveCount   { statParts += ["\(formatCount(sv)) saves"] }
        if !statParts.isEmpty { metaParts += ["**Stats:** " + statParts.joined(separator: " · ")] }

        if result.url.isEmpty {
            // Local-file imports have no source URL to link to.
            metaParts += ["**Source:** Imported file"]
        } else {
            // Hyperlinked label that names what kind of post it is — readers in Obsidian
            // see e.g. "Instagram carousel post" as the link text, not generic "View Original".
            metaParts += ["**Source:** [\(sourceLabel(for: result))](\(result.url))"]
        }
        if let url = creatorURL {
            let creatorLabel = handle.isEmpty ? result.author : handle
            metaParts += ["**Creator:** [\(creatorLabel)](\(url))"]
        }
        lines += [metaParts.joined(separator: "  \n"), ""]

        // Pinned note — exports as a "## Pinned Note" section ABOVE the transcript so
        // it reads as a summary / initial thought before the source content. There's
        // at most one pinned note (single-pin invariant enforced in the view model).
        if let pinned = notes.first(where: { $0.isPinned }),
           !pinned.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines += ["## Pinned Note", "", pinned.text, ""]
        }

        // Caption
        if !result.caption.isEmpty {
            lines += ["## Caption", "", result.caption, ""]
        }

        // Transcript (with annotation markup if any exist)
        if !result.transcript.isEmpty {
            lines += ["## Transcript", "", annotatedTranscript(result), ""]
        }

        // Non-pinned notes go BELOW the transcript so the source content appears first
        // when the user pastes into Obsidian / Notion. Sorted oldest-first so the
        // reader's eye flows top-to-bottom in time. Empty notes are filtered out
        // defensively even though the auto-discard UX should already prevent them.
        let unpinnedNotes = notes
            .filter { !$0.isPinned && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.createdAt < $1.createdAt }
        if !unpinnedNotes.isEmpty {
            lines += ["## Notes", ""]
            for note in unpinnedNotes {
                lines += ["### \(DateFormatter.noteHeading.string(from: note.createdAt))", ""]
                lines += [note.text, ""]
            }
        }

        return lines.joined(separator: "\n")
    }

    // Rebuilds transcript with ==highlight== and ==text==^[note] markup inserted.
    // Sorts annotations by offset, searches for each text string near its stored offset
    // (±300 chars window), and applies insertions in reverse order to keep indices stable.
    private static func annotatedTranscript(_ result: TranscriptResult) -> String {
        guard !result.annotations.isEmpty else { return result.transcript }

        let raw     = result.transcript as NSString
        let sorted  = result.annotations.sorted { $0.offset < $1.offset }

        struct Insertion { let range: NSRange; let open: String; let close: String }
        var insertions: [Insertion] = []
        var coveredEnd = 0

        for ann in sorted {
            let searchStart = max(coveredEnd, max(0, ann.offset - 300))
            let maxEnd      = raw.length
            guard searchStart < maxEnd else { continue }
            let searchLen   = min(maxEnd - searchStart, ann.text.count + 600)
            guard searchLen > 0 else { continue }
            let searchRange = NSRange(location: searchStart, length: searchLen)
            let found = raw.range(of: ann.text, options: [], range: searchRange)
            guard found.location != NSNotFound, found.location >= coveredEnd else { continue }

            let close = ann.comment.isEmpty ? "==" : "==^[\(ann.comment)]"
            insertions.append(Insertion(range: found, open: "==", close: close))
            coveredEnd = found.location + found.length
        }

        guard !insertions.isEmpty else { return result.transcript }

        // Work in NSString space to avoid String.Index / Int mismatch
        let output = NSMutableString(string: result.transcript)
        for ins in insertions.reversed() {
            let extracted = (output as NSString).substring(with: ins.range)
            let replacement = ins.open + extracted + ins.close
            output.replaceCharacters(in: ins.range, with: replacement)
        }
        return output as String
    }

    /// Human-readable label describing the source post — used as the hyperlink text
    /// for `**Source:**`. Branches on platform + whether the result has carousel slides
    /// so the export reads as "Instagram carousel post" / "TikTok video" / "YouTube Short"
    /// instead of a generic "View Original".
    private static func sourceLabel(for result: TranscriptResult) -> String {
        // Multi-slide posts only — a single-slide "carousel" (one image) is just a
        // regular photo post and should label that way, not as a carousel.
        let isMultiSlideCarousel = (result.carouselSlides?.count ?? 0) > 1
        let isSingleSlidePhoto   = (result.carouselSlides?.count ?? 0) == 1
        let platform = result.platform.lowercased()
        let url = result.url.lowercased()

        if platform.hasPrefix("instagram") {
            if isMultiSlideCarousel { return "Instagram carousel post" }
            if isSingleSlidePhoto   { return "Instagram photo post" }
            return "Instagram post"
        }
        if platform.hasPrefix("tiktok") {
            if isMultiSlideCarousel { return "TikTok photo carousel" }
            if isSingleSlidePhoto   { return "TikTok photo post" }
            return "TikTok video"
        }
        if platform.hasPrefix("youtube") {
            return url.contains("/shorts/") ? "YouTube Short" : "YouTube video"
        }
        if platform.hasPrefix("threads")   { return "Threads post" }
        if platform.hasPrefix("twitter") || platform.hasPrefix("x") { return "X post" }
        return "View original"
    }

    private static func profileURL(for result: TranscriptResult) -> String? {
        let raw = result.handle
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "@", with: "")
        guard !raw.isEmpty else { return nil }

        let platform = result.platform.lowercased()

        // YouTube channel IDs are 24 chars starting with "UC". Use /channel/ path.
        // Vanity handles use /@handle path.
        if platform.hasPrefix("youtube") {
            if raw.hasPrefix("UC") && raw.count == 24 {
                return "https://www.youtube.com/channel/\(raw)"
            }
            return "https://www.youtube.com/@\(raw)"
        }
        if platform.hasPrefix("tiktok")    { return "https://www.tiktok.com/@\(raw)" }
        if platform.hasPrefix("instagram") { return "https://www.instagram.com/\(raw)" }
        if platform.hasPrefix("threads")   { return "https://www.threads.net/@\(raw)" }
        if platform.hasPrefix("twitter") || platform.hasPrefix("x") {
            return "https://x.com/\(raw)"
        }
        return nil
    }

    private static func formatCount(_ n: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

extension String {
    /// Groups transcript text into paragraphs by sentence boundaries.
    /// Every `every` sentences becomes one paragraph, joined with \n\n.
    func paragraphized(every sentenceCount: Int = 5) -> String {
        // Split on sentence-ending punctuation followed by a space or end
        var sentences: [String] = []
        var buffer = ""
        var i = startIndex

        while i < endIndex {
            let c = self[i]
            buffer.append(c)
            if (c == "." || c == "!" || c == "?") {
                let next = index(after: i)
                if next == endIndex || self[next] == " " {
                    let s = buffer.trimmingCharacters(in: .whitespaces)
                    if !s.isEmpty { sentences.append(s) }
                    buffer = ""
                    if next < endIndex { i = index(after: next); continue }
                }
            }
            i = index(after: i)
        }
        let tail = buffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { sentences.append(tail) }

        // If the text has almost no punctuation (auto-captions), fall back to word-count grouping
        if sentences.count < 3 {
            return wordCountParagraphized(every: 80)
        }

        var paragraphs: [String] = []
        var idx = 0
        while idx < sentences.count {
            let group = sentences[idx..<min(idx + sentenceCount, sentences.count)]
            paragraphs.append(group.joined(separator: " "))
            idx += sentenceCount
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private func wordCountParagraphized(every wordCount: Int) -> String {
        let words = split(separator: " ").map(String.init)
        var paragraphs: [String] = []
        var idx = 0
        while idx < words.count {
            let group = words[idx..<min(idx + wordCount, words.count)]
            paragraphs.append(group.joined(separator: " "))
            idx += wordCount
        }
        return paragraphs.joined(separator: "\n\n")
    }
}

extension DateFormatter {
    static let obsidianDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Heading format for individual entries inside the `## Notes` markdown block.
    /// e.g. "Apr 12, 2026 · 3:14 PM" — readable when pasted into Obsidian, sortable
    /// when scanned alphabetically (since the year is fully spelled).
    static let noteHeading: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · h:mm a"
        return f
    }()
}
