import Foundation

/// Cross-process queue for URLs the user has shared INTO ReSerch via the
/// `ReSerchShareExtension` target. The extension writes here from its own
/// process; the host app drains the queue when it next foregrounds.
///
/// This is the only mechanism that makes the "share five posts in a row
/// without opening the app" UX possible — `extensionContext.open(_:)` from
/// a share extension always foregrounds the host app, breaking the user's
/// scroll. Writing to a shared App Group container lets the extension
/// exit silently while the queue accumulates.
///
/// **Falls back gracefully when the App Group isn't configured** (i.e.
/// the entitlement isn't installed yet, or the developer portal step
/// hasn't been done). `enqueue(_:)` returns false in that case and the
/// caller can deeplink-launch the app instead.
enum SharedURLQueue {

    /// Apple Developer Portal-registered App Group identifier. Both the
    /// main app target and the share extension target must declare this
    /// in their entitlements files for cross-process access to work.
    static let appGroupID = "group.com.perrisaquino.reserch"

    /// Storage key inside the shared UserDefaults suite. The value is an
    /// array of URL strings — order of insertion is preserved.
    private static let queueKey = "pendingShareURLs"

    /// Returns the shared UserDefaults suite, or nil when the App Group
    /// isn't accessible (missing entitlement, suite mistyped, etc).
    /// `UserDefaults(suiteName:)` doesn't throw — it just returns nil silently
    /// when the suite can't be created, which is why we double-check by
    /// reading/writing a probe value.
    private static var suite: UserDefaults? {
        guard let s = UserDefaults(suiteName: appGroupID) else { return nil }
        // Probe: write + read to confirm the container is actually writable.
        // If the entitlement is missing the suite "looks" valid but writes
        // silently fail.
        let probe = "__reserch_probe__"
        s.set("ok", forKey: probe)
        let didWrite = s.string(forKey: probe) == "ok"
        s.removeObject(forKey: probe)
        return didWrite ? s : nil
    }

    /// True when the App Group is available for cross-process IPC.
    /// Callers can use this to decide whether to enqueue + exit silently
    /// vs. deeplink-handoff.
    static var isAvailable: Bool {
        suite != nil
    }

    /// Append a URL string to the queue. Returns true on success, false if
    /// the App Group isn't accessible.
    @discardableResult
    static func enqueue(_ url: String) -> Bool {
        guard let suite else { return false }
        var existing = suite.stringArray(forKey: queueKey) ?? []
        // Dedupe: don't append a URL that's already pending. Users sometimes
        // tap share twice on the same post — only one transcript needed.
        if !existing.contains(url) {
            existing.append(url)
            suite.set(existing, forKey: queueKey)
        }
        return true
    }

    /// Returns and clears every pending URL atomically. Call from the host
    /// app on foreground.
    @discardableResult
    static func drain() -> [String] {
        guard let suite else { return [] }
        let existing = suite.stringArray(forKey: queueKey) ?? []
        suite.removeObject(forKey: queueKey)
        return existing
    }

    /// Pending count without draining — useful for showing "3 in queue" UI.
    static var pendingCount: Int {
        suite?.stringArray(forKey: queueKey)?.count ?? 0
    }
}
