import MacSpaceCore
import SwiftUI

/// The interactive treemap: three levels below `model.center` as nested tiles ("curated" look,
/// spec §5.1): rounded corners, gaps between tiles, and a discreet section header inside each
/// large folder. A folder whose children are drawn inside it is a *section*: a faint surface in
/// its color, its children on top. Every other tile is a *block*: a solid fill with a label when
/// there is room.
///
/// Layers, bottom to top: the tiles canvas, which redraws only when the tiles change or animate;
/// the hover layer, which exists only while a tile is hovered; and the pointer layer. `body`
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
    /// Whether this view has told the model its size yet: the first report is not debounced.
    @State private var reportedSize = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Resizing the window relays out the map only once the size has held this long.
    static let resizeDebounce: Duration = .milliseconds(100)

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
                if model.breadcrumb.isEmpty && !model.isScanning {
                    Text("Scegli cosa analizzare e premi Analizza")
                        .font(.title3)
                        .foregroundStyle(FusionPalette.secondaryText(scheme))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
                TreemapPointerLayer(model: model, motion: motion, motionGeneration: motionGeneration,
                                    canvas: canvas, total: model.breadcrumb.last?.size ?? 0)
            }
            .task(id: proxy.size) {
                let size = proxy.size
                if reportedSize {
                    try? await Task.sleep(for: Self.resizeDebounce)
                    guard !Task.isCancelled else { return }
                }
                reportedSize = true
                if model.chartSize != size { model.chartSize = size }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: model.breadcrumb.last?.name ?? ""))
        .accessibilityValue(Text(verbatim: Formatters.bytes(model.breadcrumb.last?.size ?? 0)))
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
                change = .zoomOut(CGRect(x: previous.x, y: previous.y, width: previous.width, height: previous.height))
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
        for (item, pose) in poses {
            guard pose.alpha > 0.01, let rect = canvas.drawn(pose.rect) else { continue }
            Self.drawTile(item, pose: pose, rect: rect, canvas: canvas, labels: labels, mode: colorMode,
                          lift: 0, scheme: scheme, in: context)
        }
    }

    /// One tile at `rect` (its drawn rect): a section's surface and header, or a block's fill and
    /// label. The hover layer draws the hovered tile again with `lift`.
    static func drawTile(_ item: TreemapMotion.Item, pose: TilePose, rect: CGRect, canvas: TreemapCanvas,
                         labels: TileLabelPlanner, mode: ColorMode, lift: Double, scheme: ColorScheme,
                         in context: GraphicsContext) {
        let tile = item.tile
        let subject = FusionPalette.FillSubject(tile)
        let shape = Self.shape(rect, depth: tile.depth)
        let alpha = min(max(pose.alpha, 0), 1)
        if item.isSection {
            let surface = labels.surface(for: item, lift: lift)
            context.fill(shape, with: .color(FusionPalette.color(surface).opacity(alpha)))
            if tile.hasHeader, let header = labels.header(for: item, canvas: canvas, in: context) {
                drawHeader(header, in: rect, canvas: canvas, alpha: alpha, scheme: scheme, context: context)
            }
        } else {
            let fill = FusionPalette.fill(subject, mode: mode, depth: pose.shadeDepth, step: pose.shadeStep,
                                          lift: lift, scheme: scheme)
            context.fill(shape, with: .color(fill.opacity(alpha)))
            if rect.width >= TileLabelPlanner.minLabelWidth, rect.height >= TileLabelPlanner.minLabelHeight,
               let label = labels.leaf(for: item, canvas: canvas, in: context), label.fits(rect.width) {
                let ink = FusionPalette.label(subject, mode: mode, depth: pose.shadeDepth, step: pose.shadeStep,
                                              lift: lift, scheme: scheme)
                drawLabel(label, in: rect, ink: ink, alpha: alpha, context: context)
            }
        }
    }

    /// Rounded tile outline: 6 pt corners on the first level, 4 pt deeper; small tiles get
    /// proportionally smaller corners, so they stay tiles instead of turning into dots.
    static func shape(_ rect: CGRect, depth: Int) -> Path {
        let radius = min(depth <= 1 ? 6.0 : 4.0, min(rect.width, rect.height) / 4)
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }

    private static func drawLabel(_ label: TileLabelPlanner.Leaf, in rect: CGRect, ink: Color, alpha: Double,
                                  context: GraphicsContext) {
        var c = context
        c.opacity = alpha
        c.clip(to: Path(rect))
        var x = rect.minX + TileLabelPlanner.padding
        let y = rect.minY + TileLabelPlanner.labelTop
        if label.locked {
            c.draw(Text(Image(systemName: "lock.fill")).font(.system(size: 9, weight: .semibold)).foregroundStyle(ink),
                   at: CGPoint(x: x + 5, y: y + TileLabelPlanner.nameHeight / 2), anchor: .center)
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
        c.draw(TileLabelPlanner.headerText(header.name.string).foregroundStyle(ink),
               at: CGPoint(x: rect.minX + TileLabelPlanner.padding, y: midY), anchor: .leading)
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

/// Fits tile labels and section headers once per map generation (each retarget starts one)
/// against the tiles' target rects, so animation frames only position them; and keeps each
/// section's surface color, which depends on the enclosing section's. Fitted strings are kept
/// for one more generation, so a scan refresh re-measures only what changed.
@MainActor
final class TileLabelPlanner {
    nonisolated static let nameFont = Font.system(size: 11, weight: .semibold)
    nonisolated static let sizeFont = Font.system(size: 10).monospacedDigit()
    nonisolated static let headerFont = Font.system(size: 11, weight: .semibold)
    nonisolated static let headerSizeFont = Font.system(size: 11, weight: .medium).monospacedDigit()
    nonisolated static let headerTracking = 0.5
    /// A block shows its name and size only when its drawn rect is at least this big.
    nonisolated static let minLabelWidth = 56.0, minLabelHeight = 30.0
    nonisolated static let padding = 6.0, labelTop = 3.5, nameHeight = 14.0, lockRoom = 13.0

    static func headerText(_ string: String) -> Text {
        Text(verbatim: string).font(headerFont).tracking(headerTracking)
    }

    /// A block's label: its name ("…"-truncated) and, on a second line, its size.
    struct Leaf {
        let name: FittedText
        let size: FittedText?
        let locked: Bool

        func fits(_ width: Double) -> Bool {
            let room = width - 2 * TileLabelPlanner.padding
            return name.width + (locked ? TileLabelPlanner.lockRoom : 0) <= room && (size?.width ?? 0) <= room
        }
    }

    /// A section header: the uppercased name and, right-aligned, the size when both fit.
    struct Header {
        let name: FittedText
        let size: FittedText?
        /// Drawn width the header needs.
        var width: Double {
            name.width + (size.map { $0.width + TileLabelPlanner.headerSpacing } ?? 0) + 2 * TileLabelPlanner.padding
        }
    }

    nonisolated static let headerSpacing = 10.0
    /// The size drops out of a header before the name would get narrower than this.
    static let headerNameMinWidth = 72.0

    private enum Line: Hashable { case name, size, header, headerSize }
    private struct TextKey: Hashable {
        let string: String
        let bucket: Int
        let line: Line
    }
    private struct SurfaceKey: Hashable {
        let id: String
        let lifted: Bool
    }

    private var generation = -1
    private var size = CGSize.zero
    private var mode = ColorMode.neutral
    private var scheme = ColorScheme.light
    private var leaves: [String: Leaf?] = [:]
    private var headers: [String: Header?] = [:]
    private var surfaces: [SurfaceKey: Contrast.RGB] = [:]
    private var texts: [TextKey: FittedText?] = [:]
    private var previousTexts: [TextKey: FittedText?] = [:]

    /// Starts a new generation when the tiles, the canvas size, the colors or the appearance changed.
    func prepare(generation: Int, size: CGSize, mode: ColorMode, scheme: ColorScheme) {
        guard generation != self.generation || size != self.size || mode != self.mode || scheme != self.scheme
        else { return }
        if mode != self.mode || scheme != self.scheme || generation != self.generation {
            surfaces.removeAll(keepingCapacity: true)
        }
        self.generation = generation
        self.size = size
        self.mode = mode
        self.scheme = scheme
        leaves.removeAll(keepingCapacity: true)
        headers.removeAll(keepingCapacity: true)
        swap(&texts, &previousTexts)
        texts.removeAll(keepingCapacity: true)
    }

    /// The surface of section `item` (`lift` > 0 while hovered), over its enclosing section's
    /// resting surface or the background.
    func surface(for item: TreemapMotion.Item, lift: Double) -> Contrast.RGB {
        let key = SurfaceKey(id: item.tile.id, lifted: lift > 0)
        if let hit = surfaces[key] { return hit }
        let base = surfaces[SurfaceKey(id: "\(item.tile.parent)", lifted: false)] ?? FusionPalette.backgroundRGB(scheme)
        let tint = FusionPalette.fillRGB(.init(item.tile), mode: mode, depth: item.to.shadeDepth,
                                         step: item.to.shadeStep, lift: lift, scheme: scheme)
        let surface = FusionPalette.sectionSurface(tint: tint, over: base, scheme: scheme)
        surfaces[key] = surface
        return surface
    }

    /// The label of block `item`, fitted to its target rect; nil when the target is too small.
    func leaf(for item: TreemapMotion.Item, canvas: TreemapCanvas, in context: GraphicsContext) -> Leaf? {
        if let plan = leaves[item.tile.id] { return plan }
        var plan: Leaf?
        if let rect = canvas.drawn(item.to.rect), rect.width >= Self.minLabelWidth, rect.height >= Self.minLabelHeight {
            let locked = item.tile.flags.contains(.unreadable)
            let room = rect.width - 2 * Self.padding
            if let name = fitted(TreemapView.title(of: item.tile), width: room - (locked ? Self.lockRoom : 0),
                                 line: .name, in: context) {
                plan = Leaf(name: name, size: fitted(Formatters.bytes(item.tile.size), width: room, line: .size,
                                                     in: context),
                            locked: locked)
            }
        }
        leaves[item.tile.id] = plan
        return plan
    }

    /// The header of section `item`, fitted to its target rect.
    func header(for item: TreemapMotion.Item, canvas: TreemapCanvas, in context: GraphicsContext) -> Header? {
        if let plan = headers[item.tile.id] { return plan }
        var plan: Header?
        if let rect = canvas.drawn(item.to.rect) {
            let room = rect.width - 2 * Self.padding
            let name = item.tile.name.uppercased(with: Locale(identifier: "it_IT"))
            let size = fitted(Formatters.bytes(item.tile.size), width: room, line: .headerSize, in: context)
            // The size stays only while the name keeps a useful width beside it.
            if let size, room - size.width - Self.headerSpacing >= Self.headerNameMinWidth,
               let fittedName = fitted(name, width: room - size.width - Self.headerSpacing, line: .header,
                                       in: context) {
                plan = Header(name: fittedName, size: size)
            } else if let fittedName = fitted(name, width: room, line: .header, in: context) {
                plan = Header(name: fittedName, size: nil)
            }
        }
        headers[item.tile.id] = plan
        return plan
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
        func measure(_ s: String) -> Double {
            let text = switch line {
            case .name: Text(verbatim: s).font(Self.nameFont)
            case .size: Text(verbatim: s).font(Self.sizeFont)
            case .header: Self.headerText(s)
            case .headerSize: Text(verbatim: s).font(Self.headerSizeFont)
            }
            return context.resolve(text).measure(in: CGSize(width: 10_000, height: 40)).width
        }
        let limit = Double(bucket * 4)
        var result: FittedText?
        let full = measure(string)
        if full <= limit {
            result = FittedText(string: string, width: full)
        } else if line == .name || line == .header {
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
