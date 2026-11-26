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

private func processName(_ pid: pid_t) -> String {
    var name = [UInt8](repeating: 0, count: 256)
    proc_name(pid, &name, UInt32(name.count))
    return String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
}

@Test func listCallEndings() {
    #expect(OpenFileSet.listCall(result: 360, errno: 0) == .bytes(360))
    // A process with no descriptors at all: the kernel fills 0 bytes and reports no error.
    #expect(OpenFileSet.listCall(result: 0, errno: 0) == .bytes(0))
    #expect(OpenFileSet.listCall(result: 0, errno: ESRCH) == .gone)
    #expect(OpenFileSet.listCall(result: 0, errno: EPERM) == .failed(errno: EPERM))
    #expect(OpenFileSet.listCall(result: -1, errno: EINVAL) == .failed(errno: EINVAL))
}

@Test func descriptorsWhosePathsCannotBeReadKeepTheSetComplete() {
    let vnode = UInt32(PROX_FDTYPE_VNODE)
    let fds = [proc_fdinfo(proc_fd: 0, proc_fdtype: vnode), proc_fdinfo(proc_fd: 1, proc_fdtype: vnode),
               proc_fdinfo(proc_fd: 2, proc_fdtype: UInt32(PROX_FDTYPE_SOCKET))]
    // Every path read fails (EBADF, ENOENT on a revoked terminal, EPERM…): skipped, still complete.
    let unreadable = OpenFileSet.listing(fds, truncated: false) { _ in nil }
    #expect(unreadable == .listed(paths: [], truncated: false))
    #expect(OpenFileSet.collect(pids: [7]) { _ in unreadable }.isComplete)
    // Only vnode descriptors are asked for.
    var asked: [Int32] = []
    let some = OpenFileSet.listing(fds, truncated: false) { fd in asked.append(fd); return fd == 1 ? "/u/f" : nil }
    #expect(some == .listed(paths: ["/u/f"], truncated: false) && asked == [0, 1])
    #expect(OpenFileSet.listing([], truncated: true) { _ in nil } == .listed(paths: [], truncated: true))
}

/// Starts `/bin/sleep 30` with `fileActions`, every other descriptor closed (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
private func spawnSleep(_ fileActions: inout posix_spawn_file_actions_t?) throws -> pid_t {
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
    var pid: pid_t = 0
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("30"), nil]
    defer { argv.forEach { free($0) } }
    let code = posix_spawn(&pid, "/bin/sleep", &fileActions, &attributes, argv, nil)
    try #require(code == 0)
    return pid
}

private func reap(_ pid: pid_t) {
    kill(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
}

/// `pid`'s inspection once it equals `expected`, polling for up to 5 s (the child may still be
/// starting); else the last one seen (nil when the pid was never listed).
private func inspection(of pid: pid_t, becoming expected: OpenFileSet.Inspection) -> OpenFileSet.Inspection? {
    let deadline = ContinuousClock.now + .seconds(5)
    var last: OpenFileSet.Inspection?
    repeat {
        last = OpenFileSet.inspectAll()?.first { $0.pid == pid }?.inspection ?? last
        if last == expected { return last }
        usleep(20_000)
    } while ContinuousClock.now < deadline
    return last
}

@Test func processWithNoDescriptorsIsListedEmpty() throws {   // review I2
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    let pid = try spawnSleep(&actions)
    defer { reap(pid) }
    let empty = OpenFileSet.Inspection.listed(paths: [], truncated: false)
    #expect(inspection(of: pid, becoming: empty) == empty)
}

@Test func processHoldingARevokedTerminalKeepsTheSetComplete() throws {   // review I1
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    try #require(master >= 0)
    defer { close(master) }
    try #require(grantpt(master) == 0 && unlockpt(master) == 0)
    let slave = String(cString: try #require(ptsname(master)))
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, slave, O_RDWR | O_NOCTTY, 0)
    let pid = try spawnSleep(&actions)
    defer { reap(pid) }
    let holding = OpenFileSet.Inspection.listed(paths: [slave], truncated: false)
    try #require(inspection(of: pid, becoming: holding) == holding)
    // Its terminal is revoked (as when the session that owned it ends): the descriptor stays, but
    // its path can no longer be read.
    try #require(revoke(slave) == 0)
    let skipped = OpenFileSet.Inspection.listed(paths: [], truncated: false)
    #expect(inspection(of: pid, becoming: skipped) == skipped)
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
                print("own process \(pid) \(processName(pid)): errno \(code) (\(String(cString: strerror(code))))")
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
