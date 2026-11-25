import MacSpaceCore
import SwiftUI

/// The marks "Eliminabili" adds on top of the fills, shared by both charts: hatch lines on caution
/// elements and the lock glyph on protected ones (spec §5.2: never color alone).
enum SafetyDecor {
    /// Hatch lines: 1.5 pt wide, at 45° (rising to the right), 6 pt apart.
    static let hatchWidth = 1.5, hatchSpacing = 6.0
    /// The lock is drawn only on an element at least this big in both directions (or in its label).
    static let lockMinSide = 18.0

    /// Strokes hatch lines over `path`, clipped to it. The lines lie on one grid for the whole
    /// canvas (`x + y` a multiple of `spacing·√2`), so neighbouring caution elements, and an element
    /// redrawn by a hover layer, line up. Builds lines only across `path`'s bounding box.
    static func hatch(in path: Path, color: Color, spacing: Double = hatchSpacing, lineWidth: Double = hatchWidth,
                      in context: GraphicsContext) {
        let box = path.boundingRect
        guard box.width >= 1, box.height >= 1, spacing > 0 else { return }
        let step = spacing * 2.squareRoot()  // along x, between lines `spacing` apart
        let first = Int(((box.minX + box.minY) / step).rounded(.down))
        let last = Int(((box.maxX + box.maxY) / step).rounded(.up))
        var lines = Path()
        for k in first...last {
            let d = Double(k) * step
            lines.move(to: CGPoint(x: d - box.minY + lineWidth, y: box.minY - lineWidth))
            lines.addLine(to: CGPoint(x: d - box.maxY - lineWidth, y: box.maxY + lineWidth))
        }
        var clipped = context
        clipped.clip(to: path)
        clipped.stroke(lines, with: .color(color), lineWidth: lineWidth)
    }

    /// Whether an element `width` × `height` pt has room for a standalone lock.
    static func fitsLock(width: Double, height: Double) -> Bool {
        width >= lockMinSide && height >= lockMinSide
    }

    /// The lock glyph (`lock.fill`, 9 pt) as it is drawn in a label, in `ink`.
    static func lockText(_ ink: Color) -> Text {
        Text(Image(systemName: "lock.fill")).font(.system(size: 9, weight: .semibold)).foregroundStyle(ink)
    }

    /// Draws standalone locks for one canvas pass, resolving the glyph once per ink (a chart has
    /// two or three inks), so a frame with many protected elements does not re-resolve it each time.
    struct Locks {
        private var resolved: [Color: GraphicsContext.ResolvedText] = [:]

        /// Draws the lock centered at `point` in `ink` (its opacity included).
        mutating func lock(at point: CGPoint, ink: Color, in context: GraphicsContext) {
            let glyph = resolved[ink] ?? context.resolve(SafetyDecor.lockText(ink))
            resolved[ink] = glyph
            context.draw(glyph, at: point, anchor: .center)
        }
    }
}

/// A safety level's marker for the legend and the list: a solid accent dot (safe), a soft dot with
/// hatch lines (caution), the lock (protected), or an empty slot of the same size (normal).
struct SafetySwatch: View {
    let level: SafetyLevel
    var diameter: Double = 9
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch level {
            case .safe:
                Circle().fill(FusionPalette.accent(scheme))
            case .caution:
                Canvas { context, size in
                    let dot = Path(ellipseIn: CGRect(origin: .zero, size: size))
                    context.fill(dot, with: .color(FusionPalette.cautionFill(scheme)))
                    // Scaled down with the dot: two or three lines still read as hatching.
                    SafetyDecor.hatch(in: dot, color: FusionPalette.hatch(scheme), spacing: size.width / 3.2,
                                      lineWidth: 1, in: context)
                }
            case .protected:
                Image(systemName: "lock.fill")
                    .font(.system(size: diameter, weight: .semibold))
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
            case .normal:
                Color.clear
            }
        }
        .overlay {
            if level == .safe || level == .caution {
                Circle().strokeBorder(FusionPalette.swatchRing(scheme), lineWidth: 0.5)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}
