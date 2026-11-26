import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

@Test func openFileIsSeen() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let url = try fx.file("d/held.bin", bytes: 10)
    let h = try FileHandle(forReadingFrom: url)
    let open = OpenFileSet.current()
    #expect(open.isOpen(url.path) && open.hasOpen(under: fx.root.path + "/d"))
    try h.close()
    #expect(!OpenFileSet.current().isOpen(url.path))
    #expect(!OpenFileSet(paths: ["/a/bc"]).hasOpen(under: "/a/b"))
}

@Test func openFileSetLookups() {
    let set = OpenFileSet(paths: ["/a/b/c", "/a/bc", "/z", "/a/b/c"])
    #expect(set.isOpen("/a/b/c") && !set.isOpen("/a/b"))
    #expect(set.hasOpen(under: "/a/b") && set.hasOpen(under: "/a") && set.hasOpen(under: "/"))
    #expect(!set.hasOpen(under: "/a/b/c") && !set.hasOpen(under: "/y"))
    #expect(!OpenFileSet(paths: []).hasOpen(under: "/"))
    // The kernel reports /var, /tmp and /etc under /private.
    let kernel = OpenFileSet(paths: ["/private/var/folders/x/f", "/tmp/t"])
    #expect(kernel.isOpen("/var/folders/x/f") && kernel.hasOpen(under: "/var/folders"))
    #expect(kernel.isOpen("/private/tmp/t") && kernel.hasOpen(under: "/tmp"))
}

@Test func prefixLookupIsByteWiseNFC() {
    // A combining mark right after "/" sorts between siblings but is not a grapheme prefix.
    let set = OpenFileSet(paths: ["/a/c", "/a/d/\u{301}x", "/a/d/\u{4E00}"])
    #expect(set.hasOpen(under: "/a/d"))
    #expect(set.isOpen("/a/d/\u{301}x") && set.isOpen("/a/d/\u{4E00}") && !set.hasOpen(under: "/a/c"))
    // The same name stored in NFD matches an NFC query, and the other way round.
    let nfd = OpenFileSet(paths: ["/u/Cafe\u{0301}/f"])
    #expect(nfd.isOpen("/u/Caf\u{E9}/f") && nfd.hasOpen(under: "/u/Caf\u{E9}"))
    let nfc = OpenFileSet(paths: ["/u/Caf\u{E9}/f"])
    #expect(nfc.isOpen("/u/Cafe\u{0301}/f") && nfc.hasOpen(under: "/u/Cafe\u{0301}"))
}

@Test func completeness() {
    #expect(OpenFileSet(paths: ["/a"]).isComplete)
    #expect(!OpenFileSet(paths: ["/a"], isComplete: false).isComplete)
    #expect(OpenFileSet.current().isComplete)
}

@Test func systemPackageProbe() {
    #expect(SystemPackageProbe().isPackage("/System/Applications/Calculator.app"))
    #expect(!SystemPackageProbe().isPackage("/System/Applications"))
    #expect(!SystemPackageProbe().isPackage("/nonexistent/Missing.app"))
}

@Test func recordingDiskActionsMovesIntoFixtureTrash() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let trash = try fx.dir("trash")
    let item = try fx.file("doc.txt", bytes: 3)
    let actions = RecordingDiskActions(trash: trash.path)
    let moved = try actions.moveToTrash(item.path)
    #expect(actions.moved == [item.path])
    #expect(moved == trash.path + "/doc.txt" && FileManager.default.fileExists(atPath: trash.path + "/doc.txt"))
    #expect(!FileManager.default.fileExists(atPath: item.path))
}

// MARK: - Completeness per process (audit SEC-03)

@Test func ownProcessThatCannotBeListedMakesTheSetIncomplete() {
    let set = OpenFileSet.collect(pids: [1, 2, 3]) { pid in
        pid == 2 ? .failed(errno: EPERM) : .listed(paths: ["/u/\(pid)"], truncated: false)
    }
    #expect(!set.isComplete)
    // What could be read is still reported.
    #expect(set.isOpen("/u/1") && set.isOpen("/u/3"))
}

@Test func truncatedDescriptorListMakesTheSetIncomplete() {
    let set = OpenFileSet.collect(pids: [1, 2]) { pid in
        .listed(paths: ["/u/\(pid)"], truncated: pid == 2)
    }
    #expect(!set.isComplete && set.isOpen("/u/2"))
}

@Test func exitedAndOtherUsersProcessesKeepTheSetComplete() {
    let set = OpenFileSet.collect(pids: [0, 1, 2, 3, 4]) { pid in
        switch pid {
        case 1: .gone
        case 2: .otherUser
        case 3: .listed(paths: ["/a/b/c", "/tmp/t"], truncated: false)
        case 4: .listed(paths: [], truncated: false)
        default: .failed(errno: EINVAL)   // pid 0 is never inspected
        }
    }
    #expect(set.isComplete)
    #expect(set.isOpen("/a/b/c") && set.hasOpen(under: "/a") && set.isOpen("/private/tmp/t"))
    #expect(!set.isOpen("/u/1"))
}

/// Opt-in: `MACSPACE_OPENFILES=1 swift test --filter openFilesCompleteInNormalConditions`.
/// Reads the open files repeatedly and prints any process of this user that could not be listed.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACSPACE_OPENFILES"] == "1"))
func openFilesCompleteInNormalConditions() throws {
    var incomplete = 0
    for _ in 0..<50 {
        let inspections = try #require(OpenFileSet.inspectAll())
        var counts: [String: Int] = [:]
        for (pid, inspection) in inspections {
            switch inspection {
            case .gone: counts["gone", default: 0] += 1
            case .otherUser: counts["otherUser", default: 0] += 1
            case let .failed(code):
                counts["failed", default: 0] += 1
                var name = [CChar](repeating: 0, count: 256)
                proc_name(pid, &name, UInt32(name.count))
                print("own process \(pid) \(String(cString: name)): errno \(code) (\(String(cString: strerror(code))))")
            case let .listed(paths, truncated):
                counts["listed", default: 0] += 1
                counts["paths", default: 0] += paths.count
                if truncated {
                    counts["truncated", default: 0] += 1
                    print("own process \(pid): descriptor list still truncated")
                }
            }
        }
        let byPID = Dictionary(inspections, uniquingKeysWith: { first, _ in first })
        if !OpenFileSet.collect(pids: inspections.map(\.pid), inspect: { byPID[$0] ?? .gone }).isComplete {
            incomplete += 1
        }
        print("open files: \(counts.sorted { $0.key < $1.key })")
    }
    #expect(incomplete == 0)
}
