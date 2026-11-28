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

@Test func sortLikeChildrenMatchesChildrenOrder() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    for i in 0..<200 { t.addChild(of: 0, name: "f\(i % 37)", kind: .file, allocatedSize: UInt64(i % 50)) }
    var picked = t.children(of: 0).filter { $0 % 3 == 0 }.shuffled()
    t.sortLikeChildren(&picked)
    #expect(picked == t.children(of: 0).filter { $0 % 3 == 0 })
    var all = (1...200).map { NodeID($0) }
    t.sortLikeChildren(&all)
    #expect(all == t.children(of: 0))
}

@Test func sizeAndLastUseAggregateThroughAFiveLevelChain() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    var chain = [FileTree.root]
    for level in 1...5 {
        chain.append(t.addChild(of: chain[level - 1], name: "d\(level)", kind: .directory, allocatedSize: 0))
    }
    t.addChild(of: chain[5], name: "leaf", kind: .file, allocatedSize: 4096, category: .video, lastUsed: 77)
    for node in chain {
        #expect(t.size(node) == 4096, "node \(node)")
        #expect(t.lastUsed(node) == 77, "node \(node)")
        #expect(t.categoryTotals(node)[.video] == 4096, "node \(node)")
    }
    #expect(t.path(of: chain[5]) == "/r/d1/d2/d3/d4/d5")
}

@Test func insertFlagsUnionsWithExistingFlags() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0, flags: .unreadable)
    #expect(t.flags(d) == .unreadable)
    t.insertFlags(.unreadable, for: d)              // idempotent
    #expect(t.flags(d) == .unreadable)
    let f = t.addChild(of: 0, name: "f", kind: .file, allocatedSize: 1)
    #expect(t.flags(f).isEmpty)
    t.insertFlags(.unreadable, for: f)
    #expect(t.flags(f) == .unreadable)
}

@Test func hasChildrenIsTrueOnlyOnceAChildExists() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    #expect(t.row(d).hasChildren == false)
    t.addChild(of: d, name: "f", kind: .file, allocatedSize: 1)
    #expect(t.row(d).hasChildren == true)
    #expect(t.row(0).hasChildren == true)
}

@Test func pathOfIgnoresATrailingSlashOnTheRoot() {
    for rootPath in ["/r", "/r/"] {
        let t = FileTree(rootName: "r", rootPath: rootPath)
        let a = t.addChild(of: 0, name: "a", kind: .directory, allocatedSize: 0)
        let b = t.addChild(of: a, name: "b", kind: .file, allocatedSize: 1)
        #expect(t.path(of: a) == "/r/a", "root \(rootPath)")
        #expect(t.path(of: b) == "/r/a/b", "root \(rootPath)")
    }
}

@Test func hundredThousandNodesInsertUnderOneSecond() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let clock = ContinuousClock()
    let elapsed = clock.measure {
        var dir = FileTree.root
        for i in 0..<100_000 {
            if i % 1000 == 0 { dir = t.addChild(of: 0, name: "d\(i)", kind: .directory, allocatedSize: 0) }
            t.addChild(of: dir, name: "f\(i)", kind: .file, allocatedSize: 10)
        }
    }
    #expect(t.count == 100_000 + 100 + 1)
    #expect(t.size(FileTree.root) == 1_000_000)
    #expect(elapsed < .seconds(1), "took \(elapsed)")
}
@Test func nodeAtPath() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let a = t.addChild(of: 0, name: "a", kind: .directory, allocatedSize: 0)
    let b = t.addChild(of: a, name: "b é", kind: .file, allocatedSize: 1)
    #expect(t.node(atPath: "/r/a/b é") == b && t.node(atPath: "/r") == 0)
    #expect(t.node(atPath: "/r/a/zz") == nil && t.node(atPath: "/other/a") == nil)
    // A trailing slash names the same folder; a sibling sharing the root's prefix is outside it.
    #expect(t.node(atPath: "/r/a/") == a && t.node(atPath: "/r/") == 0 && t.node(atPath: "/ra") == nil)
    // Exact bytes: decomposed "é" and other case are different names; "//" and "." match nothing.
    #expect(t.node(atPath: "/r/a/b e\u{301}") == nil && t.node(atPath: "/r/A") == nil)
    #expect(t.node(atPath: "/r//a") == nil && t.node(atPath: "/r/./a") == nil)
    let s = FileTree(rootName: "/", rootPath: "/")
    let u = s.addChild(of: 0, name: "Users", kind: .directory, allocatedSize: 0)
    #expect(s.node(atPath: "/Users") == u && s.node(atPath: "/") == 0)
}

