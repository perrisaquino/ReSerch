import Foundation
import Darwin

// MARK: - ShareJob

/// One unit of work in the share-to-transcribe queue. The job survives the
/// full lifecycle of an inbound URL — from "user tapped Share in TikTok"
/// through "transcript saved to history" — so a crash, OS suspend, or
/// failed fetch never silently loses the link.
///
/// Jobs are deleted only when their transcript has been saved successfully
/// (`markCompleted`). Failures are kept in the store with `lastError` and
/// a bumped `retryCount` so the user can see what didn't work.
struct ShareJob: Codable, Equatable {
    enum State: String, Codable {
        case queued      // waiting to be picked up
        case processing  // currently being fetched (must be reset on cold start)
        case failed      // last attempt errored — keep around so user can retry
    }

    let id: UUID
    let url: String
    var state: State
    var retryCount: Int
    var lastError: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        url: String,
        state: State = .queued,
        retryCount: Int = 0,
        lastError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.url = url
        self.state = state
        self.retryCount = retryCount
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - ShareJobQueue

/// Cross-process, file-backed durable job queue. The share extension calls
/// `enqueue(_:)` from its own process; the host app drains via `nextQueued()`
/// + state transitions when it foregrounds.
///
/// Why JSON-on-disk instead of UserDefaults: the previous flat-`[String]`
/// design in UserDefaults could not represent state, retry count, or errors,
/// and `drain()` deleted URLs before transcripts were saved — a crash mid-batch
/// lost links permanently. Disk + a lock file gives us atomic read-modify-write
/// across the extension and host processes.
final class ShareJobQueue {

    // MARK: - Public configuration

    /// Apple Developer Portal-registered App Group identifier. Both the main
    /// app target and the share extension target must declare this in their
    /// entitlements files for cross-process access to work.
    static let appGroupID = "group.com.perrisaquino.reserch"

    /// Cap on total jobs in the store. Past this, `enqueue` returns `.full`
    /// and the share extension surfaces a "queue full" state. Tuned for
    /// real-world scrolling sessions — comfortably above any normal share
    /// burst, well below where the host-side drain becomes a backlog trap.
    static let maxQueueSize = 50

    /// Legacy UserDefaults key used by the previous `[String]` queue. Kept
    /// around so `migrateLegacyIfNeeded` can pull any pending URLs forward
    /// after the upgrade.
    static let legacyQueueKey = "pendingShareURLs"

    // MARK: - Result types

    enum EnqueueResult {
        case added       // new job appended
        case duplicate   // URL already present in non-completed state
        case full        // would exceed maxQueueSize
        case unavailable // App Group / disk unavailable
    }

    // MARK: - Singleton

    /// Shared instance pointing at the App Group container. `nil` when the
    /// entitlement is missing. Use this from the extension and host app.
    static let shared: ShareJobQueue? = {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            return nil
        }
        let storeURL = containerURL.appendingPathComponent("share-queue.json")
        return ShareJobQueue(storeURL: storeURL)
    }()

    // MARK: - Instance state

    /// Path to the JSON file holding the encoded `[ShareJob]`. Injectable
    /// so tests can use a temp directory without an App Group.
    let storeURL: URL

    private let lockURL: URL

    /// Serial queue provides in-process ordering; the `.lock` file provides
    /// cross-process ordering between the host app and share extension.
    private let ioQueue = DispatchQueue(label: "com.perrisaquino.reserch.share-queue.io")

    init(storeURL: URL) {
        self.storeURL = storeURL
        self.lockURL = storeURL.appendingPathExtension("lock")
    }

    // MARK: - Convenience accessors

    /// True when the App Group is reachable. Mirrors the old
    /// `SharedURLQueue.isAvailable` API.
    static var isAvailable: Bool { shared != nil }

    /// Total jobs in the store regardless of state. Useful for "N pending"
    /// UI and for the `isFull` check.
    var count: Int {
        readJobs().count
    }

    /// True when at the cap. Share extension uses this to short-circuit
    /// to a "queue full" UI without doing a full enqueue round-trip.
    var isFull: Bool {
        count >= Self.maxQueueSize
    }

    // MARK: - Public API

    /// Append a URL to the queue. Dedupes against any existing job in
    /// `queued`, `processing`, or `failed` states. Returns `.full` when
    /// at the cap.
    @discardableResult
    func enqueue(_ url: String) -> EnqueueResult {
        let mutation = mutate(fallback: EnqueueResult.unavailable) { jobs in
            if jobs.contains(where: { $0.url == url }) {
                return (.duplicate, false)
            }
            if jobs.count >= Self.maxQueueSize {
                return (.full, false)
            }
            jobs.append(ShareJob(url: url))
            return (.added, true)
        }
        return mutation.persisted ? mutation.result : .unavailable
    }

