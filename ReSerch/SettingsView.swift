import SwiftUI
import UIKit
import StoreKit
import MessageUI

struct SettingsView: View {
    @State private var prefs = MarkdownStylePrefs.shared
    @State private var iap = IAPManager.shared
    @State private var gate = ExportGate.shared
    @State private var showRedeem = false
    @State private var showFeedback = false
    @State private var versionTapCount = 0
    @State private var debugUnlocked = false
    @AppStorage("embedCarouselImages") private var embedCarouselImages: Bool = true
    @Environment(\.dismiss) private var dismiss

    private static let debugUnlockTaps = 7

    var body: some View {
        NavigationStack {
            List {
                accountSection

                Section("Formatting Colors") {
                    ColorPicker("Bold", selection: colorBinding(
                        get: { prefs.boldColor },
                        set: { prefs.boldColor = $0 }
                    ))
                    ColorPicker("Highlight", selection: colorBinding(
                        get: { prefs.highlightColor },
                        set: { prefs.highlightColor = $0 }
                    ))
                    ColorPicker("Wikilink", selection: colorBinding(
                        get: { prefs.wikilinkColor },
                        set: { prefs.wikilinkColor = $0 }
                    ))
                }

                Section {
                    Toggle("Save Video to Camera Roll", isOn: Binding(
                        get: { prefs.saveVideoToCameraRoll },
                        set: { prefs.saveVideoToCameraRoll = $0; prefs.save() }
                    ))
                } header: {
                    Text("Video")
                } footer: {
                    Text("When transcribing TikTok or Instagram, saves the video to your Photos library.")
                }

                Section("Carousels") {
                    Toggle("Embed images in carousel notes", isOn: $embedCarouselImages)
                }

                feedbackSection

                Section {
                    Button("Reset to Defaults", role: .destructive) {
                        prefs.resetToDefaults()
                    }
                }

                #if DEBUG
                if debugUnlocked {
                    debugSection
                }
                #endif

                versionFooterSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.accentColor)
                }
            }
            .preferredColorScheme(.dark)
            .offerCodeRedemption(isPresented: $showRedeem) { result in
                if case .success = result {
                    Task { await iap.refreshEntitlements() }
                }
            }
            .sheet(isPresented: $showFeedback) {
                FeedbackFormView()
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account") {
            if iap.isPro {
                HStack {
                    Label("Pro Active", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                }
            } else {
                Button {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        PaywallPresenter.present()
                    }
                } label: {
                    Label("Upgrade to Pro", systemImage: "sparkles")
                        .foregroundStyle(Color.accentColor)
                }
            }
            Button("Restore Purchases") {
                Task { await iap.restorePurchases() }
            }
            Button("Redeem Code") {
                showRedeem = true
            }
        }
    }

    @ViewBuilder
    private var feedbackSection: some View {
        Section {
            Button {
                showFeedback = true
            } label: {
                Label("Submit Feedback", systemImage: "envelope")
                    .foregroundStyle(Color.accentColor)
            }
        } header: {
            Text("Feedback")
        } footer: {
            Text("Report a bug, request a feature, or send a testimonial. Attach a screenshot if it helps.")
        }
    }

    @ViewBuilder
    private var versionFooterSection: some View {
        Section {
            Button {
                versionTapCount += 1
                if versionTapCount >= Self.debugUnlockTaps {
                    debugUnlocked = true
                }
            } label: {
                HStack {
                    Spacer()
                    Text(Self.versionString)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .buttonStyle(.plain)
        }
        .listRowBackground(Color.clear)
    }

    #if DEBUG
    @ViewBuilder
    private var debugSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { gate.testInDebug },
                set: { gate.testInDebug = $0 }
            )) {
                Label("Test paywall gate", systemImage: "lock.shield")
            }
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    PaywallPresenter.present()
                }
            } label: {
                Label("Show Paywall Now", systemImage: "creditcard.fill")
            }
            Button(role: .destructive) {
                iap.debugRevertPurchase()
            } label: {
                Label("Revert to Free (debug)", systemImage: "arrow.uturn.backward")
            }
            Button {
                gate.debugFillToLimit()
            } label: {
                Label("Fill Gate (\(ExportGate.freeExportsPerWindow)/\(ExportGate.freeExportsPerWindow))", systemImage: "gauge.medium")
            }
            Button(role: .destructive) {
                gate.debugReset()
            } label: {
                Label("Reset Gate Counter", systemImage: "arrow.counterclockwise")
            }
        } header: {
            Text("Debug")
        } footer: {
            Text("Hidden by default. Tap the version label \(Self.debugUnlockTaps) times to reveal.")
        }
    }
    #endif

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "ReSerch \(version) (\(build))"
    }

    private func colorBinding(
        get: @escaping () -> UIColor,
        set: @escaping (UIColor) -> Void
    ) -> Binding<Color> {
        Binding(
            get: { get().swiftUIColor },
            set: { set(UIColor($0)); prefs.save() }
        )
    }
}

// MARK: - Feedback Form

