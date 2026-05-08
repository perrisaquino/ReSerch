import Foundation

// MARK: - Highlight timestamp format

enum HighlightDateFormat: String, Codable, CaseIterable {
    case readable           // "Apr 12, 2026 · 3:14 PM"
    case obsidianLink       // [[2026-04-12]]
    case obsidianLinkTime   // [[2026-04-12]] · 3:14 PM
    case isoDate            // 2026-04-12
    case isoDateTime        // 2026-04-12 · 3:14 PM
    case none               // omit timestamp

    var displayName: String {
        switch self {
        case .readable:         return "Apr 12, 2026 · 3:14 PM"
        case .obsidianLink:     return "[[2026-04-12]]"
        case .obsidianLinkTime: return "[[2026-04-12]] · 3:14 PM"
        case .isoDate:          return "2026-04-12"
        case .isoDateTime:      return "2026-04-12 · 3:14 PM"
        case .none:             return "No timestamp"
        }
    }

    func string(from date: Date, use24h: Bool) -> String? {
        let isoDate = DateFormatter.hlISODate.string(from: date)
        let time    = DateFormatter.hlTime(use24h: use24h).string(from: date)
        switch self {
        case .readable:         return DateFormatter.hlReadable(use24h: use24h).string(from: date)
        case .obsidianLink:     return "[[\(isoDate)]]"
        case .obsidianLinkTime: return "[[\(isoDate)]] · \(time)"
        case .isoDate:          return isoDate
        case .isoDateTime:      return "\(isoDate) · \(time)"
        case .none:             return nil
        }
    }
}

private extension DateFormatter {
    static let hlISODate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()
    static func hlReadable(use24h: Bool) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = use24h ? "MMM d, yyyy · HH:mm" : "MMM d, yyyy · h:mm a"
        return f
    }
    static func hlTime(use24h: Bool) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = use24h ? "HH:mm" : "h:mm a"
        return f
    }
}

// MARK: - Body section order

enum ExportSectionID: String, Codable, CaseIterable {
    case title, meta, pinnedNote, caption, transcript, notes

    var displayName: String {
        switch self {
        case .title:      return "Title Heading"
        case .meta:       return "Meta Block"
        case .pinnedNote: return "Pinned Note"
        case .caption:    return "Caption"
        case .transcript: return "Transcript"
        case .notes:      return "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .title:      return "textformat.size"
        case .meta:       return "info.circle"
        case .pinnedNote: return "pin.fill"
        case .caption:    return "text.alignleft"
        case .transcript: return "waveform.and.mic"
        case .notes:      return "note.text"
        }
    }
}

// MARK: - YAML field order

enum YAMLFieldID: String, Codable, CaseIterable {
    case author, handle, platform, source, notebook, savedDate, postedDate, duration, stats

    var displayName: String {
        switch self {
        case .author:     return "Author"
        case .handle:     return "Username / Handle"
        case .platform:   return "Platform"
        case .source:     return "Source URL"
        case .notebook:   return "Notebook"
        case .savedDate:  return "Captured Date"
        case .postedDate: return "Posted Date"
        case .duration:   return "Duration"
        case .stats:      return "Stats"
        }
    }
}

// MARK: - Prefs singleton

@Observable
final class ExportTemplatePrefs {
    static let shared = ExportTemplatePrefs()
    private init() { load() }

    // MARK: - Section visibility

    var showYAML: Bool = true
    var showTitle: Bool = true
    var showMetaBlock: Bool = true
    var showPinnedNote: Bool = true
    var showCaption: Bool = true
    var showTranscript: Bool = true
    var showNotes: Bool = true

    // MARK: - Section order

    var sectionOrder: [ExportSectionID] = ExportSectionID.allCases

    // MARK: - YAML field toggles + order

    var yamlAuthor: Bool = true
    var yamlHandle: Bool = true
    var yamlPlatform: Bool = true
    var yamlSource: Bool = true
    var yamlNotebook: Bool = true
    var yamlSavedDate: Bool = true
    var yamlPostedDate: Bool = true
    var yamlDuration: Bool = true
    var yamlStats: Bool = true
    var yamlFieldOrder: [YAMLFieldID] = YAMLFieldID.allCases

    // MARK: - Meta block field toggles

