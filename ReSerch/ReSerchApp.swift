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
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background || newPhase == .inactive {
                vm.saveHistory()
                vm.saveNotebooks()
                UIApplication.shared.ignoreSnapshotOnNextApplicationLaunch()
            }
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
