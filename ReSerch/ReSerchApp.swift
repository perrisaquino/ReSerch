import SwiftUI
import UIKit

@main
struct ReSerchApp: App {
    @State private var vm = TranscriptViewModel()
    @State private var shareQueueDrainTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        print("[ReSerch] ReSerchApp.init — binary is live")
        Analytics.shared.start()
        IAPManager.shared.start()

        // One-shot migration from the legacy `pendingShareURLs` flat-array
        // queue. Runs in the host (not the extension) so the extension stays
        // short-lived; any URL already enqueued via the old shim has been
        // delivered to a host-app launch by the time the user sees this build.
        if let queue = ShareJobQueue.shared {
            queue.migrateLegacyIfNeeded(
                legacyDefaults: UserDefaults(suiteName: ShareJobQueue.appGroupID)
            )
            queue.resetStaleProcessing()
        }

        #if DEBUG
        if CommandLine.arguments.contains("-PaywallOnLaunch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                PaywallPresenter.present()
            }
        }
        if CommandLine.arguments.contains("-FillGateOnLaunch") {
            ExportGate.shared.debugFillToLimit()
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(vm: vm)
                .background(Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea())
                .onAppear {
                    print("[ReSerch] RootTabView.onAppear")
                    NotificationManager.requestPermission()
                    vm.refreshPendingShareJobs()
                }
                // Custom-scheme handoff from ReSerchShareExtension. The extension fires
                // `reserch://transcribe?url=...` and the system relaunches us here.
                // We pull the embedded URL out and seed the view model directly so the
                // user sees the transcription kick off as soon as they land in the app.
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
                .onReceive(NotificationCenter.default.publisher(for: .shareQueueRetryRequested)) { _ in
                    drainSharedQueueIfNeeded()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                vm.refreshPendingShareJobs()
                drainSharedQueueIfNeeded()
            case .background, .inactive:
                vm.saveHistory()
                vm.saveNotebooks()
                UIApplication.shared.ignoreSnapshotOnNextApplicationLaunch()
            @unknown default:
                break
            }
        }
    }

    /// Process whatever the share extension has accumulated since the last foreground
    /// pass. Driven by `ShareJobQueue` so a crash, OS suspend, or transcription failure
    /// never silently loses links: each job stays in the store until its transcript
    /// has been saved (`markCompleted`), and any `processing` job left over from a
    /// previous launch (i.e. the app was killed mid-fetch) is reset to `queued` first.
    ///
    /// v1 is sequential — the existing TranscriptViewModel shares mutable state across
    /// `currentTask`/`urlInput`/`status`, so concurrent jobs would actively cancel
    /// each other. Concurrency is a future change gated on a stateless worker.
    private func drainSharedQueueIfNeeded() {
        guard let queue = ShareJobQueue.shared else { return }
        guard shareQueueDrainTask == nil else { return }
        queue.requeueRetryableFailedJobs()
        vm.refreshPendingShareJobs()
        guard queue.nextQueued() != nil else {
            // Even with no queued work, failed-at-max-retry jobs need to stay visible.
            vm.refreshPendingShareJobs()
            return
        }
        print("[ReSerch] Processing share queue — \(queue.count) job(s) total")

        shareQueueDrainTask = Task { @MainActor in
            defer {
                shareQueueDrainTask = nil
                vm.activeShareJobID = nil
                vm.refreshPendingShareJobs()
            }
            while let job = queue.nextQueued() {
                if historyContainsTranscript(for: job.url) {
                    queue.markCompleted(job.id)
                    vm.refreshPendingShareJobs()
                    continue
                }
                guard queue.markProcessing(job.id) else { continue }
                vm.refreshPendingShareJobs()

                let savedBefore = vm.history.count
                vm.nextFetchSurface = "share_extension"
                vm.activeShareJobID = job.id
                await vm.fetchTranscript(for: job.url)
                vm.activeShareJobID = nil
                let didSave = vm.history.count > savedBefore || historyContainsTranscript(for: job.url)
                if didSave {
                    queue.markCompleted(job.id)
                } else {
                    // Capture whatever the VM's status field is reporting — best-effort
                    // error text without reaching into TranscriptViewModel's internals.
                    queue.markFailed(job.id, error: "\(vm.status)")
                }
                vm.refreshPendingShareJobs()
                // Mirror fetchBatch's inter-iteration breather — gives platform-side
                // rate-limit / cookie state a moment to settle.
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func historyContainsTranscript(for url: String) -> Bool {
        let target = normalizedShareURL(url)
        return vm.history.contains { entry in
            normalizedShareURL(entry.result.url) == target
        }
    }

    private func normalizedShareURL(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count > 1 && value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }

    /// Parses an incoming `reserch://` URL and, if it carries a transcription request,
    /// hands the embedded URL to the view model and starts the fetch immediately.
    /// Anything we don't recognize is silently ignored — keeps the URL scheme forward-
    /// compatible if we add other actions later (`reserch://settings`, etc.).
    private func handleIncomingURL(_ url: URL) {
        print("[ReSerch] onOpenURL — \(url.absoluteString)")
        guard url.scheme?.lowercased() == "reserch" else { return }
        guard url.host?.lowercased() == "transcribe" else { return }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = comps.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: raw) else {
            return
        }
        Task { @MainActor in
            vm.nextFetchSurface = "share_extension"
            await vm.fetchTranscript(for: target.absoluteString)
        }
    }
}

private struct RootTabView: View {
    var vm: TranscriptViewModel

    var body: some View {
        TabView {
            ContentView(vm: vm)
                .tabItem {
                    Label("Feed", systemImage: "text.bubble")
                }

            NotebooksView(vm: vm)
                .tabItem {
                    Label("Notebooks", systemImage: "books.vertical")
                }
        }
        .tint(Color.accentColor)
    }
}
