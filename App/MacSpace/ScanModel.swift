import CoreGraphics
import Foundation
import MacSpaceCore
import Observation
import Synchronization

/// What the user asked to analyse.
enum ScanTarget: Hashable {
    case startupDisk
    case folder(URL)
}

/// App state: runs one scan at a time and publishes the views of the tree around `center`.
@MainActor @Observable
final class ScanModel {
    enum Phase {
        case idle
        case scanning(ScanProgress)
        case done(ScanSummary)
    }

    var phase: Phase = .idle {
        didSet {
            // Stored, not derived from `phase`: views that only care whether a scan is running
            // are not invalidated by every progress update.
            let scanning = if case .scanning = phase { true } else { false }
            if isScanning != scanning { isScanning = scanning }
        }
    }
    private(set) var isScanning = false
    /// The folder the chart and the list are centred on.
    var center: NodeID = FileTree.root
    var segments: [ArcSegment] = []
    var biggest: [NodeRow] = []
    /// From the scan root down to `center`.
    var breadcrumb: [NodeRow] = []
    /// Bytes per file category below `center`, non-zero entries only (for the legend).
    var categoryTotals: [FileCategory: UInt64] = [:]
    /// Bytes per age bucket below `center`, non-zero entries only (for the legend).
    var ageTotals: [AgeBucket: UInt64] = [:]
    /// The hovered sunburst segment (sunburst chart only).
    var hovered: ArcSegment?
    /// The hovered treemap tile (treemap chart only).
    var hoveredTile: TreemapTile?
    /// Which chart is on screen; only that one is laid out. Mirrors `@AppStorage(ChartKind.storageKey)`.
    /// Changing it relays out the current folder: the scan, `center` and the hovered node stay.
    var chart: ChartKind = .sunburst {
        didSet { if chart != oldValue { Task { await refreshViews() } } }
    }
    /// The treemap canvas size, set by the treemap view (debounced while the window resizes).
    var chartSize: CGSize = .zero {
        didSet { if chartSize != oldValue, chart == .treemap { Task { await refreshViews() } } }
    }
    /// Treemap tiles below `center`, laid out for `tilesSize`; empty unless `chart` is `.treemap`.
    var tiles: [TreemapTile] = []
    /// The canvas size `tiles` were laid out for.
    private(set) var tilesSize: CGSize = .zero
    /// Total capacity of the scanned volume; set only when scanning the startup disk.
    var capacity: UInt64?

    static let ringDepth = 3
    static let biggestLimit = 20
    static let refreshInterval: Duration = .milliseconds(250)

    @ObservationIgnored private var store: ScanStore?
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    /// Starts scanning `target`, cancelling any running scan first.
    func start(_ target: ScanTarget) {
        let previous = scanTask
        previous?.cancel()
        scanTask = Task {
            // Let the cancelled scan drain and publish its state before replacing it.
            await previous?.value
            guard !Task.isCancelled else { return }
            await run(target)
        }
    }

    /// Stops the running scan; what was scanned so far stays visible (`.done`, `wasCancelled`).
    func cancel() {
        scanTask?.cancel()
    }

    func drill(into node: NodeID) {
        guard store != nil, node != center else { return }
        center = node
        hovered = nil
        hoveredTile = nil
        Task { await refreshViews() }
    }

    func goUp() {
        guard let store else { return }
        let from = center
        Task {
            let crumb = await store.breadcrumb(to: from)
            guard crumb.count >= 2, store === self.store, from == center else { return }
            center = crumb[crumb.count - 2].id
            hovered = nil
            hoveredTile = nil
            await refreshViews()
        }
    }

    /// The node under the pointer in whichever chart is on screen (or a hovered list row).
    var hoveredNode: NodeID? {
        switch chart {
        case .sunburst: hovered?.node
        case .treemap: hoveredTile?.node
        }
    }

    /// Hovers the first-level element of `node` in whichever chart is on screen (nil: none), as
    /// a hovered list row does.
    func hoverFirstLevel(_ node: NodeID?) {
        switch chart {
        case .sunburst:
            let segment = node.flatMap { node in segments.first { $0.depth == 1 && $0.node == node } }
            if hovered != segment { hovered = segment }
        case .treemap:
            let tile = node.flatMap { node in tiles.first { $0.depth == 1 && $0.node == node } }
            if hoveredTile != tile { hoveredTile = tile }
        }
    }

