import MacSpaceCore
import SwiftUI

/// Pointer tracking, hit testing, clicks and the hover card. Hit tests use the arcs as drawn at
/// that moment, and are repeated after every chart update, so a still pointer never names a
/// segment that has moved away.
struct SunburstPointerLayer: View {
    let model: ScanModel
    let motion: SunburstMotion
    let motionGeneration: Int
    let geometry: ChartGeometry
    let canGoUp: Bool
    let total: UInt64
    let hover: ChartHover
    @State private var pointer: CGPoint?
    /// The segment this layer last hovered, so leaving the chart never clears a list hover.
    @State private var chartHoveredID: String?

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
                    if hover.overCenter { hover.overCenter = false }
                    if let id = model.hovered?.id, id == chartHoveredID { model.hovered = nil }
                }
            }
            .onTapGesture(coordinateSpace: .local) { location in
                click(at: location)
            }
            .pointerStyle(isOverTarget ? .link : nil)
            .task(id: motionGeneration) {
                // The arcs move under a still pointer: follow them while they settle.
                updateHover()
                try? await Task.sleep(for: .seconds(motion.duration + 0.02))
                if !Task.isCancelled { updateHover() }
            }
    }

    @ViewBuilder
    private var tooltip: some View {
        if let pointer, let hovered = model.hovered {
            let size = geometry.size
            let node = hovered.node
            SegmentTooltip(subject: .init(segment: hovered, verdict: node.flatMap { model.verdicts[$0] },
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
        if hover.overCenter { return canGoUp }
        guard pointer != nil, let hovered = model.hovered else { return false }
        return hovered.node != nil && hovered.hasChildren
    }

    private enum Target: Equatable {
        case center
        case segment(ArcSegment)
        case none
    }

    private func target(at point: CGPoint) -> Target {
        let dx = point.x - geometry.center.x, dy = point.y - geometry.center.y
        let radius = (dx * dx + dy * dy).squareRoot()
        if radius < geometry.centerRadius { return .center }
        guard radius < geometry.radius else { return .none }
        let ring = (radius - geometry.centerRadius) / geometry.ringWidth + 1
        // atan2(x, -y): 0 at 12 o'clock, growing clockwise (y points down).
        let angle = atan2(Double(dx), Double(-dy))
        guard let segment = motion.hitTest(angle: angle, ring: ring, at: .now) else { return .none }
        return .segment(segment)
    }

    private func updateHover() {
        guard let pointer else { return }
        Perf.interval("updateHover") {
            let target = self.target(at: pointer)
            let overCenter = target == .center
            if hover.overCenter != overCenter { hover.overCenter = overCenter }
            let segment: ArcSegment? = if case let .segment(segment) = target { segment } else { nil }
            chartHoveredID = segment?.id
            if model.hovered != segment { model.hovered = segment }
        }
    }

    /// A click drills into a folder (the center goes up); a ⌘-click selects or deselects a segment.
    private func click(at point: CGPoint) {
        let target = target(at: point)
        if ChartSelection.isSelectClick {
            guard case let .segment(segment) = target else { return }
            ChartSelection.toggle(segment.node, in: model)
            return
        }
        switch target {
        case .center:
            if canGoUp { model.goUp() }
        case let .segment(segment):
            if let node = segment.node, segment.hasChildren { model.drill(into: node) }
        case .none:
            break
        }
    }
}
