import Foundation

public struct ScanProgress: Sendable {
    public var filesSeen: Int
    /// Bytes added to the tree by the reads completed so far (hard-link duplicates excluded).
    /// The final report equals the store's `rootSize`; earlier ones can trail it slightly.
    public var bytesSeen: UInt64
    /// Directories queued or being read.
    public var directoriesPending: Int

    public init(filesSeen: Int, bytesSeen: UInt64, directoriesPending: Int) {
        self.filesSeen = filesSeen
        self.bytesSeen = bytesSeen
        self.directoriesPending = directoriesPending
    }
}

public struct ScanSummary: Sendable {
    /// Non-directory entries (files, symbolic links, other).
    public var files: Int
    /// Directory entries found below the root.
    public var directories: Int
    /// Directories that could not be read.
    public var unreadable: Int
    public var totalSize: UInt64
    public var duration: Duration
    public var wasCancelled: Bool
}

/// Walks a directory tree in parallel and fills a `ScanStore`.
/// At most `maxConcurrency` directory reads are in flight; each read directory costs one
/// actor hop (`insert`, or `markUnreadable` when the read fails).
public struct Scanner: Sendable {
    public let rootPath: String
    public let boundary: ScanBoundary
    public let maxConcurrency: Int

    static let progressInterval: Duration = .milliseconds(100)

    /// One read per active core, minus two: the cooperative pool keeps threads free for
    /// UI-facing work (store queries, the main actor's tasks) while a scan saturates the rest.
    public static var defaultConcurrency: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    public init(rootPath: String, boundary: ScanBoundary, maxConcurrency: Int = Scanner.defaultConcurrency) {
        self.rootPath = rootPath
        self.boundary = boundary
        self.maxConcurrency = max(1, maxConcurrency)
    }

    /// Scans from `rootPath` into `store`, whose root node represents `rootPath`.
    /// On cancellation, reads already in flight are drained and the summary reports
    /// `wasCancelled`; the store keeps whatever was inserted. `progress` is called at most every
    /// `progressInterval`, plus once with the final counts when the scan ends.
    ///
    /// Directory reads (and their `ScanStore` inserts) run in child tasks at `.utility`
    /// priority, whatever the caller's priority, so higher-priority work, such as UI queries
    /// to the same store, is scheduled ahead of them. Together with the default limit
    /// (`defaultConcurrency`), this keeps store queries responsive while a scan is running.
    public func scan(into store: ScanStore,
                     progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> ScanSummary {
        let clock = ContinuousClock()
        let start = clock.now
        var lastReport = start
        var pending: [(id: NodeID, path: String)] = [(id: FileTree.root, path: rootPath)]
        var inFlight = 0
        var files = 0, directories = 0, unreadable = 0
        var bytes: UInt64 = 0
        var cancelled = false
        let boundary = self.boundary

        await withTaskGroup(of: DirectoryResult.self) { group in
            while true {
                while !cancelled, inFlight < maxConcurrency, !pending.isEmpty {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    let next = pending.removeLast()
                    group.addTask(priority: .utility) {
                        await Self.process(next.id, path: next.path, store: store, boundary: boundary)
                    }
                    inFlight += 1
                }
                guard let result = await group.next() else { break }
                inFlight -= 1
                switch result {
                case .skipped:
                    cancelled = true
                case .unreadable:
                    unreadable += 1
                case let .read(children, fileCount, directoryCount, byteCount):
                    pending.append(contentsOf: children)
                    files += fileCount
                    directories += directoryCount
                    bytes &+= byteCount
                }
                if let progress, clock.now - lastReport >= Self.progressInterval {
                    lastReport = clock.now
                    progress(ScanProgress(filesSeen: files, bytesSeen: bytes,
                                          directoriesPending: pending.count + inFlight))
                }
            }
        }
        progress?(ScanProgress(filesSeen: files, bytesSeen: bytes, directoriesPending: 0))

        return ScanSummary(files: files, directories: directories, unreadable: unreadable,
                           totalSize: await store.rootSize(), duration: clock.now - start,
                           wasCancelled: cancelled)
    }

    private enum DirectoryResult: Sendable {
        case read(children: [(id: NodeID, path: String)], files: Int, directories: Int, bytes: UInt64)
        case unreadable
        case skipped
    }

    /// Reads one directory and inserts its entries: one actor hop either way.
    private static func process(_ id: NodeID, path: String, store: ScanStore,
                                boundary: ScanBoundary) async -> DirectoryResult {
        guard !Task.isCancelled else { return .skipped }
        let entries: [DirectoryEntry]
        do {
            entries = try DirectoryReader.read(path: path)
        } catch {
            await store.markUnreadable(id)
            return .unreadable
        }
        var files = 0, directories = 0
        for entry in entries {
            if entry.kind == .directory { directories += 1 } else { files += 1 }
        }
        let inserted = await store.insert(entries, under: id, parentPath: path, boundary: boundary)
        return .read(children: inserted.descend, files: files, directories: directories, bytes: inserted.bytes)
    }
}
