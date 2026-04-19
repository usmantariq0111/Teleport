import SwiftUI

/// Centralized design tokens. Keeps the rest of the UI declarative
/// and ensures a single source of truth for colors, radii, spacing.
enum Theme {
    enum Palette {
        static let accent      = Color(red: 0.36, green: 0.55, blue: 1.00) // #5C8CFF
        static let accentAlt   = Color(red: 0.61, green: 0.36, blue: 1.00) // #9C5CFF
        static let success     = Color(red: 0.27, green: 0.85, blue: 0.55)
        static let warning     = Color(red: 1.00, green: 0.78, blue: 0.30)
        static let danger      = Color(red: 1.00, green: 0.42, blue: 0.46)

        static let surface     = Color(nsColor: .underPageBackgroundColor)
        static let surfaceAlt  = Color(nsColor: .controlBackgroundColor)
        static let border      = Color.primary.opacity(0.08)
        static let textMuted   = Color.secondary
        static let logBg       = Color(red: 0.05, green: 0.06, blue: 0.09)
    }

    enum Radius {
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 16
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    static let brandGradient = LinearGradient(
        colors: [Palette.accent, Palette.accentAlt],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

/// Soft card surface used across the dashboard.
struct CardModifier: ViewModifier {
    var padding: CGFloat = Theme.Spacing.md
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.Palette.surfaceAlt.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .stroke(Theme.Palette.border, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = Theme.Spacing.md) -> some View {
        modifier(CardModifier(padding: padding))
    }
}
