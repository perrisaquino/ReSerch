import SwiftUI

enum BrandLogo {
    case tiktok
    case instagram
    case youtube
}

/// Stylized brand-color logo tiles for platform indicators.
/// These are descriptive representations using SF Symbols on brand-colored backgrounds.
struct BrandLogoView: View {
    let brand: BrandLogo
    let size: CGFloat

    var body: some View {
        switch brand {
        case .tiktok:    tiktok
        case .instagram: instagram
        case .youtube:   youtube
        }
    }

    // MARK: - TikTok

    private var tiktok: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color.black)
            ZStack {
                // Cyan offset (right)
                Image(systemName: "music.note")
                    .foregroundStyle(Color(red: 0.04, green: 0.95, blue: 0.94))
                    .offset(x: 1.6, y: -1.4)
                // Magenta offset (left)
                Image(systemName: "music.note")
                    .foregroundStyle(Color(red: 1.0, green: 0.16, blue: 0.36))
                    .offset(x: -1.6, y: 1.4)
                // White on top
                Image(systemName: "music.note")
                    .foregroundStyle(.white)
            }
            .font(.system(size: size * 0.50, weight: .heavy))
        }
        .frame(width: size, height: size)
    }

    // MARK: - Instagram

    private var instagram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.86, blue: 0.27), // sunny yellow
                            Color(red: 0.96, green: 0.45, blue: 0.18), // orange
                            Color(red: 0.92, green: 0.18, blue: 0.45), // hot pink
                            Color(red: 0.55, green: 0.20, blue: 0.78)  // purple
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    )
                )
            // Camera silhouette
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.13)
                    .strokeBorder(Color.white, lineWidth: size * 0.06)
                    .frame(width: size * 0.55, height: size * 0.55)
                Circle()
                    .strokeBorder(Color.white, lineWidth: size * 0.06)
                    .frame(width: size * 0.26, height: size * 0.26)
                Circle()
                    .fill(Color.white)
                    .frame(width: size * 0.07, height: size * 0.07)
                    .offset(x: size * 0.18, y: -size * 0.18)
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - YouTube

    private var youtube: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(red: 1.0, green: 0.0, blue: 0.0))
            // White triangle (play button)
            Triangle()
                .fill(Color.white)
                .frame(width: size * 0.32, height: size * 0.36)
                .offset(x: size * 0.03)
        }
        .frame(width: size, height: size)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

#Preview {
    HStack(spacing: 16) {
        BrandLogoView(brand: .tiktok, size: 60)
        BrandLogoView(brand: .instagram, size: 60)
        BrandLogoView(brand: .youtube, size: 60)
    }
    .padding(40)
    .background(Color.black)
}
