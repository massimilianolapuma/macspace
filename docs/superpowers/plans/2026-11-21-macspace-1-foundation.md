# MacSpace — Plan 1: Foundation (scan & see) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS app that scans the startup disk (or a chosen folder) fast, and shows it live as an interactive sunburst with drill-down, breadcrumbs and a biggest-items list, in the "Fusion" neutral style.

**Architecture:** A local Swift package `MacSpaceCore` (no UI) holds the `getattrlistbulk` directory reader, a compact `FileTree`, the parallel `Scanner` writing into a `ScanStore` actor, and pure layout math (sunburst). An Xcode app target `MacSpace` (generated with XcodeGen) renders with SwiftUI `Canvas`, polling the store for layouts while the scan runs.

**Tech Stack:** Swift 6.4 (Swift 6 language mode, strict concurrency), SwiftUI, Swift Testing (`import Testing`), XcodeGen 2.46, Xcode 27.2, macOS 27.

**Spec:** `docs/superpowers/specs/2026-11-21-macspace-design.md`

**Roadmap (one plan each, each ships working software):**
1. **Foundation — this plan:** scanner, tree, sunburst, navigation, Full Disk Access onboarding.
2. Treemap view, view switcher, coloring modes (deletable / category / last use), visual polish (`impeccable`, `dataviz`, `ui-ux-pro-max`).
3. Intelligence + deleting: apps index, leftovers, last-used, open files, 4-level safety rules + never-touch list, Suggestions panel, selection, confirmation sheet (space freed via `ATTR_CMNEXT_PRIVATESIZE` for APFS clones), Trash, history, package/bundle detection.
4. Snapshot + FSEvents incremental refresh, cloud locations + "Rimuovi solo la copia locale", duplicates on demand, volume info (purgeable, snapshots).

## Global Constraints

- Deployment target **macOS 27.0**; Swift 6 language mode; no third-party dependencies.
- App **not sandboxed**, Hardened Runtime on, signed with the owner's Personal Team. `DEVELOPMENT_TEAM` lives only in untracked `Local.xcconfig` (never commit it).
- UI language **Italian** via a String Catalog (`Localizable.xcstrings`, development region `it`). Code, identifiers, comments, commits in English.
- Sizes are **allocated size on disk**; hard links counted once; never follow symlinks; never double count `/System/Volumes/Data`.
- Anti-goal: the app writes nothing to disk in this plan except its own settings (`@AppStorage`).
- Respect *Reduce Motion*; never rely on color alone.
- Bundle ID: `com.massilp.macspace`. Product name: `MacSpace`.
- Git: work on a branch named `feat/<issue>-<slug>` created from `origin/main` (open a GitHub issue first, e.g. "Foundation: scan & sunburst"); **no Claude attribution lines** in commits/PRs (a local hook rejects them).
- Byte formatting: `ByteCountFormatter` with `.file` count style, Italian locale (matches Finder).

## Review Focus

1. **Startup disk double counting via firmlinks** — scanning `/` must not count `/System/Volumes/Data` twice; total should be close to the volume's used space → `ScanBoundary` tests (Task 4) + manual check (Task 9).
2. **Hard links** (Time Machine-style trees, Xcode toolchains) counted once → Task 5 test `hardLinkCountedOnce`.
3. **Unreadable folders / no Full Disk Access** — scan must continue and mark the folder, never abort → Task 3 `permissionDeniedThrows`, Task 5 `unreadableDirectoryIsMarkedAndScanContinues`.
4. **Huge flat directories** (100k+ files, e.g. caches) — layout stays bounded and UI responsive → Task 6 `tinySiblingsMergeIntoOther` with 10 000 children.
5. **Odd names** — emoji, decomposed Unicode (NFD), names with newlines, very long paths (`ENAMETOOLONG`) must not crash; long paths are marked unreadable → Task 3 `oddNamesRoundTrip`, Task 5 `pathTooLongIsMarkedUnreadable`.

---

## File Structure

