import MacSpaceCore
import Synchronization
import SwiftUI

/// The marks "Eliminabili" adds on top of the fills, shared by both charts: hatch lines on caution
/// elements and the lock glyph on protected ones (spec §5.2: never color alone).
enum SafetyDecor {
    /// Hatch lines: 1.5 pt wide, at 45° (rising to the right), 6 pt apart.
    static let hatchWidth = 1.5, hatchSpacing = 6.0
    /// The lock is drawn only on an element at least this big in both directions (or in its label).
    static let lockMinSide = 18.0

    /// Strokes the chart hatch over `path`, clipped to it: the canvas-wide line field for `canvas`
    /// (built once per canvas size, then reused by every caution element and frame), so neighbouring
    /// caution elements, and an element redrawn by a hover layer, line up.
    static func hatch(in path: Path, color: Color, canvas: CGSize, in context: GraphicsContext) {
        var clipped = context
        clipped.clip(to: path)
        clipped.stroke(hatchField(canvas), with: .color(color), lineWidth: hatchWidth)
    }

    /// The canvas-wide hatch lines (`x + y` a multiple of `hatchSpacing·√2`) covering `size`, cached
    /// for the last size asked for. Charts draw asynchronously, off the main thread: hence the lock.
    private static func hatchField(_ size: CGSize) -> Path {
        fieldCache.withLock { cache in
            if let cache, cache.size == size { return cache.path }
            let path = lines(across: CGRect(origin: .zero, size: size), spacing: hatchSpacing, lineWidth: hatchWidth)
            cache = (size, path)
            return path
        }
    }
    private static let fieldCache = Mutex<(size: CGSize, path: Path)?>(nil)

    /// Strokes hatch lines `spacing` apart over `path`, clipped to it, built across its bounding box:
    /// for one-off small marks (legend and list swatches).
    static func hatch(in path: Path, color: Color, spacing: Double, lineWidth: Double, in context: GraphicsContext) {
        let box = path.boundingRect
        guard box.width >= 1, box.height >= 1, spacing > 0 else { return }
        var clipped = context
        clipped.clip(to: path)
        clipped.stroke(lines(across: box, spacing: spacing, lineWidth: lineWidth), with: .color(color),
                       lineWidth: lineWidth)
    }

    /// Lines at 45° (`x + y` a multiple of `spacing·√2`, so `spacing` apart) across `box`.
    private static func lines(across box: CGRect, spacing: Double, lineWidth: Double) -> Path {
        let step = spacing * 2.squareRoot()  // along x, between lines `spacing` apart
        let first = Int(((box.minX + box.minY) / step).rounded(.down))
        let last = Int(((box.maxX + box.maxY) / step).rounded(.up))
        var lines = Path()
        guard first <= last else { return lines }
        for k in first...last {
            let d = Double(k) * step
            lines.move(to: CGPoint(x: d - box.minY + lineWidth, y: box.minY - lineWidth))
            lines.addLine(to: CGPoint(x: d - box.maxY - lineWidth, y: box.maxY + lineWidth))
        }
        return lines
    }

    /// How a chart element is marked: picked for the Trash, or one of the items of the suggestion
    /// whose header was clicked.
    enum Mark {
        case selected, highlighted

        /// 2 pt for a selected element; the same ink lighter, 1.5 pt, for a highlighted one.
        var lineWidth: Double { self == .selected ? 2 : 1.5 }
        /// How wide the mark is drawn in all: a highlighted line is cased in the background tone,
        /// so it stays legible on solid orange and on hatching, and never looks like a selection.
        var extent: Double { self == .selected ? 2 : 4 }
    }

    /// Strokes `path`'s outline in the primary text color, the same in both charts; a highlighted
    /// one over a casing in the background tone.
    static func selectionOutline(_ path: Path, mark: Mark, alpha: Double = 1, scheme: ColorScheme,
                                 in context: GraphicsContext) {
        let style = { (width: Double) in StrokeStyle(lineWidth: width, lineJoin: .round) }
        if mark == .highlighted {
            context.stroke(path, with: .color(FusionPalette.background(scheme).opacity(0.9 * alpha)),
                           style: style(mark.extent))
        }
        context.stroke(path, with: .color(FusionPalette.primaryText(scheme).opacity(alpha)),
                       style: style(mark.lineWidth))
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
    /// two or three), so a frame with many protected elements does not re-resolve it each time.
    struct Locks {
        private var resolved: [Color: GraphicsContext.ResolvedText] = [:]

        /// Draws the lock centered at `point` in `ink` (opaque), faded to `alpha`.
        mutating func lock(at point: CGPoint, ink: Color, alpha: Double, in context: GraphicsContext) {
            let glyph = resolved[ink] ?? context.resolve(SafetyDecor.lockText(ink))
            resolved[ink] = glyph
            var faded = context
            faded.opacity *= alpha
            faded.draw(glyph, at: point, anchor: .center)
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
