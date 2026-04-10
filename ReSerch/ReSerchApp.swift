import SwiftUI

@main
struct ReSerchApp: App {
    @State private var vm = TranscriptViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        print("[ReSerch] ReSerchApp.init — binary is live")
    }

    var body: some Scene {
        WindowGroup {
            ContentView(vm: vm)
                .background(Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea())
                .onAppear {
                    print("[ReSerch] ContentView.onAppear")
                    NotificationManager.requestPermission()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Synchronous save when app backgrounds so data survives process termination
            if newPhase == .background || newPhase == .inactive {
                vm.saveHistory()
            }
        }
    }
}
