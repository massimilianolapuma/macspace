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
    /// Folders the last finished scan could not read (0 while scanning or before any scan).
    var unreadableFolders: Int {
        if case let .done(summary) = phase { summary.unreadable } else { 0 }
    }
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
    /// Whether the active chart shows a merged "Altri N elementi" element (for the legend).
    var showsMerged = false
    /// The safety verdict of every node in `segments`, `tiles`, `biggest` and `breadcrumb`.
    /// Provisional while scanning (sizes and last uses still grow); recomputed when the scan ends.
    var verdicts: [NodeID: SafetyVerdict] = [:]
    /// Spotlight's last-used date (seconds since 1970) of hovered files, looked up once per file
    /// and scan (`scheduleLastUsedLookup`); a file Spotlight has no date for is absent.
    private(set) var spotlightLastUsed: [NodeID: UInt32] = [:]
    /// The hovered sunburst segment (sunburst chart only).
    var hovered: ArcSegment? {
        didSet { if hovered?.node != oldValue?.node { scheduleLastUsedLookup() } }
    }
    /// The hovered treemap tile (treemap chart only).
    var hoveredTile: TreemapTile? {
        didSet { if hoveredTile?.node != oldValue?.node { scheduleLastUsedLookup() } }
    }
    /// Which chart is on screen; only that one is laid out. Mirrors `@AppStorage(ChartKind.storageKey)`.
    /// Changing it relays out the current folder: the scan, `center` and the hovered node stay.
    var chart: ChartKind = .sunburst {
        didSet { if chart != oldValue { Task { await refreshViews() } } }
    }
    /// The chart area's size, reported by the content view whichever chart shows (debounced while
    /// the window resizes); the treemap is laid out for it.
    var chartSize: CGSize = .zero {
        didSet { if chartSize != oldValue, chart == .treemap { Task { await refreshViews() } } }
    }
    /// Treemap tiles below `center`, laid out for `tilesSize`; empty unless `chart` is `.treemap`.
    var tiles: [TreemapTile] = []
    /// The canvas size `tiles` were laid out for.
    private(set) var tilesSize: CGSize = .zero
    /// Total capacity of the scanned volume; set only when scanning the startup disk.
    var capacity: UInt64?

    // Selection and suggestions (`ScanModel+Selection.swift`).

    /// Items picked for the Trash, as `ScanStore.resolveSelection` keeps them: top-most, never the
    /// root or protected. Change it with `toggleSelection` and `clearSelection`.
    var selection: Set<NodeID> = []
    /// Bytes in `selection`, each counted once.
    var selectionTotal: UInt64 = 0
    /// The items of the suggestion whose header was clicked, outlined wherever they are on screen.
    var highlighted: Set<NodeID> = []
    /// The store's suggestions, recomputed when a scan ends, when the environment changes and after
    /// each trash (`refreshSuggestions`); empty while scanning.
    var suggestions: [Suggestion] = []
    /// Ticks the user changed in the suggestions; every other item is ticked when `preselected`.
    var suggestionTicks: [NodeID: Bool] = [:]
    /// Items "Sposta nel Cestino…" asked to move; the confirmation sheet shows them (nil: none).
    var pendingTrash: [NodeID]?
    /// Whether the installed apps index is ready, so `~/Library` items have been judged.
    private(set) var appsReady = false
    /// The last scan's end has fully landed: verdicts judged again on the finished tree, the
    /// selection re-resolved and the suggestions recomputed. Until then the Trash stays unavailable,
    /// so no request is made on provisional verdicts.
    private(set) var scanSettled = true
    /// Environment updates still being applied (verdicts, selection, suggestions); the Trash waits.
    private(set) var environmentUpdates = 0

    // Moving to the Trash (`ScanModel+Trash.swift`).

    /// The finished move the sheet shows in place of the confirmation (nil: none). The sheet is up
    /// while this or `pendingTrash` is set.
    var trashReport: TrashReport?
    /// Every item moved to the Trash in this session, newest first; not saved.
    var history: [HistoryEntry] = []
    /// A move is running; another one is refused until it ends.
    var isTrashing = false
    /// Bumped each time an environment update has fully landed (verdicts may have changed), so an
    /// open confirmation sheet re-reads its rows.
    var verdictRevision = 0
    /// Bumped whenever a new store replaces the old one, so a sheet opened on the old one's items
    /// can tell they no longer exist.
    @ObservationIgnored var storeGeneration = 0

    static let ringDepth = 3
    static let biggestLimit = 20
    static let refreshInterval: Duration = .milliseconds(250)

    /// Internal, not private, for the `ScanModel+…` extensions.
    @ObservationIgnored private(set) var store: ScanStore?
    /// Selection changes run one after the other, each against the outcome of the previous one.
    @ObservationIgnored var selectionWork: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// What verdicts are judged against (`updateEnvironment`, or the live one `trash` reads); nil
    /// until the provider's first one.
    @ObservationIgnored var environment: SafetyEnvironment?
    /// Nodes whose Spotlight last use was asked for in this scan (found or not).
    @ObservationIgnored private var lastUsedRequested: Set<NodeID> = []
    /// Waits for the pointer to rest on a node before looking it up.
    @ObservationIgnored private var lastUsedRest: Task<Void, Never>?
    /// A Spotlight lookup is running; at most one runs at a time.
    @ObservationIgnored private var lastUsedInFlight = false

    /// How long the pointer must rest on a file before Spotlight is asked about it.
    static let lastUsedRestDelay: Duration = .milliseconds(150)

    /// Judges verdicts against `env` from now on (the apps index became ready, an app launched or
    /// quit): hands it to the current store, and to every store a later scan creates, and refreshes.
    /// Suggestions and the selection follow (a running app's data becomes protected, and leaves both).
    func updateEnvironment(_ env: SafetyEnvironment) {
        environment = env
        if appsReady != (env.apps != nil) { appsReady = env.apps != nil }
        guard let store else { return }
        environmentUpdates += 1
        Task {
            defer { environmentUpdates -= 1 }
            // Read when the task runs, so of two quick updates the store ends with the latest.
            guard let latest = environment else { return }
            await store.setEnvironment(latest)
            guard store === self.store else { return }
            await refreshViews()
            await selectionWork?.value  // the re-resolve `refreshViews` queued
            await refreshSuggestions()
            if store === self.store { verdictRevision += 1 }
        }
    }

    /// Looks up the hovered node's Spotlight last-used date once the pointer has rested on it for
    /// `lastUsedRestDelay`, so sweeping across the chart asks Spotlight nothing.
    private func scheduleLastUsedLookup() {
        lastUsedRest?.cancel()
        guard hoveredNode != nil else { return }
        lastUsedRest = Task {
            try? await Task.sleep(for: Self.lastUsedRestDelay)
            guard !Task.isCancelled else { return }
            lookUpHoveredLastUsed()
        }
    }

    /// Looks up the hovered node's Spotlight last-used date, once per node and scan, off the main
    /// actor; only files (a folder's date says nothing about its contents). One lookup at a time:
    /// when it ends, the node hovered by then (if any, and not asked yet) goes next. The result lands
    /// in `spotlightLastUsed`.
    private func lookUpHoveredLastUsed() {
        guard !lastUsedInFlight, let store, let node = hoveredNode, lastUsedRequested.insert(node).inserted else { return }
        lastUsedInFlight = true
        Task {
            defer {
                lastUsedInFlight = false
                lookUpHoveredLastUsed()
            }
            // A node from an earlier scan's store may not exist in this one: no row, no path.
            guard await store.row(node)?.kind == .file, let path = await store.path(of: node) else { return }
            let date = await Task.detached(priority: .utility) { SpotlightLastUsed.lastUsed(path: path) }.value
            guard store === self.store, let date else { return }
            spotlightLastUsed[node] = date
        }
    }

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
            if verdicts != snapshot.verdicts { verdicts = snapshot.verdicts }
            if categoryTotals != snapshot.categoryTotals { categoryTotals = snapshot.categoryTotals }
            if ageTotals != snapshot.ageTotals { ageTotals = snapshot.ageTotals }
            let merged = switch chart {
            case .sunburst: snapshot.segments.contains { $0.node == nil }
            case .treemap: snapshot.tiles.contains { $0.node == nil }
            }
            if showsMerged != merged { showsMerged = merged }
            if let hoveredID {
                let segment = snapshot.segments.first { $0.id == hoveredID }
                if segment != hovered { hovered = segment }
                let tile = snapshot.tiles.first { $0.id == hoveredID }
                if tile != hoveredTile { hoveredTile = tile }
            }
        }
        // Sizes grow while scanning and verdicts move with the environment: re-judge the selection.
        if !selection.isEmpty { changeSelection { $0 } }
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
        // Everything that names a node of the old store goes in the same main-actor turn as the
        // store itself, before any await: node IDs are per store.
        self.store = store
        center = FileTree.root
        hovered = nil
        hoveredTile = nil
        verdicts = [:]
        spotlightLastUsed = [:]
        lastUsedRequested = []
        lastUsedRest?.cancel()
        capacity = if case .startupDisk = target { Self.startupDiskCapacity() } else { nil }
        segments = []
        tiles = []
        biggest = []
        breadcrumb = []
        categoryTotals = [:]
        ageTotals = [:]
        showsMerged = false
        // Changes still queued for the old store drop themselves (they check the store).
        selectionWork = nil
        scanSettled = false
        selection = []
        selectionTotal = 0
        highlighted = []
        suggestions = []
        suggestionTicks = [:]
        pendingTrash = nil
        trashReport = nil
        storeGeneration += 1
        phase = .scanning(ScanProgress(filesSeen: 0, bytesSeen: 0, directoriesPending: 1))
        if let environment {
            // The same apps, judged at the current time (rules measure ages from `now`) with the
            // apps running now.
            let fresh = SafetyEnvironmentProvider.environment(apps: environment.apps)
            self.environment = fresh
            await store.setEnvironment(fresh)
        }

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
        // Verdicts judged mid-scan saw partial sizes and last uses; the last timer refresh also
        // predates the final inserts: judge and show the finished tree.
        await store.invalidateVerdicts()
        await refreshViews()
        await selectionWork?.value  // the re-resolve `refreshViews` queued, on the final verdicts
        await refreshSuggestions()
        if store === self.store { scanSettled = true }
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
