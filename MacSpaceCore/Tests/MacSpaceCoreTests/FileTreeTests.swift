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

@Test func categoryTotalsAndDominant() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "a.mov", kind: .file, allocatedSize: 300, category: .video, lastUsed: 10)
    t.addChild(of: d, name: "b.pdf", kind: .file, allocatedSize: 100, category: .document, lastUsed: 50)
    #expect(t.categoryTotals(0) == [.video: 300, .document: 100])
    #expect(t.dominantCategory(d) == .video)
    #expect(t.lastUsed(0) == 50)
}

@Test func emptyFolderFallsBackToContext() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let nm = t.addChild(of: 0, name: "node_modules", kind: .directory, allocatedSize: 0, category: .development)
    let e = t.addChild(of: 0, name: "empty", kind: .directory, allocatedSize: 0)
    #expect(t.dominantCategory(nm) == .development)
    #expect(t.dominantCategory(e) == .other && t.lastUsed(e) == 0)
}

@Test func largestChildrenMatchesSortedPrefix() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    for i in 0..<1000 { t.addChild(of: 0, name: "f\(i)", kind: .file, allocatedSize: UInt64((i * 7919) % 1000)) }
    #expect(t.largestChildren(of: 0, limit: 20) == Array(t.children(of: 0).prefix(20)))
}

@Test func largestChildrenEdgeLimitsAndNameTies() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    for name in ["f", "e\u{301}", "Z", "a", "zz", "z", "ü", "日本", "Ω"] {
        t.addChild(of: 0, name: name, kind: .file, allocatedSize: 7)
    }
    t.addChild(of: 0, name: "big", kind: .file, allocatedSize: 9)
    let all = t.children(of: 0)
    for limit in [0, 1, 3, 9, 10, 50] {
        #expect(t.largestChildren(of: 0, limit: limit) == Array(all.prefix(limit)), "limit \(limit)")
    }
    #expect(t.largestChildren(of: all[0], limit: 5).isEmpty)
}

@Test func dominantCategoryTieGoesToLowerRawValueAndFileIsItsOwn() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let f = t.addChild(of: 0, name: "b.pdf", kind: .file, allocatedSize: 100, category: .document, lastUsed: 7)
    t.addChild(of: 0, name: "a.mov", kind: .file, allocatedSize: 100, category: .video)
    #expect(t.dominantCategory(0) == .video)
    #expect(t.dominantCategory(f) == .document && t.lastUsed(f) == 7)
    #expect(t.categoryTotals(f) == [.document: 100])
    #expect(t.row(f).category == .document && t.row(f).lastUsed == 7)
}

@Test func contextBytesCountTowardsTheirOwnCategoryUpTheTree() {
    // A file's category is what it was given (the scan passes the inherited context), and an
    // empty context folder only wins while its parent has no bytes of its own.
    let t = FileTree(rootName: "r", rootPath: "/r")
    let nm = t.addChild(of: 0, name: "node_modules", kind: .directory, allocatedSize: 0, category: .development)
    t.addChild(of: nm, name: "big.mov", kind: .file, allocatedSize: 500, category: .development, lastUsed: 3)
    t.addChild(of: 0, name: "x.pdf", kind: .file, allocatedSize: 100, category: .document, lastUsed: 9)
    #expect(t.categoryTotals(0) == [.development: 500, .document: 100])
    #expect(t.dominantCategory(0) == .development)
    #expect(t.lastUsed(nm) == 3 && t.lastUsed(0) == 9)
    #expect(t.categoryTotals(0).values.reduce(0, +) == t.size(0))
}
