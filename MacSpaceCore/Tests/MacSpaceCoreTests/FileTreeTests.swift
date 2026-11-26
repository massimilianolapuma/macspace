import Testing
@testable import MacSpaceCore

@Test func sizesAggregateToAncestors() {
    let t = FileTree(rootName: "root", rootPath: "/r")
    let a = t.addChild(of: FileTree.root, name: "a", kind: .directory, allocatedSize: 0)
    t.addChild(of: a, name: "f1", kind: .file, allocatedSize: 4096)
    t.addChild(of: a, name: "f2", kind: .file, allocatedSize: 8192)
    t.addChild(of: FileTree.root, name: "g", kind: .file, allocatedSize: 100)
    #expect(t.size(a) == 12288)
    #expect(t.size(FileTree.root) == 12388)
}

@Test func childrenSortedBySizeThenName() {
    let t = FileTree(rootName: "root", rootPath: "/r")
    let b = t.addChild(of: 0, name: "b", kind: .file, allocatedSize: 10)
    let a = t.addChild(of: 0, name: "a", kind: .file, allocatedSize: 10)
    let c = t.addChild(of: 0, name: "c", kind: .file, allocatedSize: 99)
    #expect(t.children(of: 0) == [c, a, b])
}

@Test func pathJoinsFromRoot() {
    let t = FileTree(rootName: "Macintosh HD", rootPath: "/")
    let u = t.addChild(of: 0, name: "Users", kind: .directory, allocatedSize: 0)
    let m = t.addChild(of: u, name: "me", kind: .directory, allocatedSize: 0)
    #expect(t.path(of: m) == "/Users/me")
    #expect(t.path(of: 0) == "/")
}

@Test func rowReflectsNode() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0, flags: .unreadable)
    #expect(t.row(d) == NodeRow(id: d, name: "d", size: 0, kind: .directory, flags: .unreadable, hasChildren: false))
    #expect(t.parent(0) == nil)
}

@Test func oddNamesRoundTripThroughTheArena() {
    let long = String(repeating: "lungo-", count: 40) + "fine"     // 244 UTF-8 bytes
    let emoji = "📦 Archivio 👩‍👩‍👧‍👦"
    let nfd = "Cafe\u{301}"                                      // decomposed "Café"
    let t = FileTree(rootName: "Disco 🖥", rootPath: "/r")
    let a = t.addChild(of: 0, name: long, kind: .directory, allocatedSize: 0)
    let b = t.addChild(of: a, name: emoji, kind: .directory, allocatedSize: 0)
    let c = t.addChild(of: b, name: nfd, kind: .file, allocatedSize: 1)
    #expect(t.name(0) == "Disco 🖥")
    #expect(t.name(a) == long && t.name(b) == emoji)
    #expect(Array(t.name(c).utf8) == Array(nfd.utf8))    // bytes kept as given, not normalized
    #expect(t.row(c).name.unicodeScalars.elementsEqual(nfd.unicodeScalars))
    #expect(Array(t.path(of: c).utf8) == Array("/r/\(long)/\(emoji)/\(nfd)".utf8))
    #expect(t.nameArenaByteCount == ["Disco 🖥", long, emoji, nfd].reduce(0) { $0 + $1.utf8.count })
}

@Test func equalSizesSortLikeStringComparison() {
    // Ties break by name exactly as `String.<` does, including canonical equivalence:
    // decomposed "é" (bytes "e\u{301}") sorts as "é", after "f".
    let t = FileTree(rootName: "r", rootPath: "/r")
    let names = ["f", "e\u{301}", "Z", "a", "zz", "z", "ü", "日本", "Ω"]
    for name in names { t.addChild(of: 0, name: name, kind: .file, allocatedSize: 7) }
    #expect(t.children(of: 0).map(t.name) == names.sorted())
}
