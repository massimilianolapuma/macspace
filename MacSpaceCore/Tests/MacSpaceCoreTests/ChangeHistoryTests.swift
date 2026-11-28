import CoreServices
import Darwin
import Foundation
import Synchronization
import Testing
@testable import MacSpaceCore

/// Live tests against FSEvents, in the temporary directory (`/var/folders/...`, really
/// `/private/var/folders/...`): changes must come back in the spelling the paths were asked in.
@Suite(.serialized) struct ChangeHistoryTests {
    let history = SystemChangeHistory()

    private func device(_ fx: Fixture) throws -> Int32 { try DirectoryReader.stat(path: fx.root.path).device }

    /// A baseline taken once the fixture's own changes have reached the history (a query waits for
    /// that), so they do not show up as changes after it. In the app, such early changes only cost a
    /// re-read of their folder.
    private func baseline(_ fx: Fixture) throws -> ChangeBaseline {
        let dev = try device(fx)
        let early = try #require(history.baseline(devices: [dev]))
        _ = history.changes(since: early, under: [fx.root.path], devices: [fx.root.path: dev])
        return try #require(history.baseline(devices: [dev]))
    }

    @Test func noChangeReportsNoFolders() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.file("a/x", bytes: 10)
        let start = try baseline(fx)
        let a = fx.root.path + "/a"
        #expect(history.changes(since: start, under: [a], devices: [a: try device(fx)]) == [a: .folders([])])
    }

    @Test func addedFileReportsItsFolder() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.file("a/x", bytes: 10)
        let start = try baseline(fx)
        try fx.file("a/sub/new", bytes: 10)
        let a = fx.root.path + "/a"
        // Asked right away, no sleep: the query must flush what is still pending.
        let result = history.changes(since: start, under: [a], devices: [a: try device(fx)])
        guard case .folders(let folders) = try #require(result[a]) else {
            Issue.record("untrusted: \(result)")
            return
        }
        #expect(a.hasPrefix("/var/"))
        #expect(folders.contains(a + "/sub"))
        #expect(folders.allSatisfy { $0 == a || $0.hasPrefix(a + "/") })
    }

    @Test func changeOutsideIsNotReported() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.file("a/x", bytes: 10)
        try fx.dir("b")
        let start = try baseline(fx)
        try fx.file("b/new", bytes: 10)
        let a = fx.root.path + "/a"
        #expect(history.changes(since: start, under: [a], devices: [a: try device(fx)]) == [a: .folders([])])
    }

    @Test func unknownDeviceIsUntrusted() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.dir("a")
        let start = try baseline(fx)
        let a = fx.root.path + "/a"
        let without = ChangeBaseline(eventID: start.eventID, deviceUUIDs: [:])
        #expect(history.changes(since: without, under: [a], devices: [a: try device(fx)]) == [a: .untrusted])
        #expect(history.changes(since: start, under: [a], devices: [:]) == [a: .untrusted])
    }

    @Test func otherUUIDIsUntrusted() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        try fx.dir("a")
        let start = try baseline(fx)
        let a = fx.root.path + "/a", dev = try device(fx)
        let other = ChangeBaseline(eventID: start.eventID, deviceUUIDs: [dev: UUID().uuidString])
        #expect(history.changes(since: other, under: [a], devices: [a: dev]) == [a: .untrusted])
    }

    // MARK: - Mapping events to paths (no FSEvents)

    private typealias Event = SystemChangeHistory.Event
    private static func flag(_ f: Int) -> FSEventStreamEventFlags { FSEventStreamEventFlags(f) }

    @Test func suffixComparesByComponent() {
        #expect(SystemChangeHistory.suffix(of: "/a/b", under: "/a/b") == "")
        #expect(SystemChangeHistory.suffix(of: "/a/b/c", under: "/a/b") == "/c")
        #expect(SystemChangeHistory.suffix(of: "/a/bc", under: "/a/b") == nil)
        #expect(SystemChangeHistory.suffix(of: "/a", under: "/a/b") == nil)
        #expect(SystemChangeHistory.suffix(of: "/x/y", under: "/") == "/x/y")
    }

    @Test func eventsMapToTheAskedSpelling() {
        let events = [Event(path: "/private/v/a/sub", flags: 0), Event(path: "/private/v/b", flags: 0)]
        #expect(SystemChangeHistory.changes(at: "/v/a", real: "/private/v/a", in: events) == .folders(["/v/a/sub"]))
    }

    @Test func untrustingFlagsAtAboveOrBelowUntrustThePath() {
        let at = { (path: String, f: Int) in
            SystemChangeHistory.changes(at: "/v/a", real: "/private/v/a",
                                        in: [Event(path: path, flags: Self.flag(f))])
        }
        #expect(at("/private/v/a/sub", kFSEventStreamEventFlagMustScanSubDirs) == .untrusted)
        #expect(at("/private/v", kFSEventStreamEventFlagMustScanSubDirs) == .untrusted)
        #expect(at("/private/v/a", kFSEventStreamEventFlagRootChanged) == .untrusted)
        #expect(at("/elsewhere", kFSEventStreamEventFlagUserDropped) == .untrusted)
        #expect(at("/elsewhere", kFSEventStreamEventFlagKernelDropped) == .untrusted)
        #expect(at("/elsewhere", kFSEventStreamEventFlagEventIdsWrapped) == .untrusted)
        #expect(at("/private/v/b", kFSEventStreamEventFlagMustScanSubDirs) == .folders([]))
    }

    /// An event spelled with other bytes than the path asked about (case, Unicode form) cannot be
    /// mapped back for sure: the path is untrusted (fail closed), not "nothing changed".
    @Test func eventSpelledOtherwiseUntrustsThePath() {
        let upper = [Event(path: "/private/v/A/sub", flags: 0)]
        #expect(SystemChangeHistory.changes(at: "/v/a", real: "/private/v/a", in: upper) == .untrusted)
        let nfd = [Event(path: "/private/v/Cafe\u{301}/x", flags: 0)]
        #expect(SystemChangeHistory.changes(at: "/v/Caf\u{e9}", real: "/private/v/Caf\u{e9}", in: nfd) == .untrusted)
    }
}