    /// Reloads the active chart (`segments` or `tiles`), `biggest`, `breadcrumb`, `categoryTotals`
    /// and `ageTotals` for the current `center`, from one consistent store snapshot. The other
    /// chart's data is emptied; the hovered node carries over to the active chart when it is
    /// still laid out there.
    func refreshViews() async {
        guard let store else { return }
        let center = self.center
        let chart = self.chart
        let size = chartSize
        let request: ChartRequest = switch chart {
        case .sunburst: .sunburst(depth: Self.ringDepth)
        case .treemap: .treemap(width: size.width, height: size.height, depth: Self.ringDepth)
        }
        let snapshot = await store.snapshot(center: center, chart: request, biggestLimit: Self.biggestLimit)
        // A newer scan, navigation, chart or canvas size happened meanwhile: its own refresh wins.
        guard store === self.store, center == self.center, chart == self.chart,
              chart == .sunburst || size == chartSize else { return }
        Perf.interval("refresh apply") {
            // Segments and tiles share ids ("\(node)"), so the hover survives a chart switch.
            let hoveredID = hovered?.id ?? hoveredTile?.id
            segments = snapshot.segments
            tilesSize = size
            tiles = snapshot.tiles
            biggest = snapshot.biggest
            breadcrumb = snapshot.breadcrumb
            if categoryTotals != snapshot.categoryTotals { categoryTotals = snapshot.categoryTotals }
            if ageTotals != snapshot.ageTotals { ageTotals = snapshot.ageTotals }
            if let hoveredID {
                let segment = snapshot.segments.first { $0.id == hoveredID }
                if segment != hovered { hovered = segment }
                let tile = snapshot.tiles.first { $0.id == hoveredID }
                if tile != hoveredTile { hoveredTile = tile }
            }
        }
    }

    private func run(_ target: ScanTarget) async {
        let (rootPath, rootName) = Self.root(of: target)
        let boundary: ScanBoundary
        do {
            boundary = switch target {
            case .startupDisk: try ScanBoundary.forStartupDisk()
            case .folder: try ScanBoundary.forFolder(rootPath)
            }
        } catch {
            // The root cannot even be stat'ed: the scan will mark it unreadable.
            boundary = ScanBoundary(allowedDevices: [], excludedPaths: [])
        }

        let store = ScanStore(rootName: rootName, rootPath: rootPath)
        self.store = store
        center = FileTree.root
        hovered = nil
        hoveredTile = nil
        capacity = if case .startupDisk = target { Self.startupDiskCapacity() } else { nil }
        segments = []
        tiles = []
        biggest = []
        breadcrumb = []
        categoryTotals = [:]
        ageTotals = [:]
        phase = .scanning(ScanProgress(filesSeen: 0, bytesSeen: 0, directoriesPending: 1))

        let latest = LatestProgress()
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled else { return }
                if let progress = latest.value { phase = .scanning(progress) }
                await refreshViews()
            }
        }
        let scanner = Scanner(rootPath: rootPath, boundary: boundary)
        let summary = await scanner.scan(into: store) { latest.value = $0 }
        ticker.cancel()
        await ticker.value

        phase = .done(summary)
        // The last timer refresh predates the final inserts: show the finished tree.
        await refreshViews()
    }

    /// The startup volume's name as Finder shows it ("Macintosh HD" unless renamed).
    static let startupDiskName: String = {
        let values = try? URL(filePath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
        return values?.volumeLocalizedName ?? "Macintosh HD"
    }()

    private static func startupDiskCapacity() -> UInt64? {
        let values = try? URL(filePath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey])
        return values?.volumeTotalCapacity.map { UInt64(clamping: $0) }
    }

    /// Scan root path and display name. Chosen folders are resolved first: the reader
    /// opens directories with `O_NOFOLLOW`, so a symlinked root would fail.
    static func root(of target: ScanTarget) -> (path: String, name: String) {
        switch target {
        case .startupDisk:
            return ("/", startupDiskName)
        case let .folder(url):
            var path = url.path(percentEncoded: false)
            if let resolved = realpath(path, nil) {
                path = String(cString: resolved)
                free(resolved)
            }
            return (path, FileManager.default.displayName(atPath: path))
        }
    }
}

/// Latest progress reported by the scanner, read by the UI refresh timer.
private final class LatestProgress: Sendable {
    private let storage = Mutex<ScanProgress?>(nil)

    var value: ScanProgress? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
