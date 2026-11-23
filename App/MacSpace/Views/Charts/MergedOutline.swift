import SwiftUI

/// The dashed outline that marks a merged "Altri N elementi" element in "by file type" mode
/// (Ruling AG): 1 pt, dashes of about 3 pt with 2 pt gaps, the period fitted so a whole number of
/// dashes runs around the shape (no stub where the path closes). It is drawn 1 pt inside the
/// element's edge, so the 1 pt separators between sunburst arcs never cover it.
enum MergedOutline {
    /// Tiles whose short side is under this get no outline: fewer than two dashes per side read as
    /// specks, not as an outline.
    static let minSide = 10.0
    /// Arcs narrower than this at their inner radius get no outline. An arc's radial sides run a
    /// whole ring wide, so even a narrow arc carries its dashes; under this the two lines would
    /// touch.
    static let minArcWidth = 4.0

    private static let lineWidth = 1.0
    private static let period = 5.0
    private static let dashShare = 0.6

    /// The stroke for a closed outline of length `perimeter`.
    static func style(perimeter: Double) -> StrokeStyle {
        let fitted = perimeter / max((perimeter / period).rounded(), 1)
        return StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .round,
                           dash: [fitted * dashShare, fitted * (1 - dashShare)])
    }

    /// Strokes the outline of a treemap tile drawn at `rect` with corner `radius`. The line is
    /// snapped inward to the device pixel grid (`scale` pixels per point), so it lands on whole
    /// pixels and stays crisp, and it follows the tile's rounded corners.
    static func strokeTile(_ rect: CGRect, radius: Double, color: Color, scale: Double, in context: GraphicsContext) {
        let scale = max(scale, 1)
        let minX = (rect.minX * scale).rounded(.up) / scale, maxX = (rect.maxX * scale).rounded(.down) / scale
        let minY = (rect.minY * scale).rounded(.up) / scale, maxY = (rect.maxY * scale).rounded(.down) / scale
        let line = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        guard min(line.width, line.height) + lineWidth >= minSide else { return }
        let r = max(min(radius - lineWidth / 2, min(line.width, line.height) / 2), 0)
        let perimeter = 2 * (line.width + line.height) - (8 - 2 * .pi) * r
        context.stroke(Path(roundedRect: line, cornerRadius: r, style: .continuous), with: .color(color),
                       style: style(perimeter: perimeter))
    }

    /// Strokes the outline of a sunburst arc between radii `inner` and `outer` from `start` to
    /// `end` (radians from 12 o'clock, clockwise), 1 pt inside its edges: the radial sides are
    /// parallel to the arc's, offset by the same distance as the curved ones.
    static func strokeArc(center: CGPoint, inner: Double, outer: Double, start: Double, end: Double, color: Color,
                          in context: GraphicsContext) {
        let offset = 1.0  // the separator covers the outer 0.5 pt; the line covers 0.5…1.5 pt inside
        let r0 = max(inner, 0) + offset, r1 = outer - offset
        guard r1 - r0 >= minSide - 2 * offset, max(inner, 0) * (end - start) >= minArcWidth else { return }
        var path = Path()
        let perimeter: Double
        if end - start >= 2 * .pi - 1e-6 {
            path.addEllipse(in: CGRect(x: center.x - r1, y: center.y - r1, width: 2 * r1, height: 2 * r1))
            path.addEllipse(in: CGRect(x: center.x - r0, y: center.y - r0, width: 2 * r0, height: 2 * r0))
            // Two closed rings: fit the dashes to the longer one, the shorter differs by a fraction.
            perimeter = 2 * .pi * r1
        } else {
            // At radius r, a point `offset` away from a radial side lies asin(offset / r) inside it.
            let in1 = asin(min(offset / r1, 1)), in0 = asin(min(offset / r0, 1))
            guard end - start > 2 * in0 else { return }
            let a0 = start - .pi / 2, a1 = end - .pi / 2
            path.addArc(center: center, radius: r1, startAngle: .radians(a0 + in1), endAngle: .radians(a1 - in1),
                        clockwise: false)
            path.addArc(center: center, radius: r0, startAngle: .radians(a1 - in0), endAngle: .radians(a0 + in0),
                        clockwise: true)
            path.closeSubpath()
            perimeter = r1 * (end - start - 2 * in1) + r0 * (end - start - 2 * in0)
                + 2 * (r1 * cos(in1) - r0 * cos(in0))
        }
        context.stroke(path, with: .color(color), style: style(perimeter: perimeter))
    }
}
