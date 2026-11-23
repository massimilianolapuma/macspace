import MacSpaceCore
import SwiftUI

/// The hovered tile, lifted: a block redrawn lighter with its label in an ink chosen for the
/// lifted fill; a section's frame and header lifted around its children, and outlined in its
/// color. Redraws on hover changes without touching the tiles canvas, and is not there at all
/// while nothing is hovered.
struct TreemapHoverLayer: View {
    let model: ScanModel
    let motion: TreemapMotion
    let labels: TileLabelPlanner
    let generation: Int
    let canvas: TreemapCanvas
    let colorMode: ColorMode
    /// The map is animating, so the hovered tile follows its pose frame by frame.
    let moving: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Nothing hovered: no view, so no canvas and no timeline run while the map is only scanning.
        if let hoveredID = model.hoveredTile?.id {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
                let date = moving ? timeline.date : .distantFuture
                Canvas { context, _ in
                    Perf.interval("treemap hover draw") {
                        draw(in: &context, hoveredID: hoveredID, date: date)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func draw(in context: inout GraphicsContext, hoveredID: String, date: Date) {
        guard let (item, pose) = motion.current(hoveredID, at: date), item.isVisible, pose.alpha > 0.01,
              let rect = canvas.drawn(pose.rect) else { return }
        labels.prepare(generation: generation, size: canvas.size, mode: colorMode, scheme: scheme)
        let lift = FusionPalette.hoverLift
        guard item.isSection, let node = item.tile.node else {
            TreemapView.drawTile(item, pose: pose, rect: rect, canvas: canvas, motion: motion, labels: labels,
                                 mode: colorMode, lift: lift, scheme: scheme, in: context)
            return
        }
        // A section: lift only what shows of it, its children keep their own fills.
        let alpha = min(max(pose.alpha, 0), 1)
        let shape = TreemapView.shape(rect, depth: item.tile.depth)
        var frame = shape
        let t = motion.progress(at: date)
        for child in motion.items where child.isCurrent && child.isVisible && child.tile.parent == node {
            let childPose = TreemapMotion.pose(of: child, t)
            if let childRect = canvas.drawn(childPose.rect) {
                frame.addPath(TreemapView.shape(childRect, depth: child.tile.depth))
            }
        }
        let surface = labels.surface(for: item, lift: lift, motion: motion)
        context.fill(frame, with: .color(FusionPalette.color(surface).opacity(alpha)), style: FillStyle(eoFill: true))
        let outline = FusionPalette.fill(.init(item.tile), mode: colorMode, depth: pose.shadeDepth,
                                         step: pose.shadeStep, scheme: scheme)
        context.stroke(TreemapView.shape(rect.insetBy(dx: 0.5, dy: 0.5), depth: item.tile.depth),
                       with: .color(outline.opacity(alpha)), lineWidth: 1)
        if item.tile.hasHeader, let header = labels.header(for: item, canvas: canvas, in: context) {
            TreemapView.drawHeader(header, in: rect, canvas: canvas, alpha: alpha, scheme: scheme, context: context)
        }
    }
}
