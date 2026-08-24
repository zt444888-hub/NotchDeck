import SwiftUI
import UIKit

// MARK: - NotchDeck Buddy Design Tokens
// Single source of truth for the companion UI. Replaces the previous
// ad-hoc `Color(red:...)` literals and `opacity(0.xx)` magic numbers spread
// across ContentView with a systematic, theme-aware token set.

// MARK: Palette
/// Dynamic, theme-aware color values. Dark and light both shipped.
enum CITheme {
    // MARK: Backgrounds & Surfaces (layered for elevation)
    /// App canvas. Deep near-black in dark, warm off-white in light.
    static let background = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.015, green: 0.016, blue: 0.018, alpha: 1)
            : UIColor(red: 0.945, green: 0.925, blue: 0.880, alpha: 1)
    }

    /// Base card / capsule surface. Lifted above the background so cards read
    /// as floating (the previous pure-black surface collapsed into the
    /// background and killed all depth).
    static let surface = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
            : UIColor(red: 0.995, green: 0.985, blue: 0.960, alpha: 1)
    }

    /// Elevated surface for popovers, highlighted rows, top-most layers.
    static let surfaceRaised = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.14, alpha: 1)
            : UIColor(red: 1.0, green: 0.99, blue: 0.97, alpha: 1)
    }

    // MARK: Foreground (text / icon / hairline)
    static let foreground = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 1)
            : UIColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1)
    }

    // MARK: Accent — unified blue-violet brand color
    static let accent = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.42, green: 0.43, blue: 0.96, alpha: 1)
            : UIColor(red: 0.36, green: 0.37, blue: 0.90, alpha: 1)
    }

    // MARK: Semantic colors (status / intent)
    static let success = UIColor(red: 0.204, green: 0.78, blue: 0.349, alpha: 1)
    static let warning = UIColor(red: 1.0, green: 0.624, blue: 0.04, alpha: 1)
    static let error   = UIColor(red: 1.0, green: 0.231, blue: 0.188, alpha: 1)
    static let info    = UIColor(red: 0.039, green: 0.518, blue: 1.0, alpha: 1)
}

// MARK: Color Tokens (ShapeStyle accessors)
extension ShapeStyle where Self == Color {
    // Surfaces
    static var ciBackground: Color { Color(CITheme.background) }
    static var ciSurface: Color { Color(CITheme.surface) }
    static var ciSurfaceRaised: Color { Color(CITheme.surfaceRaised) }

    // Foreground hierarchy (replaces scattered opacity(0.xx))
    static var ciForeground: Color { Color(CITheme.foreground) }
    static var ciForegroundSecondary: Color { Color(CITheme.foreground).opacity(0.62) }
    static var ciForegroundTertiary: Color { Color(CITheme.foreground).opacity(0.42) }

    // Accent
    static var ciAccent: Color { Color(CITheme.accent) }
    /// Tinted fill for accent buttons / highlights.
    static var ciAccentSoft: Color { Color(CITheme.accent).opacity(0.16) }

    // Semantic
    static var ciSuccess: Color { Color(CITheme.success) }
    static var ciWarning: Color { Color(CITheme.warning) }
    static var ciError: Color { Color(CITheme.error) }
    static var ciInfo: Color { Color(CITheme.info) }
}

// MARK: Spacing — 4pt base grid
enum CISpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

// MARK: Corner Radius
enum CIRadius {
    static let xs: CGFloat = 6
    static let sm: CGFloat = 10
    static let md: CGFloat = 14
    static let lg: CGFloat = 20
    static let xl: CGFloat = 28
    static let pill: CGFloat = 999
}

// MARK: Typography
enum CITypography {
    static let largeTitle = Font.system(size: 28, weight: .bold)
    static let title = Font.system(size: 20, weight: .semibold)
    static let headline = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 14, weight: .regular)
    static let caption = Font.system(size: 12, weight: .medium)
    static let footnote = Font.system(size: 11, weight: .regular)
}

// MARK: Elevation (shadow)
struct CIShadow {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat

    static let sm = CIShadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 1)
    static let md = CIShadow(color: .black.opacity(0.30), radius: 12, x: 0, y: 5)
}

extension View {
    /// Apply a design-system elevation token.
    func ciShadow(_ token: CIShadow) -> some View {
        self.shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
    }
}

// MARK: Motion
enum CIMotion {
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let close = Animation.spring(response: 0.38, dampingFraction: 1.0)
    static let pop = Animation.spring(response: 0.3, dampingFraction: 0.65)
    static let micro = Animation.easeOut(duration: 0.12)
}

// MARK: Accent Gradient — signature blue→violet brand fill
extension CITheme {
    /// Deeper violet terminus for the brand gradient (dark / light both).
    static let accentGradientEnd = UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0.55, green: 0.28, blue: 0.98, alpha: 1)
            : UIColor(red: 0.47, green: 0.26, blue: 0.92, alpha: 1)
    }
}

extension LinearGradient {
    /// NotchDeck Buddy signature gradient: blue-violet → deeper violet.
    static var ciAccent: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(CITheme.accent), location: 0.0),
                .init(color: Color(CITheme.accentGradientEnd), location: 1.0)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: Elevation — glow (brand-tinted ambient shadow for accent elements)
extension CIShadow {
    /// Soft brand-colored glow used on primary CTAs (buttons, key actions).
    static let glow = CIShadow(color: Color(CITheme.accent).opacity(0.5), radius: 14, x: 0, y: 3)
}

// MARK: Surface primitives (systematic card / chip)
extension View {
    /// Standard elevated card: layered surface + hairline border + soft shadow.
    /// Replaces the previous near-invisible `ciForeground.opacity(0.0x)` fills
    /// that collapsed every card into the background and killed all depth.
    func ciCard(
        radius: CGFloat = CIRadius.md,
        fill: Color = .ciSurface,
        border: Color = Color.ciForeground.opacity(0.08),
        shadow: CIShadow = .sm
    ) -> some View {
        self
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(border, lineWidth: 1))
            .ciShadow(shadow)
    }

    /// Glassy pill surface for compact labels (status, tool, count badges).
    func ciChip(
        fill: Color = .ciSurface,
        border: Color = Color.ciForeground.opacity(0.08)
    ) -> some View {
        self
            .background(fill, in: Capsule())
            .overlay(Capsule().stroke(border, lineWidth: 1))
    }
}
