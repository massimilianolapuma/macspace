import SwiftUI

/// The "Fusion" style (spec §5.2): warm sand neutrals in light mode, graphite in dark mode.
/// Everything is neutral except what can be removed, which uses `accent`.
struct FusionPalette {
    /// Fill of a sunburst segment; `depth` is 1 for the innermost ring, `index` its position
    /// within the ring. Deeper rings are lighter; neighbours alternate slightly.
    static func ring(depth: Int, index: Int, scheme: ColorScheme) -> Color {
        let step = 3 * (index % 4)
        let ringDepth = max(depth, 1) - 1
        switch scheme {
        case .dark:
            return hsl(240, 4, Double(min(26 + 12 * ringDepth + step, 58)))
        default:
            return hsl(30, 10, Double(min(34 + 18 * ringDepth + step, 80)))
        }
    }

    static let background: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x1C1C1E) : rgb(0xF6F3EE) }
    static let centerFill: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x1C1C1E) : rgb(0xF6F3EE) }
    static let primaryText: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0xFFFFFF) : rgb(0x1F1B16) }
    static let secondaryText: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x98989D) : rgb(0x7A7268) }

    /// Highlight for removable items. Not used until safety levels exist (Plan 3).
    static let accent = hsl(16, 88, 57)

    /// `h` in degrees, `s` and `l` in percent.
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
        let s = s / 100, l = l / 100
        let brightness = l + s * min(l, 1 - l)
        let saturation = brightness == 0 ? 0 : 2 * (1 - l / brightness)
        return Color(hue: h / 360, saturation: saturation, brightness: brightness)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}
