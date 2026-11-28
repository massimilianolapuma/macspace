import CoreServices
import Darwin
import Foundation
import Synchronization

/// Where the file system's change history stood when a scan started.
public struct ChangeBaseline: Sendable, Equatable {
    public let eventID: UInt64
    /// FSEvents UUID per device the scan was confined to; a device without history is absent.
    public let deviceUUIDs: [Int32: String]

    public init(eventID: UInt64, deviceUUIDs: [Int32: String]) {
        self.eventID = eventID
        self.deviceUUIDs = deviceUUIDs
    }
}

/// What changed at or below one path since a baseline.
public enum PathChanges: Sendable, Equatable {
    /// Folders (at or below the path, in the path's own spelling) whose entries may have changed.
    case folders(Set<String>)
    /// The history cannot say: dropped or wrapped events, the root changed, no history for the
    /// device, a different UUID, or the query timed out. Walk everything.
    case untrusted
}

/// Which folders changed since a baseline. `ScanStore.trash` asks it what to re-read before a move;
/// tests inject their own.
public protocol ChangeHistory: Sendable {
    /// The history's position now, for `devices`; nil when none of them keeps a history.
    func baseline(devices: Set<Int32>) -> ChangeBaseline?
    /// One query for all `paths`; `devices[path]` is the device each lives on. Every path gets an
    /// answer; anything that cannot be vouched for is `.untrusted`.
    func changes(since baseline: ChangeBaseline, under paths: [String], devices: [String: Int32]) -> [String: PathChanges]
}

/// `ChangeHistory` from the FSEvents service: the per-volume history every Mac keeps, which needs
/// no permission beyond reading the folders.
///
/// A query opens one stream over the real paths (`realpath`) from the baseline's event ID and waits
/// for the replay to end (`HistoryDone`). The service learns of changes from the kernel a moment
/// late, so a change made just before the query may not be in the replay yet, and flushing
/// (`FSEventStreamFlushSync`) only pushes out what the service already has. So the stream also
/// watches a private folder in the temporary directory, the query writes a file there (a cookie,
/// as watchman does), and waits until that change comes back: the kernel reports changes in
/// order, so every earlier change has come back by then. Events are per folder (no file events):
/// each names a folder whose entries changed.
///
/// Residual: if FSEvents purged history older than the baseline without resetting the volume's
/// database (which changes its UUID), and without flagging the gap, changes in the purged range are
/// not reported. The history covers weeks; a baseline is a scan's start.
public struct SystemChangeHistory: ChangeHistory {
    /// How long a query waits for the history replay before giving up (`.untrusted`).
    let timeout: DispatchTimeInterval

    /// Waits up to 5 s for a query (what `trash` can afford before a move).
    public init() { timeout = .seconds(5) }

    /// Waits up to `timeout` for a query: a refresh at launch replays a whole day's history (8–9 s
    /// for 70 k events measured on the owner's Mac), so it waits longer (#33).
    public init(timeout: DispatchTimeInterval) { self.timeout = timeout }

    public func baseline(devices: Set<Int32>) -> ChangeBaseline? {
        let id = FSEventsGetCurrentEventId()
        var uuids: [Int32: String] = [:]
        for device in devices {
            if let uuid = Self.uuid(device) { uuids[device] = uuid }
        }
        return uuids.isEmpty ? nil : ChangeBaseline(eventID: id, deviceUUIDs: uuids)
    }

    public func changes(since baseline: ChangeBaseline, under paths: [String],
                        devices: [String: Int32]) -> [String: PathChanges] {
        var result: [String: PathChanges] = [:]
        var watched: [(path: String, real: String)] = []
        var current: [Int32: String?] = [:]
        for path in Set(paths) {
            guard let device = devices[path], let expected = baseline.deviceUUIDs[device] else {
                result[path] = .untrusted
                continue
            }
            let uuid = current[device] ?? Self.uuid(device)
            current[device] = uuid
            guard uuid == expected, let real = Self.realPath(path) else {
                result[path] = .untrusted
                continue
            }
            watched.append((path, real))
        }
        guard !watched.isEmpty else { return result }
        guard let events = events(since: baseline.eventID, realPaths: Array(Set(watched.map(\.real)))) else {
            for w in watched { result[w.path] = .untrusted }
            return result
        }
        for w in watched { result[w.path] = Self.changes(at: w.path, real: w.real, in: events) }
        return result
    }

    // MARK: - Mapping events to paths

