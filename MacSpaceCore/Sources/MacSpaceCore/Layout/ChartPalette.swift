/// Chart fills for the "by file type" and "by last use" color modes, per appearance.
///
/// Designed to sit inside the Fusion style (spec §5.2): muted, paper-like tones in light mode
/// and the same hues stepped for graphite in dark mode, never in the orange reserved for what
/// can be deleted. Checked in `ChartPaletteTests`: no reserved orange, an AA label on every
/// fill, every pair of categories at CIE76 ΔE > 12 (worst pair ≈ 17.0 light, music and app;
/// ≈ 16.8 dark, system and other).
///
/// Ten categories cannot all stay apart for color-vision deficiencies (any two can touch in
/// a sunburst), so a category is never shown by color alone: the legend, tooltip and list
/// name it.
public enum ChartPalette {
    public enum Scheme: Sendable { case light, dark }

    public static func category(_ c: FileCategory, scheme: Scheme) -> Contrast.RGB {
        let hex: UInt32 = switch (c, scheme) {
        // Hues follow the kind of content: warm rose for video, sage for photos, violet for
        // music, blue for documents, indigo for apps, teal for development, ochre for archives,
        // olive for app data; system is slate and "other" a quiet stone, both nearly grey.
        // Pale light tones sit low enough to lighten over two more levels plus the hover lift
        // before they would fade into the background.
        case (.video, .light): 0xB8758F
        case (.photo, .light): 0x82B88B
        case (.music, .light): 0xB08BC7
        case (.document, .light): 0x67A3CA
        case (.app, .light): 0x767AB5
        case (.development, .light): 0x4D9895
        case (.archive, .light): 0xC5AD6B
        case (.system, .light): 0x6D7986
        case (.appData, .light): 0x8B9661
        case (.other, .light): 0xACA498
        case (.video, .dark): 0x995C74
        case (.photo, .dark): 0x6B9974
        case (.music, .dark): 0x9678A9
        case (.document, .dark): 0x5087AB
        case (.app, .dark): 0x5D6096
        case (.development, .dark): 0x3F7E7B
        case (.archive, .dark): 0xAB965D
        case (.system, .dark): 0x535C66
        case (.appData, .dark): 0x6A7140
        case (.other, .dark): 0x7F7973
        }
        return rgb(hex)
    }

    /// One steel-blue ramp (hue spread about 30°), from a pale blue-grey (used this month) to deep
    /// navy (over two years): darker with age in light mode, brighter with age in dark mode, so
    /// old files stand out against the background either way. Adjacent buckets are at least 10
    /// apart in CIEDE2000 and the recent end clears 2:1 against the background, so large areas of
    /// neighbouring buckets stay tellable apart (Ruling Z). Unknown is a warm neutral off the ramp.
    public static func age(_ b: AgeBucket, scheme: Scheme) -> Contrast.RGB {
        let hex: UInt32 = switch (b, scheme) {
        case (.lastMonth, .light): 0x96B2C0
        case (.lastSixMonths, .light): 0x6893B0
        case (.lastYear, .light): 0x3F749F
        case (.oneToTwoYears, .light): 0x235488
        case (.older, .light): 0x173668
        case (.unknown, .light): 0xD2C8BD
        case (.lastMonth, .dark): 0x445863
        case (.lastSixMonths, .dark): 0x507790
        case (.lastYear, .dark): 0x6396BF
        case (.oneToTwoYears, .dark): 0x87B4EA
        case (.older, .dark): 0xBFD2FA
        case (.unknown, .dark): 0x463E37
        }
        return rgb(hex)
    }

    // MARK: Drawn fills

    /// How much a hovered element lightens, in HSL lightness points.
    public static let hoverLift = 12.0

    /// The window and chart background (Fusion sand paper / graphite).
    public static func surface(_ scheme: Scheme) -> Contrast.RGB {
        scheme == .dark ? rgb(0x1C1C1E) : rgb(0xF6F3EE)
    }

    /// The scheme's dark text color.
    public static func ink(_ scheme: Scheme) -> Contrast.RGB {
        scheme == .dark ? rgb(0x1C1C1E) : rgb(0x1F1B16)
    }

    /// Label color on a chart fill: white or the scheme's ink when one reaches 4.5:1, else black or
    /// white. AA holds by construction, since one of black and white always reaches about 4.58:1.
    public static func labelInk(on fill: Contrast.RGB, scheme: Scheme) -> Contrast.RGB {
        Contrast.labelInk(on: fill, preferred: [Contrast.RGB(1, 1, 1), ink(scheme)])
    }

    /// A category fill as drawn at ring or tile `depth` (1 = first level; fractional while
    /// animating), lifted by `lift` lightness points while hovered. Each level below the first
    /// lightens by up to 6 points: pale tones take smaller steps, so the third level still has room
    /// for the hover lift and no fill, hovered or not, drops below 1.3:1 against the background.
    public static func categoryFill(_ c: FileCategory, scheme: Scheme, depth: Double = 1,
                                    lift: Double = 0) -> Contrast.RGB {
        let tone = (scheme == .dark ? darkCategoryTones : lightCategoryTones)[Int(c.rawValue)]
        return tone.shade(levels: tone.depthStep * (max(depth, 1) - 1), lift: lift)
    }

    // MARK: Section surfaces

    /// The scheme's secondary text color (section headers, captions).
    public static func secondaryText(_ scheme: Scheme) -> Contrast.RGB {
        scheme == .dark ? rgb(0x98989D) : rgb(0x6E665C)
    }

    /// Strongest tint of a treemap section surface, before the header's contrast limits it.
    private static func sectionTint(_ scheme: Scheme) -> Double { scheme == .dark ? 0.22 : 0.18 }
    /// Contrast kept for section headers: AA plus a little margin for rounding.
    private static let sectionContrast = 4.55