    var metaCreator: Bool = true
    var metaAuthor: Bool = true
    var metaPlatform: Bool = true
    var metaNotebook: Bool = true
    var metaCapturedDate: Bool = true
    var metaPostedDate: Bool = true
    var metaDuration: Bool = true
    var metaStats: Bool = true
    var metaSource: Bool = true

    // MARK: - Highlight export options

    var highlightDateFormat: HighlightDateFormat = .readable
    var highlightUse24HourTime: Bool = false

    // MARK: - Keys

    private enum Key {
        static let showYAML            = "etp.showYAML"
        static let showTitle           = "etp.showTitle"
        static let showMetaBlock       = "etp.showMetaBlock"
        static let showPinnedNote      = "etp.showPinnedNote"
        static let showCaption         = "etp.showCaption"
        static let showTranscript      = "etp.showTranscript"
        static let showNotes           = "etp.showNotes"
        static let sectionOrder        = "etp.sectionOrder"
        static let yamlAuthor          = "etp.yamlAuthor"
        static let yamlHandle          = "etp.yamlHandle"
        static let yamlPlatform        = "etp.yamlPlatform"
        static let yamlSource          = "etp.yamlSource"
        static let yamlNotebook        = "etp.yamlNotebook"
        static let yamlSavedDate       = "etp.yamlSavedDate"
        static let yamlPostedDate      = "etp.yamlPostedDate"
        static let yamlDuration        = "etp.yamlDuration"
        static let yamlStats           = "etp.yamlStats"
        static let yamlFieldOrder      = "etp.yamlFieldOrder"
        static let metaCreator         = "etp.metaCreator"
        static let metaAuthor          = "etp.metaAuthor"
        static let metaPlatform        = "etp.metaPlatform"
        static let metaNotebook        = "etp.metaNotebook"
        static let metaCapturedDate    = "etp.metaCapturedDate"
        static let metaPostedDate      = "etp.metaPostedDate"
        static let metaDuration        = "etp.metaDuration"
        static let metaStats           = "etp.metaStats"
        static let metaSource          = "etp.metaSource"
        static let highlightDateFormat    = "etp.highlightDateFormat"
        static let highlightUse24HourTime = "etp.highlightUse24HourTime"
    }

    // MARK: - Save

    func save() {
        let ud = UserDefaults.standard
        ud.set(showYAML,       forKey: Key.showYAML)
        ud.set(showTitle,      forKey: Key.showTitle)
        ud.set(showMetaBlock,  forKey: Key.showMetaBlock)
        ud.set(showPinnedNote, forKey: Key.showPinnedNote)
        ud.set(showCaption,    forKey: Key.showCaption)
        ud.set(showTranscript, forKey: Key.showTranscript)
        ud.set(showNotes,      forKey: Key.showNotes)

        encode(sectionOrder.map(\.rawValue),    key: Key.sectionOrder,   ud: ud)
        encode(yamlFieldOrder.map(\.rawValue),  key: Key.yamlFieldOrder, ud: ud)

        ud.set(yamlAuthor,     forKey: Key.yamlAuthor)
        ud.set(yamlHandle,     forKey: Key.yamlHandle)
        ud.set(yamlPlatform,   forKey: Key.yamlPlatform)
        ud.set(yamlSource,     forKey: Key.yamlSource)
        ud.set(yamlNotebook,   forKey: Key.yamlNotebook)
        ud.set(yamlSavedDate,  forKey: Key.yamlSavedDate)
        ud.set(yamlPostedDate, forKey: Key.yamlPostedDate)
        ud.set(yamlDuration,   forKey: Key.yamlDuration)
        ud.set(yamlStats,      forKey: Key.yamlStats)

        ud.set(metaCreator,      forKey: Key.metaCreator)
        ud.set(metaAuthor,       forKey: Key.metaAuthor)
        ud.set(metaPlatform,     forKey: Key.metaPlatform)
        ud.set(metaNotebook,     forKey: Key.metaNotebook)
        ud.set(metaCapturedDate, forKey: Key.metaCapturedDate)
        ud.set(metaPostedDate,   forKey: Key.metaPostedDate)
        ud.set(metaDuration,     forKey: Key.metaDuration)
        ud.set(metaStats,        forKey: Key.metaStats)
        ud.set(metaSource,       forKey: Key.metaSource)

        ud.set(highlightDateFormat.rawValue, forKey: Key.highlightDateFormat)
        ud.set(highlightUse24HourTime,       forKey: Key.highlightUse24HourTime)
    }

