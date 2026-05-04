import SwiftUI

/// Swipeable image carousel for the top of `TranscriptDetailView` when the underlying
/// transcript came from an Instagram carousel or TikTok photo set. Mirrors the
/// original platform's swipe-to-paginate UI so the in-app reading experience preserves
/// the visual context of the post — the slides aren't just thumbnails, they ARE the post.
///
/// Image source preference: local file first (when "Embed images in carousel notes" was
/// on at extract time), remote URL fallback. Both can be nil for slides whose download
/// failed at OCR time — those render an inline placeholder instead of breaking layout.
///
/// Sized by the caller via `height` binding so the same `videoHeight` state that drives
/// `YouTubePlayerView` / `TikTokPlayerView` resizing also drives this strip — the user
/// gets one consistent drag gesture across all media types.
struct CarouselSlidesStripView: View {
    let slides: [TranscriptCarouselSlide]
    @State private var currentIndex = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Cap visible page dots so a 20-image carousel doesn't bleed off-screen.
    /// When more than this, we render leading + trailing dots and an ellipsis.
    private static let maxVisibleDots = 10

    /// Instagram's canonical portrait carousel ratio is 4:5 (1080×1350). Locking the
    /// strip to this aspect keeps the TabView's container height constant across
    /// slides. Without it, slides with different intrinsic ratios reflow the TabView
    /// height during a swipe — that vertical layout-shift mid-drag is the visible
    /// "glitch" / "doesn't land cleanly" symptom users see, even though the page-snap
    /// physics themselves are correct.
    private static let stripAspectRatio: CGFloat = 4.0 / 5.0

    var body: some View {
        VStack(spacing: 6) {
            tabView
            pageDots
        }
        .background(Color.black)
    }

    private var tabView: some View {
        TabView(selection: $currentIndex) {
            ForEach(slides) { slide in
                slideImage(for: slide)
                    .tag(slide.index)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Slide \(slide.index + 1) of \(slides.count)")
                    .accessibilityHint(slide.accessibilityHint)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Fixed aspect ratio on the TabView itself — every page now occupies an
        // identical height, so swiping between slides of different intrinsic
        // dimensions doesn't trigger a vertical reflow mid-drag.
        .aspectRatio(Self.stripAspectRatio, contentMode: .fit)
        // No external `.animation(value: currentIndex)` — TabView(.page) has its own
        // spring physics on the swipe gesture. Adding one here re-animates the value
        // the gesture just settled, causing mid-drag stutter. The aspect-ratio lock
        // above is the OTHER half of the fix; both are required.
    }

    @ViewBuilder
    private func slideImage(for slide: TranscriptCarouselSlide) -> some View {
        if let url = slide.displayURL {
            CachedAsyncImage(url: url) { image in
                if let image {
                    // .scaledToFill + .clipped: the parent TabView is locked to a
                    // 4:5 aspect ratio, so each image fills that box and any portion
                    // of the natural aspect that doesn't match gets clipped. This is
                    // visually closer to Instagram's behavior and — critically — it
                    // means the image always paints from edge to edge with no
                    // letterboxing that could read as "image is loading still".
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(white: 0.10)
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.35))
                Text("Image unavailable")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Page dots

    private var pageDots: some View {
        // Instagram-style: tight, centered dots, no counter, no flanking elements.
        // The whole row hugs the bottom of the image so the indicator reads as
        // "attached to" the carousel, not floating in its own band.
        dotsRow
            .frame(maxWidth: .infinity)
            .padding(.bottom, 8)
    }

    @ViewBuilder
    private var dotsRow: some View {
        if slides.count <= Self.maxVisibleDots {
            HStack(spacing: 2) {
                ForEach(slides) { slide in
                    dotButton(for: slide.index)
                }
            }
        } else {
            // Leading dots, ellipsis, trailing dots — keeps total visible at ~maxVisibleDots
            // and always shows the current page's dot in context.
            collapsedDotsRow
        }
    }

    /// Shows the first 3 dots, an ellipsis, the current dot ± 1, an ellipsis, and the
    /// last 3 dots. Order is rebuilt around `currentIndex` so the active dot is always
    /// visible regardless of carousel length.
    private var collapsedDotsRow: some View {
        HStack(spacing: 2) {
            ForEach(visibleDotIndexes, id: \.self) { idx in
                if idx < 0 {
                    // Sentinel for ellipsis — sized to match dots so spacing stays uniform
                    Circle()
                        .fill(Color.white.opacity(0.30))
                        .frame(width: 3, height: 3)
                        .frame(width: 8, height: 24)
                } else {
                    dotButton(for: idx)
                }
            }
        }
    }

    private var visibleDotIndexes: [Int] {
        let n = slides.count
        let leading = [0, 1, 2]
        let trailing = [n - 3, n - 2, n - 1]
        let around = [currentIndex - 1, currentIndex, currentIndex + 1].filter { 0 <= $0 && $0 < n }
        let unique = Array(Set(leading + around + trailing)).sorted()
        // Insert -1 sentinels wherever there's a gap > 1.
        var withGaps: [Int] = []
        for (i, idx) in unique.enumerated() {
            if i > 0 && idx - unique[i - 1] > 1 {
                withGaps.append(-1)
            }
            withGaps.append(idx)
        }
        return withGaps
    }

    /// Dot is wrapped in a 44×44pt invisible hit area so a tap anywhere near it jumps
    /// to that slide. The visible dot stays 6×6pt — only the touch target grows.
    private func dotButton(for index: Int) -> some View {
        let isActive = index == currentIndex
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                currentIndex = index
            }
        } label: {
            Circle()
                .fill(isActive ? Color.white : Color.white.opacity(0.35))
                .frame(width: 6, height: 6)
                // 10pt-wide hit cell — visually Instagram-tight (only ~2pt padding on
                // each side of the dot). Sub-44pt is technically below Apple's
                // accessibility minimum but matches every social media app's
                // page-indicator style; the row of dots is ALSO tappable as one big
                // target via the swipe gesture, so functional reach isn't degraded.
                .frame(width: 10, height: 24)
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isActive)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Go to slide \(index + 1)")
    }
}

private extension TranscriptCarouselSlide {
    /// Brief preview of recognized text for VoiceOver hint. Capped to ~100 chars so
    /// the hint stays scannable.
    var accessibilityHint: String {
        guard let text = recognizedText, !text.isEmpty else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 100 { return trimmed }
        return String(trimmed.prefix(100)) + "…"
    }
}
