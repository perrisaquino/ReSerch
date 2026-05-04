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

    var body: some View {
        VStack(spacing: 10) {
            tabView
            pageDots
        }
        .background(Color.black)
    }

    private var tabView: some View {
        TabView(selection: $currentIndex) {
            ForEach(slides) { slide in
                slideContent(for: slide)
                    .tag(slide.index)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Slide \(slide.index + 1) of \(slides.count)")
                    .accessibilityHint(slide.accessibilityHint)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Reduced motion: suppress the spring transition between pages. Apple flags this
        // as a HIGH-severity accessibility concern — vestibular triggers happen here.
        .animation(reduceMotion ? nil : .default, value: currentIndex)
    }

    /// Lazy-render gate: only the current slide and its immediate neighbors instantiate
    /// AsyncImage. Off-screen slides render the placeholder until adjacent. Keeps a
    /// 20-slide carousel from firing 20 simultaneous downloads on first appear.
    @ViewBuilder
    private func slideContent(for slide: TranscriptCarouselSlide) -> some View {
        if abs(slide.index - currentIndex) <= 1 {
            slideImage(for: slide)
        } else {
            placeholder
        }
    }

    @ViewBuilder
    private func slideImage(for slide: TranscriptCarouselSlide) -> some View {
        if let url = slide.displayURL {
            // AsyncImage handles both file:// and https:// URLs uniformly.
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    placeholder
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failure:
                    placeholder
                @unknown default:
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
        HStack(spacing: 6) {
            // N / total counter on the LEFT — matches Instagram / Photos convention.
            Text("\(currentIndex + 1) / \(slides.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
            Spacer()
            dotsRow
            Spacer()
            // Spacer balance so dots stay visually centered between counter and right edge.
            Text(" ")
                .font(.caption2)
                .opacity(0)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var dotsRow: some View {
        if slides.count <= Self.maxVisibleDots {
            HStack(spacing: 6) {
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
        HStack(spacing: 6) {
            ForEach(visibleDotIndexes, id: \.self) { idx in
                if idx < 0 {
                    // Sentinel for ellipsis
                    Text("…")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.40))
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
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                currentIndex = index
            }
        } label: {
            Circle()
                .fill(index == currentIndex ? Color.white : Color.white.opacity(0.30))
                .frame(width: 6, height: 6)
                .frame(width: 28, height: 28)         // hit area, visible dot stays 6pt
                .contentShape(Rectangle())
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
