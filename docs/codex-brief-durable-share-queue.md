# Brief for Codex — durable share-to-transcribe queue

## Context
Replacing ReSerch's destructive `SharedURLQueue.drain()` flow with a file-backed durable job queue. You already audited the plan and corrected two of my claims (background-task wrapping was already present; `fetchBatch` is sequential, not parallel) — both folded in. Looking for a second pass on the actual implementation.

Branch state: dirty working tree on `main` at `a966b18`. Main app + share extension build clean (`** BUILD SUCCEEDED **`). Test target won't link due to a pre-existing, unrelated breakage in `CarouselNoteFormatterTests.swift:18` (the `CarouselPayload` init grew analytics-count params; that test wasn't updated). Out of scope for this work.

## Files touched

**Modified:**
- `ReSerch/SharedURLQueue.swift` — replaced contents
- `ReSerch/ReSerchApp.swift` — `init()` migration + new sequential `drainSharedQueueIfNeeded`
- `ReSerchShareExtension/ShareViewController.swift` — `.queueFull` state + routes through `ShareJobQueue.shared`

**Added:**
- `ReSerchTests/ShareJobQueueTests.swift` — 10 Swift Testing cases

**Why one file for `ShareJob` + `ShareJobQueue` + `SharedURLQueue` facade:** the file at `ReSerch/SharedURLQueue.swift` is already in both the main app target (via Xcode 16 `PBXFileSystemSynchronizedRootGroup`) and the extension target (via explicit pbxproj entry mirroring `path = ../ReSerch/SharedURLQueue.swift`). Splitting into separate files would require pbxproj edits to add the new files to the extension target. Single-file kept the project file untouched.

## Design

### `ShareJob`
```swift
struct ShareJob: Codable, Equatable {
    enum State: String, Codable { case queued, processing, failed }
    let id: UUID
    let url: String
    var state: State
    var retryCount: Int
    var lastError: String?
    let createdAt: Date
    var updatedAt: Date
}
```
No `completed` state — completion deletes the job. The store represents *outstanding* work only.

### `ShareJobQueue`
- Storage: JSON at `<appgroup-container>/share-queue.json`
- Singleton `ShareJobQueue.shared` resolves the App Group; `nil` if entitlement missing
- All mutations funnel through `mutate { jobs in ... }` which: takes serial `DispatchQueue` lock, then `NSFileCoordinator.coordinate(writingItemAt:options: .forReplacing)`, then atomic `Data.write(to:options:.atomic)`
- Reads use `NSFileCoordinator.coordinate(readingItemAt:)`
- ISO-8601 dates

### Public API
- `enqueue(_:) -> EnqueueResult` — `.added | .duplicate | .full | .unavailable`. Dedupe spans all states (queued, processing, failed)
- `allJobs()`, `count`, `isFull`
- `nextQueued()` — read only; caller claims via `markProcessing`
- `markProcessing(_:)`, `markCompleted(_:)` (deletes), `markFailed(_:error:)` (keeps + bumps retryCount)
- `resetStaleProcessing()` — reset all `processing` → `queued`
- `migrateLegacyIfNeeded(legacyDefaults:)` — drains `pendingShareURLs` from a `UserDefaults`, enqueues via the normal path (so cap + dedupe apply), then `removeObject(forKey:)`. Idempotent.
- `maxQueueSize = 50`

### Legacy facade
`SharedURLQueue` enum kept as a one-line shim:
```swift
static func enqueue(_ url: String) -> Bool {
    guard let q = ShareJobQueue.shared else { return false }
    switch q.enqueue(url) {
    case .added, .duplicate: return true
    case .full, .unavailable: return false
    }
}
```
The old `drain()` method is **gone**, intentionally. Any stale binary still calling it would fail to compile, surfacing the cut-over.

### Host drain (`ReSerchApp.swift`)
```swift
private func drainSharedQueueIfNeeded() {
    guard let queue = ShareJobQueue.shared else { return }
    queue.resetStaleProcessing()
    guard queue.nextQueued() != nil else { return }

    Task { @MainActor in
        while let job = queue.nextQueued() {
            queue.markProcessing(job.id)
            let savedBefore = vm.history.count
            vm.urlInput = job.url
            await vm.fetchTranscript()
            let didSave = vm.history.count > savedBefore
            if didSave {
                queue.markCompleted(job.id)
            } else {
                queue.markFailed(job.id, error: "\(vm.status)")
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
```
Sequential, per your guidance. Uses the existing `fetchTranscript` (which already does `withBackgroundTask`) — no VM internals touched, only its public surface. Success detected via `vm.history.count` snapshot delta (same trick `fetchBatch` already uses internally).

