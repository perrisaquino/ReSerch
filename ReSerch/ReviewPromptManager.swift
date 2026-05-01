import Foundation
import StoreKit
import UIKit

/// Triggers the native App Store review prompt at "magic moments" — places where the user
/// has just realized the app's value. Apple's `SKStoreReviewController` is hard-throttled
/// to 3 prompts per user per year, so the rule here is: only ask at *qualified* moments,
/// and trust Apple's throttle to handle frequency.
///
/// After a review prompt fires, we broadcast `.offerTestimonial` so a soft secondary
/// surface (toast / small sheet) can offer the user a one-tap path into Submit Feedback
/// with the Testimonial category pre-selected. The two asks are deliberately separate:
/// Apple's prompt is sacred and shouldn't be diluted with our own UI alongside it.
@MainActor
final class ReviewPromptManager {
    static let shared = ReviewPromptManager()

    /// One-time milestones tracked in UserDefaults so each only ever prompts once per install.
    /// Adding a new case = a new opportunity for review (and therefore a new userdefaults key).
    enum Milestone: String {
        /// User exported a notebook of 5+ transcripts as one combined doc — peak value moment.
        case firstNotebookCopyAll = "review.milestone.firstNotebookCopyAll"
        /// User added their first highlight/annotation — they made a transcript "theirs".
        case firstAnnotation = "review.milestone.firstAnnotation"
        /// User successfully transcribed a local file (audio/video) — discovered the app does
        /// more than scrape social.
        case firstLocalFile = "review.milestone.firstLocalFile"
        /// User saved their 5th transcript — habit forming.
        case fifthTranscript = "review.milestone.fifthTranscript"
        /// User saved their 10th transcript AND has at least one filed in a notebook —
        /// engaged power user.
        case tenthOrganizedTranscript = "review.milestone.tenthOrganizedTranscript"
    }

    /// Within a single launch of the app, only ask once. Lets the next launch surface a
    /// fresh ask if a different milestone fires — avoids prompt-stacking in one session.
    private var promptedThisSession = false

    private init() {}

    /// Records a milestone. If it hasn't fired before AND we haven't prompted this session,
    /// triggers `SKStoreReviewController` and (optionally) broadcasts a testimonial offer.
    func recordMilestone(_ milestone: Milestone, offerTestimonial: Bool = false) {
        let key = milestone.rawValue
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard !promptedThisSession else { return }

        // TestFlight bypasses paywall but should NOT bypass review prompts — testers
        // are actually a great source of TestFlight ratings (separate from App Store).
        UserDefaults.standard.set(true, forKey: key)
        promptedThisSession = true

        if let scene = activeScene() {
            // Slight delay so the user has finished whatever action just earned them this
            // moment (e.g., the "Copied" toast resolves before we steal focus).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                SKStoreReviewController.requestReview(in: scene)

                // System prompt has its own dismissal time. Wait long enough that our
                // testimonial card doesn't collide with the still-visible review overlay.
                if offerTestimonial {
                    try? await Task.sleep(for: .seconds(6))
                    NotificationCenter.default.post(name: .offerTestimonial, object: nil)
                }
            }
        }
    }

    /// Reset everything. Used by the hidden Settings → Debug section so you can re-test
    /// the prompts during development. Wrapped in `#if DEBUG` at the call site.
    func resetAllMilestones() {
        for milestone in [Milestone.firstNotebookCopyAll,
                          .firstAnnotation,
                          .firstLocalFile,
                          .fifthTranscript,
                          .tenthOrganizedTranscript] {
            UserDefaults.standard.removeObject(forKey: milestone.rawValue)
        }
        promptedThisSession = false
    }

    /// Direct deep link to the App Store's "write a review" page. Used by the always-visible
    /// "Rate ReSerch on the App Store" link in Settings — bypasses the throttle entirely so
    /// motivated users can leave reviews any time.
    static var writeReviewURL: URL {
        URL(string: "https://apps.apple.com/app/id\(AppIdentity.appStoreID)?action=write-review")!
    }

    private func activeScene() -> UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }
}

extension Notification.Name {
    /// Posted by `ReviewPromptManager` shortly after a review prompt fires so the UI can
    /// offer a soft secondary path: "Loved that? Send a quick testimonial."
    static let offerTestimonial = Notification.Name("reserch.offerTestimonial")
}

/// One-stop place for any App Store identifier the app references.
enum AppIdentity {
    /// ReSerch's App Apple ID, from App Store Connect → App Information.
    /// If this number is wrong, the "Rate ReSerch" deep link will go to a 404.
    static let appStoreID = "6762029537"
}
