import SwiftUI

/// First-launch onboarding. Four slides that build confidence and demonstrate the privacy story.
/// Completion persists to UserDefaults so it only shows once.
struct OnboardingView: View {
    @Binding var isPresented: Bool
    @State private var currentSlide = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private let totalSlides = 4

    static let completedKey = "onboarding.completed"

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    private var isPad: Bool { sizeClass == .regular }
    private var contentMaxWidth: CGFloat { isPad ? 560 : .infinity }
    private var visualMaxWidth: CGFloat { isPad ? 440 : 320 }
    private var headlineSize: CGFloat { isPad ? 48 : 36 }
    private var bodySize: CGFloat { isPad ? 19 : 16 }
    private var horizontalPadding: CGFloat { isPad ? 60 : 28 }

    var body: some View {
        ZStack {
            backgroundLayer

            VStack(spacing: 0) {
                topBar

                TabView(selection: $currentSlide) {
                    slide1.tag(0)
                    slide2.tag(1)
                    slide3.tag(2)
                    slide4.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                bottomBar
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
            RadialGradient(
                colors: [Color.accentColor.opacity(0.18), .clear],
                center: .init(x: 0.5, y: 0.0),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
            .blendMode(.screen)
        }
    }

    // MARK: - Top bar (skip)

    private var topBar: some View {
        HStack {
            Spacer()
            Button("Skip") { complete() }
                .font(.system(size: isPad ? 16 : 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, horizontalPadding)
                .padding(.top, isPad ? 28 : 18)
        }
    }

    // MARK: - Bottom bar (dots + CTA)

    private var bottomBar: some View {
        VStack(spacing: isPad ? 32 : 24) {
            HStack(spacing: 6) {
                ForEach(0..<totalSlides, id: \.self) { i in
                    Capsule()
                        .fill(i == currentSlide ? Color.accentColor : Color.white.opacity(0.15))
                        .frame(width: i == currentSlide ? 24 : 8, height: 8)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: currentSlide)
                }
            }

            Button {
                if currentSlide < totalSlides - 1 {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentSlide += 1
                    }
                } else {
                    complete()
                }
            } label: {
                Text(currentSlide == totalSlides - 1 ? "Get Started" : "Continue")
                    .font(.system(size: isPad ? 18 : 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isPad ? 18 : 16)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
            }
            .frame(maxWidth: isPad ? 420 : .infinity)
            .padding(.horizontal, horizontalPadding)
        }
        .padding(.bottom, isPad ? 56 : 40)
    }

    private func complete() {
        UserDefaults.standard.set(true, forKey: Self.completedKey)
        withAnimation(.easeOut(duration: 0.3)) {
            isPresented = false
        }
    }

    // MARK: - Slide 1 — Transcribe social media

    private var slide1: some View {
        slideContainer(
            visual: socialPlatformVisual,
            kicker: "TRANSCRIBE",
            headline: "Turn content into text instantly.",
            body: "Works with TikTok, Instagram, YouTube Shorts, and Twitter. Sign in to each in Safari once for best results — ReSerch reuses those sessions privately on your device."
        )
    }

    private var socialPlatformVisual: some View {
        VStack(spacing: 10) {
            platformCard(brand: .tiktok, name: "TikTok", example: "@user · 60s clip", note: "No sign-in needed", noteIsAccent: true)
            platformCard(brand: .instagram, name: "Instagram Reels", example: "@user · 90s reel", note: "Safari sign-in", noteIsAccent: false)
            platformCard(brand: .youtube, name: "YouTube Shorts", example: "channel · short", note: "No sign-in needed", noteIsAccent: true)
        }
    }

    private func platformCard(brand: BrandLogo, name: String, example: String, note: String, noteIsAccent: Bool) -> some View {
        HStack(spacing: 14) {
            BrandLogoView(brand: brand, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(example)
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            Text(note)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(noteIsAccent ? Color.accentColor : Color.white.opacity(0.55))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(noteIsAccent ? Color.accentColor.opacity(0.15) : Color.white.opacity(0.06))
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Slide 2 — Get a clean transcript

    private var slide2: some View {
        slideContainer(
            visual: bulkVisual,
            kicker: "BULK",
            headline: "Transcribe multiple at once.",
            body: "Paste a batch, walk away. ReSerch processes everything and pings you when done."
        )
    }

    private var bulkVisual: some View {
        VStack(spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("3")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                Text("of")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                Text("5")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }

            HStack(spacing: 6) {
                Capsule().fill(Color.accentColor).frame(width: 8, height: 8)
                Capsule().fill(Color.accentColor).frame(width: 8, height: 8)
                Capsule().fill(Color.accentColor).frame(width: 24, height: 8)
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 8, height: 8)
                Capsule().fill(Color.white.opacity(0.12)).frame(width: 8, height: 8)
            }

            ProgressView(value: 0.66)
                .tint(.accentColor)
                .scaleEffect(x: 1, y: 1.3)

            HStack(spacing: 6) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 11, weight: .semibold))
                Text("Background the app — we'll ping you")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(20)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Slide 3 — Annotations

    private var slide3: some View {
        slideContainer(
            visual: annotateVisual,
            kicker: "ANNOTATE",
            headline: "Highlight what matters.",
            body: "Mark key passages and add inline notes. Build a quotable library from every video."
        )
    }

    private var annotateVisual: some View {
        VStack(alignment: .leading, spacing: 14) {
            (Text("The most important idea I've learned is ")
                .font(.system(size: 14, weight: .regular, design: .serif))
                .foregroundStyle(.white.opacity(0.85))
             + Text("you don't need permission to start")
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(.white)
                .underline(true, color: Color.accentColor)
             + Text(" something. Just start.")
                .font(.system(size: 14, weight: .regular, design: .serif))
                .foregroundStyle(.white.opacity(0.85))
            )
            .lineSpacing(4)

            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor)
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "note.text")
                            .font(.system(size: 10, weight: .semibold))
                        Text("YOUR NOTE")
                            .font(.system(size: 9, weight: .heavy))
                            .tracking(0.8)
                    }
                    .foregroundStyle(Color.accentColor)

                    Text("Anchor quote for the launch essay.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Slide 4 — Private by design

    private var slide4: some View {
        slideContainer(
            visual: privacyVisual,
            kicker: "PRIVACY",
            headline: "Built to stay yours.",
            body: "Works in airplane mode. No accounts. No tracking. No data leaves your phone."
        )
    }

    private var privacyVisual: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "airplane")
                    .font(.system(size: 12, weight: .bold))
                Text("AIRPLANE MODE · NO INTERNET")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.7)
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .overlay(
                Capsule().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )

            VStack(spacing: 8) {
                trustPill(icon: "server.rack", text: "No servers")
                trustPill(icon: "person.crop.circle.badge.xmark", text: "No accounts")
                trustPill(icon: "eye.slash", text: "No tracking")
            }

            HStack(spacing: 8) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("0 KB SENT")
                    .font(.system(size: 11, weight: .heavy).monospacedDigit())
                    .tracking(0.5)
                    .foregroundStyle(Color.green)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.12), in: Capsule())
        }
    }

    private func trustPill(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Slide container

    private func slideContainer<V: View>(
        visual: V,
        kicker: String,
        headline: String,
        body: String
    ) -> some View {
        // Vertically + horizontally centered content with a max-width cap.
        // Spacers above and below the content stack center it in the available height.
        VStack(spacing: 0) {
            Spacer(minLength: isPad ? 32 : 16)

            VStack(spacing: isPad ? 56 : 40) {
                // Copy block — left-aligned text block
                VStack(alignment: .leading, spacing: isPad ? 18 : 14) {
                    Text(kicker)
                        .font(.system(size: isPad ? 13 : 12, weight: .heavy))
                        .tracking(1.6)
                        .foregroundStyle(Color.accentColor)

                    Text(headline)
                        .font(.system(size: headlineSize, weight: .bold))
                        .foregroundStyle(.white)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(body)
                        .font(.system(size: bodySize, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Visual block
                visual
                    .frame(maxWidth: visualMaxWidth)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: contentMaxWidth)
            .padding(.horizontal, horizontalPadding)

            Spacer(minLength: isPad ? 32 : 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Cursor

    private var cursor: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 2, height: 16)
            .opacity(0.8)
            .modifier(BlinkingModifier())
    }
}

private struct BlinkingModifier: ViewModifier {
    @State private var visible = true
    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: visible)
            .onAppear { visible = false }
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
}
