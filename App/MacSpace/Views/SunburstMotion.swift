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

    /// Navigation zooms take the full spring; scan refreshes settle well inside the 250 ms
    /// refresh interval, so the chart is idle between them instead of redrawing nonstop.
    private enum Pace { case zoom, refresh }

    static let spring = Spring(duration: 0.35, bounce: 0)  // == Animation.smooth(duration: 0.35)
    static let refreshDuration: TimeInterval = 0.18

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
        return arcs.map { ($0, t >= 1 ? $0.to : $0.from.mixed(with: $0.to, t)) }
    }

    /// The current segment drawn under a point at `date`: `angle` from 12 o'clock clockwise,
    /// `ring` the fractional ring position (1 = inner edge of the innermost ring).
    func hitTest(angle: Double, ring: Double, at date: Date) -> ArcSegment? {
        let full = 2 * Double.pi
        var a = angle.truncatingRemainder(dividingBy: full)
        if a < 0 { a += full }
        for (arc, pose) in poses(at: date).reversed() where arc.isCurrent && pose.alpha > 0.5 {
            if ring >= pose.depth, ring < pose.depth + 1, a >= pose.start, a < pose.end { return arc.segment }
        }
        return nil
    }

    mutating func retarget(to segments: [ArcSegment], change: SunburstChange, at date: Date, animated: Bool) {
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

        if animated {
            arcs = leaving + next
        } else {
            arcs = next.map { Arc(segment: $0.segment, from: $0.to, to: $0.to, isCurrent: true) }
        }
        startedAt = date
        self.animated = animated
        if case .refresh = change { pace = .refresh } else { pace = .zoom }
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
