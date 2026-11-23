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
    static let hoverLift = ChartPalette.hoverLift

    /// Text drawn on a ring fill of the given lightness: white or the scheme's ink, whichever
    /// contrasts more, falling back to pure black or white so every fill, hover-lifted ones
    /// included, reaches at least 4.5:1 (checked in `ContrastTests`).
    static func ringLabel(lightness: Double, scheme: ColorScheme) -> Color {
        color(Contrast.labelInk(on: ringRGB(lightness: lightness, scheme: scheme),
                                preferred: [Contrast.RGB(1, 1, 1), ChartPalette.ink(paletteScheme(scheme))]))
    }

    private static func ringRGB(lightness: Double, scheme: ColorScheme) -> Contrast.RGB {
        scheme == .dark ? Contrast.hsl(240, 4, lightness) : Contrast.hsl(30, 10, lightness)
    }

    /// What a chart element's color depends on: its dominant category and age bucket, and
    /// whether it is a merged "Altri N elementi" element (`node == nil`).
    struct FillSubject {
        var category: FileCategory
        var ageBucket: AgeBucket
        var isMerged: Bool

        init(_ segment: ArcSegment) {
            self.init(category: segment.category, ageBucket: segment.ageBucket, isMerged: segment.node == nil)
        }

        init(_ tile: TreemapTile) {
            self.init(category: tile.category, ageBucket: tile.ageBucket, isMerged: tile.node == nil)
        }

        init(category: FileCategory, ageBucket: AgeBucket, isMerged: Bool) {
            self.category = category
            self.ageBucket = ageBucket
            self.isMerged = isMerged
        }
    }

    /// Fill of a chart element in color mode `mode`; `depth` is 1 for the innermost ring (or
    /// top-level tile) and `index` the element's position among its siblings. Used by both charts.
    ///
    /// - Neutral: the plan-1 ring palette, unchanged.
    /// - By type: the category's `ChartPalette.categoryFill`, up to 6 lightness points lighter per
    ///   level below the first. Merged "altri" elements mix types, so they take
    ///   `ChartPalette.mergedFill` instead, a warm graphite apart from every category (Ruling AF),
    ///   which the legend names "Altri (misti)".
    /// - By last use: the age bucket's `ChartPalette.ageFill`, the same at every depth (Ruling V:
    ///   its lightness *is* the age, so a depth shift would make a deep recent folder read as an
    ///   older one). Merged "altri" take the bucket holding most of their bytes, which their
    ///   tooltip states ("Per lo più").
    ///
    /// The label ink is a separate call (`label`), so drawing loops pay for it only where a
    /// label is actually placed.
    static func fill(_ subject: FillSubject, mode: ColorMode, depth: Int, index: Int, scheme: ColorScheme) -> Color {
        fill(subject, mode: mode, depth: Double(depth), step: Double(index % 4), scheme: scheme)
    }

    /// Label ink for text drawn on `fill(subject, …)` with the same arguments: at least 4.5:1.
    static func label(_ subject: FillSubject, mode: ColorMode, depth: Int, index: Int, scheme: ColorScheme) -> Color {
        label(subject, mode: mode, depth: Double(depth), step: Double(index % 4), scheme: scheme)
    }

    /// `fill` with a continuous `depth` and `step` (`index % 4`), so animations can blend between
    /// levels, plus `lift` points of lightness (`hoverLift` while hovered).
    static func fill(_ subject: FillSubject, mode: ColorMode, depth: Double, step: Double, lift: Double = 0,
                     scheme: ColorScheme) -> Color {
        color(fillRGB(subject, mode: mode, depth: depth, step: step, lift: lift, scheme: scheme))
    }

    /// `fill` as RGB, for surfaces composited from it (treemap sections).
    static func fillRGB(_ subject: FillSubject, mode: ColorMode, depth: Double, step: Double, lift: Double = 0,
                        scheme: ColorScheme) -> Contrast.RGB {
        coloredRGB(subject, mode: mode, depth: depth, lift: lift, scheme: scheme)
            ?? ringRGB(lightness: ringLightness(depth: depth, step: step, scheme: scheme) + lift, scheme: scheme)
    }

    /// Surface of a treemap section (a tile whose children are drawn inside it): `tint` laid
    /// over `base` (the background or the enclosing section's surface) as strongly as
    /// `sectionTint` allows while the section header, in `secondaryText`, keeps 4.5:1 on it.
    /// Dark tints therefore stay fainter than pale ones.
    static func sectionSurface(tint: Contrast.RGB, over base: Contrast.RGB, scheme: ColorScheme) -> Contrast.RGB {
        let text = secondaryTextRGB(scheme)
        func mixed(_ a: Double) -> Contrast.RGB {
            Contrast.RGB(base.r + (tint.r - base.r) * a, base.g + (tint.g - base.g) * a, base.b + (tint.b - base.b) * a)
        }
        let strongest = mixed(sectionTint(scheme))
        if Contrast.ratio(text, strongest) >= sectionContrast { return strongest }
        guard Contrast.ratio(text, base) >= sectionContrast else { return base }
        var low = 0.0, high = sectionTint(scheme)  // contrast falls as the tint grows
        for _ in 0..<10 {
            let mid = (low + high) / 2
            if Contrast.ratio(text, mixed(mid)) >= sectionContrast { low = mid } else { high = mid }
        }
        return mixed(low)
    }

    /// Strongest tint of a section surface, before the header's contrast limits it.
    static func sectionTint(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.22 : 0.18 }
    /// Contrast kept for section headers: AA plus a little margin for rounding.
    private static let sectionContrast = 4.55

    static func backgroundRGB(_ scheme: ColorScheme) -> Contrast.RGB { ChartPalette.surface(paletteScheme(scheme)) }
    static func secondaryTextRGB(_ scheme: ColorScheme) -> Contrast.RGB {
        scheme == .dark ? hexRGB(0x98989D) : hexRGB(0x6E665C)
    }

    /// `label` with a continuous `depth` and `step`, plus `lift`.
    static func label(_ subject: FillSubject, mode: ColorMode, depth: Double, step: Double, lift: Double = 0,
                      scheme: ColorScheme) -> Color {
        if let rgb = coloredRGB(subject, mode: mode, depth: depth, lift: lift, scheme: scheme) {
            return color(ChartPalette.labelInk(on: rgb, scheme: paletteScheme(scheme)))
        }
        return ringLabel(lightness: ringLightness(depth: depth, step: step, scheme: scheme) + lift, scheme: scheme)
    }

    /// The fill in a colored mode; nil when the element takes the neutral ring tone.
    private static func coloredRGB(_ subject: FillSubject, mode: ColorMode, depth: Double, lift: Double,
                                   scheme: ColorScheme) -> Contrast.RGB? {
        switch mode {
        case .neutral:
            nil
        case .category:
            subject.isMerged ? ChartPalette.mergedFill(scheme: paletteScheme(scheme), lift: lift)
                : ChartPalette.categoryFill(subject.category, scheme: paletteScheme(scheme), depth: depth, lift: lift)
        case .lastUse:
            ChartPalette.ageFill(subject.ageBucket, scheme: paletteScheme(scheme), lift: lift)
        }
    }

    private static func paletteScheme(_ scheme: ColorScheme) -> ChartPalette.Scheme {
        scheme == .dark ? .dark : .light
    }

    /// The base color of a category or age bucket (its first-level fill), for legend and list dots.
    static func swatch(_ category: FileCategory, scheme: ColorScheme) -> Color {
        color(ChartPalette.categoryFill(category, scheme: paletteScheme(scheme)))
    }

    static func swatch(_ bucket: AgeBucket, scheme: ColorScheme) -> Color {
        color(ChartPalette.ageFill(bucket, scheme: paletteScheme(scheme)))
    }

    /// The merged "altri" fill in "by file type" mode, for its legend chip.
    static func mergedSwatch(scheme: ColorScheme) -> Color {
        color(ChartPalette.mergedFill(scheme: paletteScheme(scheme)))
    }

    /// Hairline around a swatch dot, so pale or dark swatches still show against the window.
    static let swatchRing: @Sendable (ColorScheme) -> Color = {
        primaryText($0).opacity($0 == .dark ? 0.22 : 0.16)
    }

    static let background: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x1C1C1E) : rgb(0xF6F3EE) }
    static let centerFill: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x1C1C1E) : rgb(0xF6F3EE) }
    /// Center disc while hovered, when clicking it goes up a level.
    static let centerHover: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x2C2C2E) : rgb(0xECE7DF) }
    /// Hover card surface: opaque, so its text keeps full contrast over any ring.
    static let tooltipFill: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0x2C2C2E) : rgb(0xFBF9F6) }
    static let primaryText: @Sendable (ColorScheme) -> Color = { $0 == .dark ? rgb(0xFFFFFF) : rgb(0x1F1B16) }
    static let secondaryText: @Sendable (ColorScheme) -> Color = { color(secondaryTextRGB($0)) }

    /// Highlight for removable items. Not used until safety levels exist (Plan 3).
    static let accent = hsl(16, 88, 57)

    /// `h` in degrees, `s` and `l` in percent.
    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color { color(Contrast.hsl(h, s, l)) }

    static func color(_ c: Contrast.RGB) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b) }

    private static func hexRGB(_ hex: UInt32) -> Contrast.RGB {
        Contrast.RGB(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}
