import SwiftUI
import WebKit

/// Full-size WKWebView sheet that loads a platform sign-in URL inside the app.
///
/// Critical detail: this view *must* use `WKWebsiteDataStore.default()` because that's the
/// same persistent store `InstagramWebExtractor` and `YouTubeShortsExtractor` read from.
/// Cookies set during sign-in here become visible to those extractors immediately.
///
/// Mobile Safari uses a different (Safari-private) store, so opening the sign-in URL via
/// `UIApplication.shared.open` does *not* surface cookies to the extractors. That's why
/// we need an in-app sheet instead of bouncing to Safari.
struct InAppSignInSheet: View {
    let provider: TranscriptViewModel.SafariProvider
    let onDismiss: () -> Void

    @State private var isLoading = true
    @State private var currentURL: URL?
    @Environment(\.dismiss) private var envDismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()

                SignInWebView(
                    url: provider.signInURL,
                    isLoading: $isLoading,
                    currentURL: $currentURL
                )

                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }
            }
            .navigationTitle("Sign in to \(provider.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        envDismiss()
                        onDismiss()
                    }
                    .foregroundStyle(Color.accentColor)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        envDismiss()
                        onDismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

extension TranscriptViewModel.SafariProvider {
    /// Sign-in landing pages. Tested to work inside an in-app WKWebView without
    /// being intercepted by Universal Links or App Store install prompts.
    var signInURL: URL {
        switch self {
        case .instagram:
            return URL(string: "https://www.instagram.com/accounts/login/")!
        case .youtube:
            return URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fm.youtube.com%2F")!
        }
    }
}

private struct SignInWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var currentURL: URL?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Critical: the SAME data store InstagramWebExtractor / YouTubeShortsExtractor read.
        // Cookies set here are visible to the extractors immediately.
        config.websiteDataStore = .default()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        // Mobile UA so platforms serve the mobile sign-in flow (cleaner, autofills better).
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.allowsBackForwardNavigationGestures = true
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: SignInWebView

        init(_ parent: SignInWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async { self.parent.isLoading = true }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.parent.isLoading = false
                self.parent.currentURL = webView.url
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.isLoading = false }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.isLoading = false }
        }
    }
}
