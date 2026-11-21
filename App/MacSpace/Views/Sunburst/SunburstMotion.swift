import Foundation
import MacSpaceCore
import SwiftUI

/// Where an arc is drawn: angles in radians (0 = 12 o'clock, clockwise) and `depth` in rings
/// (1 = innermost). While animating, depth is fractional and may leave the 1...3 band, where
/// the chart clips it. `shadeDepth`/`shadeStep` feed `FusionPalette.ringLightness`, so fills
/// blend when an arc changes ring.
struct ArcPose: Equatable {
    var start: Double
    var end: Double
    var depth: Double
    var alpha: Double
    var shadeDepth: Double
    var shadeStep: Double

    func mixed(with other: ArcPose, _ t: Double) -> ArcPose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        return ArcPose(start: mix(start, other.start), end: mix(end, other.end), depth: mix(depth, other.depth),
                       alpha: mix(alpha, other.alpha), shadeDepth: mix(shadeDepth, other.shadeDepth),
                       shadeStep: mix(shadeStep, other.shadeStep))
    }
}

/// How the new chart relates to the one on screen, so arcs can move instead of popping.
enum SunburstChange {
    /// Same center, fresher data (scan refresh).
    case refresh
    /// The new center was drawn at `start...end`, ring `depth`: zoom into it.
    case zoomIn(start: Double, end: Double, depth: Double)
    /// The old center is drawn at `start...end`, ring `depth`, in the new chart: zoom out of it.
    case zoomOut(start: Double, end: Double, depth: Double)
    /// No visible link between the two (e.g. a jump of more than three levels): cross-fade.
    case unrelated
}

/// The arcs on screen and where each one is heading. Arcs leaving the chart are kept until
/// they have faded out. Retargeting starts from what is currently drawn, so refreshes arriving
/// mid-animation never jump.
struct SunburstMotion {
    struct Arc {
        var segment: ArcSegment
        var from: ArcPose
        var to: ArcPose
        /// Still in the chart (as opposed to fading out).
        var isCurrent: Bool
    }

    /// Draw order: leaving arcs first, then current ones ring by ring.
    private(set) var arcs: [Arc] = []
    private(set) var startedAt = Date.distantPast
    private var animated = false
    private var pace = Pace.refresh

    /// Navigation zooms take the full spring. Scan refreshes are drawn at their target directly
    /// unless something visibly moves (`refreshMotionThreshold`); then they settle well inside
    /// the 250 ms refresh interval. Either way the chart is idle between refreshes.
    private enum Pace { case zoom, refresh }

    static let spring = Spring(duration: 0.35, bounce: 0)  // == Animation.smooth(duration: 0.35)
    static let refreshDuration: TimeInterval = 0.18
    /// Largest arc displacement, in radians (~2.9°), that a refresh snaps instead of animating.
    static let refreshMotionThreshold = 0.05

    /// How long the current transition runs; 0 when it is not animated.
    var duration: TimeInterval {
        guard animated else { return 0 }
        return pace == .zoom ? Self.spring.settlingDuration : Self.refreshDuration
    }

    /// Eased progress, 0...1.
    func progress(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(startedAt)
        guard animated, elapsed < duration else { return 1 }
        switch pace {
        case .zoom:
            return min(max(Self.spring.value(target: 1.0, time: max(elapsed, 0)), 0), 1)
        case .refresh:
            let t = max(elapsed, 0) / Self.refreshDuration
            return 1 - pow(1 - t, 3)  // ease-out cubic
        }
    }

    func poses(at date: Date) -> [(arc: Arc, pose: ArcPose)] {
        let t = progress(at: date)
        return arcs.map { ($0, Self.pose(of: $0, t)) }
    }

    private static func pose(of arc: Arc, _ t: Double) -> ArcPose {
        t >= 1 ? arc.to : arc.from.mixed(with: arc.to, t)
    }

    /// The current arc with segment `id` and where it is drawn at `date`.
    func current(_ id: String, at date: Date) -> (arc: Arc, pose: ArcPose)? {
        guard let arc = arcs.last(where: { $0.isCurrent && $0.segment.id == id }) else { return nil }
        return (arc, Self.pose(of: arc, progress(at: date)))
    }

    /// The current segment drawn under a point at `date`: `angle` from 12 o'clock clockwise,
    /// `ring` the fractional ring position (1 = inner edge of the innermost ring).
    /// Runs on every mouse move, so it allocates nothing.
    func hitTest(angle: Double, ring: Double, at date: Date) -> ArcSegment? {
        let a = SunburstLayout.normalizedAngle(angle)
        let t = progress(at: date)
        for arc in arcs.reversed() where arc.isCurrent {
            let pose = Self.pose(of: arc, t)
            if pose.alpha > 0.5, ring >= pose.depth, ring < pose.depth + 1, a >= pose.start, a < pose.end {
                return arc.segment
            }
        }
        return nil
    }