    /// Surface of a treemap section (a tile whose children are drawn inside it): `tint` laid
    /// over `base` (the background or the enclosing section's surface) as strongly as
    /// `sectionTint` allows while the section header, in `secondaryText`, keeps 4.5:1 on it.
    /// Dark tints therefore stay fainter than pale ones.
    public static func sectionSurface(tint: Contrast.RGB, over base: Contrast.RGB, scheme: Scheme) -> Contrast.RGB {
        let text = secondaryText(scheme)
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

    // MARK: Merged "Altri"

    /// The fill of a merged "Altri N elementi" element in "by file type" mode, sitting on `surface`
    /// (its parent section's surface in the treemap, the background in the sunburst). It mixes
    /// types, so it takes none of theirs (Ruling AG): it stays close to its surface, a little darker
    /// in light mode and a little lighter in dark mode (so it never reads as a hole), and the dashed
    /// `mergedOutline` around it says "many small items". Lifted by `lift` while hovered.
    public static func mergedFill(on surface: Contrast.RGB, scheme: Scheme, lift: Double = 0) -> Contrast.RGB {
        let (h, s, l) = Contrast.hslComponents(surface)
        let offset = scheme == .dark ? 5.0 : -4.0
        return Contrast.hsl(h, s, min(max(l + offset + lift, 0), 100))
    }

    /// The dashed outline of a merged element on `surface`, hovered when `lift` > 0: a Fusion neutral
    /// (`hsl(30, 10%, …)` light, `hsl(240, 4%, …)` dark), as close to the surface as it can be while
    /// it keeps 3:1 (WCAG 1.4.11, plus a little margin for rounding) against the surface and against
    /// the merged fill, resting and, while hovered, lifted. So it is as quiet as the rule allows: in
    /// light mode it stays the same on hover (the lifted fill is lighter, never the binding side); in
    /// dark mode it brightens with the lifted fill.
    public static func mergedOutline(on surface: Contrast.RGB, scheme: Scheme, lift: Double = 0) -> Contrast.RGB {
        var references = [surface, mergedFill(on: surface, scheme: scheme)]
        if lift > 0 { references.append(mergedFill(on: surface, scheme: scheme, lift: lift)) }
        let (hue, saturation) = scheme == .dark ? (240.0, 4.0) : (30.0, 10.0)
        func outline(_ l: Double) -> Contrast.RGB { Contrast.hsl(hue, saturation, l) }
        func clears(_ l: Double) -> Bool {
            references.allSatisfy { Contrast.ratio(outline(l), $0) >= mergedOutlineContrast }
        }
        // Light: darker than every reference, so contrast grows as the lightness falls; dark: lighter
        // than every reference, so it grows as the lightness rises.
        let lightness = references.map(Contrast.lightness)
        var near = (scheme == .dark ? lightness.max() : lightness.min()) ?? 50
        var far = scheme == .dark ? 100.0 : 0
        guard clears(far) else { return outline(far) }
        for _ in 0..<24 {
            let mid = (near + far) / 2
            if clears(mid) { far = mid } else { near = mid }
        }
        return outline(far)
    }

    /// Contrast the merged outline keeps: the 3:1 of WCAG 1.4.11 plus a little margin.
    private static let mergedOutlineContrast = 3.1

    /// An age fill, lifted by `lift` while hovered. The same at every depth: its lightness is the
    /// age, so a depth shift would make a deep recent folder read as an older one.
    public static func ageFill(_ b: AgeBucket, scheme: Scheme, lift: Double = 0) -> Contrast.RGB {
        (scheme == .dark ? darkAgeTones : lightAgeTones)[b.rawValue].shade(levels: 0, lift: lift)
    }

    /// A palette color in HSL, with the lightest it may be drawn.
    private struct Tone {
        let h, s, l: Double
        /// Highest lightness that keeps 1.3:1 against the background.
        let ceiling: Double
        /// Resting fills stop here (`ceiling - hoverLift`, or the base if already above).
        let restingMax: Double
        /// Lightness added per level: 6 points, or less when two levels would pass `restingMax`.
        let depthStep: Double

        init(_ color: Contrast.RGB, scheme: Scheme) {
            (h, s, l) = Contrast.hslComponents(color)
            let surface = ChartPalette.surface(scheme)
            var top = l
            // Only light mode can fade into its background by lightening.
            if scheme == .light {
                while top < 100, Contrast.ratio(Contrast.hsl(h, s, top + 0.25), surface) >= 1.3 { top += 0.25 }
            } else {
                top = 100
            }
            ceiling = top
            restingMax = max(l, min(scheme == .dark ? 78 : 86, top - ChartPalette.hoverLift))
            depthStep = min(6, (restingMax - l) / 2)
        }

        func shade(levels: Double, lift: Double) -> Contrast.RGB {
            Contrast.hsl(h, s, min(min(l + levels, restingMax) + lift, ceiling))
        }
    }

    private static let lightCategoryTones = FileCategory.allCases.map {
        Tone(category($0, scheme: .light), scheme: .light)
    }
    private static let darkCategoryTones = FileCategory.allCases.map {
        Tone(category($0, scheme: .dark), scheme: .dark)
    }
    private static let lightAgeTones = AgeBucket.allCases.map { Tone(age($0, scheme: .light), scheme: .light) }
    private static let darkAgeTones = AgeBucket.allCases.map { Tone(age($0, scheme: .dark), scheme: .dark) }

    private static func rgb(_ hex: UInt32) -> Contrast.RGB {
        Contrast.RGB(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}
