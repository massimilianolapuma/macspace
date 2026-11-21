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

    var phase: Phase = .idle
    /// The folder the chart and the list are centred on.
    var center: NodeID = FileTree.root
    var segments: [ArcSegment] = []
    var biggest: [NodeRow] = []
    /// From the scan root down to `center`.
    var breadcrumb: [NodeRow] = []
    var hovered: ArcSegment?

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

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
            await refreshViews()
        }
    }

    /// Reloads `segments`, `biggest` and `breadcrumb` for the current `center`.
    func refreshViews() async {
        guard let store else { return }
        let center = self.center
        let segments = await store.sunburst(center: center, depth: Self.ringDepth)
        let biggest = await store.rows(childrenOf: center, limit: Self.biggestLimit)
        let breadcrumb = await store.breadcrumb(to: center)
        // A newer scan or navigation happened meanwhile: its own refresh wins.
        guard store === self.store, center == self.center else { return }
        self.segments = segments
        self.biggest = biggest
        self.breadcrumb = breadcrumb
        if let hovered {
            self.hovered = segments.first { $0.id == hovered.id }
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
        segments = []
        biggest = []
        breadcrumb = []
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
        // The scanner sends no final progress callback: show the finished tree.
        await refreshViews()
    }

    /// Scan root path and display name. Chosen folders are resolved first: the reader
    /// opens directories with `O_NOFOLLOW`, so a symlinked root would fail.
    private static func root(of target: ScanTarget) -> (path: String, name: String) {
        switch target {
        case .startupDisk:
            return ("/", "Macintosh HD")
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