Migration runs once in `init()`:
```swift
if let queue = ShareJobQueue.shared {
    queue.migrateLegacyIfNeeded(
        legacyDefaults: UserDefaults(suiteName: ShareJobQueue.appGroupID)
    )
}
```

### Share extension
- New `ShareState.queueFull` (amber `tray.full.fill` icon, "Queue full. Open ReSerch to clear it.", 2.2s display then complete)
- Calls `ShareJobQueue.shared.enqueue` directly (not the bool facade) so `.full` and `.unavailable` are distinguishable
- `.added` / `.duplicate` → silent enqueue + `.queued` UI (1.2s)
- `.full` → `.queueFull` UI
- `.unavailable` → existing deeplink fallback

## Tests (10 cases, Swift Testing)

| # | Case | What it proves |
|---|---|---|
| 1 | enqueue persists across new instance | Disk round-trip works |
| 2 | duplicate URL → `.duplicate`, count stays 1 | Pending dedupe |
| 3 | dedupe across queued+processing+failed | Re-share of any in-flight or failed URL is a no-op |
| 4 | post-`markCompleted` re-enqueue succeeds | Completion = full delete |
| 5 | enqueue past cap → `.full`, file doesn't grow | Cap enforced |
| 6 | mark processing → fresh instance + `resetStaleProcessing` → all queued | Crash recovery |
| 7 | `markFailed` keeps URL, captures error, bumps retryCount over multiple calls | Failure surface intact |
| 8 | `nextQueued()` skips processing/failed, returns oldest queued | Order + state filtering |
| 9 | legacy migration moves URLs, dedupes within source array, clears key, idempotent on re-run | Cut-over story |
| 10 | migration with no legacy key is no-op | Doesn't break fresh installs |

Each test gets its own temp file via `FileManager.default.temporaryDirectory.appendingPathComponent("share-queue-test-\(UUID()).json")` for isolation.

## Specific things I want you to challenge

1. **`NSFileCoordinator` correctness for cross-process writes from share extension + host.** I'm using `.forReplacing` for writes and default options for reads. Is that the right combination given the extension and host can both be writing within the same second? Specifically: does `.forReplacing` give us last-writer-wins correctly, and is there any read-during-write gap I should be using `.forMerging` or a presenter for?

2. **Failure-text capture.** `queue.markFailed(job.id, error: "\(vm.status)")` interpolates the VM's `Status` enum description. That'll produce strings like "needsModel" or "error(\"…\")". Acceptable, or worth surfacing a typed error from `fetchTranscript` instead? Latter touches the VM more.

3. **Migration timing.** Runs in host `init()` synchronously, before `IAPManager.shared.start()` — wait, actually after. Order is `IAPManager.shared.start()` then migration. Should migration be earlier (before IAP)? Doesn't matter for correctness but it's the kind of thing you catch.

4. **`markProcessing` + crash window.** Between `markProcessing(job.id)` and `vm.fetchTranscript()` starting any actual work, an OS kill leaves the job in `processing`. Next launch's `resetStaleProcessing()` flips it back. Correct. But — is there any state where `fetchTranscript` saves the transcript to history *and* the process dies before `markCompleted` runs? Then on next launch the job re-runs and produces a duplicate transcript in history. The `TranscriptViewModel` history-side dedupe (if any) would need to absorb that. Worth a look.

5. **Removed `drain()`.** Hard-cut, no shim. Anyone still calling `SharedURLQueue.drain()` would fail to compile. I think that's right — no callers exist after my edits — but worth confirming I didn't miss one.

6. **The `count` getter does a full disk read.** `isFull` calls `count`, share extension calls `enqueue` which internally `mutate` reads + appends. So worst case the extension does two file reads per share. Fine for the share extension's brief lifetime, but flagging.

7. **`vm.urlInput = job.url`.** This clobbers the user's text-field input if they happen to be typing when the foreground transition fires. The previous code did the same thing for the single-URL path. Worth fixing as part of this work, or punt to a separate task?

## What I did not change
- `TranscriptViewModel` internals (currentTask, status, fetchBatch, fetchTranscript bodies)
- `Info.plist` activation rules (already correct for TikTok / IG / YouTube / Safari / Threads)
- IAP, Notebooks, paywall, history file format
- The `.pbxproj`

## Verification status
- `xcodebuild build` for `ReSerch` scheme → **BUILD SUCCEEDED**
- Test execution: blocked on the unrelated `CarouselNoteFormatterTests` breakage. New test file compiled cleanly when the build got far enough to type-check it (no errors emitted against `ShareJobQueueTests.swift`).
- Manual TikTok share-sheet round-trip on device: not yet performed.

Looking for: anything wrong with the file-coordinator usage, the crash window in #4, or the cut-over story. Also any tests I should add.
