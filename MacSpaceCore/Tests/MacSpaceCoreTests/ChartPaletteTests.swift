import Testing
@testable import MacSpaceCore

@Test func paletteAvoidsReservedOrange() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for c in FileCategory.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.category(c, scheme: s))) }
        for b in AgeBucket.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.age(b, scheme: s))) }
    }
}

@Test func everyFillTakesAnAALabel() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for c in FileCategory.allCases { #expect(Contrast.bestLabelRatio(on: ChartPalette.category(c, scheme: s)) >= 4.5) }
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
