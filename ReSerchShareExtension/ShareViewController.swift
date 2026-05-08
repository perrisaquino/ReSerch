import UIKit
import SwiftUI
import Social
import UniformTypeIdentifiers

// MARK: - Confirmation UI

enum ShareState {
    case pending
    case queued
    case deeplink
    case failed(String)
}

final class ShareStateModel: ObservableObject {
    @Published var state: ShareState = .pending
}

private struct ShareConfirmationView: View {
    @ObservedObject var model: ShareStateModel

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.09, blue: 0.13)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                icon
                    .foregroundStyle(iconColor)

                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.92))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(red: 0.12, green: 0.14, blue: 0.19))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(40)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch model.state {
        case .pending:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white.opacity(0.6))
                .font(.system(size: 32))
        case .queued:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
        case .deeplink:
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 32))
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 32))
        }
    }

    private var iconColor: Color {
        switch model.state {
        case .pending:  return .white.opacity(0.5)
        case .queued:   return Color(red: 0.2, green: 0.85, blue: 0.55)
        case .deeplink: return Color(red: 0.4, green: 0.7, blue: 1.0)
        case .failed:   return Color(red: 1.0, green: 0.4, blue: 0.4)
        }
    }

    private var message: String {
        switch model.state {
        case .pending:          return "Saving to ReSerch\u{2026}"
        case .queued:           return "Added to ReSerch"
        case .deeplink:         return "Opening ReSerch\u{2026}"
        case .failed(let msg):  return msg
        }
    }
}

// MARK: - Share Extension entry point

/// Share Extension entry point. Pulls the shared URL from the input items,
/// writes it to the App Group queue (preferred path — lets users "share and
/// forget" without the app opening), or falls back to a deeplink launch.
/// Shows a brief confirmation card so users know the share was received.
final class ShareViewController: UIViewController {

    private let urlScheme = "reserch"
    private let transcribeHost = "transcribe"

    private let stateModel = ShareStateModel()
    private var shareTask: Task<Void, Never>?

    // MARK: - Lifecycle

    override func loadView() {
        view = UIView()
        view.backgroundColor = .clear

        let hosting = UIHostingController(rootView: ShareConfirmationView(model: stateModel))
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hosting)
        view.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hosting.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        shareTask = Task { await handleIncomingShare() }
    }

    deinit {
        shareTask?.cancel()
    }

    // MARK: - Share handling

    @MainActor
    private func handleIncomingShare() async {
        guard let url = await firstSharedURL() else {
            NSLog("[ReSerch Share] URL extraction failed — no supported URL in shared content")
            stateModel.state = .failed("Couldn\u{2019}t find a link in this content.")
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            cancelExtension()
            return
        }

        NSLog("[ReSerch Share] Extracted URL: %@", url.absoluteString)

        // Preferred: write to App Group queue, exit silently.
        if SharedURLQueue.enqueue(url.absoluteString) {
            NSLog("[ReSerch Share] Enqueued via App Group — will transcribe on next ReSerch foreground")
            stateModel.state = .queued
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            completeExtension()
            return
        }

        // App Group unavailable — fall back to deeplink (forces app to foreground).
        NSLog("[ReSerch Share] App Group unavailable — falling back to deeplink")

        guard let deepLink = makeDeepLink(for: url) else {
            NSLog("[ReSerch Share] Failed to construct deeplink")
            stateModel.state = .failed("Couldn\u{2019}t open ReSerch. Please try again.")
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            cancelExtension()
            return
        }

        stateModel.state = .deeplink
        openHostApp(deepLink: deepLink)
    }

    // MARK: - URL extraction

    private func firstSharedURL() async -> URL? {
        let items = (extensionContext?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        for item in items {
            for provider in item.attachments ?? [] {
                if let url = await loadURL(from: provider) { return url }
            }
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

    @MainActor
    private func openHostApp(deepLink: URL) {
        extensionContext?.open(deepLink) { [weak self] success in
            DispatchQueue.main.async {
                NSLog("[ReSerch Share] extensionContext.open result: %@", success ? "success" : "failed")
                if success {
                    self?.completeExtension()
                } else {
                    self?.stateModel.state = .failed("Couldn\u{2019}t open ReSerch. Please launch it manually.")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                        self?.cancelExtension()
                    }
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
