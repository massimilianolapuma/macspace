import MacSpaceCore
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
        color(ringRGB(lightness: lightness, scheme: scheme))
    }

    /// How much a hovered segment lightens, in lightness percent.
    static let hoverLift = 12.0

    /// Text drawn on a ring fill of the given lightness: white or the scheme's ink, whichever
    /// contrasts more, falling back to pure black or white so every fill, hover-lifted ones
    /// included, reaches at least 4.5:1 (checked in `ContrastTests`).
    static func ringLabel(lightness: Double, scheme: ColorScheme) -> Color {
        let ink = scheme == .dark ? Contrast.RGB(0x1C / 255, 0x1C / 255, 0x1E / 255)
                                  : Contrast.RGB(0x1F / 255, 0x1B / 255, 0x16 / 255)
        return color(Contrast.labelInk(on: ringRGB(lightness: lightness, scheme: scheme),
                                       preferred: [Contrast.RGB(1, 1, 1), ink]))
    }

    private static func ringRGB(lightness: Double, scheme: ColorScheme) -> Contrast.RGB {
        scheme == .dark ? Contrast.hsl(240, 4, lightness) : Contrast.hsl(30, 10, lightness)
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
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color { color(Contrast.hsl(h, s, l)) }

    private static func color(_ c: Contrast.RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}
