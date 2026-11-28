import Darwin
import Foundation
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
}
