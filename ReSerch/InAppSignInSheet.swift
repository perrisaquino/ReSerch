import SwiftUI
import WebKit

/// Full-size WKWebView sheet that loads a platform sign-in URL inside the app.
///
/// **Cookie isolation truth:** `WKWebsiteDataStore.default()` is the *app's* persistent
/// store, NOT Safari's. iOS sandboxes Safari's cookies away from every other app — there
/// is no public API to read them. So even if the user is signed into Instagram in Safari,
/// our extractors have no way to use that session. The user signs in here ONCE and the
/// cookies persist in the app's own store across launches until Instagram signs them out.
///
/// On open we proactively check `CookieChecker` again — if cookies are already present
/// (e.g. parent missed the cache because of a race), we auto-dismiss instead of forcing
/// the user to look at the sign-in form they don't actually need.
struct InAppSignInSheet: View {
    let provider: TranscriptViewModel.SafariProvider
    let onDismiss: () -> Void

    @State private var isLoading = true
    @State private var currentURL: URL?
    @State private var didAutoDismiss = false
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
            .task {
                // Race-safe auto-dismiss: if cookies are already present, skip the sheet.
                // Common when the parent's pre-check missed (cookie store was loading) or
                // when the user reopens after a previous successful sign-in this session.
                guard !didAutoDismiss else { return }
                let hasSession: Bool
                switch provider {
                case .instagram: hasSession = await CookieChecker.hasInstagramSession()
                case .youtube:   hasSession = await CookieChecker.hasYouTubeSession()
                }
                if hasSession {
                    didAutoDismiss = true
                    envDismiss()
                    onDismiss()
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
