import UIKit
import Social
import UniformTypeIdentifiers

/// Share Extension entry point. Lives in a separate process from the main app, with
/// limited memory (~120MB) and no access to the app's WKWebView cookie store. Its
/// only job: pull the shared URL out of the input items, hand it off to the main
/// app via the `reserch://transcribe?url=...` custom scheme, exit immediately.
///
/// All actual transcription (extractor + WhisperKit) happens back in the host app.
/// This shape mirrors how Drafts, Bear, Apple Notes, and most "send-to-app" share
/// extensions work — and it sidesteps every memory and entitlement limit Apple
/// places on extensions.
final class ShareViewController: UIViewController {

    private let urlScheme = "reserch"
    private let transcribeHost = "transcribe"

    // We don't show our own UI. The handoff is instant — the user already saw
    // the share sheet, and the main app launching IS the visual feedback.
    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handleIncomingShare() }
    }

    // MARK: - Share handling

    @MainActor
    private func handleIncomingShare() async {
        guard let url = await firstSharedURL() else {
            // No URL among the inputs — nothing useful we can do. Just exit cleanly
            // so the user gets dropped back to where they were.
            cancelExtension()
            return
        }

        // Preferred path: write the URL to the App Group queue and exit silently.
        // The host app drains the queue when it next foregrounds. This is what
        // enables "share five posts in a row without leaving TikTok" — the user
        // never gets pulled into ReSerch mid-scroll.
        if SharedURLQueue.enqueue(url.absoluteString) {
            completeExtension()
            return
        }

        // Fallback: App Group entitlement isn't installed yet (or the suite is
        // misconfigured). Use the deeplink handoff so transcription still works
        // — the host app launches and processes this single URL via onOpenURL.
        guard let deepLink = makeDeepLink(for: url) else {
            cancelExtension()
            return
        }
        openHostApp(deepLink: deepLink)
    }

    /// Walks every input item's attachments and returns the first URL we find.
    /// Inputs can include text, plain strings, web pages, or "public.url"
    /// attachments — TikTok/IG/YouTube share intents typically attach the post URL
    /// as `public.url`, with the page title as text.
    private func firstSharedURL() async -> URL? {
        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        for item in items {
            for provider in item.attachments ?? [] {
                if let url = await loadURL(from: provider) { return url }
            }
            // Some apps (TikTok in particular) put the link in plain text instead
            // of attaching a URL provider. Scan the item's text for the first http(s) match.
            if let text = item.attributedContentText?.string,
               let extracted = firstURL(in: text) {
                return extracted
            }
        }
        return nil
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return await loadTypedItem(from: provider, type: UTType.url.identifier) as? URL
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadTypedItem(from: provider, type: UTType.plainText.identifier) as? String,
           let extracted = firstURL(in: text) {
            return extracted
        }
        return nil
    }

    private func loadTypedItem(from provider: NSItemProvider, type: String) async -> Any? {
        await withCheckedContinuation { (cont: CheckedContinuation<Any?, Never>) in
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                cont.resume(returning: value)
            }
        }
    }

    private func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let match = detector.firstMatch(in: text, options: [], range: range)
        return match?.url
    }

    // MARK: - Handoff

    private func makeDeepLink(for url: URL) -> URL? {
        var comps = URLComponents()
        comps.scheme = urlScheme
        comps.host = transcribeHost
        comps.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        return comps.url
    }

    /// `extensionContext.open(_:completionHandler:)` is the App Extension API for
    /// asking the system to launch the host app at a custom URL. The system
    /// surfaces a permission consent the first time, then remembers the choice.
    @MainActor
    private func openHostApp(deepLink: URL) {
        extensionContext?.open(deepLink) { [weak self] success in
            // Whether the open succeeded or not, we're done with this extension
            // instance. completeRequest cleans up our process and the user lands
            // back in their previous app (or the freshly-opened ReSerch).
            DispatchQueue.main.async {
                if success {
                    self?.completeExtension()
                } else {
                    self?.cancelExtension()
                }
            }
        }
    }

    private func completeExtension() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancelExtension() {
        let error = NSError(domain: "com.perrisaquino.reserch.share",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "No supported URL found in shared content."])
        extensionContext?.cancelRequest(withError: error)
    }
}
