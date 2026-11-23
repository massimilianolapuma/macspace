import SwiftUI

/// The dashed line that marks a merged "Altri N elementi" element in "by file type" mode (Rulings
/// AG, AH): 1 pt, dashes of about 3 pt with 2 pt gaps on a closed outline, the period fitted so a
/// whole number of dashes runs around it (no stub where the path closes). It is drawn 1 pt inside
/// the element's edge, so the 1 pt separators between sunburst arcs never cover it.
///
/// Small elements keep a mark rather than turning into bare gaps:
/// - tiles from `minTileSide` to `fineTileSide` take a finer period (about 2–1), so each side still
///   gets two or more dashes;
/// - arcs from `minArcWidth` to `midlineArcWidth` wide (at their inner radius) take one dashed line
///   along their angular midline instead of an outline, whose two radial sides would sit 1–2 pt
///   apart;
/// - narrower arcs keep their bare fill.
enum MergedOutline {
    /// Tiles are drawn from this short side (`TreemapCanvas.minDrawnSide`); under it (only in
    /// passing, while animating) they get no line.
    static let minTileSide = TreemapCanvas.minDrawnSide
    /// Tiles with a short side under this take the fine period.
    static let fineTileSide = 10.0
    /// Arcs narrower than this at their inner radius keep their bare fill.
    static let minArcWidth = 1.5
    /// Arcs narrower than this at their inner radius take the midline instead of the outline.
    static let midlineArcWidth = 8.0

    private static let lineWidth = 1.0
    /// Distance from an arc's edges to the line's center: the separator covers the outer 0.5 pt,
    /// the line covers 0.5…1.5 pt inside.
    private static let arcInset = 1.0
    private static let period = 5.0, dashShare = 0.6
    private static let finePeriod = 3.0, fineDashShare = 2.0 / 3

    /// The stroke for a closed line of length `perimeter`: a whole number of periods of about
    /// `period` (5 pt: 3–2, or 3 pt: 2–1 for the fine one).
    static func style(perimeter: Double, fine: Bool = false) -> StrokeStyle {
        let (target, share) = fine ? (finePeriod, fineDashShare) : (period, dashShare)
        let fitted = perimeter / max((perimeter / target).rounded(), 1)
        return StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .round,
                           dash: [fitted * share, fitted * (1 - share)])
    }

    /// The stroke for an open line of `length`: whole dashes at both ends, gaps between.
    private static func openStyle(length: Double) -> StrokeStyle {
        let dashes = max(((length + period * (1 - dashShare)) / period).rounded(), 1)
        let fitted = length / (dashes - (1 - dashShare))
        return StrokeStyle(lineWidth: lineWidth, lineCap: .butt, dash: [fitted * dashShare, fitted * (1 - dashShare)])
    }

    /// Strokes the outline of a treemap tile drawn at `rect` with corner `radius`. The line is
    /// snapped inward to the device pixel grid (`scale` pixels per point), so it lands on whole
    /// pixels and stays crisp, and it follows the tile's rounded corners.
    static func strokeTile(_ rect: CGRect, radius: Double, color: Color, scale: Double, in context: GraphicsContext) {
        let shortSide = min(rect.width, rect.height)
        guard shortSide >= minTileSide else { return }
        let scale = max(scale, 1)
        let minX = (rect.minX * scale).rounded(.up) / scale, maxX = (rect.maxX * scale).rounded(.down) / scale
        let minY = (rect.minY * scale).rounded(.up) / scale, maxY = (rect.maxY * scale).rounded(.down) / scale
        let line = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard line.width > 0, line.height > 0 else { return }
        let r = max(min(radius - lineWidth / 2, min(line.width, line.height) / 2), 0)
        let perimeter = 2 * (line.width + line.height) - (8 - 2 * .pi) * r
        context.stroke(Path(roundedRect: line, cornerRadius: r, style: .continuous), with: .color(color),
                       style: style(perimeter: perimeter, fine: shortSide < fineTileSide))
    }

    /// Strokes the mark of a sunburst arc between radii `inner` and `outer` from `start` to `end`
    /// (radians from 12 o'clock, clockwise): its outline 1 pt inside its edges (the radial sides
    /// parallel to the arc's), or for a narrow arc one line along its angular midline.
    static func strokeArc(center: CGPoint, inner: Double, outer: Double, start: Double, end: Double, color: Color,
                          in context: GraphicsContext) {
        let r0 = max(inner, 0) + arcInset, r1 = outer - arcInset
        let width = max(inner, 0) * (end - start)
        guard r1 - r0 > 2 * arcInset, width >= minArcWidth else { return }
        if width < midlineArcWidth {
            let mid = (start + end) / 2 - .pi / 2
            var path = Path()
            path.move(to: CGPoint(x: center.x + r0 * cos(mid), y: center.y + r0 * sin(mid)))
            path.addLine(to: CGPoint(x: center.x + r1 * cos(mid), y: center.y + r1 * sin(mid)))
            context.stroke(path, with: .color(color), style: openStyle(length: r1 - r0))
        } else if end - start >= 2 * .pi - 1e-6 {
            // Two closed rings, each with its own whole number of dashes (a dash pattern restarts
            // on every subpath, so one path for both would leave a stub on one of them).
            for r in [r1, r0] {
                context.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(color), style: style(perimeter: 2 * .pi * r))
            }
        } else {
            // At radius r, a point `arcInset` away from a radial side lies asin(arcInset / r) inside it.
            let in1 = asin(min(arcInset / r1, 1)), in0 = asin(min(arcInset / r0, 1))
            guard end - start > 2 * in0 else { return }
            let a0 = start - .pi / 2, a1 = end - .pi / 2
            var path = Path()
            path.addArc(center: center, radius: r1, startAngle: .radians(a0 + in1), endAngle: .radians(a1 - in1),
                        clockwise: false)
            path.addArc(center: center, radius: r0, startAngle: .radians(a1 - in0), endAngle: .radians(a0 + in0),
                        clockwise: true)
            path.closeSubpath()
            let perimeter = r1 * (end - start - 2 * in1) + r0 * (end - start - 2 * in0)
                + 2 * (r1 * cos(in1) - r0 * cos(in0))
            context.stroke(path, with: .color(color), style: style(perimeter: perimeter))
        }
    }
}
