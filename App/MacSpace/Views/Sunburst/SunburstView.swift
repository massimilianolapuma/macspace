import MacSpaceCore
import SwiftUI

/// Pointer state the chart's hover layers share. Kept out of `SunburstView.body`, so a hover
/// change never redraws the rings.
@MainActor @Observable
final class ChartHover {
    /// The pointer is over the center disc.
    var overCenter = false
}

/// The interactive sunburst: rings of the three levels below `model.center`.
///
/// Layers, bottom to top: the rings canvas (fills, separators, labels), which redraws only when
/// the arcs change or animate; the hover layer, which exists only while a sector is hovered or
/// the center disc is a target, and draws just that; the center label; and the pointer layer, which tracks the
/// mouse. `body` reads neither `model.hovered` nor `hover`, so hovering redraws only the small
/// layers that show it.
struct SunburstView: View {
    let model: ScanModel
    /// Changing it only repaints the arcs; it never retargets or animates them.
    let colorMode: ColorMode

    @State private var motion = SunburstMotion()
    /// The center `motion` is showing; tells refreshes apart from navigation.
    @State private var motionCenter: NodeID = FileTree.root
    @State private var animating = false
    @State private var motionGeneration = 0
    @State private var hover = ChartHover()
    @State private var labels = LabelPlanner()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let geometry = ChartGeometry(size: proxy.size)
            let moving = animating || showsPlaceholderMotion
            let generation = motionGeneration
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
                    let date = moving ? timeline.date : .distantFuture
                    // Rasterized off the main thread: during a scan it redraws on refreshes.
                    Canvas(rendersAsynchronously: true) { context, _ in
                        Perf.interval("canvas draw") {
                            draw(in: &context, geometry: geometry, generation: generation, date: date)
                        }
                    }
                }
                SunburstHoverLayer(model: model, hover: hover, motion: motion, labels: labels,
                                   generation: generation, geometry: geometry, canGoUp: canGoUp,
                                   colorMode: colorMode, moving: moving)
                centerLabel(geometry)
                    .position(geometry.center)
                    .allowsHitTesting(false)
                if model.breadcrumb.isEmpty && !model.isScanning {
                    Text("Scegli cosa analizzare e premi Analizza")
                        .font(.title3)
                        .foregroundStyle(FusionPalette.secondaryText(scheme))
                        .multilineTextAlignment(.center)
                        .frame(width: geometry.centerRadius * 1.7)
                        .position(geometry.center)
                }
                SunburstPointerLayer(model: model, motion: motion, motionGeneration: motionGeneration,
                                     geometry: geometry, canGoUp: canGoUp, total: centerSize, hover: hover)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.breadcrumb.last?.name ?? ""))
        .accessibilityValue(Text(verbatim: Formatters.bytes(centerSize)))
        .onAppear {
            motion.retarget(to: model.segments, change: .refresh, at: .now, animated: false)
            motionCenter = model.center
        }
        .onChange(of: model.segments) { old, new in
            retarget(from: old, to: new)
        }
        .task(id: motionGeneration) {
            guard animating else { return }
            try? await Task.sleep(for: .seconds(motion.duration + 0.03))
            if !Task.isCancelled { animating = false }
        }
    }

    // MARK: State

    private var centerSize: UInt64 { model.breadcrumb.last?.size ?? 0 }
    private var canGoUp: Bool { model.breadcrumb.count > 1 }

    /// Before the first rings arrive, a scan shows a sweeping placeholder ring.
    private var showsPlaceholderMotion: Bool { model.isScanning && model.segments.isEmpty }

    private func retarget(from old: [ArcSegment], to new: [ArcSegment]) {
        Perf.interval("retarget") {
            let change: SunburstChange
            if new.isEmpty || old.isEmpty && model.center != motionCenter {
                change = .unrelated
            } else if model.center == motionCenter {
                change = .refresh
            } else if let target = old.first(where: { $0.node == model.center }) {
                change = .zoomIn(start: target.startAngle, end: target.endAngle, depth: Double(target.depth))
            } else if let previous = new.first(where: { $0.node == motionCenter }) {
                change = .zoomOut(start: previous.startAngle, end: previous.endAngle, depth: Double(previous.depth))
            } else {
                change = .unrelated
            }
            motionCenter = model.center
            animating = motion.retarget(to: new, change: change, at: .now,
                                        animated: !reduceMotion && !new.isEmpty)
            motionGeneration += 1
        }
    }

    // MARK: Center

    @ViewBuilder
    private func centerLabel(_ geometry: ChartGeometry) -> some View {
        let showsCapacity = model.capacity != nil && model.center == FileTree.root
        VStack(spacing: 2) {
            CountingText(centerSize) { Text(verbatim: Formatters.bytes($0)) }
                .font(.system(size: geometry.centerFontSize, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(FusionPalette.primaryText(scheme))
            Group {
                if showsCapacity, let capacity = model.capacity {
                    Text("di \(Formatters.bytes(capacity))")
                } else {
                    Text(verbatim: model.breadcrumb.last?.name ?? "")
                }
            }
            .font(.callout)
            .foregroundStyle(FusionPalette.secondaryText(scheme))
            .truncationMode(.middle)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .multilineTextAlignment(.center)
        .frame(width: geometry.centerRadius * 1.6)
        .overlay(alignment: .top) {
            CenterChevron(hover: hover, canGoUp: canGoUp)
                .offset(y: -18)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: centerSize)
        .opacity(model.breadcrumb.isEmpty ? 0 : 1)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, geometry: ChartGeometry, generation: Int, date: Date) {
        let background = FusionPalette.background(scheme)
        var rings = context
        rings.clip(to: geometry.band, style: FillStyle(eoFill: true))

        let poses = motion.poses(at: date)
        if poses.isEmpty {
            drawPlaceholder(in: &rings, band: geometry.band, geometry: geometry, date: date)
        }

        var drawn: [(path: Path, pose: ArcPose, inner: Double)] = []
        drawn.reserveCapacity(poses.count)
        for (arc, pose) in poses {
            guard let inner = geometry.drawableInner(pose) else { continue }
            let path = Self.sector(center: geometry.center, inner: inner, outer: inner + geometry.ringWidth,
                                   start: pose.start, end: pose.end)
            let fill = FusionPalette.fill(.init(arc.segment), mode: colorMode, depth: pose.shadeDepth,
                                          step: pose.shadeStep, scheme: scheme)
            rings.fill(path, with: .color(fill.opacity(pose.alpha)))
            drawn.append((path, pose, inner))
        }
        for item in drawn where geometry.hasSeparator(item.pose, inner: item.inner) {
            rings.stroke(item.path, with: .color(background.opacity(item.pose.alpha)), lineWidth: 1)
        }
        labels.prepare(generation: generation, size: geometry.size)
        for label in RingLabel.place(poses, geometry: geometry, planner: labels, in: rings) {
            let ink = FusionPalette.label(.init(label.segment), mode: colorMode, depth: label.pose.shadeDepth,
                                          step: label.pose.shadeStep, scheme: scheme)
            RingLabel.draw(label, ink: ink, in: rings)
        }

        let disc = Path(ellipseIn: geometry.rect(radius: geometry.centerRadius - 0.5))
        context.fill(disc, with: .color(FusionPalette.centerFill(scheme)))
    }

    /// Faint rings while there is nothing to draw; while scanning, a soft highlight sweeps around
    /// them (with Reduce Motion, they breathe instead).
    private func drawPlaceholder(in context: inout GraphicsContext, band: Path, geometry: ChartGeometry, date: Date) {
        let tone = FusionPalette.ring(lightness: FusionPalette.ringLightness(depth: 2, step: 0, scheme: scheme),
                                      scheme: scheme)
        let time = date == .distantFuture ? 0 : date.timeIntervalSinceReferenceDate
        if !model.isScanning {
            context.fill(band, with: .color(tone.opacity(0.09)))
        } else if reduceMotion {
            let breath = 0.5 + 0.5 * sin(time * 2 * .pi / 2.4)
            context.fill(band, with: .color(tone.opacity(0.08 + 0.16 * breath)))
        } else {
            context.fill(band, with: .color(tone.opacity(0.09)))
            let gradient = Gradient(stops: [
                .init(color: tone.opacity(0), location: 0),
                .init(color: tone.opacity(0), location: 0.4),
                .init(color: tone.opacity(0.5), location: 0.9),
                .init(color: tone.opacity(0), location: 1),
            ])
            let turn = time.truncatingRemainder(dividingBy: 1.8) / 1.8 * 2 * .pi
            context.fill(band, with: .conicGradient(gradient, center: geometry.center, angle: .radians(turn)))
        }
        // Ring boundaries, so the placeholder already reads as the chart to come.
        for depth in 2...3 {
            let r = geometry.innerRadius(depth: Double(depth))
            context.stroke(Path(ellipseIn: geometry.rect(radius: r)),
                           with: .color(FusionPalette.background(scheme)), lineWidth: 1.5)
        }
    }

    static func title(of segment: ArcSegment) -> String {
        // The layout only merges two or more siblings, so "Altri" is always plural.
        segment.node == nil ? String(localized: "Altri \(Formatters.count(segment.otherCount)) elementi") : segment.name
    }

    /// Annular sector between radii, angles from 12 o'clock clockwise.
    static func sector(center: CGPoint, inner: Double, outer: Double, start: Double, end: Double) -> Path {
        var path = Path()
        let inner = max(inner, 0)
        if end - start >= 2 * .pi - 1e-6 {
            path.addEllipse(in: CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer))
            path.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: 2 * inner, height: 2 * inner))
            return path.normalized(eoFill: true)
        }
        let a0 = Angle.radians(start - .pi / 2), a1 = Angle.radians(end - .pi / 2)
        path.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        return path
    }
}