```
project.yml                         XcodeGen spec (app target + local package)
Local.xcconfig.example              template; copy to Local.xcconfig (gitignored)
MacSpaceCore/Package.swift
MacSpaceCore/Sources/MacSpaceCore/
  Model/FileTree.swift              compact tree storage + aggregate sizes
  Model/NodeTypes.swift             NodeID, NodeKind, NodeFlags, NodeRow
  Scan/DirectoryEntry.swift         DirectoryEntry, DirectoryReadError
  Scan/DirectoryReader.swift        getattrlistbulk wrapper
  Scan/ScanBoundary.swift           which directories to descend
  Scan/ScanStore.swift              actor owning FileTree; query API for UI
  Scan/Scanner.swift                parallel traversal, progress, cancellation
  Layout/SunburstLayout.swift       ArcSegment, compute, hitTest
MacSpaceCore/Tests/MacSpaceCoreTests/
  Support/Fixture.swift             temp-dir fixture builder
  FileTreeTests.swift  DirectoryReaderTests.swift  ScanBoundaryTests.swift
  ScannerTests.swift   SunburstLayoutTests.swift   ScannerBenchmark.swift
App/MacSpace/
  MacSpaceApp.swift                 @main, window
  ScanModel.swift                   @Observable state machine for a scan
  FullDiskAccess.swift              detection + System Settings deep link
  Views/ContentView.swift           toolbar, layout of panes, empty/onboarding states
  Views/SunburstView.swift          Canvas renderer, hover, click
  Views/BiggestListView.swift       top items of current folder
  Views/BreadcrumbView.swift
  Style/FusionPalette.swift         neutral sand/graphite tokens
  Resources/Localizable.xcstrings
  MacSpace.entitlements             (empty dict: no sandbox)
```

---

### Task 1: Project scaffold

**Files:**
- Create: `project.yml`, `Local.xcconfig.example`, `MacSpaceCore/Package.swift`, `MacSpaceCore/Sources/MacSpaceCore/Model/NodeTypes.swift` (placeholder `public enum MacSpaceCore { public static let version = "0.1.0" }`), `MacSpaceCore/Tests/MacSpaceCoreTests/SmokeTests.swift`, `App/MacSpace/MacSpaceApp.swift`, `App/MacSpace/Views/ContentView.swift`, `App/MacSpace/MacSpace.entitlements`, `App/MacSpace/Resources/Localizable.xcstrings`
- Modify: `.gitignore` (add `Local.xcconfig`, `*.xcodeproj`, `.build/`, `DerivedData/`)

**Interfaces:**
- Produces: package product `MacSpaceCore` (library); Xcode scheme `MacSpace`.

- [ ] **Step 1: Write the smoke test**

```swift
import Testing
@testable import MacSpaceCore
@Test func packageBuilds() { #expect(MacSpaceCore.version == "0.1.0") }
```

- [ ] **Step 2: Create `MacSpaceCore/Package.swift`** — `swift-tools-version: 6.2`, `platforms: [.macOS("27.0")]`, library `MacSpaceCore`, test target `MacSpaceCoreTests`, `swiftLanguageModes: [.v6]`.

- [ ] **Step 3: Run** `cd MacSpaceCore && swift test` → Expected: `packageBuilds` passes.

- [ ] **Step 4: Create `project.yml`** — one target `MacSpace` (`type: application`, `platform: macOS`, `deploymentTarget: "27.0"`, sources `App/MacSpace`), local package `MacSpaceCore` at `MacSpaceCore`, `configFiles` Debug/Release → `Local.xcconfig`; settings: `PRODUCT_BUNDLE_IDENTIFIER: com.massilp.macspace`, `ENABLE_HARDENED_RUNTIME: YES`, `CODE_SIGN_STYLE: Automatic`, `CODE_SIGN_ENTITLEMENTS: App/MacSpace/MacSpace.entitlements`, `SWIFT_VERSION: 6.0`, `DEVELOPMENT_LANGUAGE: it`, `GENERATE_INFOPLIST_FILE: YES`, `INFOPLIST_KEY_CFBundleDisplayName: MacSpace`, `INFOPLIST_KEY_LSApplicationCategoryType: public.app-category.utilities`. `Local.xcconfig.example` contains `DEVELOPMENT_TEAM = YOURTEAMID`. Create the real `Local.xcconfig` locally with the owner's team ID (read it from the "Apple Development" certificate's OU: `security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject`).

- [ ] **Step 5: Minimal app** — `MacSpaceApp` with one `WindowGroup` showing `ContentView` (`Text("MacSpace")`), default window size 1100×720.

- [ ] **Step 6: Build**

Run: `xcodegen generate && xcodebuild -project MacSpace.xcodeproj -scheme MacSpace -configuration Debug build -quiet`
Expected: `** BUILD SUCCEEDED **` (or no output with `-quiet` and exit 0).

