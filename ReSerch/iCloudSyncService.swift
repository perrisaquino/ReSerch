import Foundation
import Combine

/// Routes the app's persistent files (history JSON, notebooks JSON, carousel images)
/// between the local Documents directory and the iCloud Drive ubiquity container based
/// on user preference + container availability. Designed to be safe on every code path
/// even before the iCloud entitlement is provisioned: when the container can't be
/// resolved (no entitlement, user not signed into iCloud, or sync toggle off), every
/// `activeURL(for:)` call quietly falls back to local Documents and the rest of the app
/// keeps working unchanged.
@MainActor
final class iCloudSyncService: ObservableObject {

    static let shared = iCloudSyncService()

    enum Status: Equatable {
        /// User has sync turned off — using local Documents only.
        case localOnly
        /// Sync is on but the iCloud container is unavailable (no Apple ID, no
        /// entitlement, etc.). Falling back to local until the situation changes.
        case unavailable
        /// Sync is on and the container is available; reads/writes go to iCloud.
        case ready
        /// First-time migration in progress (moving local files into the container).
        case migrating
    }

    enum SyncTarget {
        case history
        case notebooks
        case carouselImages
    }

    @Published private(set) var status: Status = .localOnly
    @Published private(set) var lastSyncedAt: Date?

    private let containerID = "iCloud.com.perrisaquino.reserch"
    private let migrationFlagKey = "iCloudMigrationCompletedV1"
    private let syncEnabledKey = "iCloudSyncEnabled"

    private var metadataQuery: NSMetadataQuery?
    private var changeHandlers: [(SyncTarget) -> Void] = []

    private init() {
        recomputeStatus()
        // Container probe: once the user signs into iCloud or the entitlement is
        // installed, the URL becomes resolvable. We check on init and let the caller
        // re-call `recomputeStatus()` after settings changes.
    }

    // MARK: - Public API

    /// True when the user has the toggle on. Reflects what they want, not what's
    /// actually possible right now (the container may still be unavailable).
    var isSyncEnabled: Bool {
        get {
            // Default to ON for new installs. UserDefaults returns false for missing
            // keys, so we use object-presence as the discriminator.
            if UserDefaults.standard.object(forKey: syncEnabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: syncEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: syncEnabledKey)
            recomputeStatus()
        }
    }

    /// Returns the URL the app should read/write for this kind of file right now.
    /// Pure fallback when sync is unavailable: callers don't need to special-case
    /// anything, the URL is always valid.
    func activeURL(for kind: SyncTarget) -> URL {
        switch status {
        case .ready, .migrating:
            if let url = ubiquityURL(for: kind) {
                return url
            }
            // Fall through to local if the container went away mid-session.
            return localURL(for: kind)
        case .localOnly, .unavailable:
            return localURL(for: kind)
        }
    }

    /// One-time migration of local files into the ubiquity container. Idempotent:
    /// guarded by a UserDefaults flag and skipped if the container already has data.
    /// Async wrapper preserved for the Settings toggle path; the synchronous version
    /// is what app launch should call so the view model's initial reads land on the
    /// correct source.
    func migrateLocalToCloudIfNeeded() async {
        migrateLocalToCloudIfNeededSync()
    }

    /// Synchronous migration. Operations are file copies — fast enough to run on the
    /// main thread during launch (typical case: zero or two ~50KB JSON copies).
    /// Call this BEFORE any code that reads `activeURL(for:)`, otherwise the view
    /// model will read an empty container while local data still has the user's history.
    func migrateLocalToCloudIfNeededSync() {
        guard isSyncEnabled,
              !UserDefaults.standard.bool(forKey: migrationFlagKey),
              let containerDocs = ubiquityDocumentsURL() else {
            return
        }
        status = .migrating
        defer {
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
            recomputeStatus()
        }

        // Migrate each target file. Skip if the iCloud copy already exists (a previous
        // device may have already populated it) — in that case the local copy is
        // redundant and we leave both untouched. Manual merge would be a v2 feature.
        copyOneFile(target: .history, intoContainer: containerDocs)
        copyOneFile(target: .notebooks, intoContainer: containerDocs)
        copyImagesDirectory(intoContainer: containerDocs)
    }

