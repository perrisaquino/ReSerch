import SwiftUI
import UIKit
import StoreKit
import MessageUI
import Combine

struct SettingsView: View {
    @State private var prefs = MarkdownStylePrefs.shared
    @State private var iap = IAPManager.shared
    @State private var gate = ExportGate.shared
    @State private var showRedeem = false
    @State private var showFeedback = false
    @State private var versionTapCount = 0
    @State private var debugUnlocked = false
    @AppStorage("embedCarouselImages") private var embedCarouselImages: Bool = true
    @AppStorage("iCloudSyncEnabled") private var iCloudSyncEnabled: Bool = true
    @State private var exportShareItem: URL?
    @State private var exportInProgress = false
    @State private var exportError: String?
    @State private var redeemError: String?
    @State private var showBackupInfo = false
    @Environment(\.dismiss) private var dismiss

    private static let debugUnlockTaps = 7

    var body: some View {
        NavigationStack {
            List {
                accountSection
                exportSection
                highlightColorsSection
                backupSection
                privacySection
                feedbackSection
                resetSection

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
                switch result {
                case .success:
                    Task {
                        // Sync first to guarantee Apple's servers flush the new
                        // transaction into the local receipt before we check entitlements.
                        try? await AppStore.sync()
                        await iap.refreshEntitlements()
                    }
                case .failure(let error):
                    redeemError = error.localizedDescription
                }
            }
            .alert("Code Redemption Failed", isPresented: Binding(
                get: { redeemError != nil },
                set: { if !$0 { redeemError = nil } }
            )) {
                Button("OK", role: .cancel) { redeemError = nil }
            } message: {
                if let msg = redeemError { Text(msg) }
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
            } else if !ExportGate.freeForEveryone {
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

    /// All preferences that affect what shows up in the exported transcript:
    /// default format, carousel image embedding, and video saving.
    @ViewBuilder
    private var exportSection: some View {
        Section("Export") {
            Picker("Default Format", selection: Binding(
                get: { prefs.richTextMode ? 1 : 0 },
                set: { newValue in
                    prefs.richTextMode = (newValue == 1)
                    prefs.save()
                }
            )) {
                Text("Markdown").tag(0)
                Text("Rich Text").tag(1)
            }
            Toggle("Embed images in carousel notes", isOn: $embedCarouselImages)
            Toggle("Save video to Photos", isOn: Binding(
                get: { prefs.saveVideoToCameraRoll },
                set: { prefs.saveVideoToCameraRoll = $0; prefs.save() }
            ))
            NavigationLink("Export Template") {
                TemplateSettingsView()
            }
        }
    }

    @ViewBuilder
    private var highlightColorsSection: some View {
        Section("Highlight Colors") {
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
    }

    /// Combined Sync + Export section. Both speak to the same underlying concern
    /// (your data living in more than one place) and live better as a single
    /// section than as two adjacent ones. Status text sits inside the iCloud
    /// Sync row's label rather than as a standalone caption row, so the toggle
    /// reads as one cohesive control instead of split across two list rows.
    @ViewBuilder
    private var backupSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { iCloudSyncEnabled },
                set: { newValue in
                    iCloudSyncEnabled = newValue
                    iCloudSyncService.shared.objectWillChange.send()
                    if newValue {
                        Task { await iCloudSyncService.shared.migrateLocalToCloudIfNeeded() }
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("iCloud Sync")
                    Text(syncStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                Task { await runExport() }
            } label: {
                if exportInProgress {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Preparing export…")
                    }
                } else {
                    Label("Export All Data", systemImage: "square.and.arrow.up")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .disabled(exportInProgress)
            if let exportError {
                Text(exportError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("Backup")
                Spacer()
                Button {
                    showBackupInfo = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("About iCloud Sync and Export")
            }
        }
        .alert("Backup", isPresented: $showBackupInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("iCloud Sync backs up your transcripts and notebooks to your iCloud account and keeps them in sync across all your devices signed in to the same Apple ID. Everything survives uninstalling and reinstalling.\n\nExport saves a ZIP of every transcript, notebook, and carousel image so you can keep your own copy anywhere.")
        }
    }

    /// Destructive actions live alone at the bottom (above the version footer)
    /// so they don't visually compete with everyday preferences. Renamed from
    /// the ambiguous "Reset to Defaults" so the user knows this only affects
    /// the highlight color pickers, not the whole app.
    @ViewBuilder
    private var resetSection: some View {
        Section {
            Button("Reset Highlight Colors", role: .destructive) {
                prefs.resetToDefaults()
            }
        }
    }

    private var syncStatusText: String {
        switch iCloudSyncService.shared.status {
        case .ready:
            if let last = iCloudSyncService.shared.lastSyncedAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .abbreviated
                return "Synced \(formatter.localizedString(for: last, relativeTo: Date()))"
            }
            return "Connected to iCloud."
        case .migrating:
            return "Moving your data to iCloud…"
        case .localOnly:
            return "Sync is off — data lives only on this device."
        case .unavailable:
            return "iCloud unavailable. Sign in to iCloud in iPhone Settings to enable sync."
        }
    }

    @MainActor
    private func runExport() async {
        exportInProgress = true
        exportError = nil
        defer { exportInProgress = false }
        do {
            // History/notebooks reach us via the active app instance; pull them off
            // the current TranscriptViewModel via the environment-injected reference.
            // To keep this section self-contained we read the JSON files directly
            // from the sync service so the export works even before the view model
            // has been wired up. Falls back to empty arrays if either file is absent.
            let history = (try? Self.loadHistory()) ?? []
            let notebooks = (try? Self.loadNotebooks()) ?? []
            let url = try DataExportService.makeArchive(history: history, notebooks: notebooks)
            presentShareSheet(for: url)
        } catch {
            exportError = "Could not build export. \(error.localizedDescription)"
        }
    }

    private static func loadHistory() throws -> [TranscriptEntry] {
        let url = iCloudSyncService.shared.activeURL(for: .history)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TranscriptEntry].self, from: data)
    }

    private static func loadNotebooks() throws -> [Notebook] {
        let url = iCloudSyncService.shared.activeURL(for: .notebooks)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Notebook].self, from: data)
    }

    private func presentShareSheet(for url: URL) {
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = av.popoverPresentationController,
           let window = UIApplication.shared.keyForegroundWindow {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        guard let root = UIApplication.shared.keyForegroundWindow?.rootViewController else { return }
        root.topmostPresentedViewController.present(av, animated: true)
    }

    @ViewBuilder
    private var privacySection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { !Analytics.shared.isOptedOut },
                set: { newValue in
                    Analytics.shared.isOptedOut = !newValue
                }
            )) {
                Label("Share anonymous usage", systemImage: "chart.bar.fill")
            }
        } header: {
            Text("Privacy")
        } footer: {
            Text("Helps me see which features actually get used so I can make ReSerch better. No name, no email, no transcript content — just anonymous taps and screens. Turn it off anytime.")
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
            Link(destination: ReviewPromptManager.writeReviewURL) {
                Label("Rate ReSerch on the App Store", systemImage: "star")
                    .foregroundStyle(Color.accentColor)
            }
        } header: {
            Text("Feedback")
        } footer: {
            Text("Report a bug, request a feature, or send a testimonial. Or leave a quick App Store review — it really helps.")
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

enum FeedbackKind: String, CaseIterable, Identifiable {
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

struct FeedbackFormView: View {
    /// Lets external callers (review-prompt testimonial flow) pre-select a category.
    /// Default `.bug` preserves the existing entry-from-Settings behavior.
    var initialKind: FeedbackKind = .bug

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
            .onAppear {
                // Apply the externally-supplied initial kind once on first render.
                // Don't overwrite if the user has already changed it in this session.
                if kind == .bug && initialKind != .bug {
                    kind = initialKind
                }
            }
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
