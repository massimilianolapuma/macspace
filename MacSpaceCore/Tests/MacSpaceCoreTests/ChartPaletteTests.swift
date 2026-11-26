import Testing
@testable import MacSpaceCore

@Test func paletteAvoidsReservedOrange() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for c in FileCategory.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.category(c, scheme: s))) }
        for b in AgeBucket.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.age(b, scheme: s))) }
        for surface in mergedSurfaces(s) {
            for hovered in [false, true] {
                #expect(!Contrast.isReservedOrange(ChartPalette.mergedFill(on: surface, scheme: s, hovered: hovered)))
                #expect(!Contrast.isReservedOrange(ChartPalette.mergedOutline(on: surface, scheme: s, hovered: hovered)))
            }
        }
    }
}

/// Every fill the charts draw in the colored modes, resting and hovered: category fills at the
/// three ring depths and age fills (which take no depth lift), each also lifted by the +12 hover.
/// The merged "Altri" fill sits close to its surface on purpose (Ruling AG) and is checked apart.
private func drawnFills(_ s: ChartPalette.Scheme) -> [Contrast.RGB] {
    var fills: [Contrast.RGB] = []
    for lift in [0.0, 12] {
        for c in FileCategory.allCases {
            for depth in [1.0, 2, 3] { fills.append(ChartPalette.categoryFill(c, scheme: s, depth: depth, lift: lift)) }
        }
        for b in AgeBucket.allCases { fills.append(ChartPalette.ageFill(b, scheme: s, lift: lift)) }
    }
    return fills
}

/// AA holds by construction: `labelInk` falls back to black or white, one of which always reaches
/// about 4.58:1. This checks the ink the charts really use on the fills they really draw.
@Test func everyDrawnFillTakesAnAALabel() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for fill in drawnFills(s) {
            let ink = ChartPalette.labelInk(on: fill, scheme: s)
            #expect(Contrast.ratio(ink, fill) >= 4.5, "\(fill)")
        }
    }
}

/// Ruling Z: the age fills as drawn (resting) are clearly distinct where the legend and the
/// charts put them side by side: CIEDE2000 >= 10 between adjacent buckets, and "Sconosciuto"
/// apart from every bucket, in both themes.
@Test func drawnAgeFillsAreDistinctBetweenNeighbours() {
    for s in [ChartPalette.Scheme.light, .dark] {
        let known = AgeBucket.allCases.filter { $0 != .unknown }.map { ChartPalette.ageFill($0, scheme: s) }
        for (a, b) in zip(known, known.dropFirst()) {
            #expect(Contrast.deltaE2000(a, b) >= 10, "\(s) \(a) \(b): \(Contrast.deltaE2000(a, b))")
        }
        let unknown = ChartPalette.ageFill(.unknown, scheme: s)
        for fill in known { #expect(Contrast.deltaE2000(unknown, fill) >= 10, "\(s) unknown vs \(fill)") }
    }
}

/// Pale outer fills, hovered or not, never fade into the window background.
@Test func drawnFillsStayVisibleOnTheBackground() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for fill in drawnFills(s) { #expect(Contrast.ratio(fill, ChartPalette.surface(s)) >= 1.3, "\(fill)") }
    }
}

/// Hovering always shows: the lifted fill differs from the resting one.
@Test func hoverLiftIsVisibleOnEveryCategoryFill() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for c in FileCategory.allCases {
            for depth in [1.0, 2, 3] {
                let rest = ChartPalette.categoryFill(c, scheme: s, depth: depth)
                let hover = ChartPalette.categoryFill(c, scheme: s, depth: depth, lift: 12)
                #expect(Contrast.deltaE(rest, hover) > 5, "\(c) depth \(depth)")
            }
        }
    }
}

