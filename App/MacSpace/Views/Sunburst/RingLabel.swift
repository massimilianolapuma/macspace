import MacSpaceCore
import SwiftUI

/// A placed label's rotated bounding box.
private struct LabelBox {
    let center: CGPoint
    let rotation: Double
    let halfWidth: Double
    let halfHeight: Double

    private var axes: [CGVector] {
        [CGVector(dx: cos(rotation), dy: sin(rotation)), CGVector(dx: -sin(rotation), dy: cos(rotation))]
    }

    /// Separating-axis test between two rotated rectangles.
    func overlaps(_ other: LabelBox) -> Bool {
        let d = CGVector(dx: other.center.x - center.x, dy: other.center.y - center.y)
        for axis in axes + other.axes {
            let distance = abs(d.dx * axis.dx + d.dy * axis.dy)
            if distance > projectedRadius(on: axis) + other.projectedRadius(on: axis) { return false }
        }
        return true
    }

    private func projectedRadius(on axis: CGVector) -> Double {
        let (u, v) = (axes[0], axes[1])
        return halfWidth * abs(u.dx * axis.dx + u.dy * axis.dy) + halfHeight * abs(v.dx * axis.dx + v.dy * axis.dy)
    }
}

/// A segment's label, fitted once per chart generation against its arc's target pose: the name
/// (truncated with "…" if needed) and, when both lines fit, the size below it.
struct LabelPlan {
    let name: FittedText
    let size: FittedText?
    let locked: Bool

    /// Room kept before the name for the lock glyph.
    var lockRoom: Double { locked ? 14 : 0 }
}

/// Ring labels as straight text along the ring. Each line is fitted to the room at the radius
/// where it sits: within the segment's angle at the line's inner edge, and inside the ring where
/// its ends bow outwards. Labels are fitted when the chart changes (`LabelPlanner`); per frame
/// they are only positioned, shown once their arc has room for them, and skipped when their box
/// would touch one already placed.
enum RingLabel {
    static let nameFont = Font.system(size: 11, weight: .semibold)
    static let sizeFont = Font.system(size: 10).monospacedDigit()
    /// Half heights of the label lines and their offsets from the ring's mid radius.
    static let nameHalf = 7.0, sizeHalf = 6.5, nameOffset = 6.5, sizeOffset = 7.0

    /// A label positioned for one frame.
    struct Placed {
        let id: String
        let segment: ArcSegment
        let plan: LabelPlan
        let pose: ArcPose
        let point: CGPoint
        let rotation: Double
    }

    /// The straight-line room an arc posed at `pose` offers; nil when it is too small for any label.
    struct Room {
        let inner: Double
        let outer: Double
        let span: Double
        let mid: Double
        /// Local "up" points outwards on the top half and inwards on the flipped bottom half.
        let outward: Double

        init?(_ pose: ArcPose, geometry: ChartGeometry) {
            inner = geometry.innerRadius(depth: pose.depth)
            outer = inner + geometry.ringWidth
            guard inner >= geometry.centerRadius - 0.5, outer <= geometry.radius + 0.5 else { return nil }
            span = pose.end - pose.start
            mid = inner + geometry.ringWidth / 2
            guard mid * span >= 60 else { return nil }
            let midAngle = (pose.start + pose.end) / 2
            outward = midAngle > .pi / 2 && midAngle < 3 * .pi / 2 ? -1 : 1
        }

        /// Widest straight line centered on the mid angle at radius `r` with half height `h`.
        func width(_ r: Double, _ h: Double) -> Double {
            guard r - h >= inner + 2 else { return 0 }
            let angular = span / 2 >= .pi / 2 - 0.05 ? .infinity : 2 * ((r - h) * tan(span / 2) - 4)
            let bowLimit = (outer - 3) * (outer - 3) - (r + h) * (r + h)
            let bow = bowLimit > 0 ? 2 * bowLimit.squareRoot() : 0
            return min(angular, bow, 200)
        }

        var nameLine: Double { width(mid + outward * RingLabel.nameOffset, RingLabel.nameHalf) }
        var sizeLine: Double { width(mid - outward * RingLabel.sizeOffset, RingLabel.sizeHalf) }
        var singleLine: Double { width(mid, RingLabel.nameHalf) }

        func fits(_ plan: LabelPlan) -> Bool {
            if let size = plan.size {
                return nameLine - plan.lockRoom >= plan.name.width && sizeLine >= size.width
            }
            return singleLine - plan.lockRoom >= plan.name.width
        }
    }

    /// Labels of the current arcs in draw order, placed without collisions; stops after the arc
    /// `through` when given.
    @MainActor
    static func place(_ poses: [(arc: SunburstMotion.Arc, pose: ArcPose)], geometry: ChartGeometry,
                      planner: LabelPlanner, in context: GraphicsContext, through stop: String? = nil) -> [Placed] {
        var placed: [Placed] = []
        var boxes: [LabelBox] = []
        for (arc, pose) in poses where arc.isCurrent {
            if let label = place(arc, pose: pose, geometry: geometry, planner: planner, context: context, boxes: &boxes) {
                placed.append(label)
            }
            if arc.segment.id == stop { break }
        }
        return placed
    }