    /// Flags after which the events cannot be trusted to name every changed folder.
    static let untrustedFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
        | kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
    /// Flags that make every path untrusted, wherever the event says it happened.
    static let globalFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped)

    struct Event: Sendable {
        /// Real path, without a trailing `/`.
        let path: String
        let flags: FSEventStreamEventFlags
    }

    /// What `events` say about `path` (real path `real`): the changed folders at or below it, in
    /// `path`'s spelling, or `.untrusted` when an untrusting event is at, above or below it (or dropped
    /// events anywhere), or when an event is at or below it only once case and Unicode form are
    /// folded (`SafetyPaths.folded`): such an event cannot be mapped back to the tree's spelling.
    static func changes(at path: String, real: String, in events: [Event]) -> PathChanges {
        var folders: Set<String> = []
        let foldedReal = SafetyPaths.folded(real)
        for event in events {
            if event.flags & globalFlags != 0 { return .untrusted }
            if let suffix = Self.suffix(of: event.path, under: real) {
                if event.flags & untrustedFlags != 0 { return .untrusted }
                folders.insert(path + suffix)
                continue
            }
            let folded = SafetyPaths.folded(event.path)
            let below = Self.suffix(of: folded, under: foldedReal) != nil
            let above = Self.suffix(of: foldedReal, under: folded) != nil
            if below || (above && event.flags & untrustedFlags != 0) { return .untrusted }
        }
        return .folders(folders)
    }

    /// The part of `path` after `base` ("" when equal, "/x/y" below it), compared by `/` component;
    /// nil when `path` is not at or below `base`.
    static func suffix(of path: String, under base: String) -> String? {
        let p = Array(path.utf8), b = Array(base.utf8)
        if b == [UInt8(ascii: "/")] { return p == b ? "" : (p.first == UInt8(ascii: "/") ? path : nil) }
        guard p.starts(with: b) else { return nil }
        if p.count == b.count { return "" }
        guard p[b.count] == UInt8(ascii: "/") else { return nil }
        return String(decoding: p[b.count...], as: UTF8.self)
    }

    // MARK: - FSEvents

    static func uuid(_ device: Int32) -> String? {
        guard let uuid = FSEventsCopyUUIDForDevice(dev_t(device)) else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Collects a stream's events on its queue, and signals the end of the replay and the cookie.
    private final class Collector: Sendable {
        struct State {
            var events: [Event] = []
            var historyDone = false
            var cookieSeen = false
        }
        /// Real path of the cookie folder: its events are not collected.
        let cookieFolder: String
        let state = Mutex(State())
        let historyDone = DispatchSemaphore(value: 0)
        let cookieSeen = DispatchSemaphore(value: 0)

        init(cookieFolder: String) { self.cookieFolder = cookieFolder }

        func receive(_ batch: [(path: String, flags: FSEventStreamEventFlags)]) {
            var signalHistory = false, signalCookie = false
            state.withLock { state in
                for (path, flags) in batch {
                    if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                        if !state.historyDone { signalHistory = true }
                        state.historyDone = true
                        continue
                    }
                    if SystemChangeHistory.suffix(of: path, under: cookieFolder) != nil {
                        // Only the cookie written after the replay counts.
                        if state.historyDone, !state.cookieSeen, path == cookieFolder {
                            state.cookieSeen = true
                            signalCookie = true
                        }
                        // Dropped events say nothing about where; keep them.
                        if flags & SystemChangeHistory.globalFlags == 0 { continue }
                    }
                    state.events.append(Event(path: path, flags: flags))
                }
            }
            if signalHistory { historyDone.signal() }
            if signalCookie { cookieSeen.signal() }
        }
    }

    /// Every event after `eventID` at or below `realPaths`, up to now; nil when the stream cannot
    /// be started, the cookie cannot be written, or the replay or the cookie does not come back
    /// within `timeout`.
    private func events(since eventID: UInt64, realPaths: [String]) -> [Event]? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSpace-changes-\(UUID().uuidString)", isDirectory: true).path
        guard mkdir(folder, 0o700) == 0 else { return nil }
        defer { _ = try? FileManager.default.removeItem(atPath: folder) }
        guard let cookieFolder = Self.realPath(folder) else { return nil }
        let collector = Collector(cookieFolder: cookieFolder)
        let deadline = DispatchTime.now() + timeout
        return withExtendedLifetime(collector) { () -> [Event]? in
            var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                               retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                guard let info else { return }
                let collector = Unmanaged<Collector>.fromOpaque(info).takeUnretainedValue()
                let names = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
                var batch: [(path: String, flags: FSEventStreamEventFlags)] = []
                for i in 0..<count {
                    var path = String(cString: names[i])
                    while path.utf8.count > 1, path.hasSuffix("/") { path.removeLast() }
                    batch.append((path, flags[i]))
                }
                collector.receive(batch)
            }
            let createFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
            guard let stream = FSEventStreamCreate(nil, callback, &context, (realPaths + [cookieFolder]) as CFArray,
                                                   eventID, 0, createFlags) else { return nil }
            let queue = DispatchQueue(label: "MacSpace.ChangeHistory")
            FSEventStreamSetDispatchQueue(stream, queue)
            var started = false
            defer {
                if started { FSEventStreamStop(stream) }
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                // A callback already queued still runs: wait for it while `collector` is alive (the
                // context holds it unretained).
                queue.sync {}
            }
            started = FSEventStreamStart(stream)
            guard started else { return nil }
            guard collector.historyDone.wait(timeout: deadline) == .success else { return nil }
            let cookie = cookieFolder + "/cookie"
            let fd = open(cookie, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return nil }
            close(fd)
            FSEventStreamFlushSync(stream)
            guard collector.cookieSeen.wait(timeout: deadline) == .success else { return nil }
            return collector.state.withLock { $0.events }
        }
    }
}
