/// Chart fills for the "by file type" and "by last use" color modes, per appearance.
///
/// Designed to sit inside the Fusion style (spec §5.2): muted, paper-like tones in light mode
/// and the same hues stepped for graphite in dark mode, never in the orange reserved for what
/// can be deleted. Checked in `ChartPaletteTests`: no reserved orange, an AA label on every
/// fill, every pair of categories at CIE76 ΔE > 12 (worst pair ≈ 18.7 light, 17.1 dark).
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
        case (.video, .light): 0xB8758F
        case (.photo, .light): 0x8ABD93
        case (.music, .light): 0xB795CC
        case (.document, .light): 0x67A3CA
        case (.app, .light): 0x767AB5
        case (.development, .light): 0x4D9895
        case (.archive, .light): 0xC9B274
        case (.system, .light): 0x6D7986
        case (.appData, .light): 0x8B9661
        case (.other, .light): 0xC3BDB4
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

    /// One indigo ramp from a near-neutral grey (used this month) to deep indigo (over two
    /// years): darker with age in light mode, brighter with age in dark mode, so old files
    /// stand out against the background either way. Unknown is a warm neutral off the ramp.
    public static func age(_ b: AgeBucket, scheme: Scheme) -> Contrast.RGB {
        let hex: UInt32 = switch (b, scheme) {
        case (.lastMonth, .light): 0xA6ABB5
        case (.lastSixMonths, .light): 0x8790AA
        case (.lastYear, .light): 0x6A759E
        case (.oneToTwoYears, .light): 0x505B91
        case (.older, .light): 0x393F82
        case (.unknown, .light): 0xCFCAC2
        case (.lastMonth, .dark): 0x52555D
        case (.lastSixMonths, .dark): 0x636B81
        case (.lastYear, .dark): 0x7782A7
        case (.oneToTwoYears, .dark): 0x8C98CD
        case (.older, .dark): 0xA1ADE9
        case (.unknown, .dark): 0x403D39
        }
        return rgb(hex)
    }

    private static func rgb(_ hex: UInt32) -> Contrast.RGB {
        Contrast.RGB(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}
