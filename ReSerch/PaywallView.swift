import SwiftUI
import StoreKit

struct PaywallView: View {
    @State private var iap = IAPManager.shared
    @State private var gate = ExportGate.shared
    @State private var purchasing: String?
    @State private var loadAttempted = false
    @State private var loadFailed = false
    @State private var pressedCard: String?
    @State private var refreshTrigger = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let accent = Color.accentColor

    var body: some View {
        ZStack {
            backgroundLayer

            ScrollView {
                VStack(spacing: 28) {
                    Spacer().frame(height: 8)
                    heroSection
                    featureList
                    pricingCards
                    if let err = iap.purchaseError { errorBanner(err) }
                    secondaryActions
                    legalFooter
                    Spacer().frame(height: 16)
                }
                .padding(.horizontal, 22)
                .padding(.top, 60)
            }
            .scrollIndicators(.hidden)

            closeButton
        }
        .preferredColorScheme(.dark)
        .onAppear { NSLog("[PaywallView] onAppear") }
        .onDisappear { NSLog("[PaywallView] onDisappear") }
        .onChange(of: iap.isPro) { oldValue, newValue in
            NSLog("[PaywallView] isPro changed: \(oldValue) → \(newValue)")
            if !oldValue && newValue { dismiss() }
        }
        .task {
            NSLog("[PaywallView] .task started")
            guard !loadAttempted else { NSLog("[PaywallView] .task skipped (already attempted)"); return }
            loadAttempted = true
            NSLog("[PaywallView] calling loadProducts")
            await iap.loadProducts()
            NSLog("[PaywallView] loadProducts returned")
            await MainActor.run {
                if iap.products.isEmpty { loadFailed = true }
                refreshTrigger.toggle()
                NSLog("[PaywallView] post-load state set")
            }
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.08).ignoresSafeArea()
            RadialGradient(
                colors: [
                    accent.opacity(0.18),
                    Color.clear
                ],
                center: .init(x: 0.5, y: 0.0),
                startRadius: 0,
                endRadius: 380
            )
            .ignoresSafeArea()
            .blendMode(.screen)
        }
    }

    // MARK: - Close Button

    private var closeButton: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .padding(.leading, 18)
                .padding(.top, 14)
                Spacer()
            }
            Spacer()
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.15))
                    .frame(width: 84, height: 84)
                    .blur(radius: 16)
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [accent, accent.opacity(0.7)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 8) {
                Text("Unlimited transcripts.")
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .foregroundStyle(.white)
                Text("Unlimited exports.")
                    .font(.system(size: 28, weight: .bold, design: .default))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Text(headerSubtitle)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.top, 2)
        }
    }

    private var headerSubtitle: String {
        if iap.isPro { return "You're already Pro." }
        if gate.remainingFreeExports() == 0 {
            return "You've used today's \(ExportGate.freeExportsPerWindow) free exports.\nResets at midnight — or upgrade to keep going."
        }
        return "Capture every video idea, quote, and transcript without limits."
    }

    // MARK: - Feature List

    private var featureList: some View {
        VStack(alignment: .leading, spacing: 14) {
            featureRow(icon: "infinity", text: "Unlimited transcripts every day")
            featureRow(icon: "doc.on.doc", text: "Export to Markdown or Rich Text")
            featureRow(icon: "iphone", text: "On-device transcription, fully private")
            featureRow(icon: "bolt.fill", text: "Priority support and future features")
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 24, height: 24)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
            Spacer()
        }
    }

    // MARK: - Pricing Cards

    private var pricingCards: some View {
        VStack(spacing: 12) {
            #if DEBUG
            if iap.products.isEmpty {
                pricingCard(
                    id: "lifetime",
                    title: "Lifetime",
                    subtitle: "One time. Forever yours.",
                    price: "$29.99",
                    sublabel: "Pay once",
                    badge: "BEST VALUE",
                    isPrimary: true,
                    action: {
                        NSLog("[DEBUG] mock lifetime tapped — simulating purchase")
                        IAPManager.shared.debugSimulatePurchase()
                    }
                )
                pricingCard(
                    id: "monthly",
                    title: "Monthly",
                    subtitle: "Cancel anytime.",
                    price: "$4.99",
                    sublabel: "per month",
                    badge: nil,
                    isPrimary: false,
                    action: {
                        NSLog("[DEBUG] mock monthly tapped — simulating purchase")
                        IAPManager.shared.debugSimulatePurchase()
                    }
                )
            } else {
                realPricingCards
            }
            #else
            if iap.products.isEmpty {
                if loadFailed { loadFailedState } else { loadingState }
            } else {
                realPricingCards
            }
            #endif
        }
    }

    @ViewBuilder
    private var realPricingCards: some View {
        if let lifetime = iap.lifetimeProduct {
            pricingCard(
                id: lifetime.id,
                title: "Lifetime",
                subtitle: "One time. Forever yours.",
                price: lifetime.displayPrice,
                sublabel: "Pay once",
                badge: "BEST VALUE",
                isPrimary: true,
                action: { Task { await purchase(lifetime) } }
            )
        }
        if let monthly = iap.monthlyProduct {
            pricingCard(
                id: monthly.id,
                title: "Monthly",
                subtitle: "Cancel anytime.",
                price: monthly.displayPrice,
                sublabel: "per month",
                badge: nil,
                isPrimary: false,
                action: { Task { await purchase(monthly) } }
            )
        }
    }

    private var loadingState: some View {
        ProgressView()
            .padding(.vertical, 30)
            .tint(.white.opacity(0.5))
    }

    private var loadFailedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title3)
                .foregroundStyle(.orange)
            Text("Couldn't load products")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Button("Try Again") {
                loadFailed = false
                Task {
                    await iap.loadProducts()
                    if iap.products.isEmpty { loadFailed = true }
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(accent)
        }
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }

    private func purchase(_ product: Product) async {
        purchasing = product.id
        await iap.purchase(product)
        purchasing = nil
    }

    private func pricingCard(
        id: String,
        title: String,
        subtitle: String,
        price: String,
        sublabel: String,
        badge: String?,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .heavy))
                                .tracking(0.6)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(accent, in: Capsule())
                                .foregroundStyle(.black)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if purchasing == id {
                        ProgressView()
                            .tint(.white)
                            .frame(height: 22)
                    } else {
                        Text(price)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    Text(sublabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .background(cardBackground(isPrimary: isPrimary))
            .overlay(cardBorder(isPrimary: isPrimary))
            .scaleEffect(pressedCard == id ? 0.98 : 1.0)
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: pressedCard)
        }
        .buttonStyle(.plain)
        .disabled(purchasing != nil)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressedCard = id }
                .onEnded { _ in pressedCard = nil }
        )
    }

    private func cardBackground(isPrimary: Bool) -> some View {
        Group {
            if isPrimary {
                LinearGradient(
                    colors: [
                        accent.opacity(0.18),
                        Color.white.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else {
                Color.white.opacity(0.04)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func cardBorder(isPrimary: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(
                isPrimary ? accent.opacity(0.5) : Color.white.opacity(0.08),
                lineWidth: isPrimary ? 1.5 : 1
            )
    }

    // MARK: - Errors

    private func errorBanner(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(12)
        .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.red.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Secondary Actions

    private var secondaryActions: some View {
        HStack(spacing: 0) {
            Button("Restore Purchases") {
                Task { await iap.restorePurchases() }
            }
            Spacer()
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.horizontal, 4)
    }

    private var legalFooter: some View {
        VStack(spacing: 10) {
            Text("Lifetime: $29.99 one-time. Monthly: $4.99 / month, auto-renews unless cancelled at least 24 hours before the period ends. Payment is charged to your Apple ID. Manage subscriptions in App Store settings.")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.32))
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            HStack(spacing: 14) {
                Link("Terms of Use", destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                Text("·")
                    .foregroundStyle(.white.opacity(0.32))
                Link("Privacy Policy", destination: URL(string: "https://reserch-app.vercel.app/privacy")!)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
        }
        .padding(.horizontal, 8)
    }
}
