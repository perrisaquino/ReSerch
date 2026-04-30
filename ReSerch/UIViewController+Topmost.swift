import UIKit

extension UIViewController {
    /// Walks the presentedViewController chain to the topmost one. Use this before
    /// calling `present(_:animated:)` from anywhere in the app.
    ///
    /// Why: in iOS 26 on real devices, calling `present` on a VC that's already
    /// presenting another modal raises "Application tried to present modally an
    /// active controller" — which used to be a warning and is now a hard crash on
    /// arm64e (iPhone 16e and newer). The fix is to always present on the topmost VC.
    var topmostPresentedViewController: UIViewController {
        var top = self
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }
}

extension UIApplication {
    /// Returns the foreground active window scene's key window, or nil if the app is
    /// in the background or has no foreground scene. Replaces deprecated
    /// `windows.first` / `connectedScenes.first as? UIWindowScene`.
    var keyForegroundWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}
