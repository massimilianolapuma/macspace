import Foundation
import MacSpaceCore
import SwiftUI

/// Where a tile is drawn: its layout slot (un-inset, like `TreemapTile`'s rect) in the
/// coordinates of `TreemapMotion.size`, and its opacity. `shadeDepth`/`shadeStep` feed
/// `FusionPalette.fill`, so fills blend when a tile changes level.
struct TilePose: Equatable {
    var rect: CGRect
    var alpha: Double
    var shadeDepth: Double
    var shadeStep: Double

    /// The pose at eased progress `t` from `self` to `other`. Opacity runs ahead (`fade`), so a
    /// zoom's cross-fade is over well before the tiles settle.
    func mixed(with other: TilePose, _ t: Double) -> TilePose {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        let fade = Self.fade(t)
        return TilePose(rect: CGRect(x: mix(rect.minX, other.rect.minX), y: mix(rect.minY, other.rect.minY),
                                     width: mix(rect.width, other.rect.width),
                                     height: mix(rect.height, other.rect.height)),
                        alpha: alpha + (other.alpha - alpha) * fade, shadeDepth: mix(shadeDepth, other.shadeDepth),
                        shadeStep: mix(shadeStep, other.shadeStep))
    }

    /// Opacity progress at eased progress `t`.
    static func fade(_ t: Double) -> Double { min(t * 1.6, 1) }
}

/// How the new treemap relates to the one on screen, so tiles can move instead of popping.
enum TreemapChange {
    /// Same center, fresher data or a new canvas size: drawn at once.
    case refresh
    /// Drilled into the tile drawn at `rect` (in the new layout's coordinates): it grows to fill the canvas.
    case zoomIn(CGRect)
    /// Went up: the old center is the tile at `rect` in the new layout: the canvas shrinks into it.
    case zoomOut(CGRect)
    /// No visible link between the two (e.g. a jump of several levels): cross-fade.
    case unrelated
}

/// Maps layout slots to the rects drawn in the view: scaled from the layout's canvas to the
/// view (they differ while a resize waits for its relayout) and inset by half the gap, so
/// siblings show `gap` between them. Slots too small to show after the inset are not drawn.
struct TreemapCanvas {
    let size: CGSize
    let layoutSize: CGSize

    static let style = TreemapLayout.Style()
    static var gap: Double { style.gap }

    var scaleX: Double { layoutSize.width > 0 ? size.width / layoutSize.width : 1 }
    var scaleY: Double { layoutSize.height > 0 ? size.height / layoutSize.height : 1 }

    /// The slot in view coordinates, not inset.
    func slot(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * scaleX, y: rect.minY * scaleY, width: rect.width * scaleX, height: rect.height * scaleY)
    }

    /// Tiles whose drawn short side would be under this are never drawn (Ruling Y): 2–4 pt
    /// slivers read as dashes and dots. Their area shows the parent's surface, and pointing at it
    /// hovers the parent.
    static let minDrawnSide = 6.0

    /// Whether a tile settled at layout slot `rect` is drawn at all.
    static func isVisible(slot rect: CGRect) -> Bool {
        min(rect.width, rect.height) - gap >= minDrawnSide
    }

    /// The rect drawn for a slot; nil when less than 1 pt would be left on either side.
    func drawn(_ rect: CGRect) -> CGRect? {
        let inset = slot(rect).insetBy(dx: Self.gap / 2, dy: Self.gap / 2)
        guard inset.width >= 1, inset.height >= 1, inset.minX.isFinite, inset.minY.isFinite else { return nil }
        return inset
    }

    /// Height of a section header band, scaled like the slots.
    var headerHeight: Double { Self.style.header * scaleY }
}

/// The tiles on screen and where each one is heading. Tiles leaving the map are kept until they
/// have faded out. Retargeting starts from what is currently drawn, so a refresh arriving
/// mid-zoom never jumps.
struct TreemapMotion {
    struct Item {
        var tile: TreemapTile
        var from: TilePose
        var to: TilePose
        /// Still in the map (as opposed to fading out).
        var isCurrent: Bool
        /// Child tiles are drawn inside it: it is a section, not a block.
        var isSection: Bool
        /// Drawn at all: where it settles (or, leaving, where it was) it clears `minDrawnSide`.
        /// Decided once per transition, so a zoom never pops tiles in or out as they grow.
        var isVisible: Bool
    }

    private struct ItemKey: Hashable {
        let node: NodeID
        let isCurrent: Bool
    }

