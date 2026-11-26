import Testing
@testable import MacSpaceCore

@Test func contrastMatchesWCAGReferencePairs() {
    let white = Contrast.RGB(1, 1, 1), black = Contrast.RGB(0, 0, 0)
    #expect(abs(Contrast.ratio(white, black) - 21) < 0.01)
    #expect(abs(Contrast.ratio(white, white) - 1) < 0.0001)
    // #767676 on white is the classic 4.54:1 pair.
    let grey = Contrast.RGB(0x76 / 255.0, 0x76 / 255.0, 0x76 / 255.0)
    #expect(abs(Contrast.ratio(grey, white) - 4.54) < 0.01)
}

@Test func hslConvertsToRGB() {
    let red = Contrast.hsl(0, 100, 50)
    #expect(abs(red.r - 1) < 1e-9 && red.g < 1e-9 && red.b < 1e-9)
    let grey = Contrast.hsl(240, 0, 50)
    #expect(abs(grey.r - 0.5) < 1e-9 && abs(grey.g - 0.5) < 1e-9 && abs(grey.b - 0.5) < 1e-9)
}

@Test func labelInkReachesAAOnEveryRingFill() {
    let lightInk = Contrast.RGB(0x1F / 255.0, 0x1B / 255.0, 0x16 / 255.0)
    let darkInk = Contrast.RGB(0x1C / 255.0, 0x1C / 255.0, 0x1E / 255.0)
    // Fusion ring fills (spec §5.2) including the hover lift: sand hsl(30,10%,34…92%),
    // graphite hsl(240,4%,26…70%), in 0.5% steps.
    for (hue, sat, low, high, ink) in [(30.0, 10.0, 34.0, 92.0, lightInk), (240.0, 4.0, 26.0, 70.0, darkInk)] {
        var l = low
        while l <= high {
            let fill = Contrast.hsl(hue, sat, l)
            let chosen = Contrast.labelInk(on: fill, preferred: [Contrast.RGB(1, 1, 1), ink])
            #expect(Contrast.ratio(chosen, fill) >= 4.5, "hsl(\(hue),\(sat),\(l))")
            l += 0.5
        }
    }
}

@Test func colorHelpersMatchReferenceValues() {
    let white = Contrast.RGB(1, 1, 1), black = Contrast.RGB(0, 0, 0)
    #expect(abs(Contrast.deltaE(white, black) - 100) < 0.01)
    #expect(Contrast.deltaE(white, white) == 0)
    // A chromatic reference: sRGB red is Lab (53.24, 80.09, 67.20).
    let red = Contrast.lab(Contrast.RGB(1, 0, 0))
    #expect(abs(red.0 - 53.24) < 0.01 && abs(red.1 - 80.09) < 0.01 && abs(red.2 - 67.20) < 0.01)
    #expect(abs(Contrast.lightness(Contrast.hsl(30, 10, 34)) - 34) < 1e-9)
    let (h, s, l) = Contrast.hslComponents(Contrast.hsl(212, 40, 61))
    #expect(abs(h - 212) < 1e-9 && abs(s - 40) < 1e-9 && abs(l - 61) < 1e-9)
    // The "deletable" accent is the reserved orange; muted browns and other hues are not.
    #expect(Contrast.isReservedOrange(Contrast.hsl(16, 88, 57)))
    #expect(!Contrast.isReservedOrange(Contrast.hsl(16, 40, 57)))
    #expect(!Contrast.isReservedOrange(Contrast.hsl(45, 88, 57)))
}

/// CIEDE2000 against Sharma, Wu & Dalal (2005) reference pairs.
@Test func deltaE2000MatchesReferencePairs() {
    let pairs: [((Double, Double, Double), (Double, Double, Double), Double)] = [
        ((50, 2.6772, -79.7751), (50, 0, -82.7485), 2.0425),
        ((50, 0, 0), (50, -1, 2), 2.3669),
        ((50, 2.5, 0), (73, 25, -18), 27.1492),
        ((60.2574, -34.0099, 36.2677), (60.4626, -34.1751, 39.4387), 1.2644),
        ((22.7233, 20.0904, -46.6940), (23.0331, 14.9730, -42.5619), 2.0373),
    ]
    for (a, b, expected) in pairs {
        #expect(abs(Contrast.deltaE2000(lab: a, b) - expected) < 0.0005, "\(a) \(b)")
        #expect(abs(Contrast.deltaE2000(lab: b, a) - expected) < 0.0005)
    }
    #expect(Contrast.deltaE2000(Contrast.RGB(1, 1, 1), Contrast.RGB(1, 1, 1)) == 0)
}