@Test func categoriesAreDistinguishable() {
    for s in [ChartPalette.Scheme.light, .dark] {
        let cs = FileCategory.allCases.map { ChartPalette.category($0, scheme: s) }
        for i in cs.indices { for j in cs.indices where i < j { #expect(Contrast.deltaE(cs[i], cs[j]) > 12) } }
    }
}

@Test func ageRampIsMonotonicInLightness() {
    let known = AgeBucket.allCases.filter { $0 != .unknown }
    let light = known.map { Contrast.lightness(ChartPalette.age($0, scheme: .light)) }
    let dark = known.map { Contrast.lightness(ChartPalette.age($0, scheme: .dark)) }
    #expect(zip(light, light.dropFirst()).allSatisfy { $0 > $1 })   // older = darker in light mode
    #expect(zip(dark, dark.dropFirst()).allSatisfy { $0 < $1 })     // older = brighter in dark mode
}

/// Every surface a merged "Altri" element can sit on in "Per tipo di file" mode: the background
/// (the treemap's top level and the sunburst's rings), a first-level section's surface over it and
/// a second-level section's surface inside that, at depths 1…3 in half steps (animations blend
/// levels), each tint resting and hovered.
private func mergedSurfaces(_ s: ChartPalette.Scheme) -> [Contrast.RGB] {
    let background = ChartPalette.surface(s)
    var tints: [Contrast.RGB] = []
    for c in FileCategory.allCases {
        for depth in stride(from: 1.0, through: 3, by: 0.5) {
            for lift in [0.0, 12] { tints.append(ChartPalette.categoryFill(c, scheme: s, depth: depth, lift: lift)) }
        }
    }
    let first = tints.map { ChartPalette.sectionSurface(tint: $0, over: background, scheme: s) }
    let second = first.flatMap { base in tints.map { ChartPalette.sectionSurface(tint: $0, over: base, scheme: s) } }
    return [background] + first + second
}

/// Ruling AG: a merged "Altri" element mixes types, so in "Per tipo di file" mode it takes no type
/// color but a recessive fill close to its surface, delimited by a dashed neutral outline that
/// reaches the 3:1 of WCAG 1.4.11 against that surface and against its own fill, resting and
/// hovered (the hovered outline also against the resting fill, which the hover layer draws over),
/// on every surface it can sit on, in both themes.
@Test func mergedOutlineReachesThreeToOneOnEverySurface() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for surface in mergedSurfaces(s) {
            for hovered in [false, true] {
                let outline = ChartPalette.mergedOutline(on: surface, scheme: s, hovered: hovered)
                #expect(Contrast.ratio(outline, surface) >= 3, "\(s) outline \(hovered) vs surface \(surface)")
                for fillHovered in Set([false, hovered]) {
                    let fill = ChartPalette.mergedFill(on: surface, scheme: s, hovered: fillHovered)
                    #expect(Contrast.ratio(outline, fill) >= 3, "\(s) outline \(hovered) vs fill \(fillHovered) on \(surface)")
                }
            }
        }
    }
}

/// Hovering a section lifts its surface in the gaps around its children, a merged tile among them;
/// the merged outline, chosen on the resting surface, still keeps 3:1 against the lifted one.
@Test func mergedOutlineClearsTheHoveredParentSurface() {
    for s in [ChartPalette.Scheme.light, .dark] {
        let background = ChartPalette.surface(s)
        var bases = [background]
        for c in FileCategory.allCases {
            bases.append(ChartPalette.sectionSurface(tint: ChartPalette.categoryFill(c, scheme: s), over: background,
                                                     scheme: s))
        }
        for base in bases {
            for c in FileCategory.allCases {
                for depth in stride(from: 1.0, through: 3, by: 0.5) {
                    let rest = ChartPalette.sectionSurface(tint: ChartPalette.categoryFill(c, scheme: s, depth: depth),
                                                           over: base, scheme: s)
                    let hovered = ChartPalette.sectionSurface(
                        tint: ChartPalette.categoryFill(c, scheme: s, depth: depth, lift: 12), over: base, scheme: s)
                    for merged in [false, true] {
                        let outline = ChartPalette.mergedOutline(on: rest, scheme: s, hovered: merged)
                        #expect(Contrast.ratio(outline, hovered) >= 3, "\(s) \(c) d\(depth) on \(base)")
                    }
                }
            }
        }
    }
}

/// The outline is a Fusion neutral, not a hue: nothing about "many small mixed items" is a type.
@Test func mergedOutlineIsNeutral() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for surface in mergedSurfaces(s) {
            for hovered in [false, true] {
                #expect(Contrast.hslComponents(ChartPalette.mergedOutline(on: surface, scheme: s, hovered: hovered)).s <= 10.5)
            }
        }
    }
}

/// The merged fill stays recessive: close to its surface (under 1.25:1, below the 1.3:1 every
/// category fill keeps from the background, so it never outweighs a category tile) yet not the
/// surface itself (so it does not read as a hole), lighter than the
/// surface in dark mode, and its label reaches AA, resting and hovered.
@Test func mergedFillIsRecessiveAndTakesAnAALabel() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for surface in mergedSurfaces(s) {
            let rest = ChartPalette.mergedFill(on: surface, scheme: s)
            #expect(Contrast.ratio(rest, surface) < 1.25, "\(s) \(surface)")
            #expect(Contrast.deltaE2000(rest, surface) >= 2, "\(s) \(surface)")
            if s == .dark { #expect(Contrast.luminance(rest) > Contrast.luminance(surface)) }
            for hovered in [false, true] {
                let fill = ChartPalette.mergedFill(on: surface, scheme: s, hovered: hovered)
                #expect(Contrast.ratio(ChartPalette.labelInk(on: fill, scheme: s), fill) >= 4.5, "\(fill)")
            }
        }
    }
}

