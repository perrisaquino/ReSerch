import Foundation

@Observable
final class DebugLogger {
    static let shared = DebugLogger()
    private init() {}

    var entries: [Entry] = []

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let step: String
        let message: String

        enum Level: String {
            case info = "INFO"
            case ok = "OK"
            case warn = "WARN"
            case fail = "FAIL"

            var emoji: String {
                switch self {
                case .info: return "→"
                case .ok: return "✓"
                case .warn: return "⚠"
                case .fail: return "✗"
                }
            }
        }

        var formatted: String {
            let t = DateFormatter.logTime.string(from: timestamp)
            return "[\(t)] \(level.emoji) \(step): \(message)"
        }
    }

    func log(_ level: Entry.Level, step: String, _ message: String) {
        let entry = Entry(timestamp: Date(), level: level, step: step, message: message)
        entries.append(entry)
        print("ReSerch \(entry.formatted)")
    }

    func clear() { entries = [] }

    var fullLog: String {
        entries.map(\.formatted).joined(separator: "\n")
    }
}

extension DateFormatter {
    static let logTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// Convenience shorthand
func rLog(_ level: DebugLogger.Entry.Level = .info, step: String, _ message: String) {
    DebugLogger.shared.log(level, step: step, message)
}