/// Records what the real history answered, to prove a move was judged through it.
final class SpyChangeHistory: ChangeHistory {
    let real = SystemChangeHistory()
    let answers = Mutex<[String: PathChanges]>([:])
    func baseline(devices: Set<Int32>) -> ChangeBaseline? { real.baseline(devices: devices) }
    func changes(since baseline: ChangeBaseline, under paths: [String],
                 devices: [String: Int32]) -> [String: PathChanges] {
        let result = real.changes(since: baseline, under: paths, devices: devices)
        answers.withLock { $0.merge(result) { _, new in new } }
        return result
    }
}

/// End to end, with the real history: a Photos library added after the scan is caught through the
/// history's answer (not the fallback walk), and nothing moves.
@Test func realHistoryCatchesNewContent() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let bin = try Fixture(); defer { bin.cleanup() }
    try fx.file("a/sub/old.txt", bytes: 100)
    let spy = SpyChangeHistory()
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path, history: spy)
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    await store.setEnvironment(.system(home: fx.root.path, apps: .empty))
    try fx.file("a/sub/New.photoslibrary/database/x", bytes: 100)
    let a = try #require(await store.node(atPath: fx.root.path + "/a"))
    let actions = RecordingDiskActions(trash: bin.root.path)
    let outcome = await store.trash([a], actions: actions, packages: FakePackageProbe(packages: []),
                                    openFiles: { OpenFileSet(paths: []) }, expectedVerdicts: nil)
    #expect(outcome.skipped.map(\.reason) == [.containsProtected(.photosLibrary)])
    #expect(actions.moved.isEmpty)
    guard case .folders(let folders) = try #require(spy.answers.withLock { $0[fx.root.path + "/a"] }) else {
        Issue.record("the history did not vouch for the folder: the fallback walk judged it")
        return
    }
    #expect(folders.contains(fx.root.path + "/a/sub"))
}