@Test func removeKeepsAggregatesConsistent() throws {
    let now: UInt32 = 2_000_000_000
    let day: UInt32 = 86_400
    /// root → a → (mid → (deep → f3, f2), f1), g; `withMid: false` leaves `mid` and its subtree out.
    func build(withMid: Bool) -> (tree: FileTree, a: NodeID, mid: NodeID?, deep: NodeID?, f3: NodeID?) {
        let t = FileTree(rootName: "r", rootPath: "/r", now: now)
        let a = t.addChild(of: 0, name: "a", kind: .directory, allocatedSize: 128, category: .app)
        var mid: NodeID?, deep: NodeID?, f3: NodeID?
        if withMid {
            let m = t.addChild(of: a, name: "mid", kind: .directory, allocatedSize: 64, category: .development)
            let d = t.addChild(of: m, name: "deep", kind: .directory, allocatedSize: 32)
            f3 = t.addChild(of: d, name: "f3", kind: .file, allocatedSize: 5000, category: .video,
                            lastUsed: now - 900 * day)
            t.addChild(of: m, name: "f2", kind: .file, allocatedSize: 7000, category: .development,
                       lastUsed: now - 10 * day)
            mid = m; deep = d
        }
        t.addChild(of: a, name: "f1", kind: .file, allocatedSize: 3000, category: .document,
                   lastUsed: now - 100 * day)
        t.addChild(of: 0, name: "g", kind: .file, allocatedSize: 100, category: .music, lastUsed: now - day)
        return (t, a, mid, deep, f3)
    }
    let full = build(withMid: true)
    let expected = build(withMid: false)
    let mid = try #require(full.mid)
    full.tree.remove(mid)

    for (got, want) in [(FileTree.root, FileTree.root), (full.a, expected.a)] {
        #expect(full.tree.size(got) == expected.tree.size(want))
        #expect(full.tree.categoryTotals(got) == expected.tree.categoryTotals(want))
        #expect(full.tree.ageTotals(got) == expected.tree.ageTotals(want))
        #expect(full.tree.dominantCategory(got) == expected.tree.dominantCategory(want))
    }
    #expect(full.tree.size(0) == 128 + 3000 + 100)
    #expect(!full.tree.children(of: full.a).contains(mid))
    #expect(full.tree.children(of: full.a).map(full.tree.name) == ["f1"])
    #expect(full.tree.flags(mid).contains(.removed))
    // The whole subtree is marked, so stale ids below the removed folder are recognised as removed.
    #expect(full.tree.flags(try #require(full.deep)).contains(.removed))
    #expect(full.tree.flags(try #require(full.f3)).contains(.removed))
    #expect(!full.tree.flags(full.a).contains(.removed))
    #expect(full.tree.node(atPath: "/r/a/mid") == nil)
    #expect(full.tree.node(atPath: "/r/a/f1") != nil)
}

@Test func removeUnlinksAnyPositionInTheSiblingList() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let x = t.addChild(of: 0, name: "x", kind: .file, allocatedSize: 1)
    let y = t.addChild(of: 0, name: "y", kind: .file, allocatedSize: 2)
    let z = t.addChild(of: 0, name: "z", kind: .file, allocatedSize: 4)
    t.remove(y)   // middle of the list
    #expect(Set(t.children(of: 0)) == [x, z] && t.size(0) == 5)
    t.remove(z)   // head of the list (newest child)
    #expect(t.children(of: 0) == [x] && t.size(0) == 1)
    t.remove(x)   // last one
    #expect(t.children(of: 0).isEmpty && t.size(0) == 0 && !t.row(0).hasChildren)
    #expect(t.categoryTotals(0).isEmpty && t.ageTotals(0).isEmpty)
}

@Test func inodeRoundTrips() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let a = t.addChild(of: FileTree.root, name: "a", kind: .directory, allocatedSize: 0, inode: 42)
    let b = t.addChild(of: a, name: "b", kind: .file, allocatedSize: 10)
    #expect(t.inode(a) == 42)
    #expect(t.inode(b) == 0)
    #expect(t.inode(FileTree.root) == 0)
    t.setInode(7, for: FileTree.root)
    #expect(t.inode(FileTree.root) == 7)
}

@Test func creditMatchesAddChild() {
    let now: UInt32 = 2_000_000_000
    let used = now - 400 * 86_400
    let credited = FileTree(rootName: "r", rootPath: "/r", now: now)
    let added = FileTree(rootName: "r", rootPath: "/r", now: now)
    for t in [credited, added] {
        let d = t.addChild(of: FileTree.root, name: "d", kind: .directory, allocatedSize: 0)
        t.addChild(of: d, name: "other.txt", kind: .file, allocatedSize: 100, category: .document, lastUsed: now)
    }
    let creditedDir = credited.children(of: FileTree.root)[0]
    let link = credited.addChild(of: creditedDir, name: "f.mov", kind: .file, allocatedSize: 0,
                                 flags: .hardLinkDuplicate, category: .video, lastUsed: used)
    credited.credit(4096, to: link)
    let addedDir = added.children(of: FileTree.root)[0]
    added.addChild(of: addedDir, name: "f.mov", kind: .file, allocatedSize: 4096, category: .video, lastUsed: used)

    #expect(credited.size(link) == 4096)
    #expect(!credited.flags(link).contains(.hardLinkDuplicate))
    #expect(credited.size(FileTree.root) == added.size(FileTree.root))
    #expect(credited.categoryTotals(FileTree.root) == added.categoryTotals(FileTree.root))
    #expect(credited.ageTotals(FileTree.root) == added.ageTotals(FileTree.root))
    #expect(credited.categoryTotals(creditedDir) == added.categoryTotals(addedDir))
    #expect(credited.ageTotals(creditedDir) == added.ageTotals(addedDir))
}
