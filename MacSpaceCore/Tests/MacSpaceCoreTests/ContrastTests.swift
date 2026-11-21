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