/// Hovering a merged element shows. Its lift is smaller than the categories' +12 (Ruling AI: the
/// hovered fill must not become a category color), so the bar is CIE76 > 4 rather than > 5.
@Test func hoverLiftIsVisibleOnTheMergedFill() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for surface in mergedSurfaces(s) {
            let rest = ChartPalette.mergedFill(on: surface, scheme: s)
            #expect(Contrast.deltaE(rest, ChartPalette.mergedFill(on: surface, scheme: s, hovered: true)) > 4)
        }
    }
}

/// Ruling AI: the merged fill, resting and hovered, on every surface it can sit on, is never a
/// category color: CIEDE2000 >= 8 from every resting category fill at depths 1…3 (fractional ones
/// included, as animations blend levels), in both themes.
@Test func mergedFillIsNotACategoryColor() {
    for s in [ChartPalette.Scheme.light, .dark] {
        var categories: [(FileCategory, Double, Contrast.RGB)] = []
        for c in FileCategory.allCases {
            for depth in stride(from: 1.0, through: 3, by: 0.25) {
                categories.append((c, depth, ChartPalette.categoryFill(c, scheme: s, depth: depth)))
            }
        }
        for surface in mergedSurfaces(s) {
            for hovered in [false, true] {
                let merged = ChartPalette.mergedFill(on: surface, scheme: s, hovered: hovered)
                for (c, depth, fill) in categories {
                    let difference = Contrast.deltaE2000(merged, fill)
                    #expect(difference >= 8, "\(s) merged \(hovered) on \(surface) vs \(c) d\(depth): \(difference)")
                }
            }
        }
    }
}

/// Ruling AI: the hovered fill keeps its surface's tint: same hue and saturation, lifted without
/// clamping (never pure white in light mode).
@Test func hoveredMergedFillKeepsTheSurfaceTint() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for surface in mergedSurfaces(s) {
            let (h, sat, l) = Contrast.hslComponents(surface)
            let hovered = Contrast.hslComponents(ChartPalette.mergedFill(on: surface, scheme: s, hovered: true))
            #expect(hovered.l <= 98.5, "\(s) \(surface): \(hovered.l)")
            #expect(hovered.l > l - 4, "\(s) \(surface)")
            #expect(abs(hovered.s - sat) < 0.5, "\(s) \(surface)")
            if sat > 1 { #expect(abs(hovered.h - h) < 0.5, "\(s) \(surface)") }
        }
    }
}

/// Section surfaces keep their header, in the secondary text color, at AA on any base.
@Test func sectionSurfacesKeepTheirHeaderAtAA() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for surface in mergedSurfaces(s) {
            #expect(Contrast.ratio(ChartPalette.secondaryText(s), surface) >= 4.5, "\(s) \(surface)")
        }
    }
}

/// Every category lightens level by level (ring 1 -> 2 -> 3), pale ones included, so a folder and
/// its same-type children stay apart.
@Test func categoryFillsLightenWithDepth() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for c in FileCategory.allCases {
            let levels = [1.0, 2, 3].map { Contrast.lightness(ChartPalette.categoryFill(c, scheme: s, depth: $0)) }
            for (outer, inner) in zip(levels.dropFirst(), levels) {
                #expect(outer - inner >= 4, "\(s) \(c): \(levels)")
            }
        }
    }
}

// MARK: "Eliminabili" (safety levels)

/// The fills the "Eliminabili" mode draws for the two orange levels, resting and hovered (+12).
private func safetyFills(_ s: ChartPalette.Scheme) -> [(SafetyLevel, Double, Contrast.RGB)] {
    [SafetyLevel.safe, .caution].flatMap { level in
        [0.0, 12].compactMap { lift in ChartPalette.safetyFill(level, scheme: s, lift: lift).map { (level, lift, $0) } }
    }
}

