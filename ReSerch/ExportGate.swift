import Foundation

@Observable
final class ExportGate {
    static let shared = ExportGate()

    static let freeExportsPerWindow = 5

    /// Kill switch: when true, the app is fully free — all gating is bypassed and
    /// upgrade entry points are hidden. Set to false to re-enable the paywall.
    /// IAPManager, PaywallView, StoreKit products, and restore-purchases remain
    /// fully intact so existing Pro buyers keep access via `IAPManager.shared.isPro`.
    static let freeForEveryone = true

    private enum Key {
        static let timestamps = "gate.exportTimestamps"
        static let testInDebug = "gate.testInDebug"
    }

    private(set) var timestamps: [Date] = []

    private init() { load() }

    #if DEBUG
    var testInDebug: Bool {
        get { UserDefaults.standard.bool(forKey: Key.testInDebug) }
        set { UserDefaults.standard.set(newValue, forKey: Key.testInDebug) }
    }
    #endif

    func canExport() -> Bool {
        if !isEnforcing {
            print("[Gate] canExport: TRUE (gate not enforcing — Pro / TestFlight / DEBUG bypass)")
            return true
        }
        prune()
        let allowed = timestamps.count < Self.freeExportsPerWindow
        print("[Gate] canExport: \(allowed) — used \(timestamps.count)/\(Self.freeExportsPerWindow) today")
        return allowed
    }

    func recordExport() {
        if !isEnforcing { return }
        prune()
        timestamps.append(Date())
        save()
        print("[Gate] recordExport — now \(timestamps.count)/\(Self.freeExportsPerWindow)")
    }

    func remainingFreeExports() -> Int {
        if !isEnforcing { return Int.max }
        let start = startOfToday()
        let activeCount = timestamps.lazy.filter { $0 >= start }.count
        return max(0, Self.freeExportsPerWindow - activeCount)
    }

    /// Returns the next reset moment (start of tomorrow, local) when the user
    /// has used at least one export today. Nil otherwise.
    func nextResetDate() -> Date? {
        let start = startOfToday()
        guard timestamps.contains(where: { $0 >= start }) else { return nil }
        return Calendar.current.date(byAdding: .day, value: 1, to: start)
    }

    /// Inline transparency label for export buttons. Returns nil when the gate isn't enforcing
    /// (Pro, TestFlight beta, or DEBUG bypass).
    /// Free: "5 of 5 free exports today" — or "0 free exports left · resets at midnight" when empty.
    var quotaLabel: String? {
        if !isEnforcing { return nil }
        let remaining = remainingFreeExports()
        if remaining == 0 {
            return "0 free exports left · resets at midnight"
        }
        return "\(remaining) of \(Self.freeExportsPerWindow) free exports today"
    }

    /// Compact label for toolbar pill placement.
    /// Hides when the gate is bypassed (Pro, or DEBUG bypass active). Returns "5/5" / "0/5" style.
    var compactQuotaLabel: String? {
        if !isEnforcing { return nil }
        let remaining = remainingFreeExports()
        return "\(remaining)/\(Self.freeExportsPerWindow)"
    }

    /// Whether the gate is currently exhausted (would actually block an export).
    var isExhausted: Bool {
        guard isEnforcing else { return false }
        return remainingFreeExports() == 0
    }

    /// Single source of truth for "is the gate enforcing right now?"
    /// Pro users skip. TestFlight beta testers skip (App Review reviewers do NOT — they install
    /// the production-signed binary which has a `receipt`, not `sandboxReceipt`).
    /// DEBUG builds skip unless the test toggle is ON.
    private var isEnforcing: Bool {
        if Self.freeForEveryone { return false }
        if IAPManager.shared.isPro { return false }
        if Self.isTestFlight { return false }
        #if DEBUG
        if !UserDefaults.standard.bool(forKey: Key.testInDebug) { return false }
        #endif
        return true
    }

    /// True only for TestFlight beta installs. App Store production builds and App Review's
    /// production-binary tests both return false. Local Xcode runs are gated separately by `#if DEBUG`.
    /// Reference: TestFlight builds receive `sandboxReceipt`; production builds receive `receipt`.
    static let isTestFlight: Bool = {
        #if DEBUG
        return false
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
        #endif
    }()

    private func startOfToday() -> Date {
        Calendar.current.startOfDay(for: Date())
    }

    private func prune() {
        let start = startOfToday()
        timestamps.removeAll { $0 < start }
    }

    private func load() {
        let raw = UserDefaults.standard.array(forKey: Key.timestamps) as? [Double] ?? []
        timestamps = raw.map { Date(timeIntervalSince1970: $0) }
        prune()
    }

    private func save() {
        let raw = timestamps.map { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(raw, forKey: Key.timestamps)
    }

    #if DEBUG
    func debugFillToLimit() {
        let now = Date()
        timestamps = (0..<Self.freeExportsPerWindow).map { i in
            now.addingTimeInterval(-Double(i) * 60)
        }
        save()
        print("[Gate] DEBUG: filled to \(timestamps.count)/\(Self.freeExportsPerWindow) — next export hits paywall")
    }

    func debugReset() {
        timestamps = []
        save()
        print("[Gate] DEBUG: reset to 0/\(Self.freeExportsPerWindow)")
    }
    #endif
}
