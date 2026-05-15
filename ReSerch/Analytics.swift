import Foundation
#if canImport(PostHog)
import PostHog
#endif

enum AnalyticsEvent: String {
    case transcriptStarted = "transcript_started"
    case transcriptCompleted = "transcript_completed"
    case transcriptFailed = "transcript_failed"
    case transcriptViewed = "transcript_viewed"

    case transcriptEditStarted = "transcript_edit_started"
    case transcriptEditSaved = "transcript_edit_saved"
    case annotationCreated = "annotation_created"
    case annotationDeleted = "annotation_deleted"
    case documentNoteAdded = "document_note_added"
    case documentNoteEdited = "document_note_edited"
    case documentNotePinned = "document_note_pinned"

    case transcriptExported = "transcript_exported"
    case transcriptCopiedPartial = "transcript_copied_partial"
    case notebookCreated = "notebook_created"
    case notebookExported = "notebook_exported"

    case settingChanged = "setting_changed"
}

/// Single chokepoint for all analytics. Initialized once in `ReSerchApp.init()` via
/// `Analytics.shared.start()`. All event call sites go through `Analytics.shared.track(_:properties:)`.
///
/// Behavior:
/// - DEBUG builds: SDK is never initialized, `track` is a no-op. Local dev never pollutes data.
/// - Release builds: opt-out is honored at both init time and runtime via the Settings toggle.
/// - Anonymous: PostHog assigns a stable per-install distinct_id. No Apple ID, no email, no PII.
final class Analytics {
    static let shared = Analytics()

    private static let projectToken = "phc_BasvHtfELweQF8QAxNPaknrH6qUwgyuQJVkuKy2ZQeFP"
    private static let host = "https://us.i.posthog.com"
    private static let optOutKey = "analytics.optedOut"

    private init() {}

    /// User-facing opt-out, backed by UserDefaults. Defaults to false (opted in).
    var isOptedOut: Bool {
        get { UserDefaults.standard.bool(forKey: Self.optOutKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.optOutKey)
            #if canImport(PostHog)
            #if !DEBUG
            if newValue {
                PostHogSDK.shared.optOut()
            } else {
                PostHogSDK.shared.optIn()
            }
            #endif
            #endif
        }
    }

    func start() {
        #if DEBUG
        print("[Analytics] DEBUG build — PostHog disabled")
        #else
        #if canImport(PostHog)
        let config = PostHogConfig(projectToken: Self.projectToken, host: Self.host)
        config.captureApplicationLifecycleEvents = true
        config.captureScreenViews = false
        config.personProfiles = .always
        config.optOut = isOptedOut
        PostHogSDK.shared.setup(config)
        #endif
        #endif
    }

    func track(_ event: AnalyticsEvent, properties: [String: Any]? = nil) {
        #if DEBUG
        return
        #else
        #if canImport(PostHog)
        guard !isOptedOut else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
        #endif
        #endif
    }
}
