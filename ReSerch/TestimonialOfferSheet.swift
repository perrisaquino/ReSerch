import SwiftUI

/// Soft secondary ask shown after a Tier-1 review prompt fires. Gives the user a
/// one-tap path into the existing Submit Feedback form with `.testimonial` pre-selected.
/// Designed to be skippable — no negative consequence to dismissing.
struct TestimonialOfferSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showFeedbackForm = false

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.09, blue: 0.13).ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer().frame(height: 4)

                Image(systemName: "heart.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.pink, .pink.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                VStack(spacing: 8) {
                    Text("Loved that?")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    Text("Send us how you're using ReSerch — we may quote you.")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.65))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                VStack(spacing: 8) {
                    Button {
                        showFeedbackForm = true
                    } label: {
                        Text("Send Testimonial")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.white)
                    }
                    Button("Maybe later") {
                        dismiss()
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 4)
                }
                .padding(.horizontal, 22)
                .padding(.top, 4)
            }
            .padding(.vertical, 20)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showFeedbackForm, onDismiss: { dismiss() }) {
            FeedbackFormView(initialKind: .testimonial)
        }
    }
}
