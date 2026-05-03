import Foundation
import WebKit

/// Centralized check for whether the user has an active in-app session for the platforms
/// ReSerch transcribes. Cookies are read from `WKWebsiteDataStore.default()` — the *app's*
/// own persistent cookie store, NOT Safari's. iOS sandboxes Safari's cookies away from
/// every other app. So a "no session" result here only means our app hasn't seen a sign-in
/// yet (or the cookies expired) — the user may still be signed into Safari independently.
///
/// `InstagramWebExtractor`, `YouTubeShortsExtractor`, and `InAppSignInSheet` all read from
/// the same store, so cookies set by the in-app sign-in sheet become immediately visible
/// to the extractors.
///
/// Used as a pre-flight check inside `TranscriptViewModel.fetchTranscript()` so the user
/// sees an instant in-app sign-in banner instead of waiting 20s for an extractor timeout.
@MainActor
enum CookieChecker {
    /// True if Safari has any non-expired Instagram or Threads session cookies. Both products
    /// share Meta's CDN, so either set is sufficient.
    static func hasInstagramSession() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let now = Date()
        return cookies.contains { cookie in
            let domain = cookie.domain.lowercased()
            guard domain.contains("instagram.com") || domain.contains("threads.net") else { return false }
            if let expires = cookie.expiresDate, expires < now { return false }
            // Look for session-bearing cookies — sessionid is the canonical "logged in" marker.
            // ds_user_id / csrftoken indicate an authenticated session even when sessionid is httpOnly.
            return ["sessionid", "ds_user_id", "csrftoken"].contains(cookie.name)
        }
    }

    /// True if Safari has either a YouTube login marker (LOGIN_INFO) or has accepted YouTube's
    /// consent flow with a visitor session (VISITOR_INFO1_LIVE + CONSENT). Either is enough for
    /// the Shorts player to hydrate without the consent interstitial.
    static func hasYouTubeSession() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let now = Date()
        let active = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            guard domain.contains("youtube.com") || domain.contains("google.com") else { return false }
            if let expires = cookie.expiresDate, expires < now { return false }
            return true
        }
        if active.contains(where: { $0.name == "LOGIN_INFO" }) { return true }
        let hasVisitor = active.contains(where: { $0.name == "VISITOR_INFO1_LIVE" })
        let hasConsent = active.contains(where: { $0.name == "CONSENT" || $0.name == "SOCS" })
        return hasVisitor && hasConsent
    }
}
