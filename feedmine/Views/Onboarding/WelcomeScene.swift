import SwiftUI

/// Opening screen — deep navy brand opening with cascading real feed cards
/// behind light glass. "The open web, arranged by you."
struct WelcomeScene: View {
    let accent: Color
    let onShape: () -> Void
    let onStartBroad: () -> Void

    @Environment(FeedLoader.self) private var loader
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var appeared = false

    private let deepNavy = Color(hex: "#050A18")

    var body: some View {
        ZStack {
            deepNavy.ignoresSafeArea()

            // Cascading real feed cards
            cardCascade

            // Foreground content
            VStack(spacing: 0) {
                Spacer()

                // Wordmark — use existing Wawasoft "W" logo + amber-coral gradient
                // If the real wordmark is a view/component, replace this placeholder:
                Text(String(localized: "FeedMine"))
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .opacity(appeared ? 1 : 0)

                // Amber rule
                Rectangle()
                    .fill(accent)
                    .frame(width: 40, height: 1)
                    .padding(.top, 12)
                    .opacity(appeared ? 1 : 0)

                // Headline
                Text(headline)
                    .font(.largeTitle.weight(.bold))
                    .fontDesign(.serif)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 20)

                // Body
                Text(String(localized: "FeedMine brings together independent publications, podcasts, video channels and public sources. Set the mix yourself — or start broad and explore."))
                    .font(.body)
                    .foregroundStyle(Color(hex: "#8899AA"))
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 16)

                // Trust signals
                HStack(spacing: 12) {
                    trustBadge(String(localized: "On-device"))
                    Circle().fill(Color(hex: "#8899AA")).frame(width: 2, height: 2)
                    trustBadge(String(localized: "No account"))
                    Circle().fill(Color(hex: "#8899AA")).frame(width: 2, height: 2)
                    trustBadge(String(localized: "Fully editable"))
                }
                .font(.caption)
                .foregroundStyle(Color(hex: "#8899AA"))
                .padding(.top, 20)
                .opacity(appeared ? 1 : 0)

                Spacer()

                // CTAs
                VStack(spacing: 14) {
                    Button(action: onShape) {
                        Text(String(localized: "Shape my feed"))
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 16))
                    .tint(accent)
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                    .accessibilityIdentifier("welcome-shape")

                    Button(String(localized: "Start broad")) {
                        onStartBroad()
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color(hex: "#8899AA"))
                    .frame(minHeight: 44)
                    .opacity(appeared ? 1 : 0)
                    .accessibilityIdentifier("welcome-broad")
                }
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            if reduceMotion {
                appeared = true  // instant, no animation
            } else {
                withAnimation(.easeOut(duration: 0.6)) { appeared = true }
            }
        }
    }

    private var headline: AttributedString {
        var text = AttributedString(String(localized: "The open web,\narranged by you."))
        if let range = text.range(of: "you") {
            text[range].foregroundColor = UIColor(accent)
        }
        return text
    }

    /// Real feed cards behind light glass
    private var cardCascade: some View {
        let sampleItems = Array(loader.items.prefix(6))
        return ZStack {
            if sampleItems.isEmpty {
                // Fallback: abstract cards
                ForEach(0..<6, id: \.self) { i in
                    let animation: Animation? = reduceMotion
                        ? nil
                        : .easeInOut(duration: 1.0).delay(Double(i) * 0.12)
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.white.opacity(0.04))
                        .frame(
                            width: CGFloat(140 + i * 8),
                            height: CGFloat(100 + i * 6)
                        )
                        .offset(
                            x: CGFloat(-80 + i * 40),
                            y: CGFloat(-180 + i * 50)
                        )
                        .opacity(appeared ? 0.4 - Double(i) * 0.04 : 0)
                        .animation(animation, value: appeared)
                }
            } else {
                ForEach(Array(sampleItems.enumerated()), id: \.element.id) { i, item in
                    let animation: Animation? = reduceMotion
                        ? nil
                        : .easeInOut(duration: 1.0).delay(Double(i) * 0.12)
                    FeedItemCardView(
                        item: item,
                        isRead: false,
                        isBookmarked: false,
                        mediaSlot: MainFeedCardBridge.card(
                            item: item,
                            presentation: nil,
                            band: .card
                        ).mediaSlot,
                        affordances: MainFeedCardBridge.affordances(for: item)
                    )
                    .frame(width: 160, height: 110)
                    .scaleEffect(0.85)
                    .offset(
                        x: CGFloat(-90 + i * 45),
                        y: CGFloat(-190 + i * 55)
                    )
                    .opacity(appeared ? 0.45 : 0)
                    .animation(animation, value: appeared)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The welcome is deliberately dark (deep navy, explicit colours), so the
        // veil must be dark too: `.ultraThinMaterial` follows the *system*
        // appearance, and this app's pages are light by design — so light mode is
        // the common case, not the exception. A material veil therefore rendered
        // as a light grey slab over the navy, with hard edges at its own bounds.
        .overlay(
            reduceTransparency
                ? AnyShapeStyle(Color(deepNavy).opacity(0.92))
                : AnyShapeStyle(Color(deepNavy).opacity(0.62))
        )
        .accessibilityHidden(true)  // decorative — cards are behind the veil
        .allowsHitTesting(false)
    }

    private func trustBadge(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.shield.fill")
                .font(.caption2)
            Text(text)
        }
    }
}
