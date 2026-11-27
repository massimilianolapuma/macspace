import MacSpaceCore
import SwiftUI

/// Spotlights `ScanModel.spotlight` (everything else dims, the center disc stays clear) and outlines
/// the selected and spotlit segments, above the hover layer so a hovered selected
/// segment keeps its outline. A folder's outline takes in its rings outward, everything it holds;
/// when the current folder or one above it is selected, the whole chart is outlined. Exists only
/// while something is selected or highlighted, so the rings and the hover layer never redraw for it.
struct SunburstSelectionLayer: View {
    let model: ScanModel
    let motion: SunburstMotion
    let geometry: ChartGeometry
    /// The chart is animating, so the outlines follow the arcs frame by frame.
    let moving: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let selection = model.selection
        let highlighted = model.spotlight
        if !selection.isEmpty || !highlighted.isEmpty {
            let whole = model.breadcrumb.contains { selection.contains($0.id) }
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
                let date = moving ? timeline.date : .distantFuture
                Canvas { context, _ in
                    Perf.interval("selection draw") {
                        draw(in: context, selection: selection, highlighted: highlighted, whole: whole, date: date)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func draw(in context: GraphicsContext, selection: Set<NodeID>, highlighted: Set<NodeID>, whole: Bool,
                      date: Date) {
        let poses = motion.poses(at: date).filter(\.arc.isCurrent)
        // How far out each folder's contents reach: one pass, walking up at most two parents.
        var outerByNode: [NodeID: Double] = [:]
        var parentByNode: [NodeID: NodeID] = [:]
        var deepest = geometry.centerRadius
        for (arc, _) in poses {
            if let node = arc.segment.node { parentByNode[node] = arc.segment.parent }
        }
        for (arc, pose) in poses {
            guard let inner = geometry.drawableInner(pose) else { continue }
            let outer = min(inner + geometry.ringWidth, geometry.radius)
            deepest = max(deepest, outer)
            // The arc itself (a merged one belongs to its parent), then the folders it is in.
            var up: NodeID? = arc.segment.node ?? arc.segment.parent
            while let node = up {
                outerByNode[node] = max(outerByNode[node] ?? 0, outer)
                up = parentByNode[node]
            }
        }
        if !highlighted.isEmpty {
            var holes = Path(ellipseIn: geometry.rect(radius: geometry.centerRadius))
            var found = false
            for (arc, pose) in poses {
                guard let node = arc.segment.node, highlighted.contains(node),
                      let inner = geometry.drawableInner(pose) else { continue }
                let outer = outerByNode[node] ?? min(inner + geometry.ringWidth, geometry.radius)
                holes.addPath(SunburstView.sector(center: geometry.center, inner: max(inner, geometry.centerRadius),
                                                  outer: outer, start: pose.start, end: pose.end))
                found = true
            }
            if found { SafetyDecor.spotlightMask(sparing: holes, size: geometry.size, scheme: scheme, in: context) }
        }
        if whole {
            let ring = SunburstView.sector(center: geometry.center, inner: geometry.centerRadius, outer: deepest,
                                           start: 0, end: 2 * .pi)
            SafetyDecor.selectionOutline(ring, mark: .selected, scheme: scheme, in: context)
            return
        }
        for (arc, pose) in poses {
            guard let node = arc.segment.node, let inner = geometry.drawableInner(pose) else { continue }
            let mark: SafetyDecor.Mark
            if selection.contains(node) {
                mark = .selected
            } else if highlighted.contains(node) {
                mark = .highlighted
            } else {
                continue
            }
            let outer = outerByNode[node] ?? min(inner + geometry.ringWidth, geometry.radius)
            let path = SunburstView.sector(center: geometry.center, inner: max(inner, geometry.centerRadius),
                                           outer: outer, start: pose.start, end: pose.end)
            SafetyDecor.selectionOutline(path, mark: mark, alpha: pose.alpha, scheme: scheme, in: context)
        }
    }
}
