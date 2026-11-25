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
    #expect(moved == trash.path + "/doc.txt" && FileManager.default.fileExists(atPath: moved))
    #expect(!FileManager.default.fileExists(atPath: item.path))
}
