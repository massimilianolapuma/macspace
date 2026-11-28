import CoreGraphics
import Foundation
import MacSpaceCore
import Observation
import os
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
    /// A scan has started in this window: from then on the chart, its path and its legend take the
    /// content area, through scanning, its end and every later scan. Stored, set in the same turn as
    /// the first `.scanning` phase, so no frame between scans or at a scan's end shows the idle
    /// state; read instead of `phase`, which changes on every progress update.
    private(set) var hasScan = false
    /// Folders the last finished scan could not read (0 while scanning or before any scan).
    var unreadableFolders: Int {
        if case let .done(summary) = phase { summary.unreadable } else { 0 }
    }
    /// The folder the chart and the list are centred on.
    var center: NodeID = FileTree.root
    /// Bumped by every navigation the user starts (`beginNavigation`) and by a new scan: an action
    /// that resolves its target asynchronously (going up, reveal, a highlight's drill) applies only if
    /// no other navigation started meanwhile, so the latest click wins even when an earlier one
    /// resolves later.
    @ObservationIgnored private(set) var navigationNumber = 0
    var segments: [ArcSegment] = [] {
        didSet { segmentParents = Self.parentMap(segments.lazy.compactMap { s in s.node.map { ($0, s.parent) } }) }
    }
    /// Each node in `segments` → the folder above it, for `isInsideSelection`: rebuilt only when
    /// `segments` is set, so a lookup per chart element does not rebuild it.
    private(set) var segmentParents: [NodeID: NodeID] = [:]
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
        didSet { if chart != oldValue { requestRefresh(userInitiated: true) } }
    }
    /// The chart area's size, reported by the content view whichever chart shows (debounced while
    /// the window resizes); the treemap is laid out for it.
    var chartSize: CGSize = .zero {
        didSet { if chartSize != oldValue, chart == .treemap { requestRefresh(userInitiated: true) } }
    }
    /// Treemap tiles below `center`, laid out for `tilesSize`; empty unless `chart` is `.treemap`.
    var tiles: [TreemapTile] = [] {
        didSet { tileParents = Self.parentMap(tiles.lazy.compactMap { t in t.node.map { ($0, t.parent) } }) }
    }
    /// Each node in `tiles` → the folder above it, as `segmentParents` for `segments`.
    private(set) var tileParents: [NodeID: NodeID] = [:]
    /// The canvas size `tiles` were laid out for.
    private(set) var tilesSize: CGSize = .zero
    /// Whether the current (or last) scan is of the startup disk rather than a chosen folder.
    private(set) var scansStartupDisk = false
    /// The startup disk's used space and capacity, read when a startup-disk scan starts and again
    /// when it ends; nil for a folder scan, or when the volume does not report them.
    var disk: DiskUsage?
    /// The disk's usage as a fact of its own: only at the root of a startup-disk scan that finished
    /// (while scanning, the scanned total would read as a progress towards it; after a cancel, the
    /// rest is not system space but simply not scanned). The breadcrumb must already show the root:
    /// going up sets `center` before the views catch up.
    var diskAtRoot: DiskUsage? {
        // `isScanning` first: while scanning, `phase` (updated on every tick) is not read.
        guard !isScanning, case let .done(summary) = phase, !summary.wasCancelled,
              center == FileTree.root, breadcrumb.count == 1, breadcrumb[0].id == FileTree.root
        else { return nil }
        return disk
    }

    // Selection and suggestions (`ScanModel+Selection.swift`).

    /// Items picked for the Trash, as `ScanStore.resolveSelection` keeps them: top-most, never the
    /// root or protected. Change it with `toggleSelection` and `clearSelection`.
    var selection: Set<NodeID> = []
    /// Bytes in `selection`, each counted once.
    var selectionTotal: UInt64 = 0
    /// The items of the suggestion whose header was clicked, outlined wherever they are on screen.
    var highlighted: Set<NodeID> = []
    /// The node of the Elementi row under the pointer: the chart spotlights it (`spotlight`).
    var listFocus: NodeID?
    /// What the chart spotlights (dims everything else, outlines these): the hovered list row's node,
    /// or else the highlighted suggestion items.
    var spotlight: Set<NodeID> {
        if let listFocus { [listFocus] } else { highlighted }
    }
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

    // Snapshots (#33).

    /// When the shown store is a restored snapshot: when its scan started; nil once a scanned store
    /// shows. The Trash is unavailable meanwhile.
    private(set) var shownSnapshotDate: Date?
    /// The scan running out of sight behind the shown snapshot, if any.
    private(set) var update: Update?
    /// That scan's progress, for the startup disk's bar; nil before its first report.
    private(set) var updateProgress: ScanProgress?
    /// The snapshot on screen, kept to refresh it again (it shares its arrays with the shown tree).
    @ObservationIgnored private var shownSaved: (target: ScanTarget, saved: SavedScan)?

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
    /// Runs view refreshes latest-wins (at most one snapshot that is still wanted runs on the store;
    /// superseded ones never reach it) and keeps the wait state.
    @ObservationIgnored private let refresher = RefreshCoordinator()
    /// Whether work the user asked for (navigation, chart switch, canvas resize) has been pending
    /// for `RefreshCoordinator.defaultThreshold` without landing: the views then dim the chart they
    /// still show and a spinner appears in the path row. Never set by the scan ticker's own refreshes.
    var isWaiting: Bool { refresher.isWaiting }
    /// The chart kind whose data is on screen (`segments` or `tiles`): set when a refresh lands, so a
    /// chart switch keeps the previous chart up (dimmed once the wait state shows) until the new one's
    /// data arrives.
    private(set) var shownChart: ChartKind = .sunburst
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
        startTask { [self] in await run(target) }
    }

    /// Runs `body` as the window's scan work, once the work it replaces (cancelled) has drained.
    private func startTask(_ body: @escaping @MainActor () async -> Void) {
        let previous = scanTask
        previous?.cancel()
        scanTask = Task {
            // Let the cancelled scan drain and publish its state before replacing it.
            await previous?.value
            guard !Task.isCancelled else { return }
            await body()
            // Only now: until `body` returns, its locals (a decoded snapshot, a refresh's reader)
            // still hold the replaced tree's arrays.
            Self.releaseFreedMemory()
        }
    }

    /// Stops the running scan; what was scanned so far stays visible (`.done`, `wasCancelled`). A
    /// hidden scan behind a snapshot stops too: the snapshot stays, with its date.
    func cancel() {
        scanTask?.cancel()
        update = nil
        updateProgress = nil
    }

    func drill(into node: NodeID) {
        // Even a drill into the current folder is the latest navigation: a pending goUp must not undo it.
        beginNavigation()
        guard store != nil, node != center else { return }
        center = node
        hovered = nil
        hoveredTile = nil
        requestRefresh(userInitiated: true)
    }

    func goUp() {
        guard let store else { return }
        let from = center
        let navigation = beginNavigation()
        let intent = noteUserIntent()
        Task {
            let crumb = await store.breadcrumb(to: from)
            guard crumb.count >= 2, store === self.store, navigation == navigationNumber else {
                abandonUserIntent(intent)
                return
            }
            center = crumb[crumb.count - 2].id
            hovered = nil
            hoveredTile = nil
            requestRefresh(userInitiated: true)
        }
    }

    /// Starts a user navigation; returns its number (see `navigationNumber`).
    @discardableResult
    func beginNavigation() -> Int {
        navigationNumber += 1
        listFocus = nil
        return navigationNumber
    }

    /// The node under the pointer in whichever chart is on screen (or a hovered list row).
    var hoveredNode: NodeID? {
        switch shownChart {
        case .sunburst: hovered?.node
        case .treemap: hoveredTile?.node
        }
    }

    /// Hovers the first-level element of `node` in whichever chart is on screen (nil: none), as
    /// a hovered list row does.
    func hoverFirstLevel(_ node: NodeID?) {
        switch shownChart {
        case .sunburst:
            let segment = node.flatMap { node in segments.first { $0.depth == 1 && $0.node == node } }
            if hovered != segment { hovered = segment }
        case .treemap:
            let tile = node.flatMap { node in tiles.first { $0.depth == 1 && $0.node == node } }
            if hoveredTile != tile { hoveredTile = tile }
        }
    }

    /// Reloads the active chart (`segments` or `tiles`), `biggest`, `breadcrumb`, `categoryTotals`
    /// and `ageTotals` for the current `center`, from one consistent store snapshot, superseding
    /// any refresh in flight; returns once the latest refresh (this one or a newer one) has landed.
    /// The other chart's data is emptied; the hovered node carries over to the active chart when
    /// it is still laid out there.
    func refreshViews(userInitiated: Bool = false) async {
        requestRefresh(userInitiated: userInitiated)
        await refreshesSettled()
    }

    /// Starts a refresh of the views for the current state, cancelling the previous one: latest
    /// wins. Navigation, chart and canvas changes call this without waiting.
    /// `userInitiated`: a navigation or chart change the user is waiting for; it counts as a user
    /// intent (`noteUserIntent`), so the wait state shows if it has not landed in time. The scan
    /// ticker's refreshes never set it.
    func requestRefresh(userInitiated: Bool = false) {
        refresher.request(userInitiated: userInitiated) { [weak self] isLatest in
            await self?.performRefresh(isLatest: isLatest)
        }
    }

    /// The user has asked for something that will change the views; the wait state arms now, not when
    /// the refresh is issued (which may follow an actor round trip). Call at the top of the action,
    /// synchronously; every call must end in a `requestRefresh(userInitiated: true)` or an
    /// `abandonUserIntent`. Returns the intent's number.
    @discardableResult
    func noteUserIntent() -> Int { refresher.noteUserIntent() }

    /// The action that noted intent `intent` ended without refreshing anything (see
    /// `RefreshCoordinator.abandonUserIntent`).
    func abandonUserIntent(_ intent: Int) { refresher.abandonUserIntent(intent) }

    /// Waits until the latest refresh has landed (or was dropped), following any newer one that
    /// supersedes it meanwhile.
    private func refreshesSettled() async {
        await refresher.settled()
    }

    /// The scan ticker's refresh: never cancels one in flight (a navigation's, say), it waits for
    /// it and then refreshes the then-current state.
    private func refreshAfterInFlight() async {
        await refreshesSettled()
        guard !Task.isCancelled else { return }
        await refreshViews()
    }

    /// One refresh's work: `isLatest` turns false once a newer refresh is requested (the coordinator
    /// never even starts one superseded in the same turn).
    private func performRefresh(isLatest: () -> Bool) async {
        guard isLatest(), let store else { return }
        let center = self.center
        let chart = self.chart
        let size = chartSize
        let request: ChartRequest = switch chart {
        case .sunburst: .sunburst(depth: Self.ringDepth)
        case .treemap: .treemap(width: size.width, height: size.height, depth: Self.ringDepth)
        }
        // One signpost ID per interval: overlapping refreshes (one suspended on the store while the
        // next starts) must pair their own begin and end.
        let signpostID = Perf.signposter.makeSignpostID()
        let signpost = Perf.signposter.beginInterval("snapshot", id: signpostID)
        let snapshot = await store.snapshot(center: center, chart: request, biggestLimit: Self.biggestLimit)
        Perf.signposter.endInterval("snapshot", signpost)
        // A newer scan, navigation, chart or canvas size happened meanwhile: its own refresh wins.
        guard isLatest(), store === self.store, center == self.center, chart == self.chart,
              chart == .sunburst || size == chartSize else { return }
        Perf.interval("refresh apply") { apply(snapshot, chart: chart, size: size) }
        // Sizes grow while scanning and verdicts move with the environment: re-judge the selection.
        if !selection.isEmpty { changeSelection { $0 } }
    }


    /// Puts `snapshot` (laid out for `chart` at `size`) on screen.
    private func apply(_ snapshot: ScanStore.Snapshot, chart: ChartKind, size: CGSize) {
        // Segments and tiles share ids ("\(node)"), so the hover survives a chart switch.
        let hoveredID = hovered?.id ?? hoveredTile?.id
        segments = snapshot.segments
        if shownChart != chart { shownChart = chart }
        tilesSize = size
        tiles = snapshot.tiles
        biggest = snapshot.biggest
        // A row that left the list (a scan tick, a move, a navigation) sends no hover exit.
        if let listFocus, !snapshot.biggest.contains(where: { $0.id == listFocus }) { self.listFocus = nil }
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

    /// The scan boundary of `target` at `rootPath`; one that cannot even be stat'ed allows
    /// nothing (the scan then marks the root unreadable).
    private static func boundary(of target: ScanTarget, rootPath: String) -> ScanBoundary {
        do {
            return switch target {
            case .startupDisk: try ScanBoundary.forStartupDisk()
            case .folder: try ScanBoundary.forFolder(rootPath)
            }
        } catch {
            return ScanBoundary(allowedDevices: [], excludedPaths: [])
        }
    }

    /// Makes `store` the one on screen. Everything that names a node of the old store goes in the
    /// same main-actor turn as the store itself, before any await: node IDs are per store.
    /// `keepViews` leaves the charts, list, crumbs and legends up, for a caller that puts the new
    /// store's own in this same turn (`swap`); otherwise they start empty, with the root's crumb.
    private func install(_ store: ScanStore, rootName: String, startupDisk: Bool, keepViews: Bool = false) {
        self.store = store
        beginNavigation()
        center = FileTree.root
        hovered = nil
        hoveredTile = nil
        verdicts = [:]
        spotlightLastUsed = [:]
        lastUsedRequested = []
        lastUsedRest?.cancel()
        scansStartupDisk = startupDisk
        disk = startupDisk ? DiskUsage.startupDisk() : nil
        if !keepViews {
            segments = []
            tiles = []
            shownChart = chart
            biggest = []
            // The root's crumb from the first frame: the path row names what is being scanned
            // before the first refresh lands.
            breadcrumb = [NodeRow(id: FileTree.root, name: rootName, size: 0, kind: .directory, flags: [],
                                  hasChildren: false)]
            categoryTotals = [:]
            ageTotals = [:]
            showsMerged = false
        }
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
        hasScan = true
        shownSnapshotDate = nil
        shownSaved = nil
    }

    /// Hands `store` the apps of the current environment, judged now (rules measure ages from
    /// `now`) with the apps running now.
    private func applyEnvironment(to store: ScanStore) async {
        guard let environment else { return }
        let fresh = SafetyEnvironmentProvider.environment(apps: environment.apps)
        self.environment = fresh
        await store.setEnvironment(fresh)
    }

    /// The scan's end, as every scan has it: verdicts judged mid-scan saw partial sizes and last
    /// uses, and the last timer refresh predates the final inserts, so the finished tree is judged
    /// and shown; then, unless it was cancelled, it is saved (before the Trash becomes available,
    /// so nothing moved is in the snapshot).
    private func finish(_ store: ScanStore, _ summary: ScanSummary, target: ScanTarget, startedAt: Date,
                        fullDiskAccess: Bool) async {
        // Read again: the disk kept changing while it was scanned.
        if case .startupDisk = target { disk = DiskUsage.startupDisk() }
        phase = .done(summary)
        await store.invalidateVerdicts()
        await refreshViews()
        await selectionWork?.value  // the re-resolve `refreshViews` queued, on the final verdicts
        await refreshSuggestions()
        if !summary.wasCancelled, store === self.store {
            await save(store, target: target, startedAt: startedAt, fullDiskAccess: fullDiskAccess)
        }
        if store === self.store { scanSettled = true }
    }

    /// Hands the memory a replaced store freed back to the system, once a scan's work has ended.
    /// The allocator keeps freed large blocks for reuse, and a whole disk's tree is about a
    /// gigabyte: measured on the owner's disk, the footprint stayed ~1.1 GB above the live tree
    /// after a refresh (#33).
    private static func releaseFreedMemory() {
        Task.detached(priority: .utility) { _ = malloc_zone_pressure_relief(nil, 0) }
    }

    private func run(_ target: ScanTarget) async {
        let (rootPath, rootName) = Self.root(of: target)
        let boundary = Self.boundary(of: target, rootPath: rootPath)
        let startedAt = Date.now
        let fullDiskAccess = FullDiskAccess.isGranted
        let store = ScanStore(rootName: rootName, rootPath: rootPath)
        install(store, rootName: rootName, startupDisk: target == .startupDisk)
        phase = .scanning(ScanProgress(filesSeen: 0, bytesSeen: 0, directoriesPending: 1))
        await applyEnvironment(to: store)

        let latest = LatestProgress()
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled else { return }
                if let progress = latest.value { phase = .scanning(progress) }
                await refreshAfterInFlight()
            }
        }
        let scanner = Scanner(rootPath: rootPath, boundary: boundary)
        let summary = await scanner.scan(into: store) { latest.value = $0 }
        ticker.cancel()
        await ticker.value
        await finish(store, summary, target: target, startedAt: startedAt, fullDiskAccess: fullDiskAccess)
    }

    // MARK: - Snapshots (#33)

    /// A scan running out of sight behind a shown snapshot.
    enum Update: Equatable {
        /// Re-reading only what the history says changed.
        case refresh
        /// Everything (asked for, or the history cannot vouch for the snapshot).
        case fullScan
    }

    /// Shows `target`'s snapshot when it has a valid one, then refreshes it out of sight; without
    /// one, scans it as `start` does when `scanIfMissing`, else leaves the window as it is (at
    /// launch, and when another target is picked while nothing runs).
    func open(_ target: ScanTarget, scanIfMissing: Bool) {
        startTask { [self] in
            if let shown = shownSaved, shown.target == target {
                await update(target, from: shown.saved, full: false)
                return
            }
            let key = Self.savedTarget(target)
            let saved = await Task.detached(priority: .userInitiated) { SnapshotFolder.standard.load(key) }.value
            guard !Task.isCancelled else { return }
            if let saved {
                guard await show(saved, target: target) else { return }
                await update(target, from: saved, full: false)
            } else if scanIfMissing {
                await run(target)
            }
        }
    }

    /// Scans `target` in full; a snapshot of it on screen stays there, browsable, until the scan
    /// ends ("Analisi completa").
    func fullScan(_ target: ScanTarget) {
        startTask { [self] in
            if let shown = shownSaved, shown.target == target {
                await update(target, from: shown.saved, full: true)
            } else {
                await run(target)
            }
        }
    }

    /// The snapshot slot of `target`.
    static func savedTarget(_ target: ScanTarget) -> SavedScan.Target {
        switch target {
        case .startupDisk: .startupDisk
        case .folder: .folder(path: root(of: target).path)
        }
    }

    /// Puts `saved` on screen as a store of its own (ages measured from now), judged and with its
    /// suggestions; the Trash stays unavailable while it shows (`trashUnavailableReason`). False
    /// when cancelled first.
    private func show(_ saved: SavedScan, target: ScanTarget) async -> Bool {
        let rootName = Self.root(of: target).name
        let now = UInt32(clamping: Int64(Date().timeIntervalSince1970))
        let store = await Task.detached(priority: .userInitiated) { ScanStore(saved: saved, now: now) }.value
        guard !Task.isCancelled else { return false }
        install(store, rootName: rootName, startupDisk: target == .startupDisk)
        shownSaved = (target, saved)
        shownSnapshotDate = Date(timeIntervalSince1970: TimeInterval(saved.startedAt))
        phase = .idle
        await applyEnvironment(to: store)
        await refreshViews()
        await selectionWork?.value
        await refreshSuggestions()
        if store === self.store { scanSettled = true }
        return true
    }

    /// Scans `target` out of sight behind the snapshot `saved` on screen: only what changed
    /// (`SavedScan.refreshPlan`), or everything when `full` or when the history cannot vouch for
    /// the snapshot. When it ends, its store replaces the snapshot (`swap`); when it is cancelled,
    /// the snapshot stays.
    private func update(_ target: ScanTarget, from saved: SavedScan, full: Bool) async {
        let (rootPath, rootName) = Self.root(of: target)
        let boundary = Self.boundary(of: target, rootPath: rootPath)
        let startedAt = Date.now
        let fullDiskAccess = FullDiskAccess.isGranted
        update = full ? .fullScan : .refresh
        updateProgress = nil
        var reader: ListingReader?
        if !full {
            let rootInode = (try? DirectoryReader.stat(path: rootPath))?.inode ?? 0
            let now = UInt32(clamping: Int64(startedAt.timeIntervalSince1970))
            // A whole day's history can take seconds to replay (measured: 8–9 s for 70 k events).
            let plan = await Task.detached(priority: .userInitiated) {
                saved.refreshPlan(now: now, rootInode: rootInode, hasFullDiskAccess: fullDiskAccess,
                                  history: SystemChangeHistory(timeout: .seconds(30)))
            }.value
            guard !Task.isCancelled else { return }
            switch plan {
            case let .incremental(changed):
                Self.snapshotLog.info("refresh: \(changed.count, privacy: .public) changed folders")
                reader = saved.listingReader(changed: changed)
            case let .fullScan(reason):
                Self.snapshotLog.info("full scan instead of a refresh: \(String(describing: reason), privacy: .public)")
                update = .fullScan
            }
        }
        let store = ScanStore(rootName: rootName, rootPath: rootPath)
        // The snapshot says how big the tree will be: no array doubles while it fills.
        await store.reserveCapacity(like: saved)
        let scanner = reader.map { Scanner(rootPath: rootPath, boundary: boundary, listing: $0) }
            ?? Scanner(rootPath: rootPath, boundary: boundary)
        let latest = LatestProgress()
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.refreshInterval)
                guard !Task.isCancelled else { return }
                if let progress = latest.value, update != nil { updateProgress = progress }
            }
        }
        let began = ContinuousClock.now
        let summary = await scanner.scan(into: store) { latest.value = $0 }
        ticker.cancel()
        await ticker.value
        guard !summary.wasCancelled, !Task.isCancelled else { return }
        let kind = reader == nil ? "full scan" : "refresh"
        Self.snapshotLog.info("""
            \(kind, privacy: .public) took \(String(describing: ContinuousClock.now - began), privacy: .public) \
            for \(summary.files, privacy: .public) files
            """)
        await applyEnvironment(to: store)
        await swap(to: store, rootName: rootName, startupDisk: target == .startupDisk)
        update = nil
        updateProgress = nil
        await finish(store, summary, target: target, startedAt: startedAt, fullDiskAccess: fullDiskAccess)
    }

    /// Replaces the shown store by `new`, staying in the folder shown (by path; the root when it
    /// is gone) and keeping the selection (by path; what is gone drops out). The new store's views
    /// are laid out first and land in the same main-actor turn as the store, so the charts never
    /// show empty and nothing on screen names a node of the old one.
    private func swap(to new: ScanStore, rootName: String, startupDisk: Bool) async {
        guard let old = store else { return install(new, rootName: rootName, startupDisk: startupDisk) }
        var mapped = FileTree.root
        var view: ScanStore.Snapshot?
        var laidOut: (chart: ChartKind, size: CGSize) = (chart, chartSize)
        for _ in 0..<3 {
            let wanted = center
            mapped = FileTree.root
            if let path = await old.path(of: wanted), let node = await new.node(atPath: path) { mapped = node }
            laidOut = (chart, chartSize)
            let request: ChartRequest = switch laidOut.chart {
            case .sunburst: .sunburst(depth: Self.ringDepth)
            case .treemap: .treemap(width: laidOut.size.width, height: laidOut.size.height, depth: Self.ringDepth)
            }
            view = await new.snapshot(center: mapped, chart: request, biggestLimit: Self.biggestLimit)
            // The user moved meanwhile: lay out where they are now.
            if wanted == center { break }
        }
        var kept: Set<NodeID> = []
        for id in selection {
            if let path = await old.path(of: id), let node = await new.node(atPath: path) { kept.insert(node) }
        }
        guard store === old else { return }
        install(new, rootName: rootName, startupDisk: startupDisk, keepViews: view != nil)
        center = mapped
        if let view { apply(view, chart: laidOut.chart, size: laidOut.size) }
        if !kept.isEmpty { changeSelection { _ in kept } }
    }

    /// Saves `store`'s finished scan as `target`'s snapshot, written off the main actor.
    private func save(_ store: ScanStore, target: ScanTarget, startedAt: Date, fullDiskAccess: Bool) async {
        let saved = await store.savedScan(target: Self.savedTarget(target),
                                          startedAt: UInt32(clamping: Int64(startedAt.timeIntervalSince1970)),
                                          hadFullDiskAccess: fullDiskAccess)
        Task.detached(priority: .utility) {
            do {
                try SnapshotFolder.standard.save(saved)
            } catch {
                ScanModel.snapshotLog.error("snapshot not saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static let snapshotLog = Logger(subsystem: "com.massilp.macspace", category: "snapshot")

    /// The startup volume's name as Finder shows it ("Macintosh HD" unless renamed).
    static let startupDiskName: String = {
        let values = try? URL(filePath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey])
        return values?.volumeLocalizedName ?? "Macintosh HD"
    }()

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

/// The startup disk's space as Finder shows it.
struct DiskUsage: Equatable {
    /// Capacity minus the space available for important usage: what Finder shows as used.
    let used: UInt64
    let capacity: UInt64

    /// Never reached while scanning: the bar disappears when the scan ends instead.
    static let maxProgress = 0.95

    /// "/"'s figures; nil when the volume does not report them.
    static func startupDisk() -> DiskUsage? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(filePath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        let capacity = UInt64(clamping: total)
        return DiskUsage(used: capacity - min(UInt64(clamping: available), capacity), capacity: capacity)
    }

    /// The estimated share of the scan done after `bytesSeen`, in 0…`maxProgress`: scanned bytes
    /// never reach the used space (system volume, APFS snapshots, unreadable folders).
    func progress(bytesSeen: UInt64) -> Double {
        guard used > 0 else { return 0 }
        return min(Double(bytesSeen) / Double(used), Self.maxProgress)
    }

    /// "Disco: 702,12 GB occupati"; where it wraps, the figure stays whole.
    var line: String {
        let figure = String(Formatters.bytes(used).map { $0.isWhitespace ? "\u{00A0}" : $0 })
        return String(localized: "Disco: \(figure) occupati")
    }

    /// "Disco: 702,12 GB occupati su 994,61 GB": the chart's spoken summary.
    var summary: String {
        String(localized: "Disco: \(Formatters.bytes(used)) occupati su \(Formatters.bytes(capacity))")
    }

    /// The tooltip and the spoken label: used space and capacity, and why the scan counts less.
    func explanation(scanned: UInt64) -> String {
        String(localized: "Disco: \(Formatters.bytes(used)) occupati su \(Formatters.bytes(capacity)). MacSpace conta \(Formatters.bytes(scanned)) nelle cartelle che può leggere; il resto è spazio del sistema, istantanee APFS o cartelle non leggibili.")
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