private enum FeedbackKind: String, CaseIterable, Identifiable {
    case bug = "Bug"
    case feature = "Feature Request"
    case testimonial = "Testimonial"
    case general = "General"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .bug: return "ladybug.fill"
        case .feature: return "lightbulb.fill"
        case .testimonial: return "heart.fill"
        case .general: return "bubble.left.fill"
        }
    }

    var tint: Color {
        switch self {
        case .bug: return .red
        case .feature: return .yellow
        case .testimonial: return .pink
        case .general: return .blue
        }
    }

    var prompt: String {
        switch self {
        case .bug: return "What happened? What did you expect? Steps to reproduce if possible."
        case .feature: return "What would you like to see? How would you use it?"
        case .testimonial: return "Tell us how ReSerch is helping you. Quotes may be used in marketing with permission."
        case .general: return "What's on your mind?"
        }
    }
}

private enum SubmitState: Equatable {
    case idle
    case sending
    case success
    case failed(String)
}

private struct FeedbackFormView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var kind: FeedbackKind = .bug
    @State private var message: String = ""
    @State private var attachment: UIImage?
    @State private var showImagePicker = false
    @State private var showMailComposer = false
    @State private var submitState: SubmitState = .idle

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(FeedbackKind.allCases) { k in
                            Label(k.rawValue, systemImage: k.icon)
                                .tag(k)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Type of Feedback")
                }

                Section {
                    ZStack(alignment: .topLeading) {
                        if message.isEmpty {
                            Text(kind.prompt)
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $message)
                            .frame(minHeight: 140)
                            .scrollContentBackground(.hidden)
                    }
                } header: {
                    Text("Your Message")
                }

                Section {
                    if let attachment {
                        HStack(spacing: 12) {
                            Image(uiImage: attachment)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 48, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Screenshot attached")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(role: .destructive) {
                                self.attachment = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Button {
                            showImagePicker = true
                        } label: {
                            Label("Add Screenshot", systemImage: "photo.on.rectangle")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                } header: {
                    Text("Attachment (Optional)")
                }

                if case .failed(let msg) = submitState {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(msg)
                                .font(.footnote)
                        }
                    }
                }
            }
            .navigationTitle("Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(submitState == .sending)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if submitState == .sending {
                            ProgressView()
                        } else {
                            Text("Send").fontWeight(.semibold)
                        }
                    }
                    .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || submitState == .sending)
                }
            }
            .preferredColorScheme(.dark)
            .sheet(isPresented: $showImagePicker) {
                FeedbackImagePicker(image: $attachment)
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showMailComposer) {
                MailComposerView(
                    kind: kind,
                    message: message,
                    attachment: attachment,
                    onResult: handleMailResult
                )
                .ignoresSafeArea()
            }
            .overlay(alignment: .center) {
                if submitState == .success {
                    successOverlay
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: submitState)
        }
    }

    private var successOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.green)
            Text("Thanks!")
                .font(.title2.weight(.bold))
            Text("Your feedback was sent.")
                .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }

    private func submit() async {
        guard MFMailComposeViewController.canSendMail() else {
            submitState = .failed("Mail isn't set up on this device. Add a Mail account in Settings, or email reserchapp@gmail.com from any email app.")
            return
        }
        submitState = .idle
        showMailComposer = true
    }

    private func handleMailResult(_ result: MFMailComposeResult) {
        switch result {
        case .sent:
            submitState = .success
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                dismiss()
            }
        case .cancelled, .saved:
            // User backed out of Mail — leave the form as-is so they can edit and try again.
            break
        case .failed:
            submitState = .failed("Couldn't open Mail. Try again, or email reserchapp@gmail.com.")
        @unknown default:
            break
        }
    }
}

// MARK: - Image Picker

private struct FeedbackImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: FeedbackImagePicker
        init(_ parent: FeedbackImagePicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

// MARK: - Mail Composer

private struct MailComposerView: UIViewControllerRepresentable {
    let kind: FeedbackKind
    let message: String
    let attachment: UIImage?
    let onResult: (MFMailComposeResult) -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(["reserchapp@gmail.com"])
        vc.setSubject(Self.subject(kind: kind, message: message))
        vc.setMessageBody(Self.body(kind: kind, message: message), isHTML: false)

        if let img = attachment, let jpeg = img.jpegData(compressionQuality: 0.7) {
            vc.addAttachmentData(jpeg, mimeType: "image/jpeg", fileName: "screenshot.jpg")
        }
        return vc
    }

    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult) }

    private static func subject(kind: FeedbackKind, message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.prefix(60)
        let suffix = trimmed.count > 60 ? "..." : ""
        return "[ReSerch \(kind.rawValue)] \(preview)\(suffix)"
    }

    private static func body(kind: FeedbackKind, message: String) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return """
        Type: \(kind.rawValue)

        \(message)

        ---
        App: ReSerch \(version) (\(build))
        Device: \(UIDevice.current.model)
        OS: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        """
    }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onResult: (MFMailComposeResult) -> Void
        init(onResult: @escaping (MFMailComposeResult) -> Void) { self.onResult = onResult }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true) { [self] in
                onResult(result)
            }
        }
    }
}
