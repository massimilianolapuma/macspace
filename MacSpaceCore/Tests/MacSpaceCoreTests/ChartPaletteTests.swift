import Testing
@testable import MacSpaceCore

@Test func paletteAvoidsReservedOrange() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for c in FileCategory.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.category(c, scheme: s))) }
        for b in AgeBucket.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.age(b, scheme: s))) }
        for surface in mergedSurfaces(s) {
            for lift in [0.0, 12] {
                #expect(!Contrast.isReservedOrange(ChartPalette.mergedFill(on: surface, scheme: s, lift: lift)))
                #expect(!Contrast.isReservedOrange(ChartPalette.mergedOutline(on: surface, scheme: s, lift: lift)))
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
            for lift in [0.0, 12] {
                let outline = ChartPalette.mergedOutline(on: surface, scheme: s, lift: lift)
                #expect(Contrast.ratio(outline, surface) >= 3, "\(s) outline+\(lift) vs surface \(surface)")
                for fillLift in Set([0, lift]) {
                    let fill = ChartPalette.mergedFill(on: surface, scheme: s, lift: fillLift)
                    #expect(Contrast.ratio(outline, fill) >= 3, "\(s) outline+\(lift) vs fill+\(fillLift) on \(surface)")
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
                    let outline = ChartPalette.mergedOutline(on: rest, scheme: s)
                    #expect(Contrast.ratio(outline, hovered) >= 3, "\(s) \(c) d\(depth) on \(base)")
                }
            }
        }
    }
}

/// The outline is a Fusion neutral, not a hue: nothing about "many small mixed items" is a type.
@Test func mergedOutlineIsNeutral() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for surface in mergedSurfaces(s) {
            for lift in [0.0, 12] {
                #expect(Contrast.hslComponents(ChartPalette.mergedOutline(on: surface, scheme: s, lift: lift)).s <= 10.5)
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
            for lift in [0.0, 12] {
                let fill = ChartPalette.mergedFill(on: surface, scheme: s, lift: lift)
                #expect(Contrast.ratio(ChartPalette.labelInk(on: fill, scheme: s), fill) >= 4.5, "\(fill)")
            }
        }
    }
}

/// Hovering a merged element shows, as on every category fill.
@Test func hoverLiftIsVisibleOnTheMergedFill() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for surface in mergedSurfaces(s) {
            let rest = ChartPalette.mergedFill(on: surface, scheme: s)
            #expect(Contrast.deltaE(rest, ChartPalette.mergedFill(on: surface, scheme: s, lift: 12)) > 5)
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
