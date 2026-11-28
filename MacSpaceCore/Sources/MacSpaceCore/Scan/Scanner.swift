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
    /// Directories read only in part: the file system left an entry out (`DirectoryListing.isComplete`
    /// false), not a read cut short by cancellation.
    public var partlyRead: Int
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
    /// Lists one directory: `DirectoryReader.read`, or a stand-in in tests.
    let reader: @Sendable (String) throws(DirectoryReadError) -> DirectoryListing

    static let progressInterval: Duration = .milliseconds(100)

    /// One read per active core, minus two: the cooperative pool keeps threads free for
    /// UI-facing work (store queries, the main actor's tasks) while a scan saturates the rest.
    public static var defaultConcurrency: Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount - 2)
    }

    public init(rootPath: String, boundary: ScanBoundary, maxConcurrency: Int = Scanner.defaultConcurrency) {
        self.init(rootPath: rootPath, boundary: boundary, maxConcurrency: maxConcurrency) { path throws(DirectoryReadError) in
            try DirectoryReader.read(path: path)
        }
    }

    /// With `reader` in place of `DirectoryReader.read`, so tests can return incomplete listings.
    init(rootPath: String, boundary: ScanBoundary, maxConcurrency: Int = Scanner.defaultConcurrency,
         reader: @escaping @Sendable (String) throws(DirectoryReadError) -> DirectoryListing) {
        self.rootPath = rootPath
        self.boundary = boundary
        self.maxConcurrency = max(1, maxConcurrency)
        self.reader = reader
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
        var files = 0, directories = 0, unreadable = 0, partlyRead = 0
        var bytes: UInt64 = 0
        var cancelled = false
        /// Directories whose listing is missing (never read, the scan was cancelled) or partial
        /// (an entry was left out, or the read was cut short by cancellation).
        var unverified: [NodeID] = []
        let boundary = self.boundary
        let reader = self.reader
        // The root's identity, before the first read: `trash` checks the root is still this folder.
        // The history's position too, so changes made while the scan runs count as changes.
        let rootEntry = try? DirectoryReader.stat(path: rootPath)
        await store.markScanStarted(rootInode: rootEntry?.inode ?? 0, rootDevice: rootEntry?.device ?? 0,
                                    baseline: store.history.baseline(devices: boundary.allowedDevices))

        await withTaskGroup(of: DirectoryResult.self) { group in
            while true {
                while !cancelled, inFlight < maxConcurrency, !pending.isEmpty {
                    if Task.isCancelled {
                        cancelled = true
                        break
                    }
                    let next = pending.removeLast()
                    group.addTask(priority: .utility) {
                        await Self.process(next.id, path: next.path, store: store, boundary: boundary, reader: reader)
                    }
                    inFlight += 1
                }
                guard let result = await group.next() else { break }
                inFlight -= 1
                switch result {
                case .skipped(let id):
                    cancelled = true
                    unverified.append(id)
                case .unreadable:
                    unreadable += 1
                case let .read(id, children, fileCount, directoryCount, byteCount, partial, incomplete):
                    if partial { unverified.append(id) }
                    if incomplete { partlyRead += 1 }
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
        unverified += pending.map(\.id)
        await store.markScanFinished(allowedDevices: boundary.allowedDevices, unverifiedDirectories: unverified)
        progress?(ScanProgress(filesSeen: files, bytesSeen: bytes, directoriesPending: 0))

        return ScanSummary(files: files, directories: directories, unreadable: unreadable, partlyRead: partlyRead,
                           totalSize: await store.rootSize(), duration: clock.now - start,
                           wasCancelled: cancelled)
    }

    private enum DirectoryResult: Sendable {
        /// `partial`: the listing is incomplete (`DirectoryListing.isComplete`: an entry the file
        /// system reported an error for, or a malformed record, was left out) or was cut short by
        /// cancellation, so the directory's contents are not all known (`unverifiedDirectories`).
        /// `incomplete`: the file system left an entry out (not cancellation), counted in `partlyRead`.
        case read(id: NodeID, children: [(id: NodeID, path: String)], files: Int, directories: Int, bytes: UInt64,
                  partial: Bool, incomplete: Bool)
        case unreadable
        case skipped(NodeID)
    }

    /// Reads one directory and inserts its entries: one actor hop either way.
    private static func process(_ id: NodeID, path: String, store: ScanStore, boundary: ScanBoundary,
                                reader: @Sendable (String) throws(DirectoryReadError) -> DirectoryListing)
        async -> DirectoryResult {
        guard !Task.isCancelled else { return .skipped(id) }
        let listing: DirectoryListing
        do {
            listing = try reader(path)
        } catch {
            await store.markUnreadable(id)
            return .unreadable
        }
        let entries = listing.entries
        var files = 0, directories = 0
        for entry in entries {
            if entry.kind == .directory { directories += 1 } else { files += 1 }
        }
        // `read` stops early without throwing once the task is cancelled (the listing then says
        // incomplete too); checked again here in case cancellation came right after it.
        // `read` also stops early (incomplete) once cancelled: only an incomplete listing of a task
        // still running is the file system's doing.
        let cancelled = Task.isCancelled
        let incomplete = !listing.isComplete && !cancelled
        let partial = !listing.isComplete || cancelled
        let inserted = await store.insert(entries, under: id, parentPath: path, boundary: boundary)
        return .read(id: id, children: inserted.descend, files: files, directories: directories,
                     bytes: inserted.bytes, partial: partial, incomplete: incomplete)
    }
}