- [ ] **Step 7: Commit** — `git add .gitignore project.yml Local.xcconfig.example MacSpaceCore App && git commit -m "chore: scaffold MacSpace app and core package"`

---

### Task 2: FileTree

**Files:**
- Create: `MacSpaceCore/Sources/MacSpaceCore/Model/FileTree.swift`; replace placeholder content of `Model/NodeTypes.swift` (keep `MacSpaceCore.version`)
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/FileTreeTests.swift`

**Interfaces:**
- Produces:
  - `public typealias NodeID = Int32`
  - `public enum NodeKind: UInt8, Sendable { case file, directory, symlink, other }`
  - `public struct NodeFlags: OptionSet, Sendable { unreadable, dataless, mountPoint, hardLinkDuplicate }` (`rawValue: UInt8`)
  - `public struct NodeRow: Sendable, Hashable, Identifiable { id: NodeID; name: String; size: UInt64; kind: NodeKind; flags: NodeFlags; hasChildren: Bool }`
  - `public final class FileTree` (not Sendable; owned by `ScanStore`):
    - `public static let root: NodeID = 0`
    - `public init(rootName: String, rootPath: String)`
    - `@discardableResult public func addChild(of parent: NodeID, name: String, kind: NodeKind, allocatedSize: UInt64, flags: NodeFlags = []) -> NodeID` — adds the size to `parent` and every ancestor.
    - `public func insertFlags(_ flags: NodeFlags, for id: NodeID)`
    - `public var count: Int`, `name(_:)`, `kind(_:)`, `size(_:) -> UInt64` (aggregate), `flags(_:)`, `parent(_:) -> NodeID?`, `path(of:) -> String`, `children(of:) -> [NodeID]` (sorted by size desc, then name asc), `row(_:) -> NodeRow`

Storage: struct-of-arrays (`ContiguousArray` for parent, firstChild, nextSibling as `Int32` with `-1` = none, size `UInt64`, kind, flags; names `[String]`). Linked children list; sort only on `children(of:)`.

- [ ] **Step 1: Write failing tests**

```swift
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
```

- [ ] **Step 2: Run** `swift test --filter FileTreeTests` → Expected: FAIL (`FileTree` not found).
- [ ] **Step 3: Implement** `NodeTypes.swift` and `FileTree.swift` as specified.
- [ ] **Step 4: Run** `swift test --filter FileTreeTests` → Expected: 4 tests pass.
- [ ] **Step 5: Commit** — `git commit -am "feat(core): add compact FileTree with aggregate sizes"` (add new files first).

---

### Task 3: DirectoryReader (getattrlistbulk)

**Files:**
- Create: `Scan/DirectoryEntry.swift`, `Scan/DirectoryReader.swift`
- Test: `DirectoryReaderTests.swift`, `Support/Fixture.swift`

**Interfaces:**
- Produces:
  - `public struct DirectoryEntry: Sendable, Equatable { name: String; kind: NodeKind; allocatedSize: UInt64; device: Int32; inode: UInt64; linkCount: UInt32; isMountPoint: Bool; isDataless: Bool }`
  - `public enum DirectoryReadError: Error, Equatable { case permissionDenied, notFound, nameTooLong, notADirectory, other(Int32) }`
  - `public enum DirectoryReader { public static func read(path: String) throws(DirectoryReadError) -> [DirectoryEntry]; public static func stat(path: String) throws(DirectoryReadError) -> DirectoryEntry }` (`stat` describes the path itself, used for the scan root)
  - Test support: `struct Fixture { let root: URL; init() throws; func file(_ rel: String, bytes: Int) throws -> URL; func dir(_ rel: String) throws -> URL; func symlink(_ rel: String, to: URL) throws; func hardLink(_ rel: String, to: URL) throws; func cleanup() }` (temp dir under `FileManager.default.temporaryDirectory`, cleanup restores permissions before deleting)

Approach: `open(path, O_RDONLY | O_DIRECTORY)`, loop `getattrlistbulk` with a 256 KB buffer. Request `ATTR_CMN_RETURNED_ATTRS | NAME | DEVID | OBJTYPE | FLAGS | FILEID | ERROR`, `ATTR_DIR_MOUNTSTATUS`, `ATTR_FILE_LINKCOUNT | ATTR_FILE_ALLOCSIZE`. Parse each record in bit order, honoring the returned-attrs bitmap (attributes not returned are absent from the record). Allocated size for directories = 0. `isDataless` = `(flags & SF_DATALESS) != 0`; `isMountPoint` = `mountstatus & DIR_MNTSTATUS_MNTPOINT`. Map errno: `EACCES/EPERM → permissionDenied`, `ENOENT → notFound`, `ENAMETOOLONG → nameTooLong`, `ENOTDIR → notADirectory`. Entries with `ATTR_CMN_ERROR` set are skipped.

- [ ] **Step 1: Write failing tests**

```swift
@Test func readsFilesWithAllocatedSize() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("a.bin", bytes: 10_000)
    try fx.dir("sub")
    let entries = try DirectoryReader.read(path: fx.root.path)
    let a = try #require(entries.first { $0.name == "a.bin" })
    let expected = try f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize!
    #expect(a.kind == .file && a.allocatedSize == UInt64(expected))
    #expect(entries.first { $0.name == "sub" }?.kind == .directory)
}
@Test func symlinkIsNotFollowed() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let big = try fx.file("big.bin", bytes: 1_000_000)
    try fx.symlink("link", to: big)
    let link = try #require(try DirectoryReader.read(path: fx.root.path).first { $0.name == "link" })
    #expect(link.kind == .symlink && link.allocatedSize < 1_000_000)
}
@Test func hardLinksShareInode() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("x", bytes: 5000); try fx.hardLink("y", to: f)
    let e = try DirectoryReader.read(path: fx.root.path)
    let x = e.first { $0.name == "x" }!, y = e.first { $0.name == "y" }!
    #expect(x.inode == y.inode && x.linkCount == 2)
}
@Test func permissionDeniedThrows() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let d = try fx.dir("locked"); chmod(d.path, 0)
    #expect(throws: DirectoryReadError.permissionDenied) { try DirectoryReader.read(path: d.path) }
}
@Test func oddNamesRoundTrip() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let names = ["📦 pacco", "Caf\u{0065}\u{0301}", "line\nbreak", String(repeating: "x", count: 255)]
    for n in names { try fx.file(n, bytes: 1) }
    let got = Set(try DirectoryReader.read(path: fx.root.path).map(\.name))
    for n in names { #expect(got.contains { $0.precomposedStringWithCanonicalMapping == n.precomposedStringWithCanonicalMapping }) }
}
@Test func manyEntriesBeyondOneBuffer() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    for i in 0..<5000 { try fx.file("f\(i)", bytes: 1) }
    #expect(try DirectoryReader.read(path: fx.root.path).count == 5000)
}
```

- [ ] **Step 2: Run** `swift test --filter DirectoryReaderTests` → Expected: FAIL (types missing).
- [ ] **Step 3: Implement** `Fixture`, `DirectoryEntry`, `DirectoryReader` as specified.
- [ ] **Step 4: Run** `swift test --filter DirectoryReaderTests` → Expected: 6 tests pass.
- [ ] **Step 5: Commit** — `"feat(core): add getattrlistbulk directory reader"`

---

### Task 4: ScanBoundary

**Files:**
- Create: `Scan/ScanBoundary.swift`
- Test: `ScanBoundaryTests.swift`

**Interfaces:**
- Produces: `public struct ScanBoundary: Sendable, Equatable { public var allowedDevices: Set<Int32>; public var excludedPaths: Set<String>; public init(allowedDevices: Set<Int32>, excludedPaths: Set<String>); public func shouldDescend(path: String, device: Int32, isMountPoint: Bool) -> Bool; public static func forFolder(_ path: String) throws(DirectoryReadError) -> ScanBoundary; public static func forStartupDisk() throws(DirectoryReadError) -> ScanBoundary }`

Rules: descend iff `device ∈ allowedDevices` **and** `path ∉ excludedPaths`. `isMountPoint` alone does not block (firmlinked `/Users` lives on the Data volume, whose device is allowed). `forFolder` = `{device of path}`, no exclusions. `forStartupDisk` = devices of `/` and `/System/Volumes/Data`, excluding `"/System/Volumes/Data"`, `"/Volumes"`, `"/dev"`, `"/System/Volumes/VM"`, `"/System/Volumes/Preboot"`, `"/System/Volumes/Update"`, `"/System/Volumes/xarts"`, `"/System/Volumes/iSCPreboot"`, `"/System/Volumes/Hardware"` (container-level volumes are reported as volume info in Plan 4, not as tree nodes).

- [ ] **Step 1: Write failing tests**

```swift
@Test func excludesDataVolumeMirror() {
    let b = ScanBoundary(allowedDevices: [1, 2], excludedPaths: ["/System/Volumes/Data", "/Volumes"])
    #expect(b.shouldDescend(path: "/Users", device: 2, isMountPoint: false))
    #expect(!b.shouldDescend(path: "/System/Volumes/Data", device: 2, isMountPoint: true))
    #expect(!b.shouldDescend(path: "/Volumes", device: 1, isMountPoint: false))
}
@Test func otherDevicesAreNotEntered() {
    let b = ScanBoundary(allowedDevices: [1], excludedPaths: [])
    #expect(!b.shouldDescend(path: "/Users/me/USB", device: 9, isMountPoint: true))
}
@Test func startupDiskBoundaryIsReal() throws {
    let b = try ScanBoundary.forStartupDisk()
    #expect(b.allowedDevices.count == 2)
    #expect(b.excludedPaths.contains("/System/Volumes/Data"))
}
```

- [ ] **Step 2: Run** `swift test --filter ScanBoundaryTests` → FAIL.
- [ ] **Step 3: Implement** as specified (devices via `DirectoryReader.stat`).
- [ ] **Step 4: Run** → 3 pass.
- [ ] **Step 5: Commit** — `"feat(core): add scan boundary for startup disk firmlinks"`

---

### Task 5: ScanStore + Scanner

**Files:**
- Create: `Scan/ScanStore.swift`, `Scan/Scanner.swift`
- Test: `ScannerTests.swift`

**Interfaces:**
- Consumes: `FileTree`, `DirectoryReader`, `DirectoryEntry`, `ScanBoundary`.
- Produces:
  - `public struct ScanProgress: Sendable { public var filesSeen: Int; public var bytesSeen: UInt64; public var directoriesPending: Int }`
  - `public struct ScanSummary: Sendable { public var files: Int; public var directories: Int; public var unreadable: Int; public var totalSize: UInt64; public var duration: Duration; public var wasCancelled: Bool }`
  - `public actor ScanStore { public init(rootName: String, rootPath: String); public func insert(_ entries: [DirectoryEntry], under parent: NodeID, parentPath: String, boundary: ScanBoundary) -> [(id: NodeID, path: String)]; public func markUnreadable(_ id: NodeID); public func rootSize() -> UInt64; public func row(_ id: NodeID) -> NodeRow; public func rows(childrenOf id: NodeID, limit: Int) -> [NodeRow]; public func breadcrumb(to id: NodeID) -> [NodeRow]; public func path(of id: NodeID) -> String }` — `insert` returns the child directories to descend into (per boundary), adds files once per `(device, inode)` when `linkCount > 1` (later links get `.hardLinkDuplicate` and size 0), sets `.dataless`/`.mountPoint` flags.
  - `public struct Scanner: Sendable { public init(rootPath: String, boundary: ScanBoundary, maxConcurrency: Int = ProcessInfo.processInfo.activeProcessorCount * 2); public func scan(into store: ScanStore, progress: (@Sendable (ScanProgress) -> Void)? = nil) async -> ScanSummary }`

Approach: work queue of `(NodeID, path)`; a `TaskGroup` keeps at most `maxConcurrency` `DirectoryReader.read` calls in flight (run them off the cooperative pool is not required; `getattrlistbulk` is fast and bounded). Each result is inserted into the actor; returned directories are enqueued. Read errors → `markUnreadable`. Check `Task.isCancelled` before each read; on cancel, drain and return `wasCancelled: true`. Progress callback at most every 100 ms.

- [ ] **Step 1: Write failing tests**

```swift
func scanFixture(_ fx: Fixture) async throws -> (ScanStore, ScanSummary) {
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path)
    let s = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    return (store, s)
}
@Test func totalsMatchFixture() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let a = try fx.file("d1/a", bytes: 10_000), b = try fx.file("d1/d2/b", bytes: 50_000)
    let alloc = { (u: URL) in UInt64(try! u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize!) }
    let (store, s) = try await scanFixture(fx)
    #expect(s.files == 2 && s.directories >= 2 && !s.wasCancelled)
    #expect(await store.rootSize() == alloc(a) + alloc(b))
}
@Test func hardLinkCountedOnce() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let f = try fx.file("x/big", bytes: 200_000); try fx.hardLink("y/big", to: f)
    let (store, _) = try await scanFixture(fx)
    #expect(await store.rootSize() < 2 * 200_000)
}
@Test func unreadableDirectoryIsMarkedAndScanContinues() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("ok/f", bytes: 4096); let l = try fx.dir("locked"); try fx.file("locked/f", bytes: 1); chmod(l.path, 0)
    let (store, s) = try await scanFixture(fx)
    #expect(s.unreadable == 1)
    let rows = await store.rows(childrenOf: FileTree.root, limit: 10)
    #expect(rows.first { $0.name == "locked" }?.flags.contains(.unreadable) == true)
    #expect(rows.contains { $0.name == "ok" && $0.size > 0 })
}
@Test func cancelledBeforeStartReportsCancelled() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/b", bytes: 1)
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path)
    let task = Task { await Scanner(rootPath: fx.root.path, boundary: try! .forFolder(fx.root.path)).scan(into: store) }
    task.cancel()
    #expect(await task.value.wasCancelled)
}
@Test func pathTooLongIsMarkedUnreadable() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    var rel = ""; for _ in 0..<12 { rel += String(repeating: "d", count: 100) + "/" }  // > PATH_MAX (1024)
    _ = try? fx.dir(rel)   // creation via relative mkdir loop inside Fixture.dir
    let (_, s) = try await scanFixture(fx)
    #expect(!s.wasCancelled)   // must finish without crashing; deep dirs counted as unreadable if unreachable
}
@Test func breadcrumbFromRoot() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("a/b/c", bytes: 1)
    let (store, _) = try await scanFixture(fx)
    let a = await store.rows(childrenOf: FileTree.root, limit: 1)[0].id
    let b = await store.rows(childrenOf: a, limit: 1)[0].id
    #expect(await store.breadcrumb(to: b).map(\.name) == ["fx", "a", "b"])
}
```

(`Fixture.dir` must create deep paths with `mkdirat` step by step so it can exceed `PATH_MAX`.)

- [ ] **Step 2: Run** `swift test --filter ScannerTests` → FAIL.
- [ ] **Step 3: Implement** `ScanStore` and `Scanner` as specified.
- [ ] **Step 4: Run** `swift test` → all Core tests pass.
- [ ] **Step 5: Commit** — `"feat(core): add parallel scanner and ScanStore actor"`

---

### Task 6: Sunburst layout

**Files:**
- Create: `Layout/SunburstLayout.swift`; Modify: `Scan/ScanStore.swift` (add `sunburst` query)
- Test: `SunburstLayoutTests.swift`

**Interfaces:**
- Consumes: `FileTree`, `ScanStore`.
- Produces:
  - `public struct ArcSegment: Sendable, Hashable, Identifiable { public var id: String /* "\(node)" or "other-\(parent)-\(depth)" */; public var node: NodeID?; public var parent: NodeID; public var depth: Int /* 1 = innermost ring */; public var startAngle: Double; public var endAngle: Double /* radians, 0 = 12 o'clock, clockwise */; public var size: UInt64; public var name: String; public var otherCount: Int /* >0 only for merged "altri" */ }`
  - `public enum SunburstLayout { public static func compute(tree: FileTree, center: NodeID, depth: Int = 3, minAngle: Double = 0.006) -> [ArcSegment]; public static func hitTest(_ segments: [ArcSegment], angle: Double, depth: Int) -> ArcSegment? }`
  - `ScanStore.sunburst(center: NodeID, depth: Int) -> [ArcSegment]`

Rules: ring `d` children of each segment in ring `d-1` subdivide the parent's angular span proportionally to size. Siblings whose span is `< minAngle` merge into one "altri" segment (`node == nil`, `otherCount` = merged count) placed last; an "altri" segment is never subdivided. Zero-size center → `[]`. Children with size 0 are skipped.

- [ ] **Step 1: Write failing tests**

```swift
func tree(_ sizes: [UInt64]) -> FileTree {
    let t = FileTree(rootName: "r", rootPath: "/r")
    for (i, s) in sizes.enumerated() { t.addChild(of: 0, name: "f\(i)", kind: .file, allocatedSize: s) }
    return t
}
@Test func ringOneCoversFullCircleProportionally() {
    let segs = SunburstLayout.compute(tree: tree([300, 100]), center: 0)
    #expect(segs.count == 2)
    #expect(abs(segs[0].endAngle - segs[0].startAngle - 1.5 * .pi) < 1e-9)
    #expect(abs(segs.last!.endAngle - 2 * .pi) < 1e-9)
}
@Test func childrenNestInsideParentSpan() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let d = t.addChild(of: 0, name: "d", kind: .directory, allocatedSize: 0)
    t.addChild(of: d, name: "a", kind: .file, allocatedSize: 50); t.addChild(of: d, name: "b", kind: .file, allocatedSize: 50)
    t.addChild(of: 0, name: "c", kind: .file, allocatedSize: 100)
    let segs = SunburstLayout.compute(tree: t, center: 0)
    let parent = segs.first { $0.node == d }!
    let kids = segs.filter { $0.depth == 2 }
    #expect(kids.count == 2 && kids.allSatisfy { $0.startAngle >= parent.startAngle && $0.endAngle <= parent.endAngle + 1e-9 })
}
@Test func tinySiblingsMergeIntoOther() {
    let segs = SunburstLayout.compute(tree: tree([1_000_000_000] + Array(repeating: 1, count: 10_000)), center: 0)
    #expect(segs.count == 2)
    #expect(segs[1].node == nil && segs[1].otherCount == 10_000)
}
@Test func emptyCenterHasNoSegments() { #expect(SunburstLayout.compute(tree: tree([]), center: 0).isEmpty) }
@Test func hitTestFindsSegment() {
    let segs = SunburstLayout.compute(tree: tree([300, 100]), center: 0)
    #expect(SunburstLayout.hitTest(segs, angle: 0.1, depth: 1)?.name == "f0")
    #expect(SunburstLayout.hitTest(segs, angle: 1.9 * .pi, depth: 1)?.name == "f1")
    #expect(SunburstLayout.hitTest(segs, angle: 0.1, depth: 2) == nil)
}
```

- [ ] **Step 2: Run** `swift test --filter SunburstLayoutTests` → FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run** `swift test` → all pass.
- [ ] **Step 5: Commit** — `"feat(core): add sunburst layout with small-sibling merging"`

---

### Task 7: App state, target picker, Full Disk Access onboarding

**Files:**
- Create: `App/MacSpace/ScanModel.swift`, `App/MacSpace/FullDiskAccess.swift`, `App/MacSpace/Style/FusionPalette.swift`
- Modify: `App/MacSpace/Views/ContentView.swift`, `Resources/Localizable.xcstrings`

**Interfaces:**
- Consumes: `Scanner`, `ScanStore`, `ScanBoundary`, `ScanProgress`, `ScanSummary`, `NodeRow`, `ArcSegment`.
- Produces:
  - `enum FullDiskAccess { static var isGranted: Bool; static func openSettings() }` — granted iff `FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db")`; settings URL `x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles`.
  - `enum ScanTarget: Hashable { case startupDisk; case folder(URL) }`
  - `@MainActor @Observable final class ScanModel { var phase: Phase /* .idle, .scanning(ScanProgress), .done(ScanSummary) */; var center: NodeID; var segments: [ArcSegment]; var biggest: [NodeRow]; var breadcrumb: [NodeRow]; var hovered: ArcSegment?; func start(_ target: ScanTarget); func cancel(); func drill(into node: NodeID); func goUp(); func refreshViews() async }` — while scanning, a timer every 250 ms calls `refreshViews()` (sunburst depth 3, biggest limit 20).
  - `struct FusionPalette { static func ring(depth: Int, index: Int, scheme: ColorScheme) -> Color; static let background, centerFill, primaryText, secondaryText: (ColorScheme) -> Color }` — light: background `#f6f3ee`, segments `hsl(30,10%,L)` with `L = min(34 + 18·(depth-1) + 3·(index % 4), 80)`; dark: background `#1c1c1e`, `hsl(240,4%,L)` with `L = min(26 + 12·(depth-1) + 3·(index % 4), 58)`. Accent (orange `hsl(16,88%,57%)`) defined but unused until Plan 3.

UI copy (Italian, exact): toolbar picker "Macintosh HD" / "Scegli cartella…"; buttons "Analizza", "Interrompi"; progress "Analisi in corso… %@ file · %@"; onboarding title "Serve l'accesso completo al disco", body "Per vedere tutto lo spazio, MacSpace deve poter leggere anche le cartelle di sistema e la Libreria. Puoi analizzare anche senza: le cartelle non leggibili saranno segnate.", buttons "Apri Impostazioni di Sistema" / "Continua senza".

- [ ] **Step 1: Implement** the files above; `ContentView` shows onboarding sheet on launch when `!FullDiskAccess.isGranted` (re-check on `NSApplication.didBecomeActiveNotification`), the toolbar (target picker, Analizza/Interrompi, progress text), and placeholder panes for the chart and list.
- [ ] **Step 2: Build** `xcodegen generate && xcodebuild -scheme MacSpace build -quiet` → exit 0.
- [ ] **Step 3: Verify by running** (use the `run` skill): launch, pick "Scegli cartella…" → `~/Downloads`, press "Analizza": progress text updates and finishes; "Interrompi" stops a startup-disk scan within ~1 s.
- [ ] **Step 4: Commit** — `"feat(app): add scan model, target picker and Full Disk Access onboarding"`

---

### Task 8: Sunburst view, breadcrumbs, biggest list

**Files:**
- Create: `Views/SunburstView.swift`, `Views/BiggestListView.swift`, `Views/BreadcrumbView.swift`
- Modify: `Views/ContentView.swift`

**Interfaces:**
- Consumes: `ScanModel` (`segments`, `biggest`, `breadcrumb`, `hovered`, `drill`, `goUp`), `SunburstLayout.hitTest`, `FusionPalette`.

Behavior (from spec §5.1/§5.2):
- `Canvas` draws rings: center radius 0.30·R, ring width 0.70·R / 3, 1 pt separators in background color. Center shows total of `center` (large, semibold) and "di <capacity>" (secondary) — for folders show folder name instead.
- Hover: convert point → (angle from 12 o'clock clockwise, depth from radius) → `hitTest`; hovered segment lightens; tooltip with name, size, and "Non leggibile" for `.unreadable`. "altri" tooltip: "Altri %d elementi".
- Click segment with `node != nil` and children → `drill(into:)`; click center → `goUp()`; ⌘↑ also goes up. Animate segment angles (`.smooth(duration: 0.35)`), no animation when *Reduce Motion* is on.
- Labels drawn only where the arc length at mid-radius ≥ 60 pt.
- Breadcrumb above chart: clickable path components.
- Biggest list (right pane, width 260): name, size, SF Symbol for kind (`folder`, `doc`, `link`), `lock` glyph for unreadable; hovering a row highlights its segment; clicking a folder drills in.
- Empty state (no scan yet): "Scegli cosa analizzare e premi Analizza".

- [ ] **Step 1: Implement** the views.
- [ ] **Step 2: Build** → exit 0.
- [ ] **Step 3: Verify by running** (`run` skill, take screenshots light + dark): scan `~/Library`; drill 3 levels and back via center, breadcrumb and ⌘↑; hover shows tooltip; list matches ring 1 order; toggle Reduce Motion and confirm no animation.
- [ ] **Step 4: Design pass** — run `impeccable` (critique) and `ui-ux-pro-max` (`--stack swiftui` checks for hover, contrast, focus) on the screenshots; fix material issues.
- [ ] **Step 5: Commit** — `"feat(app): add interactive sunburst, breadcrumbs and biggest list"`

---

### Task 9: Performance & whole-disk verification

**Files:**
- Create: `MacSpaceCore/Tests/MacSpaceCoreTests/ScannerBenchmark.swift`

**Interfaces:**
- Consumes: `Scanner`, `ScanStore`, `ScanBoundary.forStartupDisk()`.

- [ ] **Step 1: Write the benchmark** — `@Test(.enabled(if: ProcessInfo.processInfo.environment["MACSPACE_BENCH"] == "1")) func startupDiskScan()` scans the startup disk, prints files/s, duration, peak RSS (`task_info` `phys_footprint`), and `#expect` `duration < .seconds(90)` and footprint `< 1 GB`.
- [ ] **Step 2: Run** `cd MacSpaceCore && MACSPACE_BENCH=1 swift test -c release --filter startupDiskScan` (from a terminal that has Full Disk Access) → Expected: PASS; record numbers in the PR description.
- [ ] **Step 3: Check totals** — compare `rootSize` against `URLResourceValues.volumeTotalCapacity - volumeAvailableCapacity` for `/`; difference should be explainable (snapshots, purgeable, container volumes). If the scan total exceeds used space, firmlink double counting is back: fix before continuing.
- [ ] **Step 4: Verify in app** — scan Macintosh HD with the app: first segments visible < 1 s; UI stays responsive (hover works) during the scan.
- [ ] **Step 5: Commit** — `"test(core): add opt-in startup disk benchmark"`; then use `superpowers:finishing-a-development-branch`.
