import MacSpaceCore
import SwiftUI

/// The hovered sector, lifted, with its label redrawn in an ink chosen for the lifted fill; and
/// the center disc while clicking it goes up. Redraws on hover changes without touching the rings.
struct SunburstHoverLayer: View {
    let model: ScanModel
    let hover: ChartHover
    let motion: SunburstMotion
    let labels: LabelPlanner
    let generation: Int
    let geometry: ChartGeometry
    let canGoUp: Bool
    let colorMode: ColorMode
    /// The chart is animating, so the hovered sector follows its pose frame by frame.
    let moving: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let hoveredID = model.hovered?.id
        let overCenter = hover.overCenter && canGoUp
        // Nothing hovered: no view, so no canvas and no timeline run while the chart is only scanning.
        if hoveredID != nil || overCenter {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
                let date = moving ? timeline.date : .distantFuture
                Canvas { context, _ in
                    Perf.interval("hover draw") {
                        draw(in: &context, hoveredID: hoveredID, overCenter: overCenter, date: date)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func draw(in context: inout GraphicsContext, hoveredID: String?, overCenter: Bool, date: Date) {
        if let hoveredID, let current = motion.current(hoveredID, at: date),
           let inner = geometry.drawableInner(current.pose) {
            let pose = current.pose
            var ring = context
            ring.clip(to: geometry.band, style: FillStyle(eoFill: true))
            let path = SunburstView.sector(center: geometry.center, inner: inner, outer: inner + geometry.ringWidth,
                                           start: pose.start, end: pose.end)
            let subject = FusionPalette.FillSubject(current.arc.segment)
            let fill = FusionPalette.fill(subject, mode: colorMode, depth: pose.shadeDepth, step: pose.shadeStep,
                                          lift: FusionPalette.hoverLift, scheme: scheme)
            ring.fill(path, with: .color(fill.opacity(pose.alpha)))
            if geometry.hasSeparator(pose, inner: inner) {
                ring.stroke(path, with: .color(FusionPalette.background(scheme).opacity(pose.alpha)), lineWidth: 1)
            }
            if let outline = FusionPalette.mergedOutline(subject, mode: colorMode, lift: FusionPalette.hoverLift,
                                                         scheme: scheme) {
                MergedOutline.strokeArc(center: geometry.center, inner: inner, outer: inner + geometry.ringWidth,
                                        start: pose.start, end: pose.end, color: outline.opacity(pose.alpha), in: ring)
            }
            // The label as the rings canvas placed it: replay placement up to this arc.
            labels.prepare(generation: generation, size: geometry.size)
            if let label = RingLabel.place(motion.poses(at: date), geometry: geometry, planner: labels, in: ring,
                                           through: hoveredID).last, label.id == hoveredID {
                let ink = FusionPalette.label(subject, mode: colorMode, depth: pose.shadeDepth, step: pose.shadeStep,
                                              lift: FusionPalette.hoverLift, scheme: scheme)
                RingLabel.draw(label, ink: ink, in: ring)
            }
        }
        if overCenter {
            let disc = Path(ellipseIn: geometry.rect(radius: geometry.centerRadius - 0.5))
            context.fill(disc, with: .color(FusionPalette.centerHover(scheme)))
        }
    }
}

/// "Go up" hint above the center label while the center disc is hovered.
struct CenterChevron: View {
    let hover: ChartHover
    let canGoUp: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let visible = hover.overCenter && canGoUp
        ZStack {
            if visible {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: visible)
    }
}
