import SwiftUI

/// Radii of the chart in a given size: center hole 0.30·R, three rings sharing the rest.
struct ChartGeometry {
    let size: CGSize
    let center: CGPoint
    let radius: Double
    let centerRadius: Double
    let ringWidth: Double

    init(size: CGSize) {
        self.size = size
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        radius = max(min(size.width, size.height) / 2 - 16, 40)
        centerRadius = 0.30 * radius
        ringWidth = 0.70 * radius / 3
    }

    var centerFontSize: Double { min(max(centerRadius * 0.24, 17), 30) }

    /// The ring band, for an even-odd clip: arcs animating past the rings are cut off.
    var band: Path {
        var band = Path(ellipseIn: rect(radius: radius))
        band.addPath(Path(ellipseIn: rect(radius: centerRadius)))
        return band
    }

    func innerRadius(depth: Double) -> Double { centerRadius + (depth - 1) * ringWidth }

    /// Inner radius of an arc worth drawing at `pose`; nil when it is invisible or off the band.
    func drawableInner(_ pose: ArcPose) -> Double? {
        guard pose.alpha > 0.01, pose.end - pose.start > 0.0004 else { return nil }
        let inner = innerRadius(depth: pose.depth)
        guard inner + ringWidth > centerRadius, inner < radius else { return nil }
        return inner
    }

    /// Hairline slivers get no separator of their own: a run of them reads as one tone instead
    /// of a white blur.
    func hasSeparator(_ pose: ArcPose, inner: Double) -> Bool {
        (inner + ringWidth) * (pose.end - pose.start) >= 4
    }

    func rect(radius: Double) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
    }

    func point(angle: Double, radius: Double) -> CGPoint {
        CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
    }
}
