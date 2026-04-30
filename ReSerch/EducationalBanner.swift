import SwiftUI

/// Reusable contextual banner for pre-flight prompts, transcription errors, tips, and
/// success states. Replaces the static inline `errorBanner` in `AddTranscriptView`.
///
/// Every error or empty state in the app should provide at least a primary recovery
/// action. Use `.info` for tips, `.warning` for reversible issues, `.error` for failures,
/// `.success` for confirmations.
struct EducationalBanner: View {
    enum Tone {
        case info, warning, error, success

        var color: Color {
            switch self {
            case .info: return Color.accentColor
            case .warning: return .orange
            case .error: return Color(red: 0.95, green: 0.40, blue: 0.45)
            case .success: return Color(red: 0.30, green: 0.85, blue: 0.55)
            }
        }
    }

    struct Action {
        let label: String
        let run: () -> Void
    }

    let tone: Tone
    let icon: String
    let title: String
    let message: String
    var primary: Action? = nil
    var secondary: Action? = nil
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(tone.color.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tone.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(message)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
            }

            if primary != nil || secondary != nil {
                HStack(spacing: 8) {
                    if let primary {
                        Button(action: primary.run) {
                            Text(primary.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(tone.color, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if let secondary {
                        Button(action: secondary.run) {
                            Text(secondary.label)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.08), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 44) // align under the title text, not the icon
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tone.color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tone.color.opacity(0.28), lineWidth: 1)
        )
    }
}
