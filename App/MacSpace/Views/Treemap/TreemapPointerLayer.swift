import MacSpaceCore
import SwiftUI

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
            let node = hovered.node
            SegmentTooltip(subject: .init(tile: hovered, verdict: node.flatMap { model.verdicts[$0] },
                                          spotlightLastUsed: node.flatMap { model.spotlightLastUsed[$0] }),
                           total: total)
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

    /// A tile with children drills into it; on a section that includes its header. A ⌘-click
    /// selects or deselects the tile instead.
    private func click(at point: CGPoint) {
        guard let tile = motion.hitTest(point, canvas: canvas, at: .now) else { return }
        if ChartSelection.isSelectClick {
            ChartSelection.toggle(tile.node, in: model)
            return
        }
        guard let node = tile.node, tile.hasChildren else { return }
        model.drill(into: node)
    }
}