    @MainActor
    private static func place(_ arc: SunburstMotion.Arc, pose: ArcPose, geometry: ChartGeometry,
                              planner: LabelPlanner, context: GraphicsContext, boxes: inout [LabelBox]) -> Placed? {
        guard pose.alpha > 0.5, geometry.drawableInner(pose) != nil, let room = Room(pose, geometry: geometry),
              let plan = planner.plan(for: arc, geometry: geometry, in: context),
              room.fits(plan)  // fitted for the target pose: an arc still growing towards it waits
        else { return nil }
        let midAngle = (pose.start + pose.end) / 2
        let point = geometry.point(angle: midAngle, radius: room.mid)
        let rotation = room.outward < 0 ? midAngle + .pi : midAngle
        let box = LabelBox(center: point, rotation: rotation,
                           halfWidth: max(plan.name.width + plan.lockRoom, plan.size?.width ?? 0) / 2 + 2,
                           halfHeight: plan.size != nil ? nameOffset + nameHalf : nameHalf)
        guard !boxes.contains(where: { $0.overlaps(box) }) else { return nil }
        boxes.append(box)
        return Placed(id: arc.segment.id, segment: arc.segment, plan: plan, pose: pose, point: point,
                      rotation: rotation)
    }

    static func draw(_ label: Placed, ink: Color, in context: GraphicsContext) {
        var c = context
        c.opacity = label.pose.alpha
        c.translateBy(x: label.point.x, y: label.point.y)
        c.rotate(by: .radians(label.rotation))
        let plan = label.plan
        let nameY = plan.size != nil ? -nameOffset : 0
        let name = c.resolve(Text(verbatim: plan.name.string).font(nameFont).foregroundStyle(ink))
        if plan.locked {
            // Lock glyph before the name; the pair stays centered.
            let lock = c.resolve(Text(Image(systemName: "lock.fill")).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ink))
            c.draw(lock, at: CGPoint(x: -(plan.name.width + plan.lockRoom) / 2 + 5, y: nameY), anchor: .center)
            c.draw(name, at: CGPoint(x: plan.lockRoom / 2, y: nameY), anchor: .center)
        } else {
            c.draw(name, at: CGPoint(x: 0, y: nameY), anchor: .center)
        }
        if let size = plan.size {
            c.draw(Text(verbatim: size.string).font(sizeFont).foregroundStyle(ink),
                   at: CGPoint(x: 0, y: sizeOffset), anchor: .center)
        }
    }
}

/// Fits labels once per chart generation (each retarget starts one) against their arcs' target
/// poses, so animation frames only position them. Fitted strings are kept for one more
/// generation, so a refresh re-measures only the labels whose text or room changed; the caches
/// never hold more than two generations' labels.
@MainActor
final class LabelPlanner {
    private enum Line: Hashable { case name, size }

    private var generation = -1
    private var size = CGSize.zero
    private var plans: [String: LabelPlan?] = [:]
    private let fitter = TextFitter<Line>(
        text: { string, line in Text(verbatim: string).font(line == .name ? RingLabel.nameFont : RingLabel.sizeFont) },
        truncates: { $0 == .name })

    /// Starts a new generation when the arcs or the chart size changed.
    func prepare(generation: Int, size: CGSize) {
        guard generation != self.generation || size != self.size else { return }
        self.generation = generation
        self.size = size
        plans.removeAll(keepingCapacity: true)
        fitter.newGeneration()
    }

    /// The label for `arc`, fitted against its target pose; nil when nothing useful fits.
    func plan(for arc: SunburstMotion.Arc, geometry: ChartGeometry, in context: GraphicsContext) -> LabelPlan? {
        if let plan = plans[arc.segment.id] { return plan }
        let plan = makePlan(arc.segment, target: arc.to, geometry: geometry, context: context)
        plans[arc.segment.id] = plan
        return plan
    }

    private func makePlan(_ segment: ArcSegment, target: ArcPose, geometry: ChartGeometry,
                          context: GraphicsContext) -> LabelPlan? {
        guard let room = RingLabel.Room(target, geometry: geometry) else { return nil }
        let locked = segment.flags.contains(.unreadable)
        let lockRoom = locked ? 14.0 : 0
        let title = SunburstView.title(of: segment)
        if geometry.ringWidth >= 34,
           let name = fitted(title, width: room.nameLine - lockRoom, line: .name, in: context),
           let size = fitted(Formatters.bytes(segment.size), width: room.sizeLine, line: .size, in: context) {
            return LabelPlan(name: name, size: size, locked: locked)
        }
        guard let name = fitted(title, width: room.singleLine - lockRoom, line: .name, in: context) else { return nil }
        return LabelPlan(name: name, size: nil, locked: locked)
    }

    private func fitted(_ string: String, width: Double, line: Line, in context: GraphicsContext) -> FittedText? {
        fitter.fitted(string, width: width, line: line, in: context)
    }
}
