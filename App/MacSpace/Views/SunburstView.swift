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
/// the arcs change or animate; the hover layer, which draws just the hovered sector (and the
/// center disc while it is a target); the center label; and the pointer layer, which tracks the
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
                    ZStack {
                        // Rasterized off the main thread: during a scan it redraws on refreshes.
                        Canvas(rendersAsynchronously: true) { context, _ in
                            Perf.interval("canvas draw") {
                                draw(in: &context, geometry: geometry, generation: generation, date: date)
                            }
                        }
                        SunburstHoverLayer(model: model, hover: hover, motion: motion, labels: labels,
                                           generation: generation, geometry: geometry, canGoUp: canGoUp,
                                           colorMode: colorMode, date: date)
                    }
                }
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

        let now = Date.now.timestamp
        var drawn: [(path: Path, pose: ArcPose, inner: Double)] = []
        drawn.reserveCapacity(poses.count)
        for (arc, pose) in poses {
            guard let inner = geometry.drawableInner(pose) else { continue }
            let path = Self.sector(center: geometry.center, inner: inner, outer: inner + geometry.ringWidth,
                                   start: pose.start, end: pose.end)
            let fill = Self.fill(arc.segment, pose: pose, mode: colorMode, scheme: scheme, now: now).fill
            rings.fill(path, with: .color(fill.opacity(pose.alpha)))
            drawn.append((path, pose, inner))
        }
        for item in drawn where geometry.hasSeparator(item.pose, inner: item.inner) {
            rings.stroke(item.path, with: .color(background.opacity(item.pose.alpha)), lineWidth: 1)
        }
        labels.prepare(generation: generation, size: geometry.size)
        for label in RingLabel.place(poses, geometry: geometry, planner: labels, in: rings) {
            let ink = Self.fill(label.segment, pose: label.pose, mode: colorMode, scheme: scheme, now: now).label
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

    /// Fill and label ink of `segment` drawn at `pose`, lifted by `lift` lightness points.
    static func fill(_ segment: ArcSegment, pose: ArcPose, mode: ColorMode, lift: Double = 0, scheme: ColorScheme,
                     now: UInt32) -> (fill: Color, label: Color) {
        FusionPalette.fill(category: segment.category, lastUsed: segment.lastUsed, mode: mode,
                           depth: pose.shadeDepth, step: pose.shadeStep, lift: lift, scheme: scheme, now: now)
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

/// The hovered sector, lifted, with its label redrawn in an ink chosen for the lifted fill; and
/// the center disc while clicking it goes up. Redraws on hover changes without touching the rings.
private struct SunburstHoverLayer: View {
    let model: ScanModel
    let hover: ChartHover
    let motion: SunburstMotion
    let labels: LabelPlanner
    let generation: Int
    let geometry: ChartGeometry
    let canGoUp: Bool
    let colorMode: ColorMode
    let date: Date
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let hoveredID = model.hovered?.id
        let overCenter = hover.overCenter && canGoUp
        Canvas { context, _ in
            Perf.interval("hover draw") {
                draw(in: &context, hoveredID: hoveredID, overCenter: overCenter)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(in context: inout GraphicsContext, hoveredID: String?, overCenter: Bool) {
        if let hoveredID, let current = motion.current(hoveredID, at: date),
           let inner = geometry.drawableInner(current.pose) {
            let pose = current.pose
            var ring = context
            ring.clip(to: geometry.band, style: FillStyle(eoFill: true))
            let path = SunburstView.sector(center: geometry.center, inner: inner, outer: inner + geometry.ringWidth,
                                           start: pose.start, end: pose.end)
            let lifted = SunburstView.fill(current.arc.segment, pose: pose, mode: colorMode,
                                           lift: FusionPalette.hoverLift, scheme: scheme, now: Date.now.timestamp)
            ring.fill(path, with: .color(lifted.fill.opacity(pose.alpha)))
            if geometry.hasSeparator(pose, inner: inner) {
                ring.stroke(path, with: .color(FusionPalette.background(scheme).opacity(pose.alpha)), lineWidth: 1)
            }
            // The label as the rings canvas placed it: replay placement up to this arc.
            labels.prepare(generation: generation, size: geometry.size)
            if let label = RingLabel.place(motion.poses(at: date), geometry: geometry, planner: labels, in: ring,
                                           through: hoveredID).last, label.id == hoveredID {
                RingLabel.draw(label, ink: lifted.label, in: ring)
            }
        }
        if overCenter {
            let disc = Path(ellipseIn: geometry.rect(radius: geometry.centerRadius - 0.5))
            context.fill(disc, with: .color(FusionPalette.centerHover(scheme)))
        }
    }
}

/// "Go up" hint above the center label while the center disc is hovered.
private struct CenterChevron: View {
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

/// Pointer tracking, hit testing, clicks and the hover card. Hit tests use the arcs as drawn at
/// that moment, and are repeated after every chart update, so a still pointer never names a
/// segment that has moved away.
private struct SunburstPointerLayer: View {
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
            SegmentTooltip(segment: hovered, total: total)
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

    private func click(at point: CGPoint) {
        switch target(at: point) {
        case .center:
            if canGoUp { model.goUp() }
        case let .segment(segment):
            if let node = segment.node, segment.hasChildren { model.drill(into: node) }
        case .none:
            break
        }
    }
}

/// Radii of the chart in a given size: center hole 0.30·R, three rings sharing the rest.
struct ChartGeometry {
    let size: CGSize
    let center: CGPoint
    let radius: Double
    let centerRadius: Double
    let ringWidth: Double

    init(size: CGSize) {
        self.size = size
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        radius = max(min(size.width, size.height) / 2 - 16, 40)
        centerRadius = 0.30 * radius
        ringWidth = 0.70 * radius / 3
    }

    var centerFontSize: Double { min(max(centerRadius * 0.24, 17), 30) }

    /// The ring band, for an even-odd clip: arcs animating past the rings are cut off.
    var band: Path {
        var band = Path(ellipseIn: rect(radius: radius))
        band.addPath(Path(ellipseIn: rect(radius: centerRadius)))
        return band
    }

    func innerRadius(depth: Double) -> Double { centerRadius + (depth - 1) * ringWidth }

    /// Inner radius of an arc worth drawing at `pose`; nil when it is invisible or off the band.
    func drawableInner(_ pose: ArcPose) -> Double? {
        guard pose.alpha > 0.01, pose.end - pose.start > 0.0004 else { return nil }
        let inner = innerRadius(depth: pose.depth)
        guard inner + ringWidth > centerRadius, inner < radius else { return nil }
        return inner
    }

    /// Hairline slivers get no separator of their own: a run of them reads as one tone instead
    /// of a white blur.
    func hasSeparator(_ pose: ArcPose, inner: Double) -> Bool {
        (inner + ringWidth) * (pose.end - pose.start) >= 4
    }

    func rect(radius: Double) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)
    }

    func point(angle: Double, radius: Double) -> CGPoint {
        CGPoint(x: center.x + radius * sin(angle), y: center.y - radius * cos(angle))
    }
}

/// A placed label's rotated bounding box.
private struct LabelBox {
    let center: CGPoint
    let rotation: Double
    let halfWidth: Double
    let halfHeight: Double

    private var axes: [CGVector] {
        [CGVector(dx: cos(rotation), dy: sin(rotation)), CGVector(dx: -sin(rotation), dy: cos(rotation))]
    }

    /// Separating-axis test between two rotated rectangles.
    func overlaps(_ other: LabelBox) -> Bool {
        let d = CGVector(dx: other.center.x - center.x, dy: other.center.y - center.y)
        for axis in axes + other.axes {
            let distance = abs(d.dx * axis.dx + d.dy * axis.dy)
            if distance > projectedRadius(on: axis) + other.projectedRadius(on: axis) { return false }
        }
        return true
    }

    private func projectedRadius(on axis: CGVector) -> Double {
        let (u, v) = (axes[0], axes[1])
        return halfWidth * abs(u.dx * axis.dx + u.dy * axis.dy) + halfHeight * abs(v.dx * axis.dx + v.dy * axis.dy)
    }
}

struct FittedText {
    let string: String
    let width: Double
}

/// A segment's label, fitted once per chart generation against its arc's target pose: the name
/// (truncated with "…" if needed) and, when both lines fit, the size below it.
struct LabelPlan {
    let name: FittedText
    let size: FittedText?
    let locked: Bool

    /// Room kept before the name for the lock glyph.
    var lockRoom: Double { locked ? 14 : 0 }
}

/// Ring labels as straight text along the ring. Each line is fitted to the room at the radius
/// where it sits: within the segment's angle at the line's inner edge, and inside the ring where
/// its ends bow outwards. Labels are fitted when the chart changes (`LabelPlanner`); per frame
/// they are only positioned, shown once their arc has room for them, and skipped when their box
/// would touch one already placed.
enum RingLabel {
    static let nameFont = Font.system(size: 11, weight: .semibold)
    static let sizeFont = Font.system(size: 10).monospacedDigit()
    /// Half heights of the label lines and their offsets from the ring's mid radius.
    static let nameHalf = 7.0, sizeHalf = 6.5, nameOffset = 6.5, sizeOffset = 7.0

    /// A label positioned for one frame.
    struct Placed {
        let id: String
        let segment: ArcSegment
        let plan: LabelPlan
        let pose: ArcPose
        let point: CGPoint
        let rotation: Double
    }

    /// The straight-line room an arc posed at `pose` offers; nil when it is too small for any label.
    struct Room {
        let inner: Double
        let outer: Double
        let span: Double
        let mid: Double
        /// Local "up" points outwards on the top half and inwards on the flipped bottom half.
        let outward: Double

        init?(_ pose: ArcPose, geometry: ChartGeometry) {
            inner = geometry.innerRadius(depth: pose.depth)
            outer = inner + geometry.ringWidth
            guard inner >= geometry.centerRadius - 0.5, outer <= geometry.radius + 0.5 else { return nil }
            span = pose.end - pose.start
            mid = inner + geometry.ringWidth / 2
            guard mid * span >= 60 else { return nil }
            let midAngle = (pose.start + pose.end) / 2
            outward = midAngle > .pi / 2 && midAngle < 3 * .pi / 2 ? -1 : 1
        }

        /// Widest straight line centered on the mid angle at radius `r` with half height `h`.
        func width(_ r: Double, _ h: Double) -> Double {
            guard r - h >= inner + 2 else { return 0 }
            let angular = span / 2 >= .pi / 2 - 0.05 ? .infinity : 2 * ((r - h) * tan(span / 2) - 4)
            let bowLimit = (outer - 3) * (outer - 3) - (r + h) * (r + h)
            let bow = bowLimit > 0 ? 2 * bowLimit.squareRoot() : 0
            return min(angular, bow, 200)
        }

        var nameLine: Double { width(mid + outward * RingLabel.nameOffset, RingLabel.nameHalf) }
        var sizeLine: Double { width(mid - outward * RingLabel.sizeOffset, RingLabel.sizeHalf) }
        var singleLine: Double { width(mid, RingLabel.nameHalf) }

        func fits(_ plan: LabelPlan) -> Bool {
            if let size = plan.size {
                return nameLine - plan.lockRoom >= plan.name.width && sizeLine >= size.width
            }
            return singleLine - plan.lockRoom >= plan.name.width
        }
    }

    /// Labels of the current arcs in draw order, placed without collisions; stops after the arc
    /// `through` when given.
    @MainActor
    static func place(_ poses: [(arc: SunburstMotion.Arc, pose: ArcPose)], geometry: ChartGeometry,
                      planner: LabelPlanner, in context: GraphicsContext, through stop: String? = nil) -> [Placed] {
        var placed: [Placed] = []
        var boxes: [LabelBox] = []
        for (arc, pose) in poses where arc.isCurrent {
            if let label = place(arc, pose: pose, geometry: geometry, planner: planner, context: context, boxes: &boxes) {
                placed.append(label)
            }
            if arc.segment.id == stop { break }
        }
        return placed
    }

    @MainActor
    private static func place(_ arc: SunburstMotion.Arc, pose: ArcPose, geometry: ChartGeometry,
                              planner: LabelPlanner, context: GraphicsContext, boxes: inout [LabelBox]) -> Placed? {
        guard pose.alpha > 0.5, geometry.drawableInner(pose) != nil, let room = Room(pose, geometry: geometry),
              let plan = planner.plan(for: arc, geometry: geometry, in: context),
              room.fits(plan)  // fitted for the target pose: an arc still growing towards it waits
        else { return nil }
        let midAngle = (pose.start + pose.end) / 2
        let point = geometry.point(angle: midAngle, radius: room.mid)
        let rotation = room.outward < 0 ? midAngle + .pi : midAngle
        let box = LabelBox(center: point, rotation: rotation,
                           halfWidth: max(plan.name.width + plan.lockRoom, plan.size?.width ?? 0) / 2 + 2,
                           halfHeight: plan.size != nil ? nameOffset + nameHalf : nameHalf)
        guard !boxes.contains(where: { $0.overlaps(box) }) else { return nil }
        boxes.append(box)
        return Placed(id: arc.segment.id, segment: arc.segment, plan: plan, pose: pose, point: point,
                      rotation: rotation)
    }

    static func draw(_ label: Placed, ink: Color, in context: GraphicsContext) {
        var c = context
        c.opacity = label.pose.alpha
        c.translateBy(x: label.point.x, y: label.point.y)
        c.rotate(by: .radians(label.rotation))
        let plan = label.plan
        let nameY = plan.size != nil ? -nameOffset : 0
        let name = c.resolve(Text(verbatim: plan.name.string).font(nameFont).foregroundStyle(ink))
        if plan.locked {
            // Lock glyph before the name; the pair stays centered.
            let lock = c.resolve(Text(Image(systemName: "lock.fill")).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ink))
            c.draw(lock, at: CGPoint(x: -(plan.name.width + plan.lockRoom) / 2 + 5, y: nameY), anchor: .center)
            c.draw(name, at: CGPoint(x: plan.lockRoom / 2, y: nameY), anchor: .center)
        } else {
            c.draw(name, at: CGPoint(x: 0, y: nameY), anchor: .center)
        }
        if let size = plan.size {
            c.draw(Text(verbatim: size.string).font(sizeFont).foregroundStyle(ink),
                   at: CGPoint(x: 0, y: sizeOffset), anchor: .center)
        }
    }
}

/// Fits labels once per chart generation (each retarget starts one) against their arcs' target
/// poses, so animation frames only position them. Fitted strings are kept for one more
/// generation, so a refresh re-measures only the labels whose text or room changed; the caches
/// never hold more than two generations' labels.
@MainActor
final class LabelPlanner {
    private enum Line: Hashable { case name, size }
    private struct TextKey: Hashable {
        let string: String
        let bucket: Int
        let line: Line
    }

    private var generation = -1
    private var size = CGSize.zero
    private var plans: [String: LabelPlan?] = [:]
    private var texts: [TextKey: FittedText?] = [:]
    private var previousTexts: [TextKey: FittedText?] = [:]

    /// Starts a new generation when the arcs or the chart size changed.
    func prepare(generation: Int, size: CGSize) {
        guard generation != self.generation || size != self.size else { return }
        self.generation = generation
        self.size = size
        plans.removeAll(keepingCapacity: true)
        swap(&texts, &previousTexts)
        texts.removeAll(keepingCapacity: true)
    }

    /// The label for `arc`, fitted against its target pose; nil when nothing useful fits.
    func plan(for arc: SunburstMotion.Arc, geometry: ChartGeometry, in context: GraphicsContext) -> LabelPlan? {
        if let plan = plans[arc.segment.id] { return plan }
        let plan = makePlan(arc.segment, target: arc.to, geometry: geometry, context: context)
        plans[arc.segment.id] = plan
        return plan
    }

    private func makePlan(_ segment: ArcSegment, target: ArcPose, geometry: ChartGeometry,
                          context: GraphicsContext) -> LabelPlan? {
        guard let room = RingLabel.Room(target, geometry: geometry) else { return nil }
        let locked = segment.flags.contains(.unreadable)
        let lockRoom = locked ? 14.0 : 0
        let title = SunburstView.title(of: segment)
        if geometry.ringWidth >= 34,
           let name = fitted(title, width: room.nameLine - lockRoom, line: .name, in: context),
           let size = fitted(Formatters.bytes(segment.size), width: room.sizeLine, line: .size, in: context) {
            return LabelPlan(name: name, size: size, locked: locked)
        }
        guard let name = fitted(title, width: room.singleLine - lockRoom, line: .name, in: context) else { return nil }
        return LabelPlan(name: name, size: nil, locked: locked)
    }

    /// `string` (for a name, its longest "…" prefix) that fits `width`, with its width; nil when
    /// nothing useful fits.
    private func fitted(_ string: String, width: Double, line: Line, in context: GraphicsContext) -> FittedText? {
        guard width > 20 else { return nil }
        let bucket = Int(width / 4)
        let key = TextKey(string: string, bucket: bucket, line: line)
        if let hit = texts[key] { return hit }
        if let hit = previousTexts[key] {
            texts[key] = hit
            return hit
        }
        let font = line == .name ? RingLabel.nameFont : RingLabel.sizeFont
        func measure(_ s: String) -> Double {
            context.resolve(Text(verbatim: s).font(font)).measure(in: CGSize(width: 10_000, height: 40)).width
        }
        let limit = Double(bucket * 4)
        var result: FittedText?
        let full = measure(string)
        if full <= limit {
            result = FittedText(string: string, width: full)
        } else if line == .name {
            let characters = Array(string)
            var low = 0, high = characters.count
            while low < high {
                let mid = (low + high + 1) / 2
                if measure(String(characters[..<mid]) + "…") <= limit { low = mid } else { high = mid - 1 }
            }
            if low >= 3 {
                let text = String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…"
                result = FittedText(string: text, width: measure(text))
            }
        }
        texts[key] = result
        return result
    }
}

/// Hover card: name, size and share of the current folder, file type, estimated last use, and
/// whether it could be read. Type and last use are always in words, whatever the color mode.
private struct SegmentTooltip: View {
    let segment: ArcSegment
    let total: UInt64
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: SunburstView.title(of: segment))
                .font(.callout.weight(.semibold))
                .foregroundStyle(FusionPalette.primaryText(scheme))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(verbatim: "\(Formatters.bytes(segment.size)) · \(Formatters.percent(segment.size, of: total))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(FusionPalette.secondaryText(scheme))
            Group {
                // A merged "altri" segment mixes types: only its latest use is meaningful.
                if segment.node != nil {
                    Text("Tipo: \(String(localized: segment.category.title))")
                }
                Text("Ultimo uso (stimato): \(Formatters.lastUsedDate(segment.lastUsed))")
            }
            .font(.callout)
            .foregroundStyle(FusionPalette.secondaryText(scheme))
            if segment.flags.contains(.unreadable) {
                Label("Non leggibile", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(FusionPalette.tooltipFill(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}
