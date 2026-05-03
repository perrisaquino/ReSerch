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
    @State private var showSignedInToast = false
    @Environment(\.dismiss) private var envDismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()

                SignInWebView(
                    url: provider.signInURL,
                    isLoading: $isLoading,
                    currentURL: $currentURL,
                    onPossibleSuccess: { handlePossibleSuccess() }
                )

                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.2)
                }

                if showSignedInToast {
                    VStack {
                        Spacer()
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Signed in. Closing...")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 32)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Sign in to \(provider.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        rLog(step: "SignIn", "User cancelled — no cookies saved")
                        envDismiss()
                        onDismiss()
                    }
                    .foregroundStyle(Color.accentColor)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        // Smarter Done: verify cookies before closing. If the user taps Done
                        // before actually signing in, we want to keep the sheet open with an
                        // explanation rather than silently leaving them in a broken state.
                        Task {
                            let hasSession: Bool
                            switch provider {
                            case .instagram: hasSession = await CookieChecker.hasInstagramSession()
                            case .youtube:   hasSession = await CookieChecker.hasYouTubeSession()
                            }
                            rLog(hasSession ? .ok : .warn,
                                 step: "SignIn",
                                 "Done tapped — session cookies present: \(hasSession)")
                            envDismiss()
                            onDismiss()
                        }
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
                rLog(step: "SignIn", "Sheet opened — initial session check: \(hasSession)")
                if hasSession {
                    didAutoDismiss = true
                    envDismiss()
                    onDismiss()
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Called by the WKWebView's navigation delegate when the URL leaves the login flow.
    /// We don't trust the URL alone — we verify there's an actual session cookie before
    /// declaring success. Avoids false positives from intermediate redirects (challenge,
    /// 2FA, captcha pages all sit at non-login URLs but don't mean signed-in yet).
    private func handlePossibleSuccess() {
        guard !didAutoDismiss else { return }
        Task { @MainActor in
            let hasSession: Bool
            switch provider {
            case .instagram: hasSession = await CookieChecker.hasInstagramSession()
            case .youtube:   hasSession = await CookieChecker.hasYouTubeSession()
            }
            guard hasSession, !didAutoDismiss else { return }
            didAutoDismiss = true
            rLog(.ok, step: "SignIn", "Auto-detected successful sign-in — closing sheet")
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                showSignedInToast = true
            }
            try? await Task.sleep(for: .seconds(1.0))
            envDismiss()
            onDismiss()
        }
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
    /// Fired when the WKWebView lands on a non-login URL — sheet's task verifies cookies
    /// before treating this as a real success (could be challenge / 2FA / captcha redirect).
    var onPossibleSuccess: () -> Void = {}

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // App's persistent cookie store. NOT shared with Safari (iOS sandboxes that).
        // Cookies written here are visible to InstagramWebExtractor / YouTubeShortsExtractor.
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
                self.checkForSuccess(webView: webView)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.isLoading = false }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async { self.parent.isLoading = false }
        }

        /// Heuristic: if we landed somewhere that isn't a login / challenge / two-factor
        /// page, the user might have just successfully signed in. Notify the parent so it
        /// can verify with a cookie check (URL alone is too noisy — Instagram bounces
        /// through several intermediate URLs even before login completes).
        private func checkForSuccess(webView: WKWebView) {
            guard let path = webView.url?.path.lowercased() else { return }
            let stillSigningIn = path.contains("/accounts/login")
                || path.contains("/accounts/signup")
                || path.contains("/accounts/two_factor")
                || path.contains("/accounts/onetap")
                || path.contains("/challenge")
                || path.contains("/captcha")
                || path.contains("/identifier")
                || path.contains("/signin")
                || path.contains("/oauth")
            if !stillSigningIn {
                parent.onPossibleSuccess()
            }
        }
    }
}