    /// Subscribe to remote-change notifications. The handler fires on the main actor
    /// when iCloud delivers a new version of one of the watched files.
    func observeRemoteChanges(_ handler: @escaping (SyncTarget) -> Void) {
        changeHandlers.append(handler)
        startMetadataQueryIfNeeded()
    }

    // MARK: - URL resolution

    private func ubiquityURL(for kind: SyncTarget) -> URL? {
        guard let docs = ubiquityDocumentsURL() else { return nil }
        switch kind {
        case .history:
            return docs.appendingPathComponent("reserch_history.json")
        case .notebooks:
            return docs.appendingPathComponent("reserch_notebooks.json")
        case .carouselImages:
            let dir = docs.appendingPathComponent("CarouselImages", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
    }

    private func ubiquityDocumentsURL() -> URL? {
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else {
            return nil
        }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: docs.path) {
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        }
        return docs
    }

    private func localURL(for kind: SyncTarget) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        switch kind {
        case .history:
            return docs.appendingPathComponent("reserch_history.json")
        case .notebooks:
            return docs.appendingPathComponent("reserch_notebooks.json")
        case .carouselImages:
            let dir = docs.appendingPathComponent("CarouselImages", isDirectory: true)
            if !FileManager.default.fileExists(atPath: dir.path) {
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            return dir
        }
    }

    // MARK: - Status

    private func recomputeStatus() {
        if !isSyncEnabled {
            status = .localOnly
            CarouselImageDirectoryResolver.shared.setOverride(nil)
            return
        }
        if ubiquityDocumentsURL() != nil {
            status = .ready
            CarouselImageDirectoryResolver.shared.setOverride(activeURL(for: .carouselImages))
        } else {
            status = .unavailable
            CarouselImageDirectoryResolver.shared.setOverride(nil)
        }
    }

    // MARK: - Migration helpers

    private func copyOneFile(target: SyncTarget, intoContainer: URL) {
        let local = localURL(for: target)
        let remote: URL
        switch target {
        case .history:
            remote = intoContainer.appendingPathComponent("reserch_history.json")
        case .notebooks:
            remote = intoContainer.appendingPathComponent("reserch_notebooks.json")
        case .carouselImages:
            return // handled by copyImagesDirectory(intoContainer:)
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: local.path) else { return }
        if fm.fileExists(atPath: remote.path) { return } // remote wins, leave local

        do {
            try fm.copyItem(at: local, to: remote)
        } catch {
            print("[iCloudSync] migrate \(remote.lastPathComponent) failed: \(error)")
        }
    }

    private func copyImagesDirectory(intoContainer: URL) {
        let fm = FileManager.default
        let local = localURL(for: .carouselImages)
        let remote = intoContainer.appendingPathComponent("CarouselImages", isDirectory: true)

        guard fm.fileExists(atPath: local.path) else { return }
        if !fm.fileExists(atPath: remote.path) {
            try? fm.createDirectory(at: remote, withIntermediateDirectories: true)
        }

        guard let items = try? fm.contentsOfDirectory(atPath: local.path) else { return }
        for name in items {
            let src = local.appendingPathComponent(name)
            let dst = remote.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            try? fm.copyItem(at: src, to: dst)
        }
    }

    // MARK: - Remote change observation

    private func startMetadataQueryIfNeeded() {
        guard metadataQuery == nil, status == .ready else { return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        // Watch our two JSON files specifically — carousel images don't need to trigger
        // the same reload path (they're referenced by filename, not loaded eagerly).
        query.predicate = NSPredicate(
            format: "%K == %@ OR %K == %@",
            NSMetadataItemFSNameKey, "reserch_history.json",
            NSMetadataItemFSNameKey, "reserch_notebooks.json"
        )

        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate,
            object: query,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleMetadataUpdate(note) }
        }
        NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidFinishGathering,
            object: query,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleMetadataUpdate(note) }
        }

        query.start()
        metadataQuery = query
    }

    private func handleMetadataUpdate(_ note: Notification) {
        // An updated or downloaded file fires this; re-fire each handler so the view
        // model can reload its in-memory state. We don't try to be granular about
        // which file changed — both files are small and reload is cheap.
        for handler in changeHandlers {
            handler(.history)
            handler(.notebooks)
        }
        lastSyncedAt = Date()
    }
}