    /// Moves the chart to `segments`. Returns whether the change animates: a `.refresh` whose
    /// arcs barely move is drawn at its target directly, even when `animated` is true.
    @discardableResult
    mutating func retarget(to segments: [ArcSegment], change: SunburstChange, at date: Date, animated: Bool) -> Bool {
        let shown = poses(at: date).filter { $0.pose.alpha > 0.01 }
        var shownByID: [String: ArcPose] = [:]
        for (arc, pose) in shown { shownByID[arc.segment.id] = pose }

        var next: [Arc] = []
        var newIDs = Set<String>()
        var fromByID: [String: ArcPose] = [:]
        var toByID: [String: ArcPose] = [:]
        var ringIndex: [Int: Int] = [:]
        for segment in segments {
            let index = ringIndex[segment.depth, default: 0]
            ringIndex[segment.depth] = index + 1
            let to = ArcPose(start: segment.startAngle, end: segment.endAngle, depth: Double(segment.depth),
                             alpha: 1, shadeDepth: Double(segment.depth), shadeStep: Double(index % 4))
            let from = shownByID[segment.id]
                ?? entering(to, parentFrom: fromByID["\(segment.parent)"], parentTo: toByID["\(segment.parent)"],
                            change: change)
            fromByID[segment.id] = from
            toByID[segment.id] = to
            newIDs.insert(segment.id)
            next.append(Arc(segment: segment, from: from, to: to, isCurrent: true))
        }

        var leaving: [Arc] = []
        for (arc, pose) in shown where !newIDs.contains(arc.segment.id) {
            var to = Self.map(pose, change)
            to.alpha = 0
            leaving.append(Arc(segment: arc.segment, from: pose, to: to, isCurrent: false))
        }

        var animated = animated
        if animated, case .refresh = change {
            animated = Self.largestMotion(next + leaving) > Self.refreshMotionThreshold
        }
        if animated {
            arcs = leaving + next
        } else {
            arcs = next.map { Arc(segment: $0.segment, from: $0.to, to: $0.to, isCurrent: true) }
        }
        startedAt = date
        self.animated = animated
        if case .refresh = change { pace = .refresh } else { pace = .zoom }
        return animated
    }

    /// How far the most-moving arc travels, in radians; an appearing or fading arc counts its
    /// span scaled by the change in opacity.
    private static func largestMotion(_ arcs: [Arc]) -> Double {
        var largest = 0.0
        for arc in arcs {
            let (a, b) = (arc.from, arc.to)
            let fade = abs(a.alpha - b.alpha) * max(a.end - a.start, b.end - b.start)
            largest = max(largest, abs(a.start - b.start), abs(a.end - b.end), fade)
        }
        return largest
    }

    /// Starting pose of an arc that is not on screen yet.
    private func entering(_ to: ArcPose, parentFrom: ArcPose?, parentTo: ArcPose?,
                          change: SunburstChange) -> ArcPose {
        switch change {
        case .refresh:
            // Grow out of the parent's current span, so children never spill outside it.
            guard let parentFrom, let parentTo, parentTo.end > parentTo.start else {
                var from = to
                from.alpha = 0
                return from
            }
            let scale = (parentFrom.end - parentFrom.start) / (parentTo.end - parentTo.start)
            var from = to
            from.start = parentFrom.start + (to.start - parentTo.start) * scale
            from.end = parentFrom.start + (to.end - parentTo.start) * scale
            from.alpha = parentFrom.alpha
            return from
        case .zoomIn, .zoomOut:
            return Self.unmap(to, change)
        case .unrelated:
            var from = to
            from.alpha = 0
            return from
        }
    }

    private static let full = 2 * Double.pi

    /// Old chart → new chart coordinates.
    private static func map(_ pose: ArcPose, _ change: SunburstChange) -> ArcPose {
        var p = pose
        switch change {
        case .refresh, .unrelated:
            break
        case let .zoomIn(a, b, k):
            p.start = clamp((pose.start - a) / (b - a) * full)
            p.end = clamp((pose.end - a) / (b - a) * full)
            p.depth = pose.depth - k
        case let .zoomOut(a, b, k):
            p.start = a + pose.start / full * (b - a)
            p.end = a + pose.end / full * (b - a)
            p.depth = pose.depth + k
        }
        return p
    }

    /// New chart → old chart coordinates.
    private static func unmap(_ pose: ArcPose, _ change: SunburstChange) -> ArcPose {
        switch change {
        case let .zoomIn(a, b, k):
            map(pose, .zoomOut(start: a, end: b, depth: k))
        case let .zoomOut(a, b, k):
            map(pose, .zoomIn(start: a, end: b, depth: k))
        case .refresh, .unrelated:
            pose
        }
    }

    private static func clamp(_ angle: Double) -> Double { min(max(angle, 0), full) }
}
