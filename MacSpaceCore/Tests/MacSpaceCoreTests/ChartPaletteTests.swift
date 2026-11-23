import Testing
@testable import MacSpaceCore

@Test func paletteAvoidsReservedOrange() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for c in FileCategory.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.category(c, scheme: s))) }
        for b in AgeBucket.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.age(b, scheme: s))) }
        for lift in [0.0, 12] { #expect(!Contrast.isReservedOrange(ChartPalette.mergedFill(scheme: s, lift: lift))) }
    }
}

/// Every fill the charts draw in the colored modes, resting and hovered: category fills at the
/// three ring depths, age fills and the merged "Altri" fill (which take no depth lift), each also
/// lifted by the +12 hover.
private func drawnFills(_ s: ChartPalette.Scheme) -> [Contrast.RGB] {
    var fills: [Contrast.RGB] = []
    for lift in [0.0, 12] {
        for c in FileCategory.allCases {
            for depth in [1.0, 2, 3] { fills.append(ChartPalette.categoryFill(c, scheme: s, depth: depth, lift: lift)) }
        }
        for b in AgeBucket.allCases { fills.append(ChartPalette.ageFill(b, scheme: s, lift: lift)) }
        fills.append(ChartPalette.mergedFill(scheme: s, lift: lift))
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

/// Ruling AF: a merged "Altri" element mixes types, so in "Per tipo di file" mode it must not read
/// as any category. Its fill, resting or hovered, stays at CIEDE2000 >= 10 from every category
/// fill at every depth the charts draw (fractional ones included, as animations blend levels),
/// resting or hovered, in both themes.
@Test func mergedFillIsDistinctFromEveryCategoryFill() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for mergedLift in [0.0, 12] {
            let merged = ChartPalette.mergedFill(scheme: s, lift: mergedLift)
            for c in FileCategory.allCases {
                for depth in stride(from: 1.0, through: 3, by: 0.25) {
                    for lift in [0.0, 12] {
                        let fill = ChartPalette.categoryFill(c, scheme: s, depth: depth, lift: lift)
                        let difference = Contrast.deltaE2000(merged, fill)
                        #expect(difference >= 10, "\(s) merged+\(mergedLift) vs \(c) d\(depth)+\(lift): \(difference)")
                    }
                }
            }
        }
    }
}

/// Hovering a merged element shows, as on every category fill.
@Test func hoverLiftIsVisibleOnTheMergedFill() {
    for s in [ChartPalette.Scheme.light, .dark] {
        #expect(Contrast.deltaE(ChartPalette.mergedFill(scheme: s), ChartPalette.mergedFill(scheme: s, lift: 12)) > 5)
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
