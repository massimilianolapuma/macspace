# MacSpace — Plan 2: Treemap, view switcher, coloring modes, polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the curated squarified Treemap view with a remembered Raggiera/Treemap switcher, three coloring modes (neutral, by file type, by last use) with a legend, the scanner data they need (file category, timestamps), and the performance/accessibility/hardening items deferred from plan 1.

**Architecture:** The scanner now reads modification/access times and classifies every entry into a `FileCategory` (extension + inherited folder context). `FileTree` stores per-node category/last-use and per-directory category byte totals and most-recent use, aggregated O(depth) on insert like sizes. A pure `TreemapLayout` mirrors `SunburstLayout`; `ScanStore.snapshot` returns the layout for the active view. The app adds `TreemapView`, a view switcher and a color mode stored with `@AppStorage`, palettes validated in core.

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing, XcodeGen, macOS 27. No dependencies.

**Spec:** `docs/superpowers/specs/2026-11-21-macspace-design.md` (§5.1 incl. the plan-2 decisions added 2026-11-21, §5.2, §7). Plan 1 (done, branch `feat/2-foundation`) is the codebase this builds on.

## Global Constraints

- Everything in plan 1's Global Constraints still holds (macOS 27, Swift 6, no deps, not sandboxed, Italian UI via `Localizable.xcstrings`, English code, allocated sizes, hard links once, no symlinks, no `/System/Volumes/Data` double count, never cross mount points, app writes nothing but its settings).
- Branch `feat/3-treemap-colors` (issue #3), created from `feat/2-foundation`. **No Claude attribution lines** in commits (hook rejects them). Never commit `Local.xcconfig`.
- Memory gate stays per spec: benchmark `peakBytesPerFile ≤ 333` (1 GB / 3 M files). Plan 1 measured 89 B/file; this plan may add at most ~40 B/file.
- Scan time must not regress more than 15 % vs plan 1 (51.5 s for 5.72 M files on the owner's disk without FDA).
- Orange (hue 5–30°, saturation > 50 %) is **reserved for "deletable"** (plan 3): no category or age color may use it.
- Every chart color must allow a label at ≥ 4.5:1 via `Contrast.labelInk` (light and dark, including the +12 hover lift).
- Never rely on color alone: tooltip and list state the category / last-use in words.
- GUI verification runs appear on the owner's screen: keep them short, quit the app, never change system appearance globally, never commit debug hooks.

## Review Focus

1. **Classification cost on 5.7 M entries** — a slow classifier (allocating lowercased strings, regexes) would blow the 15 % scan-time budget → Task 3 benchmark gate + Task 2 test `classifierIsAllocationLight` (1 M calls under a time bound).
2. **Context inheritance edge cases** — `node_modules` inside an `.app`, a video inside `~/Library/Caches`, `.photoslibrary` inside `Pictures` → Task 2 tests `appBundleIsSealed`, `contextWinsOverExtension`, `packageContexts`.
3. **Folder with only zero-byte or unreadable content** — dominant category and last-use must not crash or show garbage → Task 3 test `emptyFolderFallsBackToContext`.
4. **Treemap with extreme aspect ratios / tiny window / 10 000 tiny children** — layout stays bounded and never produces NaN or negative rects → Task 4 tests `tinySiblingsMergeIntoOtherTile`, `degenerateRectProducesNoTiles`.
5. **Switching view or color mode mid-scan** — must not restart the scan or lose the current folder/hover → Task 7 verification step + `ScanModel` test hook (center preserved).

---

## File Structure

```
MacSpaceCore/Sources/MacSpaceCore/
  Scan/DirectoryEntry.swift        + modificationTime, accessTime
  Scan/DirectoryReader.swift       + ATTR_CMN_MODTIME/ACCTIME, cancellation between batches
  Model/FileCategory.swift         NEW: FileCategory, AgeBucket
  Model/CategoryClassifier.swift   NEW: extension + context rules
  Model/FileTree.swift             + category/lastUsed storage, per-dir aggregates, largestChildren
  Model/NodeTypes.swift            NodeRow + category, lastUsed
  Scan/ScanStore.swift             classify on insert; snapshot(view:); categoryTotals
  Layout/SunburstLayout.swift      ArcSegment + category, lastUsed
  Layout/TreemapLayout.swift       NEW: TreemapTile, compute, hitTest
  Layout/ChartPalette.swift        NEW: category + age palettes (RGB), validated
  Format/ByteFormat.swift          NEW: moved from App Formatters.bytes (testable)
MacSpaceCore/Tests/MacSpaceCoreTests/
  CategoryClassifierTests.swift  TreemapLayoutTests.swift  ChartPaletteTests.swift  ByteFormatTests.swift
  (+ additions to DirectoryReaderTests, FileTreeTests, ScannerTests, SunburstLayoutTests)
App/MacSpace/
  ChartSettings.swift              NEW: ChartKind/ColorMode @AppStorage keys
  Style/FusionPalette.swift        + fill(for:mode:depth:index:scheme:)
  Views/Sunburst/                  SunburstView.swift split: SunburstView, SunburstHoverLayer,
                                   SunburstPointerLayer, RingLabel+LabelPlanner, SegmentTooltip
  Views/Treemap/TreemapView.swift  NEW (+ TreemapMotion.swift, TreemapHoverLayer.swift)
  Views/ChartLegend.swift          NEW
  Views/ContentView.swift          switcher + color menu + legend
```

---

### Task 1: Timestamps, cancellable reads, reader hardening

**Files:** Modify `Scan/DirectoryEntry.swift`, `Scan/DirectoryReader.swift`; Test `DirectoryReaderTests.swift`

**Interfaces:**
- Produces: `DirectoryEntry.modificationTime: UInt32`, `DirectoryEntry.accessTime: UInt32` (seconds since 1970, clamped to `UInt32` range, 0 = unknown); public init gains both params **with default 0** (existing synthetic-entry tests keep compiling).
- `DirectoryReader.read(path:)` checks `Task.isCancelled` between `getattrlistbulk` batches and returns the entries read so far (no throw) when cancelled.

Request `ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME` (each a `timespec`, 16 bytes, in bit order: MODTIME 0x400 before ACCTIME 0x1000, both after OBJTYPE 0x8 and before FLAGS 0x40000).

- [ ] **Step 1: Failing tests**

```swift
@Test func readsTimestamps() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("t.bin", bytes: 10)
    let past = Date(timeIntervalSince1970: 1_600_000_000)
    try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: f.path)
    let e = try #require(try DirectoryReader.read(path: fx.root.path).first { $0.name == "t.bin" })
    #expect(e.modificationTime == 1_600_000_000)
    #expect(e.accessTime > 0)
}
@Test func statDescribesFileDirAndSymlink() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("f", bytes: 5000); let d = try fx.dir("d"); try fx.symlink("l", to: d)
    #expect(try DirectoryReader.stat(path: f.path).kind == .file)
    #expect(try DirectoryReader.stat(path: d.path).kind == .directory)
    #expect(try DirectoryReader.stat(path: fx.root.appending(path: "l").path).kind == .symlink)
}
@Test func errnoMapping() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("f", bytes: 1)
    #expect(throws: DirectoryReadError.notFound) { try DirectoryReader.read(path: fx.root.path + "/missing") }
    #expect(throws: DirectoryReadError.notADirectory) { try DirectoryReader.read(path: f.path) }
}
@Test func cancelledReadStopsBetweenBatches() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    for i in 0..<20_000 { try fx.file("f\(i)", bytes: 1) }
    let n = await Task { withUnsafeCurrentTask { $0?.cancel() }; return try DirectoryReader.read(path: fx.root.path).count }.value
    #expect(n < 20_000)
}
```

- [ ] **Step 2: Run** `swift test --filter DirectoryReaderTests` → FAIL (members missing).
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run** `swift test` → all pass.
- [ ] **Step 5: Commit** — `feat(core): read file timestamps and stop reads on cancellation`

---

### Task 2: FileCategory and classifier

**Files:** Create `Model/FileCategory.swift`, `Model/CategoryClassifier.swift`; Test `CategoryClassifierTests.swift`

**Interfaces:**
- `public enum FileCategory: UInt8, Sendable, CaseIterable, Hashable { case video, photo, music, document, app, development, archive, system, appData, other }`
- `public enum AgeBucket: Int, Sendable, CaseIterable { case lastMonth, lastSixMonths, lastYear, oneToTwoYears, older, unknown; public init(lastUsed: UInt32, now: UInt32) }` — thresholds in days: ≤ 30, ≤ 182, ≤ 365, ≤ 730, > 730; `lastUsed == 0` → `.unknown`.
- `public struct CategoryClassifier: Sendable { public init(home: String); public func context(forDirectory name: String, path: String, parent: FileCategory?) -> FileCategory?; public func category(forFile name: String, context: FileCategory?) -> FileCategory }`

Rules (exact):
- **Context precedence:** if `parent == .app` → `.app` (bundles are sealed). Else the directory's own rule if any, else `parent`.
- **Directory rules** (name compared case-insensitively; path compared exactly):
  - path has prefix (component-wise) `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin`, `/private/var`, `/private/etc`, `/cores`, `/Library/Apple` → `.system`
  - path prefix `/usr/local`, `/opt/homebrew`, `<home>/Library/Developer` → `.development`
  - path prefix `/Library/Application Support`, `/Library/Caches`, `<home>/Library/{Application Support, Caches, Containers, Group Containers, Saved Application State, HTTPStorages, WebKit, Logs, Preferences, Cookies}` → `.appData`
  - extension `app` → `.app`
  - name ∈ {`node_modules`, `DerivedData`, `.git`, `.build`, `.swiftpm`, `Pods`, `Carthage`, `.gradle`, `.venv`, `venv`, `__pycache__`, `.tox`, `.next`, `.nuxt`, `.terraform`, `.cargo`, `.rustup`, `.npm`, `.pnpm-store`, `.yarn`} → `.development`
  - extension `photoslibrary` → `.photo`; `fcpbundle`, `imovielibrary` → `.video`; `logicx`, `band` → `.music`; `sparsebundle` → `.archive`
- **File rule:** `context` if non-nil, else by lowercased extension:
  - video: mov mp4 m4v avi mkv webm mpg mpeg wmv flv 3gp mts m2ts braw r3d
  - photo: jpg jpeg png heic heif gif tif tiff bmp webp cr2 cr3 nef arw dng orf rw2 raf psd ai svg
  - music: mp3 m4a aac wav aif aiff flac alac ogg opus mid midi caf
  - document: pdf doc docx pages key numbers xls xlsx ppt pptx txt rtf md csv odt ods odp epub
  - archive: zip rar 7z tar gz tgz bz2 xz zst dmg pkg xip iso sparseimage
  - development: swift py js mjs ts tsx jsx c h m mm cpp hpp java kt go rs rb php o a dylib
  - anything else → `.other`
- Performance: extension extraction and case-folding must not allocate per call for ASCII names (compare UTF-8 bytes against precomputed tables).

- [ ] **Step 1: Failing tests**

```swift
let c = CategoryClassifier(home: "/Users/me")
@Test func extensionsMap() {
    #expect(c.category(forFile: "Intervista.MOV", context: nil) == .video)
    #expect(c.category(forFile: "x.heic", context: nil) == .photo)
    #expect(c.category(forFile: "Xcode_27.xip", context: nil) == .archive)
    #expect(c.category(forFile: "README", context: nil) == .other)
    #expect(c.category(forFile: ".zshrc", context: nil) == .other)
}
@Test func contextWinsOverExtension() {
    let caches = c.context(forDirectory: "Caches", path: "/Users/me/Library/Caches", parent: nil)
    #expect(caches == .appData)
    #expect(c.category(forFile: "clip.mp4", context: caches) == .appData)
}
@Test func appBundleIsSealed() {
    let app = c.context(forDirectory: "Xcode.app", path: "/Applications/Xcode.app", parent: nil)
    #expect(app == .app)
    #expect(c.context(forDirectory: "node_modules", path: "/Applications/Xcode.app/x/node_modules", parent: app) == .app)
}
@Test func developmentAndSystem() {
    #expect(c.context(forDirectory: "node_modules", path: "/Users/me/p/node_modules", parent: nil) == .development)
    #expect(c.context(forDirectory: "Developer", path: "/Users/me/Library/Developer", parent: nil) == .development)
    #expect(c.context(forDirectory: "System", path: "/System", parent: nil) == .system)
    #expect(c.context(forDirectory: "local", path: "/usr/local", parent: .system) == .development)
    #expect(c.context(forDirectory: "Documents", path: "/Users/me/Documents", parent: nil) == nil)
}
@Test func packageContexts() {
    #expect(c.context(forDirectory: "Foto.photoslibrary", path: "/Users/me/Pictures/Foto.photoslibrary", parent: nil) == .photo)
    #expect(c.context(forDirectory: "Lib.fcpbundle", path: "/Users/me/Movies/Lib.fcpbundle", parent: nil) == .video)
}
@Test func ageBuckets() {
    let now: UInt32 = 1_800_000_000, day: UInt32 = 86_400
    #expect(AgeBucket(lastUsed: now - 10 * day, now: now) == .lastMonth)
    #expect(AgeBucket(lastUsed: now - 200 * day, now: now) == .lastYear)
    #expect(AgeBucket(lastUsed: now - 800 * day, now: now) == .older)
    #expect(AgeBucket(lastUsed: 0, now: now) == .unknown)
}
@Test func classifierIsAllocationLight() {
    let start = ContinuousClock.now
    var n = 0
    for i in 0..<1_000_000 { if c.category(forFile: i & 1 == 0 ? "photo_0001.JPG" : "notes.txt", context: nil) == .photo { n += 1 } }
    #expect(n == 500_000)
    #expect(ContinuousClock.now - start < .seconds(2))   // debug-build bound; the release benchmark (Task 3) is the real gate
}
```

- [ ] **Step 2: Run** `swift test --filter CategoryClassifierTests` → FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run** `swift test` → pass.
- [ ] **Step 5: Commit** — `feat(core): classify files by type with folder context`

---

### Task 3: Category and last-use in the tree and scan

**Files:** Modify `Model/FileTree.swift`, `Model/NodeTypes.swift`, `Scan/ScanStore.swift`, `Scan/Scanner.swift` (pass classifier), `Layout/SunburstLayout.swift`; Tests `FileTreeTests.swift`, `ScannerTests.swift`, `SunburstLayoutTests.swift`, `ScannerBenchmark.swift`

**Interfaces:**
- Consumes: `FileCategory`, `CategoryClassifier`, `DirectoryEntry.modificationTime/accessTime`.
- Produces:
  - `FileTree.addChild(of:name:kind:allocatedSize:flags:category:lastUsed:)` — new params default `.other` / `0`. For directories `category` is the inherited **context** (or `.other` when none); for files it is the file's category. Adds `allocatedSize` to the ancestors' per-category totals and raises ancestors' `lastUsed` to at least `lastUsed`.
  - `FileTree.dominantCategory(_:) -> FileCategory` (file: own; directory: category with the largest byte total, ties → lower rawValue; no bytes → its context, else `.other`)
  - `FileTree.lastUsed(_:) -> UInt32` (file: own; directory: max over descendants, 0 if none)
  - `FileTree.categoryTotals(_:) -> [FileCategory: UInt64]` (non-zero entries only)
  - `FileTree.largestChildren(of:limit:) -> [NodeID]` (same order as `children(of:)`, partial selection, no full sort when `limit < count`)
  - `NodeRow` gains `category: FileCategory`, `lastUsed: UInt32` (init params default `.other`, `0`); `ArcSegment` gains the same (merged "altri": `.other`, max of merged `lastUsed`).
  - `ScanStore.init(rootName:rootPath:home: String = NSHomeDirectory())` builds a `CategoryClassifier`; `insert` computes each entry's context/category from the parent's stored context and `lastUsed = max(modificationTime, accessTime)`; hard-link duplicates add 0 bytes but still raise `lastUsed`.
  - `ScanStore.rows(childrenOf:limit:)` uses `largestChildren`.
  - `ScanStore.categoryTotals(of: NodeID) -> [FileCategory: UInt64]`.

Storage: per node `categories: ContiguousArray<UInt8>`, `lastUsed: ContiguousArray<UInt32>`, `dirSlot: ContiguousArray<Int32>` (−1 for files); per directory `categoryBytes: ContiguousArray<UInt64>` of `FileCategory.allCases.count` entries per slot. Budget: ≤ 40 B/file added (Global Constraints).

- [ ] **Step 1: Failing tests**

```swift
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
@Test func scanClassifiesWithContext() async throws {     // ScannerTests
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("node_modules/x/big.js", bytes: 200_000); try fx.file("film.mov", bytes: 100_000)
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path, home: "/nonexistent")
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    let totals = await store.categoryTotals(of: FileTree.root)
    #expect(totals[.development, default: 0] >= 200_000 && totals[.video, default: 0] >= 100_000)
    let rows = await store.rows(childrenOf: FileTree.root, limit: 10)
    #expect(rows.first { $0.name == "node_modules" }?.category == .development)
    #expect(rows.allSatisfy { $0.lastUsed > 0 })
}
```

Plus in `SunburstLayoutTests`: a segment's `category` equals `tree.dominantCategory(node)`.

- [ ] **Step 2: Run** `swift test` → FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run** `swift test` → pass; then `MACSPACE_BENCH=1 swift test -c release --filter startupDiskScan` → PASS with `peakBytesPerFile ≤ 333`; record duration and B/file vs plan 1 (51.45 s, 89 B/file) — duration must be ≤ 59.2 s.
- [ ] **Step 5: Commit** — `feat(core): track file category and last use per node`

---

### Task 4: Treemap layout

**Files:** Create `Layout/TreemapLayout.swift`; Modify `Scan/ScanStore.swift`; Test `TreemapLayoutTests.swift`

**Interfaces:**
- `public struct TreemapTile: Sendable, Hashable, Identifiable { public var id: String /* "\(node)" or "other-\(parent)-\(depth)" */; node: NodeID?; parent: NodeID; depth: Int /* 1 = children of center */; x, y, width, height: Double; size: UInt64; name: String; otherCount: Int; flags: NodeFlags; hasChildren: Bool; category: FileCategory; lastUsed: UInt32; hasHeader: Bool }`
- `public enum TreemapLayout { public struct Style: Sendable { gap = 3.0, header = 18.0, headerMinWidth = 120.0, headerMinHeight = 60.0, minTileArea = 36.0 }; public static func compute(tree: FileTree, center: NodeID, width: Double, height: Double, depth: Int = 3, style: Style = .init()) -> [TreemapTile]; public static func hitTest(_ tiles: [TreemapTile], x: Double, y: Double) -> TreemapTile? /* deepest containing tile */ }`
- `public enum ChartRequest: Sendable { case sunburst(depth: Int); case treemap(width: Double, height: Double, depth: Int) }`; `ScanStore.Snapshot` gains `tiles: [TreemapTile]` and `categoryTotals: [FileCategory: UInt64]`; `ScanStore.snapshot(center:chart:biggestLimit:)` fills `segments` **or** `tiles` per request (the old `snapshot(center:depth:biggestLimit:)` is removed; update the app call site in Task 7).

Algorithm: squarified treemap (Bruls, Huizing, van Wijk 2000) on children sorted by size desc; children of a tile are laid out inside the tile's rect inset by `gap/2`, minus a `header` band at the top when the tile is at least `headerMinWidth × headerMinHeight` (then `hasHeader = true`). Children whose tile area would be `< minTileArea` merge into one trailing "altri" tile (only when ≥ 2 non-empty, same rule as the sunburst); "altri" and files are never subdivided. Recurse up to `depth`. Zero/negative/NaN-free: skip rects with width or height < 1.

- [ ] **Step 1: Failing tests**

```swift
func flat(_ sizes: [UInt64]) -> FileTree {
    let t = FileTree(rootName: "r", rootPath: "/r")
    for (i, s) in sizes.enumerated() { t.addChild(of: 0, name: "f\(i)", kind: .file, allocatedSize: s) }
    return t
}
@Test func areasAreProportionalAndInside() {
    let tiles = TreemapLayout.compute(tree: flat([600, 300, 100]), center: 0, width: 400, height: 300)
    #expect(tiles.count == 3)
    let total = tiles.reduce(0) { $0 + $1.width * $1.height }
    #expect(abs(tiles[0].width * tiles[0].height / total - 0.6) < 0.05)
    #expect(tiles.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x + $0.width <= 400.001 && $0.y + $0.height <= 300.001 })
}
@Test func squarifiedKeepsAspectReasonable() {
    let tiles = TreemapLayout.compute(tree: flat(Array(repeating: 10, count: 16)), center: 0, width: 400, height: 400)
    #expect(tiles.allSatisfy { max($0.width / $0.height, $0.height / $0.width) < 2.5 })
}
@Test func nestedChildrenSitInsideParentBelowHeader() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    for i in 0..<4 { t.addChild(of: d, name: "c\(i)", kind: .file, allocatedSize: 100) }
    let tiles = TreemapLayout.compute(tree: t, center: 0, width: 600, height: 400)
    let p = tiles.first { $0.node == d }!, kids = tiles.filter { $0.depth == 2 }
    #expect(p.hasHeader && kids.count == 4)
    #expect(kids.allSatisfy { $0.y >= p.y + 18 && $0.x >= p.x && $0.x + $0.width <= p.x + p.width + 0.001 })
}
@Test func tinySiblingsMergeIntoOtherTile() {
    let tiles = TreemapLayout.compute(tree: flat([1_000_000_000] + Array(repeating: 1, count: 10_000)), center: 0, width: 800, height: 600)
    #expect(tiles.count == 2 && tiles[1].node == nil && tiles[1].otherCount == 10_000)
}
@Test func degenerateRectProducesNoTiles() {
    #expect(TreemapLayout.compute(tree: flat([5, 5]), center: 0, width: 0, height: 300).isEmpty)
    #expect(TreemapLayout.compute(tree: flat([]), center: 0, width: 300, height: 300).isEmpty)
}
@Test func hitTestReturnsDeepest() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "c", kind: .file, allocatedSize: 100)
    let tiles = TreemapLayout.compute(tree: t, center: 0, width: 600, height: 400)
    let c = tiles.first { $0.depth == 2 }!
    #expect(TreemapLayout.hitTest(tiles, x: c.x + c.width / 2, y: c.y + c.height / 2)?.name == "c")
    #expect(TreemapLayout.hitTest(tiles, x: -5, y: -5) == nil)
}
```

- [ ] **Step 2: Run** `swift test --filter TreemapLayoutTests` → FAIL.
- [ ] **Step 3: Implement** layout + `ChartRequest` snapshot (update existing snapshot test to the new signature).
- [ ] **Step 4: Run** `swift test` → pass (app build will fail until Task 7 updates `ScanModel`; fix the one call site now with `.sunburst(depth: Self.ringDepth)` so the app keeps building).
- [ ] **Step 5: Commit** — `feat(core): add squarified treemap layout and per-chart snapshots`

---

### Task 5: Palettes, color modes, legend, tooltip/list wording

**Files:** Create `Layout/ChartPalette.swift`, `Format/ByteFormat.swift`, `App/MacSpace/ChartSettings.swift`, `App/MacSpace/Views/ChartLegend.swift`; Modify `Style/FusionPalette.swift`, `Style/Formatters.swift` (delegate bytes to `ByteFormat`), `Views/ContentView.swift`, sunburst tooltip, `BiggestListView.swift`, `Localizable.xcstrings`; Tests `ChartPaletteTests.swift`, `ByteFormatTests.swift`

**Interfaces:**
- Core: `public enum ChartPalette { public enum Scheme: Sendable { case light, dark }; public static func category(_ c: FileCategory, scheme: Scheme) -> Contrast.RGB; public static func age(_ b: AgeBucket, scheme: Scheme) -> Contrast.RGB }`
- Core: `public enum ByteFormat { public static func string(_ bytes: UInt64, locale: Locale = Locale(identifier: "it_IT")) -> String }` — same output as plan 1's `Formatters.bytes` (two decimals ≥ 1 GB, one decimal MB, numeric zero "0 byte").
- App: `enum ChartKind: String { case sunburst, treemap }`, `enum ColorMode: String { case neutral, category, lastUse }`, keys `@AppStorage("chartKind")` default `.sunburst`, `@AppStorage("colorMode")` default `.neutral`.
- App: `FusionPalette.fill(category: FileCategory, lastUsed: UInt32, mode: ColorMode, depth: Int, index: Int, scheme: ColorScheme, now: UInt32) -> (Color, labelLightness)` used by both charts. Neutral mode = plan-1 ring colors unchanged. Category/age modes: base color per category/bucket; deeper rings/tiles lighten by +6 L per depth (keeping AA labels via `Contrast.labelInk`).

Colors: design with the `dataviz` skill (categorical: 10 hues distinguishable in light and dark, muted to fit the Fusion sand/graphite look; age: sequential ramp from neutral (recent) to a saturated **non-orange** hue (old), e.g. slate→indigo or neutral→deep teal). Test constraints are binding; exact values are the designer's call.

Copy (Italian, exact): menu title "Colori"; options "Neutri", "Per tipo di file", "Per ultimo uso"; category labels "Video", "Foto e immagini", "Musica e audio", "Documenti", "App", "Sviluppo", "Archivi e installer", "Sistema", "Dati delle app e cache", "Altro"; age labels "Ultimo mese", "Ultimi 6 mesi", "Ultimo anno", "1–2 anni fa", "Oltre 2 anni", "Sconosciuto"; tooltip lines "Tipo: %@" and "Ultimo uso (stimato): %@" (date formatted `.abbreviated` date style, it_IT; "Sconosciuto" when 0). Legend: in category mode one chip per category present in the current folder with its size (from `Snapshot.categoryTotals`, sorted desc); in last-use mode the six buckets; hidden in neutral mode.

- [ ] **Step 1: Failing tests**

```swift
@Test func paletteAvoidsReservedOrange() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for c in FileCategory.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.category(c, scheme: s))) }
        for b in AgeBucket.allCases { #expect(!Contrast.isReservedOrange(ChartPalette.age(b, scheme: s))) }
    }
}
@Test func everyFillTakesAnAALabel() {
    for s in [ChartPalette.Scheme.light, .dark] {
        for c in FileCategory.allCases { #expect(Contrast.bestLabelRatio(on: ChartPalette.category(c, scheme: s)) >= 4.5) }
    }
}
@Test func categoriesAreDistinguishable() {
    for s in [ChartPalette.Scheme.light, .dark] {
        let cs = FileCategory.allCases.map { ChartPalette.category($0, scheme: s) }
        for i in cs.indices { for j in cs.indices where i < j { #expect(Contrast.deltaE(cs[i], cs[j]) > 12) } }
    }
}
@Test func ageRampIsMonotonicInLightness() {
    let known = AgeBucket.allCases.filter { $0 != .unknown }
    let light = known.map { Contrast.lightness(ChartPalette.age($0, scheme: .light)) }
    let dark = known.map { Contrast.lightness(ChartPalette.age($0, scheme: .dark)) }
    #expect(zip(light, light.dropFirst()).allSatisfy { $0 > $1 })   // older = darker in light mode
    #expect(zip(dark, dark.dropFirst()).allSatisfy { $0 < $1 })     // older = brighter in dark mode
}
@Test func byteFormatMatchesPlanOne() {
    #expect(ByteFormat.string(0) == "0 byte")
    #expect(ByteFormat.string(142_870_000_000).hasPrefix("142,87"))
    #expect(ByteFormat.string(850_500_000).hasPrefix("850,5"))
}
```

(`Contrast.isReservedOrange` = hue in 5…30° and saturation > 0.5 in HSL; `Contrast.bestLabelRatio` = max contrast against white / ink / black; `Contrast.deltaE` = CIE76 on Lab; `Contrast.lightness` = HSL lightness 0…100 — add these helpers.)

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** core palettes/helpers/ByteFormat, then the app mode setting, legend, tooltip/list lines (list row shows a small category dot + label in category mode, relative age in last-use mode).
- [ ] **Step 4: Run** `swift test` + app build → pass; screenshots of sunburst in all three modes, light and dark.
- [ ] **Step 5: Commit** — `feat: color charts by file type or last use, with legend`

---

### Task 6: Split the sunburst view and calm the hover layer

**Files:** Move `Views/SunburstView.swift` (743 lines) into `Views/Sunburst/`: `SunburstView.swift`, `SunburstHoverLayer.swift`, `SunburstPointerLayer.swift`, `RingLabel.swift` (RingLabel, LabelPlanner, LabelPlan, FittedText, LabelBox), `SegmentTooltip.swift`, `ChartGeometry.swift`; Move `SunburstMotion.swift` into the same folder.

**Interfaces:** none change; this is a no-behavior refactor plus one performance change.

- [ ] **Step 1:** Move code verbatim into the files above (one type family per file, `private` → `fileprivate`/internal only where needed). Build → exit 0, no warnings; app behaves identically (screenshot of done state light+dark matches plan-1 `t8-f-done-*`).
- [ ] **Step 2 (plan-1 Ruling M follow-up):** `SunburstHoverLayer` renders only while something is hovered or the pointer is over the center (otherwise it contributes an empty view), and it no longer sits inside the animation `TimelineView`. Verify with the existing `Perf` signposts that hover-layer draws during an un-hovered scan drop to 0.
- [ ] **Step 3: Commit** — `refactor(app): split sunburst view; draw hover layer only when hovering`

---

### Task 7: Treemap view and view switcher

**Files:** Create `Views/Treemap/TreemapView.swift`, `Views/Treemap/TreemapMotion.swift`, `Views/Treemap/TreemapHoverLayer.swift`; Modify `ScanModel.swift`, `Views/ContentView.swift`, `Localizable.xcstrings`

**Interfaces:**
- Consumes: `TreemapLayout`, `TreemapTile`, `ChartRequest`, `ScanStore.snapshot(center:chart:biggestLimit:)`, `ChartKind`, `ColorMode`, `FusionPalette.fill`.
- `ScanModel` gains `var chart: ChartKind` (bound to `@AppStorage`), `var chartSize: CGSize` (set by the active chart view, debounced 100 ms), `var tiles: [TreemapTile]`, `var categoryTotals: [FileCategory: UInt64]`, `var hoveredTile: TreemapTile?`; `refreshViews()` requests `.sunburst(depth: 3)` or `.treemap(width:height:depth: 3)` per `chart`. Switching chart or color mode never restarts the scan and keeps `center` (and the hovered node if it exists in the new layout).

Behavior (spec §5.1, mockup B1 "curated"): rounded corners 6 pt (4 pt for depth ≥ 2), 3 pt gaps, discreet uppercase section header (11 pt semibold, secondary text, with size right-aligned) in tiles with `hasHeader`; leaf labels (name + size, two lines, AA ink via `Contrast.labelInk`) only when the tile is ≥ 56 × 30 pt; hover lightens the tile (+12 L) and shows the shared tooltip; click a tile with children → `drill(into:)`; click header → drill into that parent; ⌘↑ / breadcrumb → up. Zoom animation: tiles interpolate rects from the clicked tile's rect to full size (0.35 s spring); scan refreshes are drawn directly (no animation) like the sunburst; Reduce Motion → no animation. Hit-test against drawn rects. Hover layer drawn only while hovering (same rule as Task 6).

Toolbar: segmented control "Raggiera" | "Treemap" (SF Symbols `chart.pie` / `square.grid.2x2`) placed before the status pill; "Colori" menu next to it (`paintpalette`). Both enabled while scanning.

- [ ] **Step 1: Implement**; build → exit 0, no warnings.
- [ ] **Step 2: Verify by running** (temporary hook allowed, never committed): scan a fixture folder and ~/Library; treemap done/hover/drill 2 levels/up/altri/long names in light+dark; switch chart and color mode **during** a scan (scan continues, center kept); min window width. Screenshots `p2-t7-*` in the scratchpad.
- [ ] **Step 3: Design pass** — `impeccable` critique + `ui-ux-pro-max` (`--stack swiftui`) + `dataviz` check on the screenshots (both charts, all three color modes); fix material issues; list findings and actions in the report.
- [ ] **Step 4: Commit** — `feat(app): add treemap view and remembered view switcher`

---

### Task 8: Accessibility, localization and test hardening

**Files:** Modify sunburst/treemap views, `ContentView.swift`, `project.yml`, `Localizable.xcstrings`, `FileTreeTests.swift`, `SunburstLayoutTests.swift`, `ScannerTests.swift`, `Tests/.../Support/Fixture.swift`

- [ ] **Step 1: Accessibility** — chart containers expose a meaningful label in every state (idle: "Scegli cosa analizzare e premi Analizza"; otherwise "<cartella>, <totale>"); add accessibility actions "Torna su" (goUp) and "Apri" on focused segment/tile; each segment/tile reachable as an accessibility child with "name, size, tipo, ultimo uso" (cap at the 50 largest to keep VoiceOver usable). Verify with Accessibility Inspector (`accessibility audit` via `xcrun` if available) and report.
- [ ] **Step 2: Localization** — `SWIFT_EMIT_LOC_STRINGS: YES` in `project.yml`; regenerate; confirm `Localizable.xcstrings` has no stale or missing keys (build log shows none extracted as new without translation).
- [ ] **Step 3: Tests** — replace force-unwraps in tests with `try #require`; add FileTree tests: 5-level aggregation chain, `insertFlags`, `hasChildren == true`, `path(of:)` with `"/r"` and `"/r/"` roots, 100 k-node bulk insert under 1 s (debug); Fixture `cleanup()` asserts (in DEBUG) that the root is gone.
- [ ] **Step 4: Run** `swift test` → all pass; app build → no warnings.
- [ ] **Step 5: Commit** — `chore: accessibility actions, string extraction, test hardening`

---

### Task 9: Real-window performance check and final verification

**Files:** Modify `ScannerBenchmark.swift` only if numbers need re-baselining.

- [ ] **Step 1: Benchmark** — `MACSPACE_BENCH=1 swift test -c release --filter startupDiskScan`: record duration (≤ 59.2 s), files/s, peak, B/file (≤ 333) vs plan 1.
- [ ] **Step 2: Plan-1 Ruling M** — with the app window **visible and frontmost** (bring it forward with `osascript -e 'tell application "MacSpace" to activate'`), run a whole-disk scan with the signposts and a 20 ms main-thread heartbeat over the whole scan, in both charts. Report max gap after warm-up (target < 100 ms) and whether the ~24 s Core Animation stall reproduces when visible. If it does, capture `xctrace record --template 'Time Profiler'` (or `sample`) around it and report the top stacks.
- [ ] **Step 3: Owner check** — do NOT mark done until the controller has asked the owner to hover and click both charts during a whole-disk scan with a real pointer and confirm smoothness (controller handles this message; implementer reports readiness).
- [ ] **Step 4: Commit** any re-baselined numbers — `test(core): re-baseline benchmark for plan 2`
