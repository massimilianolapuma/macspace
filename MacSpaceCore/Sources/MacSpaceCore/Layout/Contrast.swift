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
}