    /// Draw order: leaving tiles first, then current ones level by level (parents before children).
    private(set) var items: [Item] = []
    /// The canvas size the current layout was computed for; poses are in its coordinates.
    private(set) var size: CGSize = .zero
    private(set) var startedAt = Date.distantPast
    private var animated = false
    /// Index in `items` of each folder's item, current and leaving apart.
    private var indexByNode: [ItemKey: Int] = [:]

    static let spring = Spring(duration: 0.35, bounce: 0)  // == Animation.smooth(duration: 0.35)

    /// How long the current transition runs; 0 when it is not animated.
    var duration: TimeInterval { animated ? Self.spring.settlingDuration : 0 }

    /// Eased progress, 0...1.
    func progress(at date: Date) -> Double {
        let elapsed = date.timeIntervalSince(startedAt)
        guard animated, elapsed < duration else { return 1 }
        return min(max(Self.spring.value(target: 1.0, time: max(elapsed, 0)), 0), 1)
    }

    func poses(at date: Date) -> [(item: Item, pose: TilePose)] {
        let t = progress(at: date)
        return items.map { ($0, Self.pose(of: $0, t)) }
    }

    /// Where `item` is drawn at eased progress `t`.
    static func pose(of item: Item, _ t: Double) -> TilePose {
        t >= 1 ? item.to : item.from.mixed(with: item.to, t)
    }

    /// The current tile with id `id` and where it is drawn at `date`.
    func current(_ id: String, at date: Date) -> (item: Item, pose: TilePose)? {
        guard let item = items.last(where: { $0.isCurrent && $0.tile.id == id }) else { return nil }
        return (item, Self.pose(of: item, progress(at: date)))
    }

    /// The item of `item`'s parent in the same transition (current with current, leaving with
    /// leaving); nil for a child of the center.
    func parent(of item: Item) -> Item? {
        indexByNode[ItemKey(node: item.tile.parent, isCurrent: item.isCurrent)].map { items[$0] }
    }

    /// The deepest current tile whose drawn rect contains `point` (view coordinates) at `date`.
    /// Runs on every mouse move, so it allocates nothing.
    func hitTest(_ point: CGPoint, canvas: TreemapCanvas, at date: Date) -> TreemapTile? {
        let t = progress(at: date)
        // Children are drawn after their parents: the last hit is the one on top.
        for item in items.reversed() where item.isCurrent && item.isVisible {
            let pose = Self.pose(of: item, t)
            if pose.alpha > 0.5, let rect = canvas.drawn(pose.rect), rect.contains(point) { return item.tile }
        }
        return nil
    }

    /// When the current transition ends; `startedAt` when it is not animated.
    var endsAt: Date { startedAt.addingTimeInterval(duration) }

    /// Moves the map to `tiles`, laid out for `size`. Zooms and cross-fades animate; a refresh
    /// is drawn at its target directly, unless it lands mid-zoom: then the zoom carries on,
    /// unbroken, towards the fresher targets. Returns whether the map is animating.
    @discardableResult
    mutating func retarget(to tiles: [TreemapTile], size: CGSize, change: TreemapChange, at date: Date,
                           animated: Bool) -> Bool {
        // What is on screen, in the new layout's coordinates.
        let rescale = TreemapCanvas(size: size, layoutSize: self.size == .zero ? size : self.size)
        let shown = poses(at: date).compactMap { item, pose -> (Item, TilePose)? in
            guard pose.alpha > 0.01 else { return nil }
            var pose = pose
            pose.rect = rescale.slot(pose.rect)
            return (item, pose)
        }
        var shownByID: [String: TilePose] = [:]
        for (item, pose) in shown where item.isCurrent { shownByID[item.tile.id] = pose }

        let isRefresh = if case .refresh = change { true } else { false }
        let isZoom = switch change {
        case .zoomIn, .zoomOut: true
        case .refresh, .unrelated: false
        }
        let t = progress(at: date)
        // A refresh mid-zoom keeps the zoom's clock: each tile's start is chosen so that it is
        // drawn exactly where it is now, and it still arrives when the zoom ends.
        let continuing = isRefresh && self.animated && t < 0.98
        let animate = continuing || (animated && !isRefresh)
        func start(_ now: TilePose, _ to: TilePose) -> TilePose {
            guard animate else { return to }
            return continuing ? Self.extrapolate(now, to: to, t) : now
        }

        let canvas = CGRect(origin: .zero, size: size)
        let sections = Set(tiles.map(\.parent))
        var next: [Item] = []
        next.reserveCapacity(tiles.count)
        var newIDs = Set<String>()
        var nowByNode: [NodeID: TilePose] = [:]
        var toByNode: [NodeID: TilePose] = [:]
        var familyIndex: [NodeID: Int] = [:]
        for tile in tiles {
            let index = familyIndex[tile.parent, default: 0]
            familyIndex[tile.parent] = index + 1
            let to = TilePose(rect: CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height), alpha: 1,
                              shadeDepth: Double(tile.depth), shadeStep: Double(index % 4))
            // A zoom moves the whole map as one picture (the old one growing out of view or
            // shrinking into its tile, the new one growing from the clicked tile or in from
            // around the old center) and cross-fades: matching tiles one by one would shuffle
            // them, since a folder's layout changes with its rect's proportions.
            let now = (isZoom ? nil : shownByID[tile.id])
                ?? entering(to, parentNow: nowByNode[tile.parent], parentTo: toByNode[tile.parent],
                            canvas: canvas, change: change)
            if let node = tile.node {
                nowByNode[node] = now
                toByNode[node] = to
            }
            newIDs.insert(tile.id)
            next.append(Item(tile: tile, from: start(now, to), to: to, isCurrent: true,
                             isSection: tile.node.map(sections.contains) ?? false,
                             isVisible: TreemapCanvas.isVisible(slot: to.rect)))
        }

