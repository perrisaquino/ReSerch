import SwiftUI

/// Swipeable image carousel for the top of `TranscriptDetailView` when the underlying
/// transcript came from an Instagram carousel or TikTok photo set. Mirrors the
/// original platform's swipe-to-paginate UI so the in-app reading experience preserves
/// the visual context of the post — the slides aren't just thumbnails, they ARE the post.
///
/// Image source preference: local file first (when "Embed images in carousel notes" was
/// on at extract time), remote URL fallback. Both can be nil for slides whose download
/// failed at OCR time — those render an inline placeholder instead of breaking layout.
struct CarouselSlidesStripView: View {
    let slides: [TranscriptCarouselSlide]
    @State private var currentIndex = 0

    var body: some View {
        VStack(spacing: 10) {
            TabView(selection: $currentIndex) {
                ForEach(slides) { slide in
                    slideImage(for: slide)
                        .tag(slide.index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 320)

            pageDots
        }
        .background(Color.black)
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

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(slides) { slide in
                Circle()
                    .fill(slide.index == currentIndex ? Color.white : Color.white.opacity(0.30))
                    .frame(width: 6, height: 6)
            }
            Spacer()
            Text("\(currentIndex + 1) / \(slides.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }
}
