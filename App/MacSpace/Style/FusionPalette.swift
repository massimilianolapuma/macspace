import SwiftUI

/// The "Fusion" style (spec §5.2): warm sand neutrals in light mode, graphite in dark mode.
/// Everything is neutral except what can be removed, which uses `accent`.
struct FusionPalette {
    /// Fill of a sunburst segment; `depth` is 1 for the innermost ring, `index` its position
    /// within the ring. Deeper rings are lighter; neighbours alternate slightly.
    static func ring(depth: Int, index: Int, scheme: ColorScheme) -> Color {
        ring(lightness: ringLightness(depth: Double(depth), step: Double(index % 4), scheme: scheme),
             scheme: scheme)
    }

    /// Lightness (percent) of a ring fill. Continuous so animations can blend between rings;
    /// `step` is the neighbour alternation, `index % 4`.
    static func ringLightness(depth: Double, step: Double, scheme: ColorScheme) -> Double {
        let ringDepth = max(depth, 1) - 1
        return switch scheme {
        case .dark: min(26 + 12 * ringDepth + 3 * step, 58)
        default: min(34 + 18 * ringDepth + 3 * step, 80)
        }
    }

    static func ring(lightness: Double, scheme: ColorScheme) -> Color {
        scheme == .dark ? hsl(240, 4, lightness) : hsl(30, 10, lightness)
    }

    /// How much a hovered segment lightens, in lightness percent.
    static let hoverLift = 12.0

    /// Text drawn on a ring of the given lightness: white on dark fills, ink on light ones
    /// (at least 4.4:1 in both schemes).
    static func ringLabel(lightness: Double, scheme: ColorScheme) -> Color {
        if lightness < 48 { return .white }
        return scheme == .dark ? rgb(0x1C1C1E) : rgb(0x1F1B16)
    }

    static let background: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x1C1C1E) : rgb(0xF6F3EE) }
    static let centerFill: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x1C1C1E) : rgb(0xF6F3EE) }
    /// Center disc while hovered, when clicking it goes up a level.
    static let centerHover: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x2C2C2E) : rgb(0xECE7DF) }
    /// Hover card surface: opaque, so its text keeps full contrast over any ring.
    static let tooltipFill: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x2C2C2E) : rgb(0xFBF9F6) }
    static let primaryText: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0xFFFFFF) : rgb(0x1F1B16) }
    static let secondaryText: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x98989D) : rgb(0x6E665C) }

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
