import Testing
import Foundation
@testable import ReSerch

// MARK: - Test helpers

/// Each test gets its own temp file so they're fully independent and
/// don't see each other's state across runs.
private func makeTempQueue() -> (queue: ShareJobQueue, url: URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("share-queue-test-\(UUID().uuidString).json")
    return (ShareJobQueue(storeURL: url), url)
}

private func cleanup(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

// MARK: - Tests

@Suite("ShareJobQueue")
struct ShareJobQueueTests {

    @Test("enqueue persists across new instance")
    func enqueuePersists() {
        let (q1, url) = makeTempQueue()
        defer { cleanup(url) }

        #expect(q1.enqueue("https://tiktok.com/@a/video/1") == .added)
        #expect(q1.count == 1)

        // Simulate process restart — fresh instance, same store URL.
        let q2 = ShareJobQueue(storeURL: url)
        let jobs = q2.allJobs()
        #expect(jobs.count == 1)
        #expect(jobs.first?.url == "https://tiktok.com/@a/video/1")
        #expect(jobs.first?.state == .queued)
    }

    @Test("enqueue same URL twice returns duplicate, stores one")
    func dedupes() {
        let (q, url) = makeTempQueue()
        defer { cleanup(url) }

        #expect(q.enqueue("https://x.com/post/42") == .added)
        #expect(q.enqueue("https://x.com/post/42") == .duplicate)
        #expect(q.count == 1)
    }

    @Test("dedupe spans queued, processing, and failed states")
    func dedupeAcrossStates() {
        let (q, url) = makeTempQueue()
        defer { cleanup(url) }

        let target = "https://reels.example/abc"
        _ = q.enqueue(target)
        let job = q.allJobs().first!

        // While processing — duplicate enqueue is a no-op.
        q.markProcessing(job.id)
        #expect(q.enqueue(target) == .duplicate)
        #expect(q.count == 1)

        // After failure — still deduped (user can re-share, doesn't pile up).
        q.markFailed(job.id, error: "network down")
        #expect(q.enqueue(target) == .duplicate)
        #expect(q.count == 1)
    }

    @Test("after markCompleted the URL is gone and re-enqueue succeeds")
    func completionAllowsReenqueue() {
        let (q, url) = makeTempQueue()
        defer { cleanup(url) }

        _ = q.enqueue("https://yt/watch?v=1")
        let id = q.allJobs().first!.id
        q.markCompleted(id)
        #expect(q.count == 0)
        #expect(q.enqueue("https://yt/watch?v=1") == .added)
    }

    @Test("enqueue past max returns full and does not grow store")
    func enforcesCap() {
        let (q, url) = makeTempQueue()
        defer { cleanup(url) }

        for i in 0..<ShareJobQueue.maxQueueSize {
            #expect(q.enqueue("https://example.com/\(i)") == .added)
        }
        #expect(q.count == ShareJobQueue.maxQueueSize)
        #expect(q.isFull == true)
        #expect(q.enqueue("https://example.com/overflow") == .full)
        #expect(q.count == ShareJobQueue.maxQueueSize)
    }

    @Test("processing jobs reset to queued after simulated kill")
    func recoversStaleProcessing() {
        let (q1, url) = makeTempQueue()
        defer { cleanup(url) }

        _ = q1.enqueue("https://tt/1")
        _ = q1.enqueue("https://tt/2")
        let firstID = q1.allJobs().first!.id
        q1.markProcessing(firstID)

        // Simulate the host app being killed mid-fetch — fresh instance,
        // resetStaleProcessing is what the host should call on cold start.
        let q2 = ShareJobQueue(storeURL: url)
        q2.resetStaleProcessing()

        let jobs = q2.allJobs()
        #expect(jobs.allSatisfy { $0.state == .queued })
        #expect(q2.nextQueued()?.id == firstID)
    }

    @Test("failure path keeps URL with error and bumps retryCount")
    func failureKeepsURL() {
        let (q, url) = makeTempQueue()
        defer { cleanup(url) }

        _ = q.enqueue("https://insta/p/xyz")
        let id = q.allJobs().first!.id

        q.markProcessing(id)
        q.markFailed(id, error: "401 unauthorized")

        let job = q.allJobs().first!
        #expect(job.state == .failed)
        #expect(job.lastError == "401 unauthorized")
        #expect(job.retryCount == 1)

        q.markFailed(id, error: "network")
        #expect(q.allJobs().first?.retryCount == 2)
        #expect(q.count == 1)
    }

    @Test("retryable failed jobs are requeued up to the retry limit")
    func requeuesRetryableFailures() {
        let (q, url) = makeTempQueue()
        defer { cleanup(url) }

        _ = q.enqueue("https://insta/p/retry")
        let id = q.allJobs().first!.id

        q.markFailed(id, error: "temporary")
        #expect(q.requeueRetryableFailedJobs(maxRetryCount: 3) == 1)
        #expect(q.allJobs().first?.state == .queued)

        q.markFailed(id, error: "still failing")
        q.markFailed(id, error: "last try")
        #expect(q.allJobs().first?.retryCount == 3)
        #expect(q.requeueRetryableFailedJobs(maxRetryCount: 3) == 0)
        #expect(q.allJobs().first?.state == .failed)
    }

    @Test("nextQueued returns oldest queued and skips processing/failed")
    func nextQueuedOrder() {
        let (q, url) = makeTempQueue()
        defer { cleanup(url) }

        _ = q.enqueue("https://a")
        _ = q.enqueue("https://b")
        _ = q.enqueue("https://c")

        let jobs = q.allJobs()
        q.markProcessing(jobs[0].id)
        q.markFailed(jobs[1].id, error: "x")

        // Only "c" remains queued.
        #expect(q.nextQueued()?.url == "https://c")
    }

    @Test("legacy migration moves URLs into the job store and clears the key")
    func legacyMigration() {
        let (q, url) = makeTempQueue()
        defer { cleanup(url) }

        let suiteName = "test.shareQueueLegacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            ["https://legacy/1", "https://legacy/2", "https://legacy/1"],
            forKey: ShareJobQueue.legacyQueueKey
        )

        q.migrateLegacyIfNeeded(legacyDefaults: defaults)

        let urls = q.allJobs().map(\.url)
        // Legacy array could contain dupes — migration goes through enqueue
        // so dedupe still applies.
        #expect(urls == ["https://legacy/1", "https://legacy/2"])
        #expect(defaults.stringArray(forKey: ShareJobQueue.legacyQueueKey) == nil)

        // Idempotent — calling again does nothing.
        q.migrateLegacyIfNeeded(legacyDefaults: defaults)
        #expect(q.allJobs().count == 2)
    }

    @Test("legacy migration preserves URLs it cannot enqueue")
    func legacyMigrationPreservesOverflow() {
        let (q, url) = makeTempQueue()
        defer { cleanup(url) }

        for i in 0..<ShareJobQueue.maxQueueSize {
            #expect(q.enqueue("https://existing/\(i)") == .added)
        }

        let suiteName = "test.shareQueueLegacyOverflow.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            ["https://legacy/overflow-1", "https://legacy/overflow-2"],
            forKey: ShareJobQueue.legacyQueueKey
        )

        q.migrateLegacyIfNeeded(legacyDefaults: defaults)

        #expect(q.count == ShareJobQueue.maxQueueSize)
        #expect(defaults.stringArray(forKey: ShareJobQueue.legacyQueueKey) == [
            "https://legacy/overflow-1",
            "https://legacy/overflow-2"
        ])
    }

    @Test("concurrent queue instances keep all unique enqueues")
    func concurrentInstancesKeepUniqueEnqueues() {
        let (_, url) = makeTempQueue()
        defer { cleanup(url) }

        let q1 = ShareJobQueue(storeURL: url)
        let q2 = ShareJobQueue(storeURL: url)
        let group = DispatchGroup()
        let worker = DispatchQueue(label: "share-job-queue-test", attributes: .concurrent)

        for i in 0..<20 {
            group.enter()
            worker.async {
                _ = q1.enqueue("https://batch-a/\(i)")
                group.leave()
            }

            group.enter()
            worker.async {
                _ = q2.enqueue("https://batch-b/\(i)")
                group.leave()
            }
        }

        #expect(group.wait(timeout: .now() + 10) == .success)

        let urls = Set(ShareJobQueue(storeURL: url).allJobs().map(\.url))
        #expect(urls.count == 40)
        #expect(urls.contains("https://batch-a/0"))
        #expect(urls.contains("https://batch-b/19"))
    }

    @Test("migration with no legacy data is a no-op")
    func migrationNoOp() {
        let (q, url) = makeTempQueue()
        defer { cleanup(url) }

        let suiteName = "test.shareQueueLegacyEmpty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        q.migrateLegacyIfNeeded(legacyDefaults: defaults)
        #expect(q.allJobs().isEmpty)
    }
}
