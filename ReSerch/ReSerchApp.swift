import SwiftUI
import UIKit

@main
struct ReSerchApp: App {
    @State private var vm = TranscriptViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        print("[ReSerch] ReSerchApp.init — binary is live")
        IAPManager.shared.start()

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
                }
                // Custom-scheme handoff from ReSerchShareExtension. The extension fires
                // `reserch://transcribe?url=...` and the system relaunches us here.
                // We pull the embedded URL out and seed the view model directly so the
                // user sees the transcription kick off as soon as they land in the app.
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                vm.saveHistory()
                vm.saveNotebooks()
                UIApplication.shared.ignoreSnapshotOnNextApplicationLaunch()
            }
        }
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
        vm.urlInput = target.absoluteString
        Task { @MainActor in
            await vm.fetchTranscript()
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
