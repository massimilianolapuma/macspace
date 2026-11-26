import MacSpaceCore
import SwiftUI

/// Fits tile labels and section headers once per map generation (each retarget starts one)
/// against the tiles' settled rects, so animation frames only position them; and keeps each
/// section's surface color, which depends on the enclosing section's. Text fitting is the shared
/// `TextFitter`, so a scan refresh re-measures only what changed.
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
    /// Plans and surfaces are kept per tile *and* per side of a transition: during a zoom the
    /// leaving copy of a tile has another rect, shade and parent than the current one.
    private struct PlanKey: Hashable {
        let id: String
        let isCurrent: Bool
    }
    private struct SurfaceKey: Hashable {
        let plan: PlanKey
        let lifted: Bool
    }

    private var generation = -1
    private var size = CGSize.zero
    private var mode = ColorMode.neutral
    private var scheme = ColorScheme.light
    private var leaves: [PlanKey: Leaf?] = [:]
    private var headers: [PlanKey: Header?] = [:]
    private var surfaces: [SurfaceKey: Contrast.RGB] = [:]
    private var mergedOutlines: [SurfaceKey: Color] = [:]
    private let fitter = TextFitter<Line>(
        text: { string, line in
            switch line {
            case .name: Text(verbatim: string).font(TileLabelPlanner.nameFont)
            case .size: Text(verbatim: string).font(TileLabelPlanner.sizeFont)
            case .header: TileLabelPlanner.headerText(string)
            case .headerSize: Text(verbatim: string).font(TileLabelPlanner.headerSizeFont)
            }
        },
        truncates: { $0 == .name || $0 == .header })

    /// Starts a new generation when the tiles, the canvas size, the colors or the appearance changed.
    func prepare(generation: Int, size: CGSize, mode: ColorMode, scheme: ColorScheme) {
        guard generation != self.generation || size != self.size || mode != self.mode || scheme != self.scheme
        else { return }
        if mode != self.mode || scheme != self.scheme || generation != self.generation {
            surfaces.removeAll(keepingCapacity: true)
            mergedOutlines.removeAll(keepingCapacity: true)
        }
        self.generation = generation
        self.size = size
        self.mode = mode
        self.scheme = scheme
        leaves.removeAll(keepingCapacity: true)
        headers.removeAll(keepingCapacity: true)
        fitter.newGeneration()
    }

    private static func key(_ item: TreemapMotion.Item) -> PlanKey {
        PlanKey(id: item.tile.id, isCurrent: item.isCurrent)
    }

    /// Where `item` sits settled, which its text is fitted to: a current tile's target, a leaving
    /// tile's start (where it was on screen).
    private static func settledRect(_ item: TreemapMotion.Item) -> CGRect {
        item.isCurrent ? item.to.rect : item.from.rect
    }

    /// What `item` sits on: its parent section's resting surface (resolved through `motion`,
    /// whatever was drawn first) or the background.
    func base(for item: TreemapMotion.Item, motion: TreemapMotion) -> Contrast.RGB {
        motion.parent(of: item).map { surface(for: $0, lift: 0, motion: motion) } ?? FusionPalette.backgroundRGB(scheme)
    }

    /// The dashed outline of merged block `item` on `base(for: item)`, `hovered` or not; solved once
    /// per tile and generation.
    func mergedOutline(for item: TreemapMotion.Item, hovered: Bool, motion: TreemapMotion) -> Color {
        let key = SurfaceKey(plan: Self.key(item), lifted: hovered)
        if let hit = mergedOutlines[key] { return hit }
        let outline = FusionPalette.mergedOutline(on: base(for: item, motion: motion), hovered: hovered, scheme: scheme)
        mergedOutlines[key] = outline
        return outline
    }

    /// The surface of section `item` (`lift` > 0 while hovered), over `base(for: item)`.
    func surface(for item: TreemapMotion.Item, lift: Double, motion: TreemapMotion) -> Contrast.RGB {
        let key = SurfaceKey(plan: Self.key(item), lifted: lift > 0)
        if let hit = surfaces[key] { return hit }
        let base = base(for: item, motion: motion)
        let shade = item.isCurrent ? item.to : item.from
        let tint = FusionPalette.fillRGB(.init(item.tile), mode: mode, depth: shade.shadeDepth,
                                         step: shade.shadeStep, lift: lift, scheme: scheme)
        let surface = FusionPalette.sectionSurface(tint: tint, over: base, scheme: scheme)
        surfaces[key] = surface
        return surface
    }

    /// The label of block `item`, fitted to its settled rect; nil when that is too small.
    func leaf(for item: TreemapMotion.Item, canvas: TreemapCanvas, in context: GraphicsContext) -> Leaf? {
        let key = Self.key(item)
        if let plan = leaves[key] { return plan }
        var plan: Leaf?
        if let rect = canvas.drawn(Self.settledRect(item)), rect.width >= Self.minLabelWidth,
           rect.height >= Self.minLabelHeight {
            let locked = item.tile.flags.contains(.unreadable)
            let room = rect.width - 2 * Self.padding
            if let name = fitter.fitted(TreemapView.title(of: item.tile), width: room - (locked ? Self.lockRoom : 0),
                                        line: .name, in: context) {
                plan = Leaf(name: name, size: fitter.fitted(Formatters.bytes(item.tile.size), width: room,
                                                            line: .size, in: context),
                            locked: locked)
            }
        }
        leaves[key] = plan
        return plan
    }

    /// The header of section `item`, fitted to its settled rect.
    func header(for item: TreemapMotion.Item, canvas: TreemapCanvas, in context: GraphicsContext) -> Header? {
        let key = Self.key(item)
        if let plan = headers[key] { return plan }
        var plan: Header?
        if let rect = canvas.drawn(Self.settledRect(item)) {
            let room = rect.width - 2 * Self.padding
            let name = item.tile.name.uppercased(with: Locale(identifier: "it_IT"))
            let size = fitter.fitted(Formatters.bytes(item.tile.size), width: room, line: .headerSize, in: context)
            // The size stays only while the name keeps a useful width beside it.
            if let size, room - size.width - Self.headerSpacing >= Self.headerNameMinWidth,
               let fittedName = fitter.fitted(name, width: room - size.width - Self.headerSpacing, line: .header,
                                              in: context) {
                plan = Header(name: fittedName, size: size)
            } else if let fittedName = fitter.fitted(name, width: room, line: .header, in: context) {
                plan = Header(name: fittedName, size: nil)
            }
        }
        headers[key] = plan
        return plan
    }
}
