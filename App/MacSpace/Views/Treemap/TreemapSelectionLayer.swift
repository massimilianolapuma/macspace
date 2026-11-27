import MacSpaceCore
import SwiftUI

/// Spotlights `ScanModel.spotlight` (every other tile dims) and outlines the selected and spotlit
/// tiles (a section's outline takes in its children), above
/// the hover layer so a hovered selected tile keeps its outline; when the current folder or one
/// above it is selected, the whole map is outlined. Exists only while something is selected or
/// highlighted, so the tiles and the hover layer never redraw for it.
struct TreemapSelectionLayer: View {
    let model: ScanModel
    let motion: TreemapMotion
    let canvas: TreemapCanvas
    /// The map is animating, so the outlines follow the tiles frame by frame.
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
                    Perf.interval("treemap selection draw") {
                        draw(in: context, selection: selection, highlighted: highlighted, whole: whole, date: date)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func draw(in context: GraphicsContext, selection: Set<NodeID>, highlighted: Set<NodeID>, whole: Bool,
                      date: Date) {
        if !highlighted.isEmpty {
            var holes = Path()
            for (item, pose) in motion.poses(at: date) where item.isCurrent && item.isVisible {
                guard let node = item.tile.node, highlighted.contains(node), pose.alpha > 0.01,
                      let rect = canvas.drawn(pose.rect) else { continue }
                holes.addPath(Path(roundedRect: rect, cornerRadius: TreemapView.cornerRadius(rect, depth: item.tile.depth),
                                   style: .continuous))
            }
            if !holes.isEmpty { SafetyDecor.spotlightMask(sparing: holes, size: canvas.size, scheme: scheme, in: context) }
        }
        if whole {
            let bounds = CGRect(origin: .zero, size: canvas.size).insetBy(dx: TreemapCanvas.gap / 2,
                                                                         dy: TreemapCanvas.gap / 2)
            Self.outline(bounds, depth: 1, mark: .selected, alpha: 1, scheme: scheme, in: context)
            return
        }
        for (item, pose) in motion.poses(at: date) where item.isCurrent && item.isVisible {
            guard let node = item.tile.node, pose.alpha > 0.01, let rect = canvas.drawn(pose.rect) else { continue }
            let mark: SafetyDecor.Mark
            if selection.contains(node) {
                mark = .selected
            } else if highlighted.contains(node) {
                mark = .highlighted
            } else {
                continue
            }
            Self.outline(rect, depth: item.tile.depth, mark: mark, alpha: min(pose.alpha, 1), scheme: scheme,
                         in: context)
        }
    }

    /// The tile's rounded outline, drawn just inside its edge so the gap around it stays clear.
    private static func outline(_ rect: CGRect, depth: Int, mark: SafetyDecor.Mark, alpha: Double,
                                scheme: ColorScheme, in context: GraphicsContext) {
        let inset = mark.extent / 2
        let line = rect.insetBy(dx: inset, dy: inset)
        guard line.width > 0, line.height > 0 else { return }
        let radius = max(TreemapView.cornerRadius(rect, depth: depth) - inset, 0)
        SafetyDecor.selectionOutline(Path(roundedRect: line, cornerRadius: radius, style: .continuous), mark: mark,
                                     alpha: alpha, scheme: scheme, in: context)
    }
}