    /// All jobs currently in the store, oldest first.
    func allJobs() -> [ShareJob] {
        readJobs()
    }

    /// Oldest queued job, or `nil` if none. Does not change state — caller
    /// must explicitly `markProcessing` to claim it.
    func nextQueued() -> ShareJob? {
        readJobs().first(where: { $0.state == .queued })
    }

    /// Claim a job for processing. No-op if the job has been removed.
    @discardableResult
    func markProcessing(_ id: UUID) -> Bool {
        let mutation = mutate(fallback: false) { jobs in
            guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return (false, false) }
            jobs[idx].state = .processing
            jobs[idx].updatedAt = Date()
            return (true, true)
        }
        return mutation.persisted && mutation.result
    }

    /// Permanently remove a completed job. This is the only path that
    /// deletes a URL from the store — guarantees no link is lost until
    /// its transcript is saved.
    @discardableResult
    func markCompleted(_ id: UUID) -> Bool {
        let mutation = mutate(fallback: false) { jobs in
            let originalCount = jobs.count
            jobs.removeAll(where: { $0.id == id })
            return (jobs.count != originalCount, jobs.count != originalCount)
        }
        return mutation.persisted && mutation.result
    }

    /// Mark a job as failed, capturing the error and bumping `retryCount`.
    /// Job stays in the store so the user can see what happened and so
    /// a future retry path can pick it up.
    @discardableResult
    func markFailed(_ id: UUID, error: String) -> Bool {
        let mutation = mutate(fallback: false) { jobs in
            guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return (false, false) }
            jobs[idx].state = .failed
            jobs[idx].lastError = error
            jobs[idx].retryCount += 1
            jobs[idx].updatedAt = Date()
            return (true, true)
        }
        return mutation.persisted && mutation.result
    }

    /// Reset any `processing` jobs back to `queued`. Called on cold start —
    /// if the app was killed mid-fetch, the in-flight job's `processing`
    /// state is stale and we need to re-queue it.
    @discardableResult
    func resetStaleProcessing() -> Int {
        let mutation = mutate(fallback: 0) { jobs in
            var resetCount = 0
            for idx in jobs.indices where jobs[idx].state == .processing {
                jobs[idx].state = .queued
                jobs[idx].updatedAt = Date()
                resetCount += 1
            }
            return (resetCount, resetCount > 0)
        }
        return mutation.persisted ? mutation.result : 0
    }

    /// Flip a single failed job back to queued, ignoring retry caps. Used by
    /// the in-feed retry chip — user-initiated retries shouldn't share the
    /// auto-retry budget consumed by `requeueRetryableFailedJobs`.
    @discardableResult
    func requeueFailedJob(_ id: UUID) -> Bool {
        let mutation = mutate(fallback: false) { jobs in
            guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return (false, false) }
            guard jobs[idx].state == .failed else { return (false, false) }
            jobs[idx].state = .queued
            jobs[idx].updatedAt = Date()
            return (true, true)
        }
        return mutation.persisted && mutation.result
    }

    /// Move failed jobs back into the drain path for a bounded number of
    /// foreground retries. This keeps transient network/cookie failures from
    /// becoming invisible permanent backlog while still stopping retry loops.
    @discardableResult
    func requeueRetryableFailedJobs(maxRetryCount: Int = 3) -> Int {
        let mutation = mutate(fallback: 0) { jobs in
            var requeuedCount = 0
            for idx in jobs.indices
            where jobs[idx].state == .failed && jobs[idx].retryCount < maxRetryCount {
                jobs[idx].state = .queued
                jobs[idx].updatedAt = Date()
                requeuedCount += 1
            }
            return (requeuedCount, requeuedCount > 0)
        }
        return mutation.persisted ? mutation.result : 0
    }

    /// Migrate any URLs sitting in the previous flat-`[String]` queue
    /// (`pendingShareURLs` in the App Group's `UserDefaults`) into job-store
    /// form, then clear the legacy key. Safe to call repeatedly — once the
    /// key is gone this is a no-op.
    ///
    /// Tests pass a custom `UserDefaults` instance; production callers use
    /// the App Group suite.
    func migrateLegacyIfNeeded(legacyDefaults: UserDefaults?) {
        guard let defaults = legacyDefaults else { return }
        guard let legacy = defaults.stringArray(forKey: Self.legacyQueueKey),
              !legacy.isEmpty else {
            return
        }
        var remaining: [String] = []
        for url in legacy {
            switch enqueue(url) {
            case .added, .duplicate:
                continue
            case .full, .unavailable:
                remaining.append(url)
            }
        }
        if remaining.isEmpty {
            defaults.removeObject(forKey: Self.legacyQueueKey)
        } else {
            defaults.set(remaining, forKey: Self.legacyQueueKey)
        }
    }

    // MARK: - File I/O

    /// Read-modify-write under one cross-process file lock. Keeping the load,
    /// transform, and save inside the same lock prevents the host app and share
    /// extension from overwriting each other's updates.
    private func mutate<Result>(
        fallback: Result,
        _ transform: (inout [ShareJob]) -> (result: Result, didChange: Bool)
    ) -> (result: Result, persisted: Bool) {
        withLockedStore(fallback: fallback) {
            var jobs = loadJobsUncoordinated(from: storeURL)
            let outcome = transform(&jobs)
            if outcome.didChange {
                let data = try JSONEncoder.shareQueue.encode(jobs)
                try data.write(to: storeURL, options: .atomic)
            }
            return outcome.result
        }
    }

    private func readJobs() -> [ShareJob] {
        withLockedStore(fallback: []) {
            loadJobsUncoordinated(from: storeURL)
        }.result
    }

    private func withLockedStore<Result>(
        fallback: Result,
        _ operation: () throws -> Result
    ) -> (result: Result, persisted: Bool) {
        ioQueue.sync {
            do {
                try FileManager.default.createDirectory(
                    at: storeURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            } catch {
                NSLog("[ShareJobQueue] create directory failed: %@", error.localizedDescription)
                return (fallback, false)
            }

            let fd = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
            guard fd >= 0 else {
                NSLog("[ShareJobQueue] open lock failed: %@", String(cString: strerror(errno)))
                return (fallback, false)
            }
            defer { close(fd) }

            guard flock(fd, LOCK_EX) == 0 else {
                NSLog("[ShareJobQueue] acquire lock failed: %@", String(cString: strerror(errno)))
                return (fallback, false)
            }
            defer { flock(fd, LOCK_UN) }

            do {
                return (try operation(), true)
            } catch {
                NSLog("[ShareJobQueue] operation failed: %@", error.localizedDescription)
                return (fallback, false)
            }
        }
    }

    private func loadJobsUncoordinated(from url: URL) -> [ShareJob] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder.shareQueue.decode([ShareJob].self, from: data)
        } catch {
            NSLog("[ShareJobQueue] read failed: %@", error.localizedDescription)
            return []
        }
    }

}

