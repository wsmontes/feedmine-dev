import SwiftUI

// MARK: - Color Extension (OKLCH + Hex)

extension Color {
    /// Create a Color from OKLCH components (perceptual color space).
    init(oklchL l: Double, chroma c: Double, hue h: Double) {
        // Convert OKLCH → sRGB (simplified: uses OKLab intermediate)
        let hRad = h * .pi / 180.0
        let a = c * cos(hRad)
        let b = c * sin(hRad)

        // OKLab to linear sRGB
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b

        let l3 = l_ * l_ * l_
        let m3 = m_ * m_ * m_
        let s3 = s_ * s_ * s_

        let r = 4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3
        let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3
        let d = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3

        self.init(
            red: Double(max(0, min(1, r))),
            green: Double(max(0, min(1, g))),
            blue: Double(max(0, min(1, d)))
        )
    }

    /// Convenience from hex string (kept for migration, prefer OKLCH).
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Layer 1: Primitives (OKLCH-based color scales)

/// Raw color scales in OKLCH. Independent of theme or circadian phase.
enum PrimitiveColor {
    // Neutral gray scale (chroma ~0, just lightness)
    static func neutral(_ level: Int) -> Color {
        let l = scaleLightness(level)
        return Color(oklchL: l, chroma: 0, hue: 0)
    }

    // Warm scale (amber, h=50)
    static func warm(_ level: Int) -> Color {
        let l = scaleLightness(level)
        let c = min(0.15, Double(level) / 600.0)
        return Color(oklchL: l, chroma: c, hue: 50)
    }

    // Cool scale (blue, h=260)
    static func cool(_ level: Int) -> Color {
        let l = scaleLightness(level)
        let c = min(0.15, Double(level) / 600.0)
        return Color(oklchL: l, chroma: c, hue: 260)
    }

    // Brand accent scale (matches Warm Earth brand gradient)
    static func accent(_ level: Int) -> Color {
        let l = scaleLightness(level)
        let c = min(0.20, Double(level) / 500.0)
        let h = lerp(from: 50, to: 25, t: Double(level) / 1000.0)  // amber → deeper coral
        return Color(oklchL: l, chroma: c, hue: h)
    }
}

// MARK: - Layer 2: Semantic Tokens

/// Purpose-based colors. These are the ONLY colors views should reference directly.
/// They resolve to primitives based on the active circadian phase.
enum SemanticColor {
    // Foreground (static, non-circadian)
    static var fgDefault: Color { PrimitiveColor.neutral(900) }
    static var fgMuted: Color { PrimitiveColor.neutral(600) }
    static var fgSubtle: Color { PrimitiveColor.neutral(400) }

    // Background (static)
    static var bgSurface: Color { Color(hex: "#FFFFFF") }
    static var bgElevated: Color { PrimitiveColor.neutral(100) }

    // Borders & separators
    static var borderDefault: Color { PrimitiveColor.neutral(200) }
    static var separatorDefault: Color { PrimitiveColor.neutral(150) }

    // Semantic actions
    static var affirmativeAction: Color { Color(hex: "#34C759") }  // iOS green
    static var cautionAction: Color { Color(hex: "#FF9F0A") }       // iOS orange
    static var tertiaryAction: Color { PrimitiveColor.neutral(400) }
    static var destructiveAction: Color { Color(hex: "#FF3B30") }   // iOS red

    // Feedback
    static var fgError: Color { Color(hex: "#FF3B30") }
    static var fgSuccess: Color { Color(hex: "#34C759") }

    // Overlays
    static var overlayLight: Color { Color.black.opacity(0.15) }
    static var overlayHeavy: Color { Color.black.opacity(0.35) }
}

// MARK: - Layer 3: Component Tokens

/// Concrete UI element tokens. Reference semantic tokens only.
enum ComponentToken {
    // Feed card (static)
    static var feedCardBg: Color { SemanticColor.bgSurface }
    static var feedCardShadow: Color { Color.black.opacity(0.04) }

    // Swipe actions
    static var swipeReadActive: Color { SemanticColor.affirmativeAction }
    static var swipeReadInactive: Color { SemanticColor.tertiaryAction }
    static var swipeBookmark: Color { Color(hex: "#FFD60A") }  // iOS yellow

    // Category badges
    static func categoryColor(for category: String) -> Color {
        switch category.lowercased() {
        case "tech", "technology":     return Color(hex: "#5B7FA5")
        case "news":                   return Color(hex: "#B8685C")
        case "science":                return Color(hex: "#6B9E7A")
        case "design":                 return Color(hex: "#8B7BA8")
        case "culture":                return Color(hex: "#C4854A")
        default:                       return PrimitiveColor.neutral(500)
        }
    }

    static func categoryColor(for category: String?) -> Color {
        guard let category else { return PrimitiveColor.neutral(500) }
        return categoryColor(for: category)
    }

    // Category gradients (for placeholders)
    static func categoryGradient(for category: String) -> [Color] {
        let base = categoryColor(for: category)
        return [base.opacity(0.3), base.opacity(0.15)]
    }

    // Briefing card
    static var briefingGradient: [Color] {
        [Color(hex: "#FF7A45").opacity(0.3), Color(hex: "#8B7BA8").opacity(0.15)]
    }

    // Carousel
    static var carouselAccentGradient: [Color] {
        [Color(hex: "#5B7FA5").opacity(0.6), Color(hex: "#8B7BA8").opacity(0.4), Color.black.opacity(0.7)]
    }

    // Share overlay
    static func shareOverlayGradient(for category: String) -> [Color] {
        let base = categoryColor(for: category)
        return [base.opacity(0.2), base.opacity(0.05)]
    }

    // Badges
    static func badgeBg(_ color: Color) -> Color { color.opacity(0.12) }

    // Media badges
    static var podcastBadge: Color { Color(hex: "#8B7BA8") }  // purple
    static var videoBadge: Color { Color(hex: "#FF3B30") }    // red
    static var newBadge: Color { Color(hex: "#5B7FA5") }      // blue
}

// MARK: - Math Helper

/// OKLCH lightness for one step of the `100…950` primitive scales.
///
/// OKLCH `L` runs 0 (black) to 1 (white), and the scale is its inverse: step 100 is the lightest
/// (L = 0.90), step 950 the darkest (L = 0.05). The previous `(100 - level) / 100` only agreed with that
/// domain below step 100 — it produced 0 at step 100 and negative values above it, which
/// `Color(oklchL:)` clamps to black, so every neutral from 100 up (borders, elevated surface, muted text,
/// the `categoryColor` fallback) rendered black (S13).
private func scaleLightness(_ level: Int) -> Double {
    Double(1000 - level) / 1000.0
}

private func lerp(from a: Double, to b: Double, t: Double) -> Double {
    a + (b - a) * max(0, min(1, t))
}
