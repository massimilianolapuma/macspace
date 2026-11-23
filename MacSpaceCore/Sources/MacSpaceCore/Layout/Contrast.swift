import Foundation

/// WCAG 2 contrast arithmetic, used to pick legible text over chart fills.
public enum Contrast {
    /// sRGB components in 0...1.
    public struct RGB: Sendable, Equatable {
        public var r, g, b: Double
        public init(_ r: Double, _ g: Double, _ b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }
    }

    /// `h` in degrees, `s` and `l` in percent.
    public static func hsl(_ h: Double, _ s: Double, _ l: Double) -> RGB {
        let s = s / 100, l = l / 100
        let c = (1 - abs(2 * l - 1)) * s
        let hp = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r, g, b): (Double, Double, Double) = switch hp {
        case ..<1: (c, x, 0)
        case ..<2: (x, c, 0)
        case ..<3: (0, c, x)
        case ..<4: (0, x, c)
        case ..<5: (x, 0, c)
        default: (c, 0, x)
        }
        let m = l - c / 2
        return RGB(r + m, g + m, b + m)
    }

    public static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    public static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The `preferred` text color with the best contrast on `fill` if it reaches `minimum`;
    /// otherwise pure black or white, one of which always reaches about 4.58:1.
    public static func labelInk(on fill: RGB, preferred: [RGB], minimum: Double = 4.5) -> RGB {
        if let best = preferred.max(by: { ratio($0, fill) < ratio($1, fill) }), ratio(best, fill) >= minimum {
            return best
        }
        let white = RGB(1, 1, 1), black = RGB(0, 0, 0)
        return ratio(white, fill) >= ratio(black, fill) ? white : black
    }

    /// HSL of `c`: hue in degrees `0..<360` (0 for greys), saturation and lightness in percent.
    public static func hslComponents(_ c: RGB) -> (h: Double, s: Double, l: Double) {
        let high = max(c.r, c.g, c.b), low = min(c.r, c.g, c.b)
        let l = (high + low) / 2
        let d = high - low
        guard d > 1e-12 else { return (0, 0, l * 100) }
        let s = d / (1 - abs(2 * l - 1))
        var h = switch high {
        case c.r: ((c.g - c.b) / d).truncatingRemainder(dividingBy: 6)
        case c.g: (c.b - c.r) / d + 2
        default: (c.r - c.g) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, s * 100, l * 100)
    }

    /// HSL lightness of `c`, in percent.
    public static func lightness(_ c: RGB) -> Double { hslComponents(c).l }

    /// The "deletable" orange (spec §5.2): hue 5…30° with saturation above 50 %. Reserved for
    /// what can be removed, so no other chart color may fall in it.
    public static func isReservedOrange(_ c: RGB) -> Bool {
        let (h, s, _) = hslComponents(c)
        return (5...30).contains(h) && s > 50
    }

    /// CIE 1976 color difference: Euclidean distance in CIELAB (D65). Around 2 is barely
    /// noticeable; above 10 two fills read as different colors at a glance.
    public static func deltaE(_ a: RGB, _ b: RGB) -> Double {
        let (l1, a1, b1) = lab(a), (l2, a2, b2) = lab(b)
        return ((l1 - l2) * (l1 - l2) + (a1 - a2) * (a1 - a2) + (b1 - b2) * (b1 - b2)).squareRoot()
    }

    /// CIEDE2000 colour difference between `a` and `b` (kL = kC = kH = 1): closer to perceived
    /// difference than CIE76, especially for pale and dark tones.
    public static func deltaE2000(_ a: RGB, _ b: RGB) -> Double { deltaE2000(lab: lab(a), lab(b)) }

    /// CIEDE2000 between two CIELAB colours (Sharma, Wu & Dalal 2005).
    static func deltaE2000(lab first: (Double, Double, Double), _ second: (Double, Double, Double)) -> Double {
        let (l1, a1, b1) = first, (l2, a2, b2) = second
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        func deg(_ r: Double) -> Double { r * 180 / .pi }
        let pow25to7 = 6_103_515_625.0  // 25^7
        let cBar = ((a1 * a1 + b1 * b1).squareRoot() + (a2 * a2 + b2 * b2).squareRoot()) / 2
        let g = 0.5 * (1 - (pow(cBar, 7) / (pow(cBar, 7) + pow25to7)).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            guard b != 0 || a != 0 else { return 0 }
            let h = deg(atan2(b, a))
            return h < 0 ? h + 360 : h
        }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = l2 - l1, dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(rad(dhp / 2))
        let lBarP = (l1 + l2) / 2, cBarP = (c1p + c2p) / 2
        var hBarP = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) <= 180 { hBarP = (h1p + h2p) / 2 }
            else if h1p + h2p < 360 { hBarP = (h1p + h2p + 360) / 2 }
            else { hBarP = (h1p + h2p - 360) / 2 }
        }
        let t = 1 - 0.17 * cos(rad(hBarP - 30)) + 0.24 * cos(rad(2 * hBarP)) + 0.32 * cos(rad(3 * hBarP + 6))
            - 0.20 * cos(rad(4 * hBarP - 63))
        let dTheta = 30 * exp(-pow((hBarP - 275) / 25, 2))
        let rc = 2 * (pow(cBarP, 7) / (pow(cBarP, 7) + pow25to7)).squareRoot()
        let lOffset = (lBarP - 50) * (lBarP - 50)
        let sl = 1 + 0.015 * lOffset / (20 + lOffset).squareRoot()
        let sc = 1 + 0.045 * cBarP
        let sh = 1 + 0.015 * cBarP * t
        let rt = -sin(rad(2 * dTheta)) * rc
        let l = dLp / sl, c = dCp / sc, h = dHp / sh
        return (l * l + c * c + h * h + rt * c * h).squareRoot()
    }

    /// CIELAB (D65) of `c`: L 0…100, a and b roughly −128…127.
    static func lab(_ c: RGB) -> (Double, Double, Double) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = linear(c.r), g = linear(c.g), b = linear(c.b)
        // sRGB -> XYZ (D65), scaled by the white point.
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / 0.9504700
        let y = (0.2126729 * r + 0.7151522 * g + 0.0721750 * b) / 1.0000001
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / 1.0888300
        func f(_ t: Double) -> Double { t > 216.0 / 24389 ? cbrt(t) : (24389.0 / 27 * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }
}
