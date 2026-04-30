import SwiftUI

/// Full-screen showcase that demonstrates ReSerch's privacy story.
/// Designed to also be screenshotted for App Store marketing.
struct PrivacyShowcaseView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var typedText: String = ""
    @State private var typing = false

    private let demoTranscript = "The most powerful tool for thought is one that doesn't require you to give up your privacy to use it."

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 0) {
                fakeStatusBar
                    .padding(.top, 8)

                ScrollView {
                    VStack(spacing: 32) {
                        Spacer().frame(height: 16)

                        airplaneBadge
                        headline
                        transcriptCard
                        trustGrid
                        footer

                        Spacer().frame(height: 60)
                    }
                    .padding(.horizontal, 22)
                }
                .scrollIndicators(.hidden)
            }

            closeButton
        }
        .preferredColorScheme(.dark)
        .onAppear { startTyping() }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
            RadialGradient(
                colors: [Color.accentColor.opacity(0.20), .clear],
                center: .init(x: 0.5, y: 0.0),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
            .blendMode(.screen)
        }
    }

    // MARK: - Fake status bar (simulates airplane mode for the screenshot)

    private var fakeStatusBar: some View {
        HStack {
            Text("9:41")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "airplane")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "wifi.slash")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "battery.100")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 4)
    }

    // MARK: - Close

    private var closeButton: some View {
        VStack {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .padding(.trailing, 18)
                .padding(.top, 60)
            }
            Spacer()
        }
    }

    // MARK: - Header

    private var airplaneBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "airplane")
                .font(.system(size: 13, weight: .bold))
            Text("AIRPLANE MODE · NO INTERNET")
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.8)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
        .overlay(
            Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var headline: some View {
        VStack(spacing: 10) {
            Text("Still works.")
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
            Text("Because nothing leaves your phone.")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Transcript card (simulated)

    private var transcriptCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle().fill(Color.green.opacity(0.3))
                            .frame(width: 16, height: 16)
                    )
                Text("Transcript complete")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text("4.2s")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }

            Text(typedText)
                .font(.system(size: 16, weight: .regular, design: .serif))
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(4)
                .frame(minHeight: 100, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 12) {
                deviceChip(icon: "iphone", label: "iPhone Neural Engine")
                Spacer()
                Text("0 KB sent")
                    .font(.system(size: 11, weight: .heavy).monospacedDigit())
                    .tracking(0.5)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12), in: Capsule())
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func deviceChip(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.55))
    }

    // MARK: - Trust grid

    private var trustGrid: some View {
        VStack(spacing: 10) {
            trustRow(
                icon: "lock.shield",
                title: "Your data, your phone",
                detail: "Transcripts live in the app. Nothing syncs unless you copy it."
            )
            trustRow(
                icon: "server.rack",
                title: "No servers",
                detail: "Transcription runs on your iPhone, not a cloud."
            )
            trustRow(
                icon: "person.crop.circle.badge.xmark",
                title: "No accounts",
                detail: "No signup. No email. No login. Ever."
            )
            trustRow(
                icon: "eye.slash",
                title: "No tracking",
                detail: "Zero analytics. Zero ads. Zero third parties."
            )
        }
    }

    private func trustRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineSpacing(1)
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 6) {
            Text("ReSerch")
                .font(.system(size: 14, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(.white.opacity(0.85))
            Text("Built privacy-first, by an indie developer.")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 12)
    }

    // MARK: - Typing animation

    private func startTyping() {
        guard !typing else { return }
        typing = true
        typedText = ""
        Task { @MainActor in
            for char in demoTranscript {
                typedText.append(char)
                try? await Task.sleep(for: .milliseconds(28))
            }
            typing = false
        }
    }
}

#Preview {
    PrivacyShowcaseView()
}
