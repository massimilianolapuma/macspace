import MacSpaceCore
import SwiftUI

/// The interactive sunburst: rings of the three levels below `model.center`.
///
/// The pointer lives in `SunburstPointerLayer`, so mouse moves redraw only that small layer;
/// the canvas redraws when the arcs, the hovered segment or the center hover change.
struct SunburstView: View {
    let model: ScanModel

    @State private var motion = SunburstMotion()
    /// The center `motion` is showing; tells refreshes apart from navigation.
    @State private var motionCenter: NodeID = FileTree.root
    @State private var animating = false
    @State private var motionGeneration = 0
    @State private var hoveringCenter = false
    @State private var labels = LabelFitter()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let geometry = ChartGeometry(size: proxy.size)
            let hoveredID = model.hovered?.id
            let moving = animating || showsPlaceholderMotion
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
                    // Rasterized off the main thread: during a scan it redraws several times a second.
                    Canvas(rendersAsynchronously: true) { context, _ in
                        draw(in: &context, geometry: geometry, hoveredID: hoveredID,
                             date: moving ? timeline.date : .distantFuture)
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
                                     geometry: geometry, canGoUp: canGoUp, total: centerSize,
                                     hoveringCenter: $hoveringCenter)
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
        let animate = !reduceMotion && !new.isEmpty
        motion.retarget(to: new, change: change, at: .now, animated: animate)
        animating = animate
        motionGeneration += 1
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
            if hoveringCenter && canGoUp {
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .offset(y: -18)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: centerSize)
        .animation(.easeOut(duration: 0.15), value: hoveringCenter)
        .opacity(model.breadcrumb.isEmpty ? 0 : 1)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, geometry: ChartGeometry, hoveredID: String?, date: Date) {
        let background = FusionPalette.background(scheme)

        var rings = context
        var band = Path(ellipseIn: geometry.rect(radius: geometry.radius))
        band.addPath(Path(ellipseIn: geometry.rect(radius: geometry.centerRadius)))
        rings.clip(to: band, style: FillStyle(eoFill: true))

        let poses = motion.poses(at: date)
        if poses.isEmpty {
            drawPlaceholder(in: &rings, band: band, geometry: geometry, date: date)
        }

        var drawn: [(path: Path, arc: SunburstMotion.Arc, pose: ArcPose, inner: Double, lightness: Double)] = []
        drawn.reserveCapacity(poses.count)
        for (arc, pose) in poses where pose.alpha > 0.01 && pose.end - pose.start > 0.0004 {
            let inner = geometry.innerRadius(depth: pose.depth)
            let outer = inner + geometry.ringWidth
            guard outer > geometry.centerRadius, inner < geometry.radius else { continue }
            let path = Self.sector(center: geometry.center, inner: inner, outer: outer,
                                   start: pose.start, end: pose.end)
            var lightness = FusionPalette.ringLightness(depth: pose.shadeDepth, step: pose.shadeStep, scheme: scheme)
            if arc.isCurrent, arc.segment.id == hoveredID { lightness += FusionPalette.hoverLift }
            rings.fill(path, with: .color(FusionPalette.ring(lightness: lightness, scheme: scheme).opacity(pose.alpha)))
            drawn.append((path, arc, pose, inner, lightness))
        }
        for item in drawn where (item.inner + geometry.ringWidth) * (item.pose.end - item.pose.start) >= 4 {
            // Hairline slivers get no separator of their own: a run of them reads as one tone
            // instead of a white blur.
            rings.stroke(item.path, with: .color(background.opacity(item.pose.alpha)), lineWidth: 1)
        }
        var placed: [LabelBox] = []
        for item in drawn where item.arc.isCurrent {
            drawLabel(in: &rings, segment: item.arc.segment, pose: item.pose, inner: item.inner,
                      lightness: item.lightness, geometry: geometry, placed: &placed)
        }

        let disc = Path(ellipseIn: geometry.rect(radius: geometry.centerRadius - 0.5))
        let discColor = hoveringCenter && canGoUp ? FusionPalette.centerHover(scheme) : FusionPalette.centerFill(scheme)
        context.fill(disc, with: .color(discColor))
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

    private static let nameFont = Font.system(size: 11, weight: .semibold)
    private static let sizeFont = Font.system(size: 10).monospacedDigit()
    /// Half heights of the label lines and their offsets from the ring's mid radius.
    private static let nameHalf = 7.0, sizeHalf = 6.5, nameOffset = 6.5, sizeOffset = 7.0

    /// Draws a segment's name (and size, when there is room) as straight text along the ring.
    /// Each line is fitted to the room at the radius where it sits: within the segment's angle
    /// at the line's inner edge, and inside the ring where its ends bow outwards. A label
    /// whose box would touch one already placed is skipped.
    private func drawLabel(in context: inout GraphicsContext, segment: ArcSegment, pose: ArcPose, inner: Double,
                           lightness: Double, geometry: ChartGeometry, placed: inout [LabelBox]) {
        guard pose.alpha > 0.5, inner >= geometry.centerRadius - 0.5,
              inner + geometry.ringWidth <= geometry.radius + 0.5 else { return }
        let span = pose.end - pose.start
        let mid = inner + geometry.ringWidth / 2
        guard mid * span >= 60 else { return }
        let outer = inner + geometry.ringWidth

        /// Widest straight line centered on the mid angle at radius `r` with half height `h`.
        func room(_ r: Double, _ h: Double) -> Double {
            guard r - h >= inner + 2 else { return 0 }
            let angular = span / 2 >= .pi / 2 - 0.05 ? .infinity : 2 * ((r - h) * tan(span / 2) - 4)
            let bowLimit = (outer - 3) * (outer - 3) - (r + h) * (r + h)
            let bow = bowLimit > 0 ? 2 * bowLimit.squareRoot() : 0
            return min(angular, bow, 200)
        }

        let midAngle = (pose.start + pose.end) / 2
        let upright = midAngle > .pi / 2 && midAngle < 3 * .pi / 2
        // Local "up" points outwards on the top half and inwards on the flipped bottom half.
        let outward: Double = upright ? -1 : 1
        let locked = segment.flags.contains(.unreadable)
        let lockRoom = locked ? 14.0 : 0
        let title = Self.title(of: segment)
        let sizeText = Formatters.bytes(segment.size)

        var name: FittedText?
        var size: FittedText?
        if geometry.ringWidth >= 34 {
            let nameRoom = room(mid + outward * Self.nameOffset, Self.nameHalf) - lockRoom
            let sizeRoom = room(mid - outward * Self.sizeOffset, Self.sizeHalf)
            name = labels.fitted(title, width: nameRoom, in: context, font: Self.nameFont)
            size = labels.fitted(sizeText, width: sizeRoom, in: context, font: Self.sizeFont, truncate: false)
        }
        let twoLines = name != nil && size != nil
        if !twoLines {
            size = nil
            name = labels.fitted(title, width: room(mid, Self.nameHalf) - lockRoom, in: context, font: Self.nameFont)
        }
        guard let name else { return }

        let point = geometry.point(angle: midAngle, radius: mid)
        let rotation = upright ? midAngle + .pi : midAngle
        let box = LabelBox(center: point, rotation: rotation,
                           halfWidth: (max(name.width + lockRoom, size?.width ?? 0)) / 2 + 2,
                           halfHeight: twoLines ? Self.nameOffset + Self.nameHalf : Self.nameHalf)
        guard !placed.contains(where: { $0.overlaps(box) }) else { return }
        placed.append(box)

        let ink = FusionPalette.ringLabel(lightness: lightness, scheme: scheme)
        var label = context
        label.opacity = pose.alpha
        label.translateBy(x: point.x, y: point.y)
        label.rotate(by: .radians(rotation))
        let nameY = twoLines ? -Self.nameOffset : 0
        let nameText = label.resolve(Text(verbatim: name.string).font(Self.nameFont).foregroundStyle(ink))
        if locked {
            // Lock glyph before the name; the pair stays centered.
            let lock = label.resolve(Text(Image(systemName: "lock.fill")).font(.system(size: 9, weight: .semibold))
                .foregroundStyle(ink))
            label.draw(lock, at: CGPoint(x: -(name.width + lockRoom) / 2 + 5, y: nameY), anchor: .center)
            label.draw(nameText, at: CGPoint(x: lockRoom / 2, y: nameY), anchor: .center)
        } else {
            label.draw(nameText, at: CGPoint(x: 0, y: nameY), anchor: .center)
        }
        if let size {
            label.draw(Text(verbatim: size.string).font(Self.sizeFont).foregroundStyle(ink),
                       at: CGPoint(x: 0, y: Self.sizeOffset), anchor: .center)
        }
    }

    static func title(of segment: ArcSegment) -> String {
        // The layout only merges two or more siblings, so "Altri" is always plural.
        segment.node == nil ? String(localized: "Altri \(Formatters.count(segment.otherCount)) elementi") : segment.name
    }

    /// Annular sector between radii, angles from 12 o'clock clockwise.
    private static func sector(center: CGPoint, inner: Double, outer: Double, start: Double, end: Double) -> Path {
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
    @Binding var hoveringCenter: Bool
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
                    if hoveringCenter { hoveringCenter = false }
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
        if hoveringCenter { return canGoUp }
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
        let target = self.target(at: pointer)
        let overCenter = target == .center
        if hoveringCenter != overCenter { hoveringCenter = overCenter }
        let segment: ArcSegment? = if case let .segment(segment) = target { segment } else { nil }
        chartHoveredID = segment?.id
        if model.hovered != segment { model.hovered = segment }
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

    func innerRadius(depth: Double) -> Double { centerRadius + (depth - 1) * ringWidth }

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

/// Truncates labels to a width, remembering results so animation frames stay cheap.
@MainActor
final class LabelFitter {
    private var cache: [String: FittedText?] = [:]

    /// `string` (or its longest "…" prefix when `truncate`) that fits `width`, with its width;
    /// nil when nothing useful fits.
    func fitted(_ string: String, width: Double, in context: GraphicsContext, font: Font,
                truncate: Bool = true) -> FittedText? {
        guard width > 20 else { return nil }
        let bucket = Int(width / 4)
        let limit = Double(bucket * 4)
        let key = "\(bucket)|\(truncate)|\(string)"
        if let hit = cache[key] { return hit }
        func measure(_ s: String) -> Double {
            context.resolve(Text(verbatim: s).font(font)).measure(in: CGSize(width: 10_000, height: 40)).width
        }
        var result: FittedText?
        let full = measure(string)
        if full <= limit {
            result = FittedText(string: string, width: full)
        } else if truncate {
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
        if cache.count > 4000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = result
        return result
    }
}

/// Hover card: name, size and share of the current folder, and whether it could be read.
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

