import MacSpaceCore
import SwiftUI

/// The interactive treemap: three levels below `model.center` as nested tiles ("curated" look,
/// spec §5.1): rounded corners, gaps between tiles, and a discreet section header inside each
/// large folder. A folder whose children are drawn inside it is a *section*: a faint surface in
/// its color, its children on top. Every other tile is a *block*: a solid fill with a label when
/// there is room.
///
/// Layers, bottom to top: the tiles canvas, which redraws only when the tiles change or animate;
/// the hover layer, which exists only while a tile is hovered; the selection layer, which exists
/// only while something is selected or highlighted; and the pointer layer. `body`
/// never reads `model.hoveredTile`, so hovering redraws only the small layer that shows it.
struct TreemapView: View {
    let model: ScanModel
    /// Changing it only repaints the tiles; it never relays them out or animates them.
    let colorMode: ColorMode

    @State private var motion = TreemapMotion()
    /// The center `motion` is showing; tells refreshes apart from navigation.
    @State private var motionCenter: NodeID = FileTree.root
    @State private var animating = false
    @State private var motionGeneration = 0
    @State private var labels = TileLabelPlanner()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let canvas = TreemapCanvas(size: proxy.size, layoutSize: motion.size)
            let moving = animating || showsPlaceholderMotion
            let generation = motionGeneration
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !moving)) { timeline in
                    let date = moving ? timeline.date : .distantFuture
                    // Rasterized off the main thread: during a scan it redraws on refreshes.
                    Canvas(rendersAsynchronously: true) { context, _ in
                        Perf.interval("treemap draw") {
                            draw(in: &context, canvas: canvas, generation: generation, date: date)
                        }
                    }
                }
                TreemapHoverLayer(model: model, motion: motion, labels: labels, generation: generation,
                                  canvas: canvas, colorMode: colorMode, moving: animating)
                TreemapSelectionLayer(model: model, motion: motion, canvas: canvas, moving: animating)
                TreemapPointerLayer(model: model, motion: motion, motionGeneration: motionGeneration,
                                    canvas: canvas, total: model.breadcrumb.last?.size ?? 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: ChartAccessibility.label(for: model)))
        .chartUpAction(enabled: model.breadcrumb.count > 1) { model.goUp() }
        .accessibilityChildren { accessibleTiles }
        .onAppear {
            motion.retarget(to: model.tiles, size: model.tilesSize, change: .refresh, at: .now, animated: false)
            motionCenter = model.center
        }
        .onChange(of: model.tiles) { old, new in
            retarget(from: old, to: new)
        }
        .task(id: motionGeneration) {
            guard animating else { return }
            try? await Task.sleep(for: .seconds(max(motion.endsAt.timeIntervalSinceNow, 0) + 0.03))
            if !Task.isCancelled { animating = false }
        }
    }

    // MARK: Accessibility

    /// The largest tiles as VoiceOver children, each on its own slot.
    private var accessibleTiles: some View {
        GeometryReader { proxy in
            let canvas = TreemapCanvas(size: proxy.size, layoutSize: motion.size)
            ForEach(LargestElements.of(model.tiles) { $0.size }) { tile in
                let subject = SegmentTooltip.Subject(tile: tile, verdict: tile.node.flatMap { model.verdicts[$0] })
                let slot = canvas.slot(tile.slot)
                Color.clear
                    .frame(width: slot.width, height: slot.height)
                    .position(x: slot.midX, y: slot.midY)
                    .accessibilityElement()
                    .accessibilityLabel(Text(verbatim: subject.spokenTitle))
                    .accessibilityValue(Text(verbatim: subject.spokenValue))
                    .chartOpenAction(node: tile.node, hasChildren: tile.hasChildren) { model.drill(into: $0) }
                    .selectionAction(node: tile.node, model: model)
            }
        }
    }

    // MARK: State

    /// Before the first tiles arrive, a scan shows a sweeping placeholder.
    private var showsPlaceholderMotion: Bool { model.isScanning && model.tiles.isEmpty }

    private func retarget(from old: [TreemapTile], to new: [TreemapTile]) {
        Perf.interval("treemap retarget") {
            let size = model.tilesSize
            let date = Date.now
            let change: TreemapChange
            if new.isEmpty || old.isEmpty && model.center != motionCenter {
                change = .unrelated
            } else if model.center == motionCenter {
                change = .refresh
            } else if let target = motion.current("\(model.center)", at: date) {
                // Where the new center is drawn now, in the new layout's coordinates.
                let rescale = TreemapCanvas(size: size, layoutSize: motion.size)
                change = .zoomIn(rescale.slot(target.pose.rect))
            } else if let previous = new.first(where: { $0.node == motionCenter }) {
                change = .zoomOut(previous.slot)
            } else {
                change = .unrelated
            }
            motionCenter = model.center
            animating = motion.retarget(to: new, size: size, change: change, at: date,
                                        animated: !reduceMotion && !new.isEmpty)
            motionGeneration += 1
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, canvas: TreemapCanvas, generation: Int, date: Date) {
        let poses = motion.poses(at: date)
        if poses.isEmpty {
            drawPlaceholder(in: &context, size: canvas.size, date: date)
            return
        }
        labels.prepare(generation: generation, size: canvas.size, mode: colorMode, scheme: scheme)
        var locks = SafetyDecor.Locks()
        for (item, pose) in poses where item.isVisible {
            guard pose.alpha > 0.01, let rect = canvas.drawn(pose.rect) else { continue }
            Self.drawTile(item, pose: pose, rect: rect, canvas: canvas, motion: motion, labels: labels,
                          mode: colorMode, lift: 0, scheme: scheme, scale: displayScale, locks: &locks, in: context)
        }
    }

    /// One tile at `rect` (its drawn rect): a section's surface and header, or a block's fill and
    /// label; a merged "altri" block in "by file type" mode also gets its dashed outline. In
    /// "Eliminabili" a caution block is hatched, and a protected tile carries the lock: in its label
    /// or header when it has one, else at its center when it is big enough. The hover layer draws
    /// the hovered tile again with `lift`. `scale` is the display's pixels per point.
    static func drawTile(_ item: TreemapMotion.Item, pose: TilePose, rect: CGRect, canvas: TreemapCanvas,
                         motion: TreemapMotion, labels: TileLabelPlanner, mode: ColorMode, lift: Double,
                         scheme: ColorScheme, scale: Double, locks: inout SafetyDecor.Locks,
                         in context: GraphicsContext) {
        let tile = item.tile
        let subject = FusionPalette.FillSubject(tile)
        let shape = Self.shape(rect, depth: tile.depth)
        let alpha = min(max(pose.alpha, 0), 1)
        if item.isSection {
            let surface = labels.surface(for: item, lift: lift, motion: motion)
            context.fill(shape, with: .color(FusionPalette.color(surface).opacity(alpha)))
            if tile.hasHeader, let header = labels.header(for: item, canvas: canvas, in: context) {
                drawHeader(header, in: rect, canvas: canvas, alpha: alpha, scheme: scheme, context: context)
            }
        } else {
            // A merged block takes a tone close to what it sits on; no other block needs that.
            let base = subject.isMerged && mode == .category ? labels.base(for: item, motion: motion) : nil
            let fill = FusionPalette.fill(subject, mode: mode, depth: pose.shadeDepth, step: pose.shadeStep,
                                          lift: lift, on: base, scheme: scheme)
            context.fill(shape, with: .color(fill.opacity(alpha)))
            if subject.isHatched(in: mode) {
                SafetyDecor.hatch(in: shape, color: FusionPalette.hatch(scheme, lift: lift).opacity(alpha),
                                  canvas: canvas.size, in: context)
            }
            if base != nil {
                let outline = labels.mergedOutline(for: item, hovered: lift > 0, motion: motion)
                MergedOutline.strokeTile(rect, radius: cornerRadius(rect, depth: tile.depth),
                                         color: outline.opacity(alpha), scale: scale, in: context)
            }
            // Solved only for a tile that shows a label or a lock.
            func ink() -> Color {
                FusionPalette.label(subject, mode: mode, depth: pose.shadeDepth, step: pose.shadeStep, lift: lift,
                                    on: base, scheme: scheme)
            }
            if rect.width >= TileLabelPlanner.minLabelWidth, rect.height >= TileLabelPlanner.minLabelHeight,
               let label = labels.leaf(for: item, canvas: canvas, in: context), label.fits(rect.width) {
                drawLabel(label, in: rect, ink: ink(), alpha: alpha, context: context)
            } else if subject.isLocked(in: mode), alpha > 0.5,
                      SafetyDecor.fitsLock(width: rect.width, height: rect.height) {
                locks.lock(at: CGPoint(x: rect.midX, y: rect.midY), ink: ink(), alpha: alpha, in: context)
            }
        }
    }

    /// Rounded tile outline: 6 pt corners on the first level, 4 pt deeper; small tiles get
    /// proportionally smaller corners, so they stay tiles instead of turning into dots.
    static func shape(_ rect: CGRect, depth: Int) -> Path {
        Path(roundedRect: rect, cornerRadius: cornerRadius(rect, depth: depth), style: .continuous)
    }

    static func cornerRadius(_ rect: CGRect, depth: Int) -> Double {
        min(depth <= 1 ? 6.0 : 4.0, min(rect.width, rect.height) / 4)
    }

    private static func drawLabel(_ label: TileLabelPlanner.Leaf, in rect: CGRect, ink: Color, alpha: Double,
                                  context: GraphicsContext) {
        var c = context
        c.opacity = alpha
        c.clip(to: Path(rect))
        var x = rect.minX + TileLabelPlanner.padding
        let y = rect.minY + TileLabelPlanner.labelTop
        if label.locked {
            c.draw(SafetyDecor.lockText(ink), at: CGPoint(x: x + 5, y: y + TileLabelPlanner.nameHeight / 2),
                   anchor: .center)
            x += TileLabelPlanner.lockRoom
        }
        c.draw(Text(verbatim: label.name.string).font(TileLabelPlanner.nameFont).foregroundStyle(ink),
               at: CGPoint(x: x, y: y), anchor: .topLeading)
        if let size = label.size {
            c.draw(Text(verbatim: size.string).font(TileLabelPlanner.sizeFont).foregroundStyle(ink),
                   at: CGPoint(x: rect.minX + TileLabelPlanner.padding, y: y + TileLabelPlanner.nameHeight),
                   anchor: .topLeading)
        }
    }

    static func drawHeader(_ header: TileLabelPlanner.Header, in rect: CGRect, canvas: TreemapCanvas,
                           alpha: Double, scheme: ColorScheme, context: GraphicsContext) {
        let band = canvas.headerHeight
        guard band >= 12, rect.width >= header.width else { return }
        var c = context
        c.opacity = alpha
        c.clip(to: Path(rect))
        let ink = FusionPalette.secondaryText(scheme)
        let midY = rect.minY + band / 2 + 0.5
        var x = rect.minX + TileLabelPlanner.padding
        if header.locked {
            c.draw(SafetyDecor.lockText(ink), at: CGPoint(x: x + 5, y: midY), anchor: .center)
            x += TileLabelPlanner.lockRoom
        }
        c.draw(TileLabelPlanner.headerText(header.name.string).foregroundStyle(ink),
               at: CGPoint(x: x, y: midY), anchor: .leading)
        if let size = header.size {
            c.draw(Text(verbatim: size.string).font(TileLabelPlanner.headerSizeFont).foregroundStyle(ink),
                   at: CGPoint(x: rect.maxX - TileLabelPlanner.padding, y: midY), anchor: .trailing)
        }
    }

    /// Faint map while there is nothing to draw; while scanning, a soft highlight sweeps across it
    /// (with Reduce Motion, it breathes instead).
    private func drawPlaceholder(in context: inout GraphicsContext, size: CGSize, date: Date) {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: TreemapCanvas.gap / 2, dy: TreemapCanvas.gap / 2)
        guard rect.width > 1, rect.height > 1 else { return }
        let shape = Self.shape(rect, depth: 1)
        let tone = FusionPalette.ring(lightness: FusionPalette.ringLightness(depth: 2, step: 0, scheme: scheme),
                                      scheme: scheme)
        let time = date == .distantFuture ? 0 : date.timeIntervalSinceReferenceDate
        if !model.isScanning {
            context.fill(shape, with: .color(tone.opacity(0.09)))
        } else if reduceMotion {
            let breath = 0.5 + 0.5 * sin(time * 2 * .pi / 2.4)
            context.fill(shape, with: .color(tone.opacity(0.08 + 0.16 * breath)))
        } else {
            context.fill(shape, with: .color(tone.opacity(0.09)))
            let phase = time.truncatingRemainder(dividingBy: 1.8) / 1.8
            let width = rect.width * 0.6
            let x = rect.minX - width + (rect.width + width) * phase
            let gradient = Gradient(colors: [tone.opacity(0), tone.opacity(0.35), tone.opacity(0)])
            var sweep = context
            sweep.clip(to: shape)
            sweep.fill(Path(rect), with: .linearGradient(gradient, startPoint: CGPoint(x: x, y: rect.midY),
                                                         endPoint: CGPoint(x: x + width, y: rect.midY)))
        }
    }

    static func title(of tile: TreemapTile) -> String {
        // The layout only merges two or more siblings, so "Altri" is always plural.
        tile.node == nil ? String(localized: "Altri \(Formatters.count(tile.otherCount)) elementi") : tile.name
    }
}
