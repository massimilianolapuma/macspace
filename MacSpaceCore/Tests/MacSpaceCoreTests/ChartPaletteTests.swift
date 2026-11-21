import Testing
@testable import MacSpaceCore

@Test func paletteAvoidsReservedOrange() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for c in FileCategory.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.category(c, scheme: s))) }
        for b in AgeBucket.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.age(b, scheme: s))) }
    }
}

/// Every fill the charts draw in the colored modes, resting and hovered: category fills at the
/// three ring depths, age fills (which take no depth lift), each also lifted by the +12 hover.
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
