import Foundation

extension Notification.Name {
    static let showPaywall = Notification.Name("ReSerch.showPaywall")
    static let showOnboarding = Notification.Name("ReSerch.showOnboarding")
}

enum PaywallPresenter {
    static func present() {
        NSLog("[Paywall] present() — posting notification")
        NotificationCenter.default.post(name: .showPaywall, object: nil)
    }
}