        var leaving: [Item] = []
        if animate {
            for (item, now) in shown where isZoom || !(item.isCurrent && newIDs.contains(item.tile.id)) {
                var to = now
                if continuing, !item.isCurrent {
                    // Already leaving along a zoom: it keeps that path.
                    to.rect = rescale.slot(item.to.rect)
                } else {
                    to.rect = Self.oldToNew(now.rect, canvas: canvas, change: change)
                }
                to.alpha = 0
                leaving.append(Item(tile: item.tile, from: start(now, to), to: to, isCurrent: false,
                                    isSection: item.isSection,
                                    isVisible: item.isCurrent ? TreemapCanvas.isVisible(slot: now.rect)
                                                              : item.isVisible))
            }
        }

        items = leaving + next
        indexByNode.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            if let node = item.tile.node { indexByNode[ItemKey(node: node, isCurrent: item.isCurrent)] = index }
        }
        self.size = size
        if !continuing { startedAt = date }
        self.animated = animate
        return animate
    }

    /// The start pose that makes `mixed(with: to, t)` land on `now`.
    private static func extrapolate(_ now: TilePose, to: TilePose, _ t: Double) -> TilePose {
        func back(_ n: Double, _ b: Double) -> Double { (n - b * t) / (1 - t) }
        let fade = TilePose.fade(t)
        // Once the fade is over, opacity holds: it is already at its target.
        let alpha = fade < 1 ? (now.alpha - to.alpha * fade) / (1 - fade) : to.alpha
        return TilePose(rect: CGRect(x: back(now.rect.minX, to.rect.minX), y: back(now.rect.minY, to.rect.minY),
                                     width: back(now.rect.width, to.rect.width),
                                     height: back(now.rect.height, to.rect.height)),
                        alpha: alpha, shadeDepth: back(now.shadeDepth, to.shadeDepth),
                        shadeStep: back(now.shadeStep, to.shadeStep))
    }

    /// Where a tile that is not on screen yet starts: riding along with its parent when the
    /// parent is on screen, else where the zoom maps it from; either way it fades in.
    private func entering(_ to: TilePose, parentNow: TilePose?, parentTo: TilePose?, canvas: CGRect,
                          change: TreemapChange) -> TilePose {
        var now = to
        now.alpha = 0
        if let parentNow, let parentTo {
            now.rect = Self.map(to.rect, from: parentTo.rect, to: parentNow.rect)
        } else {
            now.rect = Self.newToOld(to.rect, canvas: canvas, change: change)
        }
        return now
    }

    /// `rect` re-expressed so that frame `a` becomes frame `b`.
    private static func map(_ rect: CGRect, from a: CGRect, to b: CGRect) -> CGRect {
        guard a.width > 0, a.height > 0 else { return rect }
        let sx = b.width / a.width, sy = b.height / a.height
        return CGRect(x: b.minX + (rect.minX - a.minX) * sx, y: b.minY + (rect.minY - a.minY) * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }

    /// Old map → new map coordinates.
    private static func oldToNew(_ rect: CGRect, canvas: CGRect, change: TreemapChange) -> CGRect {
        switch change {
        case let .zoomIn(target): map(rect, from: target, to: canvas)
        case let .zoomOut(target): map(rect, from: canvas, to: target)
        case .refresh, .unrelated: rect
        }
    }

    /// New map → old map coordinates.
    private static func newToOld(_ rect: CGRect, canvas: CGRect, change: TreemapChange) -> CGRect {
        switch change {
        case let .zoomIn(target): map(rect, from: canvas, to: target)
        case let .zoomOut(target): map(rect, from: target, to: canvas)
        case .refresh, .unrelated: rect
        }
    }
}