/// Safe is the spec's solid accent (`hsl(16, 88%, 57%)`, dark `hsl(16, 85%, 56%)`); normal and
/// protected take no safety fill, so they keep the neutral ring tone.
@Test func safetyFillsAreTheAccentAndNeutralElsewhere() throws {
    let light = try #require(ChartPalette.safetyFill(.safe, scheme: .light))
    let dark = try #require(ChartPalette.safetyFill(.safe, scheme: .dark))
    #expect(Contrast.deltaE(light, Contrast.hsl(16, 88, 57)) < 0.01)
    #expect(Contrast.deltaE(dark, Contrast.hsl(16, 85, 56)) < 0.01)
    for s in [ChartPalette.Scheme.light, .dark] {
        #expect(ChartPalette.safetyFill(.caution, scheme: s) != nil)
        for lift in [0.0, 12] {
            #expect(ChartPalette.safetyFill(.normal, scheme: s, lift: lift) == nil)
            #expect(ChartPalette.safetyFill(.protected, scheme: s, lift: lift) == nil)
        }
    }
}

/// A label on a safe or caution element reaches 4.5:1, resting and hovered, in both themes. A
/// caution label also crosses the hatch lines, so the same ink reaches 4.5:1 on them too (which is
/// why the dark hatch is a deeper accent: white on the full accent is only about 3.3:1).
@Test func safetyFillsTakeAnAALabelIncludingTheHatch() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for (level, lift, fill) in safetyFills(s) {
            let ink = ChartPalette.labelInk(on: fill, scheme: s)
            #expect(Contrast.ratio(ink, fill) >= 4.5, "\(s) \(level) +\(lift)")
            if level == .caution {
                let hatch = ChartPalette.hatch(s, lift: lift)
                #expect(Contrast.ratio(ink, hatch) >= 4.5, "\(s) caution +\(lift) ink on hatch")
            }
        }
    }
}

/// Caution must not read as safe. Dark: the soft fill alone is 3:1 from the accent. Light: the
/// pale soft fill is under 3:1 from the accent (about 1.9:1), so the hatch tells them apart; it
/// stays visible on the caution fill (at least 1.3:1, resting and hovered, as each is drawn) in both
/// themes, yet quiet: tone on tone, 1.4–1.8:1 at rest, so a large hatched area never outshouts the
/// solid accent.
@Test func cautionDiffersFromSafe() throws {
    let darkSafe = try #require(ChartPalette.safetyFill(.safe, scheme: .dark))
    let darkCaution = try #require(ChartPalette.safetyFill(.caution, scheme: .dark))
    #expect(Contrast.ratio(darkSafe, darkCaution) >= 3)
    for s in [ChartPalette.Scheme.light, .dark] {
        for lift in [0.0, 12] {
            let caution = try #require(ChartPalette.safetyFill(.caution, scheme: s, lift: lift))
            let stripes = Contrast.ratio(ChartPalette.hatch(s, lift: lift), caution)
            #expect(stripes >= 1.3, "\(s) hatch on caution +\(lift): \(stripes)")
            if lift == 0 { #expect((1.4...1.8).contains(stripes), "\(s) hatch stays quiet: \(stripes)") }
        }
    }
}

/// The two orange levels and the hatch stay in the accent's hue (14–18°), resting and hovered;
/// the safe fill and the hatch are the reserved orange itself (the dark soft fill, at about 48 %
/// saturation, sits just below it, which is fine: it only has to stay orange in hue).
@Test func safetyColorsStayInTheAccentHue() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for (level, lift, fill) in safetyFills(s) {
            #expect((14...18).contains(Contrast.hslComponents(fill).h), "\(s) \(level) +\(lift)")
            if level == .safe { #expect(Contrast.isReservedOrange(fill), "\(s) safe +\(lift)") }
        }
        #expect((14...18).contains(Contrast.hslComponents(ChartPalette.hatch(s)).h), "\(s) hatch")
        #expect(Contrast.isReservedOrange(ChartPalette.hatch(s)))
    }
}

/// Hovering a safe or caution element shows (CIE76 > 5), and neither fill, resting or hovered, comes
/// within 1.3:1 of the background: the pale light caution stops lifting before it would fade into it.
@Test func safetyFillsStayVisibleOnTheBackgroundWhenHovered() throws {
    for s in [ChartPalette.Scheme.light, .dark] {
        for level in [SafetyLevel.safe, .caution] {
            let rest = try #require(ChartPalette.safetyFill(level, scheme: s))
            let hover = try #require(ChartPalette.safetyFill(level, scheme: s, lift: 12))
            #expect(Contrast.ratio(rest, ChartPalette.surface(s)) >= 1.3, "\(s) \(level) rest")
            #expect(Contrast.ratio(hover, ChartPalette.surface(s)) >= 1.3, "\(s) \(level) hovered")
            #expect(Contrast.deltaE(rest, hover) > 5, "\(s) \(level) hover shows")
        }
    }
}