    // MARK: - Reset

    func resetToDefaults() {
        showYAML = true; showTitle = true; showMetaBlock = true
        showPinnedNote = true; showCaption = true; showTranscript = true; showNotes = true
        sectionOrder = ExportSectionID.allCases
        yamlFieldOrder = YAMLFieldID.allCases
        yamlAuthor = true; yamlHandle = true; yamlPlatform = true; yamlSource = true
        yamlNotebook = true; yamlSavedDate = true; yamlPostedDate = true
        yamlDuration = true; yamlStats = true
        metaCreator = true; metaAuthor = true; metaPlatform = true; metaNotebook = true
        metaCapturedDate = true; metaPostedDate = true; metaDuration = true
        metaStats = true; metaSource = true
        highlightDateFormat = .readable; highlightUse24HourTime = false
        save()
    }

    // MARK: - Load

    private func load() {
        let ud = UserDefaults.standard
        func stored(_ key: String, fallback: Bool) -> Bool {
            ud.object(forKey: key) != nil ? ud.bool(forKey: key) : fallback
        }

        showYAML       = stored(Key.showYAML,       fallback: true)
        showTitle      = stored(Key.showTitle,      fallback: true)
        showMetaBlock  = stored(Key.showMetaBlock,  fallback: true)
        showPinnedNote = stored(Key.showPinnedNote, fallback: true)
        showCaption    = stored(Key.showCaption,    fallback: true)
        showTranscript = stored(Key.showTranscript, fallback: true)
        showNotes      = stored(Key.showNotes,      fallback: true)

        sectionOrder   = decodeOrder(key: Key.sectionOrder,   ud: ud, allCases: ExportSectionID.allCases)
        yamlFieldOrder = decodeOrder(key: Key.yamlFieldOrder, ud: ud, allCases: YAMLFieldID.allCases)

        yamlAuthor     = stored(Key.yamlAuthor,     fallback: true)
        yamlHandle     = stored(Key.yamlHandle,     fallback: true)
        yamlPlatform   = stored(Key.yamlPlatform,   fallback: true)
        yamlSource     = stored(Key.yamlSource,     fallback: true)
        yamlNotebook   = stored(Key.yamlNotebook,   fallback: true)
        yamlSavedDate  = stored(Key.yamlSavedDate,  fallback: true)
        yamlPostedDate = stored(Key.yamlPostedDate, fallback: true)
        yamlDuration   = stored(Key.yamlDuration,   fallback: true)
        yamlStats      = stored(Key.yamlStats,      fallback: true)

        metaCreator      = stored(Key.metaCreator,      fallback: true)
        metaAuthor       = stored(Key.metaAuthor,       fallback: true)
        metaPlatform     = stored(Key.metaPlatform,     fallback: true)
        metaNotebook     = stored(Key.metaNotebook,     fallback: true)
        metaCapturedDate = stored(Key.metaCapturedDate, fallback: true)
        metaPostedDate   = stored(Key.metaPostedDate,   fallback: true)
        metaDuration     = stored(Key.metaDuration,     fallback: true)
        metaStats        = stored(Key.metaStats,        fallback: true)
        metaSource       = stored(Key.metaSource,       fallback: true)

        if let raw = ud.string(forKey: Key.highlightDateFormat),
           let fmt = HighlightDateFormat(rawValue: raw) {
            highlightDateFormat = fmt
        }
        highlightUse24HourTime = stored(Key.highlightUse24HourTime, fallback: false)
    }

    // MARK: - Helpers

    private func encode(_ rawValues: [String], key: String, ud: UserDefaults) {
        if let data = try? JSONEncoder().encode(rawValues) { ud.set(data, forKey: key) }
    }

    private func decodeOrder<T: RawRepresentable & CaseIterable>(
        key: String, ud: UserDefaults, allCases: [T]
    ) -> [T] where T.RawValue == String {
        guard let data = ud.data(forKey: key),
              let rawValues = try? JSONDecoder().decode([String].self, from: data)
        else { return allCases }
        let decoded = rawValues.compactMap(T.init(rawValue:))
        let missing = allCases.filter { item in !decoded.contains(where: { $0.rawValue == item.rawValue }) }
        return decoded + missing
    }
}