private extension JSONEncoder {
    static let shareQueue: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

private extension JSONDecoder {
    static let shareQueue: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - SharedURLQueue (legacy facade)

/// Compatibility shim for the old enum-based API. Internally delegates to
/// `ShareJobQueue.shared`. Existing call sites (`SharedURLQueue.enqueue`,
/// `SharedURLQueue.isAvailable`, `SharedURLQueue.pendingCount`) keep working;
/// new call sites should use `ShareJobQueue.shared` directly to access state,
/// errors, and retry counts.
enum SharedURLQueue {

    static let appGroupID = ShareJobQueue.appGroupID

    static var isAvailable: Bool { ShareJobQueue.isAvailable }

    /// Returns true on `.added` or `.duplicate` (both are "the URL is now
    /// either in the queue or already was — extension can exit silently").
    /// Returns false on `.full` or `.unavailable` so the caller can fall
    /// back to a queue-full message or a deeplink launch.
    @discardableResult
    static func enqueue(_ url: String) -> Bool {
        guard let queue = ShareJobQueue.shared else { return false }
        switch queue.enqueue(url) {
        case .added, .duplicate: return true
        case .full, .unavailable: return false
        }
    }

    static var pendingCount: Int {
        ShareJobQueue.shared?.count ?? 0
    }
}

extension Notification.Name {
    /// Posted by the in-feed retry chip after `requeueFailedJob(_:)` flips a
    /// job back to queued. `ReSerchApp` listens and runs `drainSharedQueueIfNeeded`
    /// immediately, so retry doesn't wait for the next foreground bounce.
    static let shareQueueRetryRequested = Notification.Name("ShareQueueRetryRequested")
}
