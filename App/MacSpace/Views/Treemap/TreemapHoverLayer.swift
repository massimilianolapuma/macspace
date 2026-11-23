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

/// Pointer tracking, hit testing, clicks and the hover card. Hit tests use the tiles as drawn at
/// that moment (inset rects, so the gaps hover nothing), and are repeated after every map
/// update, so a still pointer never names a tile that has moved away.
struct TreemapPointerLayer: View {
    let model: ScanModel
    let motion: TreemapMotion
    let motionGeneration: Int
    let canvas: TreemapCanvas
    let total: UInt64
    @State private var pointer: CGPoint?
    /// The tile this layer last hovered, so leaving the map never clears a list hover.
    @State private var mapHoveredID: String?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) { tooltip }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case let .active(location):
                    pointer = location
                    updateHover()
                case .ended:
                    pointer = nil
                    if let id = model.hoveredTile?.id, id == mapHoveredID { model.hoveredTile = nil }
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                click(at: location)
            }
            .pointerStyle(isOverTarget ? .link : nil)
            .task(id: motionGeneration) {
                // The tiles move under a still pointer: follow them while they settle.
                updateHover()
                try? await Task.sleep(for: .seconds(max(motion.endsAt.timeIntervalSinceNow, 0) + 0.02))
                if !Task.isCancelled { updateHover() }
            }
    }

    @ViewBuilder
    private var tooltip: some View {
        if let pointer, let hovered = model.hoveredTile {
            let size = canvas.size
            SegmentTooltip(tile: hovered, total: total)
                .fixedSize()
                .alignmentGuide(.leading) { d in
                    pointer.x + 16 + d.width > size.width ? d.width + 10 - pointer.x : -(pointer.x + 16)
                }
                .alignmentGuide(.top) { d in
                    pointer.y + 20 + d.height > size.height ? d.height + 8 - pointer.y : -(pointer.y + 20)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .allowsHitTesting(false)
        }
    }

    private var isOverTarget: Bool {
        guard pointer != nil, let hovered = model.hoveredTile else { return false }
        return hovered.node != nil && hovered.hasChildren
    }

    private func updateHover() {
        guard let pointer else { return }
        Perf.interval("treemap updateHover") {
            let tile = motion.hitTest(pointer, canvas: canvas, at: .now)
            mapHoveredID = tile?.id
            if model.hoveredTile != tile { model.hoveredTile = tile }
        }
    }

    /// A tile with children drills into it; on a section that includes its header.
    private func click(at point: CGPoint) {
        guard let tile = motion.hitTest(point, canvas: canvas, at: .now), let node = tile.node,
              tile.hasChildren else { return }
        model.drill(into: node)
    }
}
