# MacSpace — Plan 3: Intelligence, safety levels, suggestions and Trash — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every node gets an owning app, a safety level (safe / caution / normal / protected) and an Italian reason; the default "Eliminabili" coloring lights up what can go; a Suggestions panel lists leftovers, regenerable caches and installers; the user selects items, confirms in a sheet that shows the space really freed, and MacSpace moves them to the Trash after re-checking each one, updating the tree in place.

**Architecture:** Core gains a `Safety/` module: an installed-apps index (bundles + Spotlight + team IDs), an owner matcher for `~/Library` folders, and `SafetyRules.evaluate` — one pure, first-match-wins rule table over `NodeFacts` + `SafetyEnvironment`, the single tunable place. `ScanStore` flags packages at insert, caches verdicts for what the UI shows, stamps `safety` on segments/tiles/rows, finds suggestions, and owns the trash pipeline (re-verify → `DiskActions.moveToTrash` → `FileTree.remove`). Probes that touch the system (open files via libproc, package check via LaunchServices, private size via `ATTR_CMNEXT_PRIVATESIZE`, the Trash itself) sit behind small types so tests never touch the real Trash. The app supplies running apps (NSWorkspace) and renders levels, selection, suggestions, the confirmation sheet and the session history.

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing, XcodeGen, macOS 27; Darwin (`libproc`, `getattrlist`), CoreServices (`MDQuery`, `MDItem`), Security (`SecStaticCode`). No dependencies.

**Spec:** `docs/superpowers/specs/2026-11-21-macspace-design.md` — §5.1 (default coloring), §5.2 (safety styling), §5.3 (private size), §5.4 (intelligence, rules, cloud), §5.5 (suggestions 1–3), §5.6 (deleting, except "Rimuovi solo la copia locale"), §7 (safety is the top priority). Plans 1–2 (branches `feat/2-foundation`, `feat/3-treemap-colors`) are the codebase this builds on. Out of scope (plan 4): snapshot/FSEvents, "Rimuovi solo la copia locale" and the cloud suggestion, duplicates, volume info.

## Global Constraints

- Everything in plans 1–2 Global Constraints still holds (macOS 27, Swift 6, no deps, not sandboxed, Italian UI via `Localizable.xcstrings`, English code, allocated sizes, hard links once, no symlinks followed, no `/System/Volumes/Data` double count, never cross mount points, orange reserved for "deletable").
- Branch `feat/7-intelligence-trash` (open GitHub issue first: "Intelligence & deleting", expected #7), created from `feat/3-treemap-colors` (or `main` once PRs #4–#6 are merged). **No Claude attribution lines** in commits (hook rejects them). Never commit `Local.xcconfig`.
- Disk writes allowed from this plan on: only (a) moving **user-confirmed** items to the Trash with `FileManager.trashItem` (so Finder's "Rimetti al suo posto" works) and (b) the app's settings. Never `removeItem`, never empty the Trash, never touch anything unconfirmed.
- **Protected is never trashable**: enforced three times — selection refuses it, the sheet excludes it, the store re-evaluates right before moving. A bug that could trash a protected item is a release blocker (spec §7).
- Tunables (thresholds, cache lists, never-touch list, package extensions) live only in `Safety/SafetyRules.swift` and `Safety/SafetyTables.swift`.
- Memory gate unchanged: benchmark `peakBytesPerFile ≤ 333`. This plan adds no per-node storage beyond two flag bits and the installers list. Scan time may not regress > 5 % vs the baseline measured in Task 1 Step 1.
- Safety colors: safe = solid accent `hsl(16,88%,57%)`; caution = soft accent + hatching; normal = Fusion neutral; protected = neutral + lock glyph. Every fill allows a label ≥ 4.5:1 (light/dark, +12 hover lift). Never color alone: tooltip, list and VoiceOver say the level and the reason in words.
- GUI verification runs appear on the owner's screen: keep them short, quit only the app's own PID, save/restore the owner's `com.massilp.macspace` window frame, never change system appearance globally, never commit debug hooks. **Trash tests in the GUI use only items inside a throwaway fixture folder**, and are restored afterwards.

## Review Focus

1. **Leftover false positives** — the data of an installed app whose folder name is not its bundle ID (helpers, group containers named by team ID, apps found only by Spotlight, a running app not in `/Applications`) must never come out *safe* → Task 3 tests `helperPrefixIsInstalled`, `teamGroupContainerIsInstalled`, `spotlightOnlyAppIsInstalled`, `runningIdentifierIsInstalled`; Task 4 `recentLeftoverIsCaution`.
2. **The item changed between scan and Trash** (deleted, replaced by a symlink or a folder, now open, now inside a package) — it is skipped with a reason, nothing else is moved → Task 8 tests `missingIsSkipped`, `replacedBySymlinkIsSkipped`, `openFileIsSkipped`, `unlistedPackageAncestorBlocksTrash`.
3. **Overlapping or stale selections** — a folder and something inside it, or IDs from a previous scan — trash the top-most item once, never crash → Task 8 `nestedSelectionTrashesTopMostOnce`, `removedNodeIsSkipped`; Task 10 selection cleared on a new scan.
4. **Scanning a folder that is itself inside a bundle** (e.g. `Foo.app/Contents`) — everything stays protected as bundle interior → Task 1 `rootInsideBundleIsInsidePackage`.
5. **Apps index not ready yet** (built in the background at launch) — nothing in `~/Library` may be classed as a leftover meanwhile → Task 5 `noAppsIndexMeansNoLeftovers`.

---

## File Structure

```
MacSpaceCore/Sources/MacSpaceCore/
  Model/NodeTypes.swift            NodeFlags + .package, .insidePackage, .removed; NodeRow + safety
  Model/CategoryClassifier.swift   + isPackage(directoryName:), isInstaller(fileName:)
  Model/FileTree.swift             + node(atPath:), remove(_:)
  Scan/RootContext.swift           NEW: ancestor-aware context/flags for the scan root
  Scan/ScanStore.swift             package flags, installers list, environment, verdicts, suggestions, trash
  Scan/DirectoryEntry.swift        + privateSize
  Scan/DirectoryReader.swift       + read(path:includePrivateSize:)
  Layout/SunburstLayout.swift      ArcSegment + safety
  Layout/TreemapLayout.swift       TreemapTile + safety
  Layout/ChartPalette.swift        + safetyFill, hatch color (validated)
  Safety/AppsIndex.swift           NEW: AppRecord, AppsIndex.build, Spotlight app paths
  Safety/Spotlight.swift           NEW: SpotlightLastUsed
  Safety/OwnerMatcher.swift        NEW: LibraryLocation, Ownership, OwnerMatcher
  Safety/SafetyTypes.swift         NEW: SafetyLevel, SafetyReason, SafetyVerdict, NodeFacts, SafetyEnvironment
  Safety/SafetyTables.swift        NEW: essential folders, system prefixes, never-touch, developer caches, package exts
  Safety/SafetyRules.swift         NEW: evaluate + thresholds
  Safety/Suggestions.swift         NEW: Suggestion, SuggestionItem, SuggestionKind
  Actions/OpenFiles.swift          NEW: OpenFileSet (libproc)
  Actions/PrivateSize.swift        NEW: space freed estimate
  Actions/DiskActions.swift        NEW: DiskActions, SystemDiskActions, PackageProbe
  Actions/TrashGuard.swift         NEW: last-line hard refusals
  Actions/TrashOutcome.swift       NEW: TrashOutcome, TrashSkip
MacSpaceCore/Tests/MacSpaceCoreTests/
  RootContextTests  AppsIndexTests  OwnerMatcherTests  SafetyRulesTests  SuggestionsTests
  OpenFilesTests  PrivateSizeTests  TrashTests  (+ FileTreeTests, ScannerTests, ChartPaletteTests, Fixture)
App/MacSpace/
  SafetyEnvironmentProvider.swift  NEW: builds AppsIndex, tracks running apps
  SafetyText.swift                 NEW: Italian titles for SafetyLevel / SafetyReason / TrashSkip
  ChartSettings.swift              ColorMode.deletable replaces .neutral (default)
  ScanModel.swift                  environment, verdicts, selection, highlight, suggestions, trash, history
  Style/FusionPalette.swift        deletable fills, hatch, lock
  Views/Charts/SafetyDecor.swift   NEW: hatch + lock + selection outline drawing shared by both charts
  Views/Sidebar/SidebarView.swift  NEW: "Elementi" | "Suggerimenti" + selection bar
  Views/Sidebar/SuggestionsView.swift   NEW
  Views/Trash/TrashConfirmationSheet.swift  NEW
  Views/Trash/TrashResultView.swift          NEW
  Views/Trash/HistoryPopover.swift          NEW
  (+ SunburstView, TreemapView, SegmentTooltip, BiggestListView, ChartLegend, ContentView)
```

---

### Task 1: Package flags and ancestor-aware root context

**Files:** Create `Scan/RootContext.swift`, `Tests/.../RootContextTests.swift`; Modify `Model/NodeTypes.swift`, `Model/CategoryClassifier.swift`, `Scan/ScanStore.swift`, `Safety/SafetyTables.swift` (create, package extensions only for now); Test `ScannerTests.swift`

**Interfaces:**
- Produces:
  - `NodeFlags.package = 1 << 4` (a directory that is a package), `.insidePackage = 1 << 5` (anything below a package), `.removed = 1 << 6` (Task 8).
  - `SafetyTables.packageExtensions: Set<String>` (lowercase): `app appex xpc framework bundle plugin kext qlgenerator mdimporter saver prefpane systemextension photoslibrary photolibrary aplibrary musiclibrary tvlibrary fcpbundle imovielibrary logicx band xcarchive xcodeproj xcworkspace playground rtfd pages key numbers sparsebundle dsym mlmodelc docc`.
  - `CategoryClassifier.isPackage(directoryName: String) -> Bool` (same FNV extension lookup, no allocation), `isInstaller(fileName: String) -> Bool` (`dmg pkg mpkg xip`).
  - `RootContext.resolve(rootPath: String, classifier: CategoryClassifier) -> (context: FileCategory?, flags: NodeFlags)` — walks the components of `rootPath` from `/`, threading `classifier.context(forDirectory:path:parent:)` through each ancestor, and sets `.insidePackage` if any **ancestor** is a package, `.package` if the root itself is.
  - `ScanStore.init` uses `RootContext` for the root's context and flags (replacing the single-component call). `insert`: a directory entry whose name `isPackage` gets `.package`; every entry under a parent flagged `.package` or `.insidePackage` gets `.insidePackage` (read the parent's flags once per batch). Installer files' IDs are appended to a private `installerIDs: [NodeID]` (used in Task 6).

- [ ] **Step 1: Baseline** — on the unchanged branch run `MACSPACE_BENCH=1 swift test -c release --filter startupDiskScan`; record duration and B/file in the task report (the 5 % budget is measured against this).
- [ ] **Step 2: Failing tests**

```swift
@Test func rootInsideBundleIsInsidePackage() {
    let c = CategoryClassifier(home: "/Users/u")
    let r = RootContext.resolve(rootPath: "/Applications/Foo.app/Contents", classifier: c)
    #expect(r.context == .app && r.flags.contains(.insidePackage) && !r.flags.contains(.package))
    let p = RootContext.resolve(rootPath: "/Users/u/Pictures/Photos Library.photoslibrary", classifier: c)
    #expect(p.flags == [.package] && p.context == .photo)
    #expect(RootContext.resolve(rootPath: "/", classifier: c).flags.isEmpty)
}
@Test func packagesFlagTheirInterior() async throws {   // ScannerTests
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Foo.app/Contents/MacOS/foo", bytes: 10_000); try fx.file("Lib.photoslibrary/db", bytes: 10)
    try fx.file("Setup.DMG", bytes: 1_000); try fx.file("plain/x.txt", bytes: 10)
    let store = ScanStore(rootName: "fx", rootPath: fx.root.path, home: "/nonexistent")
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    let rows = await store.rows(childrenOf: FileTree.root, limit: 10)
    let app = try #require(rows.first { $0.name == "Foo.app" })
    #expect(app.flags.contains(.package) && !app.flags.contains(.insidePackage))
    let inner = await store.rows(childrenOf: app.id, limit: 10)
    #expect(inner.allSatisfy { $0.flags.contains(.insidePackage) })
    #expect(rows.first { $0.name == "plain" }?.flags.isDisjoint(with: [.package, .insidePackage]) == true)
    #expect(await store.installerCount() == 1)   // internal test accessor
}
@Test func scanOfBundleInteriorMarksEverything() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Foo.app/Contents/Resources/a.png", bytes: 100)
    let root = fx.root.appendingPathComponent("Foo.app/Contents").path
    let store = ScanStore(rootName: "Contents", rootPath: root, home: "/nonexistent")
    _ = await Scanner(rootPath: root, boundary: try .forFolder(root)).scan(into: store)
    #expect(await store.row(FileTree.root).flags.contains(.insidePackage))
    #expect(await store.categoryTotals(of: FileTree.root).keys.allSatisfy { $0 == .app })
}
```

- [ ] **Step 3: Run** `swift test` (in `MacSpaceCore`) → the three tests FAIL.
- [ ] **Step 4: Implement** as specified.
- [ ] **Step 5: Run** `swift test` → all pass; rerun the benchmark → duration ≤ baseline × 1.05, B/file ≤ 333.
- [ ] **Step 6: Commit** — `feat(core): flag packages and their interior, resolve root context from ancestors`

---

### Task 2: Installed apps index and Spotlight lookups

**Files:** Create `Safety/AppsIndex.swift`, `Safety/Spotlight.swift`, `Tests/.../AppsIndexTests.swift`; Modify `Tests/.../Support/Fixture.swift` (+ `write(_ rel: String, data: Data)`, `plist(_ rel: String, _ dict: [String: Any])`)

**Interfaces:**
- Produces:
  - `public struct AppRecord: Sendable, Hashable { bundleID: String; name: String; teamID: String?; path: String }` — embedded bundles carry the **host app's** `name` and `path`.
  - `public struct AppsIndex: Sendable` with `init(records: [AppRecord])`, `static let empty`, `var count: Int`, and lookups (all ASCII case-insensitive):
    - `app(forIdentifier id: String) -> AppRecord?` — an app whose bundle ID equals `id`, or where one is a prefix of the other on a `.` boundary **and** they share at least 2 labels (`com.foo.helper` ↔ `com.foo`; `com.foo` ↔ `com.foo.mac`; never `com` ↔ anything).
    - `app(named: String) -> AppRecord?` — exact display name or file name without `.app`.
    - `hasTeam(_ teamID: String) -> Bool`.
  - `static func build(roots: [String] = AppsIndex.defaultRoots, extraAppPaths: [String] = [], readTeamIDs: Bool = true) -> AppsIndex` — `defaultRoots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]`; finds `*.app` up to 2 levels below each root (not descending into apps); for each app reads `Contents/Info.plist` (`CFBundleIdentifier`, name = `CFBundleDisplayName` ?? `CFBundleName` ?? file name) and adds embedded bundles from `Contents/Library/LoginItems/*.app`, `Contents/Helpers/*.app`, `Contents/PlugIns/*.appex`, `Contents/XPCServices/*.xpc`, `Contents/Library/LaunchServices/*`. Team ID via `SecStaticCodeCreateWithPath` + `SecCodeCopySigningInformation` (`kSecCodeInfoTeamIdentifier`), top-level apps only. Apps without a bundle ID are skipped. Duplicates by path ignored.
  - `static func spotlightAppPaths() -> [String]` — synchronous `MDQueryCreate` on `kMDItemContentType == "com.apple.application-bundle"`, `MDQueryExecute(…, kMDQuerySynchronous)`; returns `kMDItemPath`s; `[]` if Spotlight is off.
  - `public enum SpotlightLastUsed { static func lastUsed(path: String) -> UInt32? }` — `MDItemCreate` + `kMDItemLastUsedDate`, seconds since 1970; nil when not indexed.

- [ ] **Step 1: Failing tests**

```swift
@Test func indexReadsBundlesAndHelpers() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.plist("Apps/Foo.app/Contents/Info.plist", ["CFBundleIdentifier": "com.foo.Foo", "CFBundleName": "Foo"])
    try fx.plist("Apps/Foo.app/Contents/Library/LoginItems/FooHelper.app/Contents/Info.plist",
                 ["CFBundleIdentifier": "com.foo.helper"])
    try fx.plist("Apps/Utilities/Bar.app/Contents/Info.plist", ["CFBundleIdentifier": "org.bar.app"])
    try fx.dir("Apps/NoPlist.app")
    let idx = AppsIndex.build(roots: [fx.root.path + "/Apps"], readTeamIDs: false)
    #expect(idx.count == 3)
    #expect(idx.app(forIdentifier: "com.foo.helper")?.name == "Foo")
    #expect(idx.app(forIdentifier: "COM.FOO.FOO.savedstate-x") == nil)   // not a dot-boundary prefix
    #expect(idx.app(forIdentifier: "org.bar.app.extension")?.bundleID == "org.bar.app")
    #expect(idx.app(named: "bar")?.bundleID == "org.bar.app")
}
@Test func prefixMatchNeedsTwoLabels() {
    let idx = AppsIndex(records: [AppRecord(bundleID: "com.foo", name: "Foo", teamID: "ABCDE12345", path: "/A/Foo.app")])
    #expect(idx.app(forIdentifier: "com.foo.mac") != nil && idx.app(forIdentifier: "com") == nil)
    #expect(idx.app(forIdentifier: "com.foobar") == nil && idx.hasTeam("abcde12345"))
}
@Test func spotlightHelpersDoNotCrash() {
    #expect(AppsIndex.spotlightAppPaths().allSatisfy { $0.hasSuffix(".app") })
    #expect(SpotlightLastUsed.lastUsed(path: "/nonexistent/x") == nil)
}
@Test func realIndexFindsSystemApps() {   // tolerant smoke test on the owner's Mac
    let idx = AppsIndex.build()
    #expect(idx.app(forIdentifier: "com.apple.calculator") != nil)
}
```

- [ ] **Step 2: Run** `swift test --filter AppsIndexTests` → FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Run** → pass. Time `AppsIndex.build(extraAppPaths: AppsIndex.spotlightAppPaths())` once on the owner's Mac (release) and report it; target < 3 s.
- [ ] **Step 5: Commit** — `feat(core): index installed apps with helpers, team IDs and Spotlight`

---

### Task 3: Owner matcher for `~/Library` folders

**Files:** Create `Safety/OwnerMatcher.swift`, `Tests/.../OwnerMatcherTests.swift`

**Interfaces:**
- Consumes: `AppsIndex`, `AppRecord`.
- Produces:
  - `public enum LibraryLocation: String, CaseIterable, Sendable` — raw values are folder names under `~/Library`: `Application Support`, `Caches`, `Containers`, `Group Containers`, `Preferences`, `Saved Application State`, `HTTPStorages`, `WebKit`, `Logs`, `LaunchAgents`.
  - `public enum Ownership: Sendable, Hashable { case apple, installed(AppRecord), unmatchedIdentifier(String), unknownName }`
  - `public enum OwnerMatcher { static func ownership(of name: String, in location: LibraryLocation, apps: AppsIndex, running: Set<String>) -> Ownership; static func identifier(from name: String, in location: LibraryLocation) -> String? }`

Rules (in order):
1. Strip suffixes: `.plist` (Preferences, LaunchAgents), `.savedState` (Saved Application State), `.binarycookies` (HTTPStorages). Group Containers: `group.<rest>` → `<rest>`; `<TEAMID>.<rest>` (10 uppercase alphanumerics) → `<rest>`, remembering the team.
2. Apple: identifier starts with `com.apple.` (case-insensitive) → `.apple`.
3. Identifier-like = no spaces, ≥ 2 labels, each `[A-Za-z0-9_-]+`, and (≥ 3 labels, or first label in `com org net io app dev me co de uk fr it jp cn ru us ch nl se`). Not identifier-like → `apps.app(named:)` → `.installed`, else `.unknownName`.
4. Identifier-like → `apps.app(forIdentifier:)`, or a running bundle ID related by the same prefix rule (wrap `running` into a temporary record named after the identifier), or (Group Containers) `apps.hasTeam(team)` → `.installed`; else `.unmatchedIdentifier(id)`.

- [ ] **Step 1: Failing tests**

```swift
private let apps = AppsIndex(records: [
    AppRecord(bundleID: "com.spotify.client", name: "Spotify", teamID: "2FNC3A47ZF", path: "/Applications/Spotify.app"),
    AppRecord(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", teamID: "BQR82RBBHL", path: "/Applications/Slack.app"),
])
private func own(_ n: String, _ l: LibraryLocation, running: Set<String> = []) -> Ownership {
    OwnerMatcher.ownership(of: n, in: l, apps: apps, running: running)
}
@Test func helperPrefixIsInstalled() { #expect(own("com.spotify.client.helper", .caches) == .installed(apps.app(named: "Spotify")!)) }
@Test func teamGroupContainerIsInstalled() { if case .installed = own("BQR82RBBHL.com.tinyspeck.slack", .groupContainers) {} else { Issue.record() } }
@Test func runningIdentifierIsInstalled() {
    if case .installed = own("com.acme.tool", .applicationSupport, running: ["com.acme.tool"]) {} else { Issue.record() }
}
@Test func suffixesAndApple() {
    #expect(own("com.spotify.client.plist", .preferences) != .unknownName)
    #expect(own("com.apple.Safari.savedState", .savedState) == .apple)
    #expect(own("group.com.apple.notes", .groupContainers) == .apple)
    #expect(own("com.gone.app.plist", .preferences) == .unmatchedIdentifier("com.gone.app"))
    #expect(own("homebrew.mxcl.postgresql.plist", .launchAgents) == .unmatchedIdentifier("homebrew.mxcl.postgresql"))
}
@Test func namesAreNotIdentifiers() {
    if case .installed = own("Slack", .applicationSupport) {} else { Issue.record() }
    #expect(own("AddressBook", .applicationSupport) == .unknownName)
    #expect(own("cache.db", .caches) == .unknownName)          // one dot, not a TLD
    #expect(own("Google Chrome", .caches) == .unknownName)
}
```

Plus `spotlightOnlyAppIsInstalled`: an index built with `extraAppPaths: [fixture app outside roots]` matches its identifier.

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → pass.
- [ ] **Step 5: Commit** — `feat(core): match Library folders to installed apps`

---

### Task 4: Safety rules

**Files:** Create `Safety/SafetyTypes.swift`, `Safety/SafetyRules.swift`, extend `Safety/SafetyTables.swift`, `Tests/.../SafetyRulesTests.swift`

**Interfaces:**
- Consumes: `OwnerMatcher`, `LibraryLocation`, `AppsIndex`, `NodeFlags`, `FileCategory`.
- Produces:
  - `public enum SafetyLevel: UInt8, Sendable, CaseIterable { case safe, caution, normal, protected }` and `var isTrashable: Bool { self != .protected }`.
  - `public enum SafetyReason: Sendable, Hashable` — the cases in the table below (no payloads).
  - `public struct SafetyVerdict: Sendable, Hashable { level: SafetyLevel; reason: SafetyReason; owner: String? }` (`owner` = app name, cloud provider or developer-cache name).
  - `public struct NodeFacts: Sendable { path: String; name: String; kind: NodeKind; flags: NodeFlags; size: UInt64; lastUsed: UInt32; category: FileCategory; isScanRoot: Bool }`
  - `public struct SafetyEnvironment: Sendable { home: String; apps: AppsIndex?; runningBundleIDs: Set<String>; runningAppPaths: Set<String>; now: UInt32; isWritable: @Sendable (String) -> Bool }` — `apps == nil` means "index not ready". `static func system(home:apps:runningBundleIDs:runningAppPaths:)` uses `access(dir, W_OK) == 0`.
  - `public enum SafetyRules { static func evaluate(_ f: NodeFacts, in env: SafetyEnvironment) -> SafetyVerdict }` plus tunables `longUnusedSeconds = 730 * 86_400`, `longUnusedMinSize: UInt64 = 50_000_000`, `recentLeftoverSeconds = 30 * 86_400`, `suggestionMinSize: UInt64 = 1_000_000`.

Rule table (first match wins; `H` = home, `L` = `H/Library`; "under X" = X or below it, component-wise like `CategoryClassifier.matches`):

| # | Condition | Level | Reason | owner |
|---|---|---|---|---|
| 1 | `isScanRoot` | protected | `.scanRoot` | |
| 2 | path ∈ `SafetyTables.essentialPaths(home:)` (exact): `/ /Applications /Library /System /Users /Volumes /private /usr /opt /bin /sbin /cores /etc /var /tmp`, `H`, `L`, `H/{Desktop,Documents,Downloads,Movies,Music,Pictures,Public,Applications}`, `L/<each LibraryLocation>`, `L/Developer`, `L/Mobile Documents`, `L/CloudStorage`, `H/.Trash` | protected | `.essentialFolder` | |
| 3 | flags ∋ `.insidePackage` | protected | `.insidePackage` | |
| 4 | under `/System /usr /bin /sbin /private /cores /Library/Apple` but not under `/usr/local` | protected | `.systemLocation` | |
| 5 | under `H/.Trash`, or any component `.Trashes` | protected | `.trash` | |
| 6 | under `L/Keychains`, `L/Mail`, `L/Messages`; under `L/Containers/com.apple.*`; under `L/Group Containers/group.com.apple.*` or `L/Group Containers/*.com.apple.*`; under `L/<LibraryLocation>/<name>` with ownership `.apple` (except Caches, Logs) | protected | `.appleData` | |
| 7 | name ends `.photoslibrary` | protected | `.photosLibrary` | |
| 8 | path ∈ `runningAppPaths` | protected | `.runningApp` | app name |
| 9 | `!isWritable(parent)` | protected | `.notWritable` | |
| 10 | flags ∋ `.dataless` | normal | `.cloudOnly` | |
| 11 | under `L/Mobile Documents` (provider "iCloud Drive") or `L/CloudStorage/<P>` (provider = `<P>` up to its first `-`) | caution | `.cloudSynced` | provider |
| 12 | under a `SafetyTables.developerCaches(home:)` root: `L/Developer/Xcode/DerivedData`, `L/Developer/CoreSimulator/Caches`, `H/.npm/_cacache`, `H/.gradle/caches`, `H/.cargo/registry/cache`, `H/go/pkg/mod/cache`, `H/.cache/pip`, `L/pnpm/store`, `H/.pnpm-store` (Xcode `Archives` is user data: not listed) | safe | `.developerCache` | cache display name (`DerivedData`, `npm`, …) |
| 13 | under `L/<loc>/<name>`; `apps == nil` | normal | `.analysisPending` | |
| 14 | ↳ `loc == .caches`: `.apple` → caution `.appleCache`; `.installed(a)` running → caution `.cacheOfRunningApp`; `.installed(a)` → safe `.cacheOfApp`; `.unmatchedIdentifier` → safe `.leftover`; `.unknownName` → safe `.cacheOfApp` (owner nil) | | | app name |
| 15 | ↳ other locs: `.apple` (only Logs reaches here) → normal `.ordinary`; `.installed(a)` running → protected `.runningAppData`; `.installed(a)` → caution `.appData`; `.unmatchedIdentifier`: `loc == .launchAgents` → caution `.leftoverLaunchAgent`; `now − lastUsed < recentLeftoverSeconds` → caution `.recentLeftover`; else safe `.leftover`; `.unknownName` → normal `.ordinary` | | | app name |
| 16 | file, `isInstaller(name)` | safe | `.installer` | installed app name if `InstallerMatcher` finds one |
| 17 | file under `H` but not `L`, category ∈ video/photo/music/document/archive, `size ≥ longUnusedMinSize`, `lastUsed > 0`, `now − lastUsed ≥ longUnusedSeconds` | caution | `.notUsedForLong` | |
| 18 | otherwise | normal | `.ordinary` | |

Rule 6's `.apple` check needs no index (call `OwnerMatcher` with `apps ?? .empty`). "Running" for 14/15 = the app's bundle ID or any `runningBundleIDs` entry related by the `AppsIndex` prefix rule. Rules 14/15 apply to the location child **and everything below it** (a node deeper inside `Caches/com.foo/` inherits that folder's verdict). `InstallerMatcher.app(forInstaller name: String, apps:) -> AppRecord?`: lowercase the name, drop the extension, cut at the first digit or at `-_ (`, trim; match an app whose lowercased name equals it or starts with it (≥ 3 chars) — `Firefox 132.0.dmg` → Firefox.

- [ ] **Step 1: Failing tests** — a helper `v(_ path:, kind: .directory, flags: [], size: 0, lastUsed: 0, category: .other, root: false, apps: AppsIndex? = testApps, running: [], runningPaths: [], writable: true) -> SafetyVerdict` that builds `NodeFacts` (name = last component) and a `SafetyEnvironment` with `home = "/Users/u"`, `now = 2_000_000_000`; `testApps` = the Spotify + Slack index of Task 3. Assertions:

```swift
@Test func protectedRows() {
    #expect(v("/Users/u/Library").reason == .essentialFolder)
    #expect(v("/Users/u/Library/Caches").level == .protected)
    #expect(v("/Applications/Foo.app/Contents", flags: [.insidePackage]).reason == .insidePackage)
    #expect(v("/usr/local/bin/x", kind: .file).reason == .ordinary)            // /usr/local is not system
    #expect(v("/usr/local/bin/x", kind: .file, writable: false).reason == .notWritable)
    #expect(v("/usr/lib/x", kind: .file).reason == .systemLocation)
    #expect(v("/Users/u/.Trash/x").reason == .trash && v("/Volumes/USB/.Trashes/501").reason == .trash)
    #expect(v("/Users/u/Library/Containers/com.apple.Notes/Data").reason == .appleData)
    #expect(v("/Users/u/Pictures/Photos Library.photoslibrary", flags: [.package]).reason == .photosLibrary)
    #expect(v("/Applications/Spotify.app", running: ["com.spotify.client"], runningPaths: ["/Applications/Spotify.app"]).reason == .runningApp)
    #expect(v("/Applications/Old.app", writable: false).reason == .notWritable)
}
@Test func cacheRows() {
    #expect(v("/Users/u/Library/Caches/com.spotify.client") == SafetyVerdict(level: .safe, reason: .cacheOfApp, owner: "Spotify"))
    #expect(v("/Users/u/Library/Caches/com.spotify.client/Data/x", kind: .file).level == .safe)   // inherits
    #expect(v("/Users/u/Library/Caches/com.spotify.client", running: ["com.spotify.client"]).reason == .cacheOfRunningApp)
    #expect(v("/Users/u/Library/Caches/com.apple.Safari").reason == .appleCache)
    #expect(v("/Users/u/Library/Developer/Xcode/DerivedData/App-abc").reason == .developerCache)
}
@Test func leftoverRows() {
    #expect(v("/Users/u/Library/Application Support/com.gone.app", lastUsed: 1_000_000_000).reason == .leftover)
    #expect(v("/Users/u/Library/LaunchAgents/com.gone.agent.plist", kind: .file).reason == .leftoverLaunchAgent)
    #expect(v("/Users/u/Library/Application Support/Slack").reason == .appData)
    #expect(v("/Users/u/Library/Application Support/Slack", running: ["com.tinyspeck.slackmacgap"]).reason == .runningAppData)
    #expect(v("/Users/u/Library/Application Support/AddressBook").reason == .ordinary)
}
@Test func recentLeftoverIsCaution() {
    #expect(v("/Users/u/Library/Containers/com.gone.app", lastUsed: 2_000_000_000 - 86_400).reason == .recentLeftover)
}
@Test func noAppsIndexIsPending() {
    #expect(v("/Users/u/Library/Application Support/com.gone.app", apps: nil).reason == .analysisPending)
}
@Test func cloudInstallersAndAge() {
    #expect(v("/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a.mov", kind: .file)
            == SafetyVerdict(level: .caution, reason: .cloudSynced, owner: "iCloud Drive"))
    #expect(v("/Users/u/Library/CloudStorage/Dropbox-Personal/x", kind: .file).owner == "Dropbox")
    #expect(v("/Users/u/Library/CloudStorage/Dropbox-Personal/x", kind: .file, flags: [.dataless]).reason == .cloudOnly)
    #expect(v("/Users/u/Downloads/Spotify 1.2.dmg", kind: .file) == SafetyVerdict(level: .safe, reason: .installer, owner: "Spotify"))
    #expect(v("/Users/u/Movies/old.mov", kind: .file, size: 60_000_000, lastUsed: 1_000_000_000, category: .video).reason == .notUsedForLong)
    #expect(v("/Users/u/Movies/old.mov", kind: .file, size: 10_000_000, lastUsed: 1_000_000_000, category: .video).reason == .ordinary)
    #expect(v("/Users/u/Projects/app", root: true).reason == .scanRoot)
}
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → pass.
- [ ] **Step 5: Commit** — `feat(core): four-level safety rules with reasons`

---

### Task 5: Verdicts in the store and in every chart element

**Files:** Modify `Scan/ScanStore.swift`, `Model/FileTree.swift`, `Model/NodeTypes.swift`, `Layout/SunburstLayout.swift`, `Layout/TreemapLayout.swift`; Tests `ScannerTests.swift`, `FileTreeTests.swift`

**Interfaces:**
- Consumes: `SafetyRules`, `SafetyEnvironment`, `NodeFacts`, `.package` flags (Task 1).
- Produces:
  - `ArcSegment.safety`, `TreemapTile.safety`, `NodeRow.safety: SafetyLevel` — init params default `.normal`; merged "altri" stay `.normal`.
  - `FileTree.node(atPath: String) -> NodeID?` — walks from the root by exact name bytes; nil if absent or outside `rootPath`.
  - `ScanStore.setEnvironment(_ env: SafetyEnvironment)` — replaces the environment and clears the verdict cache. Until called, the store uses `SafetyEnvironment(home:, apps: nil, …)` (rule 13 keeps Library items pending).
  - `ScanStore.verdict(_ id: NodeID) -> SafetyVerdict` — cached per node in `[NodeID: SafetyVerdict]`; facts from the tree (`dominantCategory`, `lastUsed`, `isScanRoot = id == root`).
  - `ScanStore.invalidateVerdicts()` — the app calls it when the scan ends (sizes and last use moved meanwhile).
  - `Snapshot` gains `verdicts: [NodeID: SafetyVerdict]` for every node in `segments`/`tiles`/`biggest`/`breadcrumb`; the store stamps `safety` on those elements and rows.
  - Internal test accessor `installerCount() -> Int` (Task 1) stays internal (`@testable`).

- [ ] **Step 1: Failing tests**

```swift
@Test func snapshotCarriesVerdicts() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let home = fx.root.path
    try fx.file("Library/Caches/com.gone.app/blob", bytes: 50_000); try fx.file("Downloads/Setup.dmg", bytes: 5_000)
    let store = ScanStore(rootName: "fx", rootPath: home, home: home)
    _ = await Scanner(rootPath: home, boundary: try .forFolder(home)).scan(into: store)
    await store.setEnvironment(.system(home: home, apps: .empty, runningBundleIDs: [], runningAppPaths: []))
    let caches = try #require(await store.node(atPath: home + "/Library/Caches"))
    let snap = await store.snapshot(center: caches, chart: .sunburst(depth: 3), biggestLimit: 5)
    let seg = try #require(snap.segments.first { $0.name == "com.gone.app" })
    #expect(seg.safety == .safe && snap.verdicts[seg.node!]?.reason == .leftover)
    #expect(snap.breadcrumb.last?.safety == .protected)        // Library/Caches is essential
}
@Test func noAppsIndexMeansNoLeftovers() async throws {
    // same fixture, no setEnvironment: the leftover is `.normal` / `.analysisPending`
}
@Test func nodeAtPath() {
    let t = FileTree(rootName: "r", rootPath: "/r")
    let a = t.addChild(of: 0, name: "a", kind: .directory, allocatedSize: 0)
    let b = t.addChild(of: a, name: "b é", kind: .file, allocatedSize: 1)
    #expect(t.node(atPath: "/r/a/b é") == b && t.node(atPath: "/r") == 0)
    #expect(t.node(atPath: "/r/a/zz") == nil && t.node(atPath: "/other/a") == nil)
}
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.**
- [ ] **Step 4: Run** `swift test` → pass. Measure `snapshot` with verdicts on a treemap of `~/Library` (debug log, release build): report ms; must stay < 20 ms with a warm cache.
- [ ] **Step 5: Commit** — `feat(core): safety verdicts in the store and on chart elements`

---

### Task 6: Suggestions

**Files:** Create `Safety/Suggestions.swift`, `Tests/.../SuggestionsTests.swift`; Modify `Scan/ScanStore.swift`

**Interfaces:**
- Consumes: `verdict(_:)`, `node(atPath:)`, `installerIDs`, `LibraryLocation`, `SafetyTables.developerCaches`.
- Produces:
  - `public enum SuggestionKind: Sendable, CaseIterable { case leftovers, caches, installers }`
  - `public struct SuggestionItem: Sendable, Hashable, Identifiable { id: NodeID; name: String; path: String; size: UInt64; verdict: SafetyVerdict; preselected: Bool }` — `preselected = verdict.level == .safe`.
  - `public struct Suggestion: Sendable, Identifiable { kind: SuggestionKind; items: [SuggestionItem]; total: UInt64 }` — `id = kind`; items sorted by size desc; only items with `size ≥ SafetyRules.suggestionMinSize` and level `.safe` or `.caution`; empty suggestions omitted.
  - `ScanStore.suggestions() -> [Suggestion]` (order: leftovers, caches, installers). Leftovers = children of every `L/<loc>` with reason `.leftover`, `.recentLeftover` or `.leftoverLaunchAgent`. Caches = children of `L/Caches` with reasons `.cacheOfApp`, `.cacheOfRunningApp`, `.appleCache`, plus each existing developer-cache root's node (or its children when the root itself is essential). Installers = `installerIDs` with reason `.installer` (inside-package / protected ones drop out by verdict). Nodes flagged `.removed` are skipped.

A leftover inside `Caches` (unmatched identifier, reason `.leftover`) is listed under **leftovers**, not caches.

- [ ] **Step 1: Failing tests** — fixture home with `Library/Caches/com.spotify.client` (2 MB), `Library/Caches/com.apple.y` (2 MB), `Library/Caches/com.gone.x` (2 MB), `Library/Application Support/com.gone.app` (3 MB, file mtime/atime set 3 years back with `utimes`), `Library/Caches/tiny` (10 KB), `Downloads/A.dmg` (4 MB), `Foo.app/Contents/Resources/inner.pkg` (4 MB); environment whose index holds only the Spotify record of Task 3:

```swift
let s = await store.suggestions()
#expect(s.map(\.kind) == [.leftovers, .caches, .installers])
#expect(Set(s[0].items.map(\.name)) == ["com.gone.app", "com.gone.x"] && s[0].total >= 5_000_000)
#expect(Set(s[1].items.map(\.name)) == ["com.spotify.client", "com.apple.y"])
#expect(s[1].items.first { $0.name == "com.apple.y" }?.preselected == false)
#expect(s[2].items.map(\.name) == ["A.dmg"])   // the pkg inside the bundle is protected
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → pass.
- [ ] **Step 5: Commit** — `feat(core): suggestions for leftovers, caches and installers`

---

### Task 7: System probes — open files, private size, packages, Trash

**Files:** Create `Actions/OpenFiles.swift`, `Actions/PrivateSize.swift`, `Actions/DiskActions.swift`, `Tests/.../OpenFilesTests.swift`, `Tests/.../PrivateSizeTests.swift`; Modify `Scan/DirectoryEntry.swift`, `Scan/DirectoryReader.swift`, `Tests/.../DirectoryReaderTests.swift`

**Interfaces:**
- Produces:
  - `public struct OpenFileSet: Sendable { static func current() -> OpenFileSet; init(paths: [String]); func isOpen(_ path: String) -> Bool; func hasOpen(under directory: String) -> Bool }` — `current()` lists PIDs (`proc_listallpids`), their vnode FDs (`proc_pidinfo(PROC_PIDLISTFDS)` + `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)`); processes it cannot inspect are skipped silently. Paths stored sorted; `hasOpen(under:)` = binary search for the `directory + "/"` prefix.
  - `DirectoryEntry.privateSize: UInt64?` (default nil) and `DirectoryReader.read(path:includePrivateSize: Bool = false)` — with the flag, request `ATTR_CMNEXT_PRIVATESIZE` in `forkattr` (extended common attributes); nil where the volume does not report it. The scan path keeps `includePrivateSize: false` (no cost).
  - `public enum PrivateSize { static func freed(path: String) -> UInt64 }` — what moving `path` would free: a file's `privateSize ?? allocatedSize`, 0 if `linkCount > 1`; a directory's sum over its subtree read with `includePrivateSize: true`, not following symlinks or crossing devices; stops early and returns the partial sum when the task is cancelled.
  - `public protocol PackageProbe: Sendable { func isPackage(_ path: String) -> Bool }`; `SystemPackageProbe` uses `URLResourceValues.isPackage` (LaunchServices; catches package types not in `SafetyTables.packageExtensions`).
  - `public protocol DiskActions: Sendable { func moveToTrash(_ path: String) throws -> String }` (returns the path inside the Trash); `SystemDiskActions` = `FileManager.default.trashItem(at:resultingItemURL:)`. Tests use a `RecordingDiskActions` (in the test target) that records paths and renames into a fixture "trash" folder.

- [ ] **Step 1: Failing tests**

```swift
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
@Test func cloneFreesNothing() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let a = try fx.file("a.bin", bytes: 1_000_000)
    #expect(clonefile(a.path, fx.root.path + "/b.bin", 0) == 0)
    #expect(PrivateSize.freed(path: fx.root.path + "/b.bin") < 100_000)
    #expect(PrivateSize.freed(path: fx.root.path) >= 1_000_000)   // both together free the blocks
}
@Test func hardLinkFreesNothing() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let a = try fx.file("a.bin", bytes: 100_000); try fx.hardLink("b.bin", to: a)
    #expect(PrivateSize.freed(path: a.path) == 0)
}
@Test func privateSizeReadIsOptIn() throws {   // DirectoryReaderTests
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("x", bytes: 10_000)
    #expect(try DirectoryReader.read(path: fx.root.path).allSatisfy { $0.privateSize == nil })
    #expect(try DirectoryReader.read(path: fx.root.path, includePrivateSize: true).first?.privateSize ?? 0 > 0)
}
@Test func systemPackageProbe() { #expect(SystemPackageProbe().isPackage("/System/Applications/Calculator.app")) }
```

(`cloneFreesNothing` note: the directory total counts the shared blocks once only if both clones are inside it — with `privateSize` each clone reports ~0, so the directory sum is ~0. If the test shows that, change the expectation to document it: the confirmation sheet then states "parte dello spazio è condivisa con copie APFS" when `freed < size`. Report which behaviour the volume shows.)

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → pass.
- [ ] **Step 5: Commit** — `feat(core): probes for open files, freed space, packages and the Trash`

---

### Task 8: Trash pipeline and in-place tree update

**Files:** Create `Actions/TrashGuard.swift`, `Actions/TrashOutcome.swift`, `Tests/.../TrashTests.swift`; Modify `Model/FileTree.swift`, `Scan/ScanStore.swift`, `Tests/.../FileTreeTests.swift`

**Interfaces:**
- Consumes: `SafetyRules`, `OpenFileSet`, `PackageProbe`, `DiskActions`, `DirectoryReader.stat`.
- Produces:
  - `FileTree.remove(_ id: NodeID)` — unlinks `id` from its parent's child list, subtracts its size, per-category bytes and per-age bytes from every ancestor, inserts `.removed` on it. Ancestors' `lastUsed` is not lowered (documented). Precondition: not the root, not already removed.
  - `public enum TrashGuard { static func refusal(path: String, home: String) -> String? }` — independent last line, returns why it refuses or nil: path not absolute; contains an empty, `.` or `..` component; is `/`; is `home` or an ancestor of it; is in `SafetyTables.essentialPaths(home:)`; has fewer than 2 components.
  - `public enum TrashSkip: Sendable, Hashable { case missing, changed, protected(SafetyReason), openNow, insidePackage, refused, failed(String) }`
  - `public struct TrashOutcome: Sendable { struct Moved: Sendable, Hashable { node: NodeID; name: String; size: UInt64; trashedPath: String }; struct Skipped: Sendable, Hashable { node: NodeID; name: String; reason: TrashSkip }; var moved: [Moved]; var skipped: [Skipped] }`
  - `ScanStore.topMost(_ ids: Set<NodeID>) -> [NodeID]` — drops ids with a selected ancestor, removed ids and the root; sorted by size desc.
  - `ScanStore.trash(_ ids: Set<NodeID>, actions: any DiskActions, packages: any PackageProbe, openFiles: @Sendable () -> OpenFileSet) -> TrashOutcome` — for each `topMost` id, in order, skipping at the first failing check: (1) `.removed` → `missing`; (2) `TrashGuard.refusal` → `refused`; (3) fresh `SafetyRules.evaluate` (not the cache) → `.protected` ⇒ `protected(reason)`; (4) `DirectoryReader.stat` fails → `missing`; kind differs from the tree's (a folder now a symlink, a file now a folder) → `changed`; (5) any ancestor up to `/` `isPackage` → `insidePackage`; (6) `openFiles()` (called once, right before the loop) `isOpen` / `hasOpen(under:)` → `openNow`; (7) `actions.moveToTrash` throws → `failed(error.localizedDescription)`; success → `tree.remove`, record `Moved`. Clears the verdict cache at the end.

- [ ] **Step 1: Failing tests** — `TrashTests` builds a fixture home, scans it, sets an environment with an empty index, uses `RecordingDiskActions` and a `FakePackageProbe(packages: Set<String>)`:

```swift
@Test func movesAndUpdatesTree() async throws {
    // Library/Caches/com.gone.x (2 MB) → moved; root size drops by its size; categoryTotals agree with a fresh scan
}
@Test func nestedSelectionTrashesTopMostOnce() async throws {
    // select com.gone.x and com.gone.x/sub/file → actions.recorded == [path of com.gone.x]
}
@Test func protectedIsNeverMoved() async throws {
    // select Library, Library/Caches, a node inside Foo.app, the root → all skipped, actions.recorded.isEmpty
}
@Test func missingIsSkipped() async throws { /* remove the file on disk after the scan → .missing */ }
@Test func replacedBySymlinkIsSkipped() async throws { /* replace a scanned folder with a symlink → .changed, target untouched */ }
@Test func openFileIsSkipped() async throws { /* openFiles returns OpenFileSet(paths: [file]) → its folder .openNow */ }
@Test func unlistedPackageAncestorBlocksTrash() async throws { /* FakePackageProbe([home + "/Weird.thing"]) → child .insidePackage */ }
@Test func removedNodeIsSkipped() async throws { /* trash twice with the same id → second time .missing */ }
@Test func guardRefusals() {
    for p in ["relative/x", "/", "/Users", "/Users/u", "/Users/u/Library", "/Users/u/a/../b", "/Users/u//x", "/x"] {
        #expect(TrashGuard.refusal(path: p, home: "/Users/u") != nil)
    }
    #expect(TrashGuard.refusal(path: "/Users/u/Downloads/a.dmg", home: "/Users/u") == nil)
}
@Test func removeKeepsAggregatesConsistent() {   // FileTreeTests
    // build a 3-level tree, remove a middle folder: sizes, categoryTotals, ageTotals of all ancestors
    // equal those of the same tree built without it; children(of:) no longer lists it; flags ∋ .removed
}
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** `swift test` → all pass.
- [ ] **Step 5: Commit** — `feat(core): verified move to Trash with in-place tree update`

---

### Task 9: "Eliminabili" coloring, reasons in tooltip and list, environment

**Files:** Create `App/MacSpace/SafetyEnvironmentProvider.swift`, `App/MacSpace/SafetyText.swift`, `Views/Charts/SafetyDecor.swift`; Modify `ChartSettings.swift`, `ScanModel.swift`, `Style/FusionPalette.swift`, `Layout/ChartPalette.swift` (core) + `ChartPaletteTests.swift`, sunburst/treemap views, `SegmentTooltip.swift`, `BiggestListView.swift`, `ChartLegend.swift`, `ChartAccessibility.swift`, `Localizable.xcstrings`

**Interfaces:**
- Consumes: `SafetyLevel`, `SafetyVerdict`, `Snapshot.verdicts`, `ScanStore.setEnvironment`, `invalidateVerdicts`, `AppsIndex.build`, `SpotlightLastUsed`.
- Produces:
  - `ColorMode.deletable` (raw `"deletable"`, title "Eliminabili") replaces `.neutral` and is the `@AppStorage` default; a stored `"neutral"` falls back to it. Menu order: Eliminabili, Per tipo di file, Per ultimo uso.
  - Core `ChartPalette.safetyFill(_ level: SafetyLevel, scheme:, lift:) -> Contrast.RGB?` (nil for normal/protected = neutral ring) and `ChartPalette.hatch(_ scheme:) -> Contrast.RGB`: safe = `hsl(16,88,57)` (dark: `hsl(16,85,56)`); caution = accent at ~40 % over the surface plus hatch lines (accent, 1.5 pt wide, 45°, every 6 pt). Tests: label ≥ 4.5:1 on both levels incl. lift; caution and safe differ by ≥ 3:1 or by the hatch (state which); hue stays within 14–18°.
  - `SafetyDecor` (shared by both charts): `hatch(in path:)`, `lock(at:)` (SF Symbol `lock.fill`, 9 pt, drawn when the element is ≥ 18 pt in both directions), `selectionOutline(path:)` (Task 10).
  - `SafetyEnvironmentProvider` (`@MainActor @Observable`): at launch builds `AppsIndex.build(extraAppPaths: AppsIndex.spotlightAppPaths())` in a detached `.utility` task; observes `NSWorkspace.didLaunchApplicationNotification` / `didTerminateApplicationNotification`; publishes `environment: SafetyEnvironment` (bundle IDs and `bundleURL` paths of `runningApplications`). `ScanModel.updateEnvironment(_:)` forwards to the store (and to every new store) and refreshes.
  - `ScanModel.verdicts: [NodeID: SafetyVerdict]` from each snapshot; `invalidateVerdicts()` + refresh when a scan ends.
  - `SafetyText`: `SafetyLevel.title` ("Sicuro da eliminare", "Da controllare", "Normale", "Protetto") and `SafetyVerdict.sentence` built from the copy below (`<App>` = owner):

| Reason | Italian copy |
|---|---|
| scanRoot | È la cartella analizzata |
| essentialFolder | Cartella essenziale del Mac o dell'utente |
| insidePackage | Fa parte di un pacchetto: si può spostare solo il pacchetto intero |
| systemLocation | File di sistema protetto da macOS |
| trash | È il Cestino: svuotalo dal Finder |
| appleData | Dati di sistema di Apple: rimuoverli rompe le app |
| photosLibrary | Libreria di Foto: libera spazio da Foto › Impostazioni › «Ottimizza spazio» |
| runningApp | App in esecuzione |
| runningAppData | Dati di <App>, che è in esecuzione |
| notWritable | Non hai i permessi per spostarlo |
| cloudOnly | Solo nel cloud: non occupa spazio su questo Mac |
| cloudSynced | Sincronizzato con <provider>: verrà eliminato anche da <provider> e dagli altri dispositivi. |
| developerCache | Cache per sviluppatori (<name>): si rigenera da sola |
| analysisPending | Analisi delle app in corso… |
| appleCache | Cache di sistema: si rigenera, ma alcuni servizi la usano di continuo |
| cacheOfRunningApp | Cache di <App>, che è in esecuzione: chiudila prima |
| cacheOfApp | Cache di <App>, app non in esecuzione: si rigenera da sola · senza app: Cache: si rigenera da sola |
| leftover | Avanzo di un'app non più installata |
| recentLeftover | Sembra un avanzo, ma è stato usato di recente: forse appartiene a un'app non trovata |
| leftoverLaunchAgent | Avvio automatico di un programma non trovato: controlla prima di rimuoverlo |
| appData | Dati di <App>: rimuoverli azzera documenti o impostazioni |
| installer | File d'installazione · con app: File d'installazione: <App> è già installata |
| notUsedForLong | Non usato da oltre 2 anni (stima) |
| ordinary | — (no sentence) |

Behavior: deletable mode draws safe solid accent, caution soft accent + hatch, normal/protected the plan-1 neutral ring, protected adds the lock where it fits; merged "altri" neutral. Tooltip adds "Sicurezza: <level>", the sentence, "App: <owner>" when known (not for providers/dev caches, which the sentence names); for a file it looks up `SpotlightLastUsed` once per hovered node (off the main actor) and, when found, shows "Ultimo uso: <data>" without "(stimato)". List rows in deletable mode show the level as a dot (solid / hatched / none / lock) plus the sentence on the detail line. Legend in deletable mode: three chips with swatches — "Sicuro da eliminare", "Da controllare", "Protetto" (lock). VoiceOver labels add the level title.

- [ ] **Step 1: Core palette tests** (`ChartPaletteTests`) → FAIL → implement `safetyFill`/`hatch` → pass.
- [ ] **Step 2: Implement the app side**; build → exit 0, no warnings; `Localizable.xcstrings` has every new string, none stale.
- [ ] **Step 3: Verify by running** — scan `~/Library` and a fixture folder with a fake leftover, an installer and a `.app`; check before/after the index is ready (pending → verdicts), both charts, light + dark, hover tooltips, list rows. Screenshots `p3-t9-*` in the scratchpad.
- [ ] **Step 4: Design pass** — `impeccable` critique + `dataviz` + `ui-ux-pro-max` (`--stack swiftui`) on the screenshots: the eye must go to orange first; hatch legible but quiet; lock not noisy. Fix material issues; list findings and actions.
- [ ] **Step 5: Commit** — `feat(app): deletable coloring with safety reasons in tooltip, list and legend`

---

### Task 10: Selection and Suggestions panel

**Files:** Create `Views/Sidebar/SidebarView.swift`, `Views/Sidebar/SuggestionsView.swift`; Modify `ScanModel.swift`, `ContentView.swift`, sunburst/treemap views + pointer layers, `BiggestListView.swift`, `ChartAccessibility.swift`, `Localizable.xcstrings`

**Interfaces:**
- Consumes: `ScanStore.suggestions()`, `topMost(_:)`, `verdicts`, `SafetyDecor.selectionOutline`.
- Produces (`ScanModel`):
  - `selection: Set<NodeID>`, `selectionTotal: UInt64` (sum over `topMost`), `toggleSelection(_ node: NodeID)` — ignores the root, merged elements and nodes whose verdict is protected; selecting a node drops selected descendants; selecting inside a selected folder is a no-op. Cleared when a scan starts.
  - `highlighted: Set<NodeID>` (a clicked suggestion's items), drawn with the same outline in a lighter weight.
  - `suggestions: [Suggestion]`, recomputed when a scan ends, when the environment changes and after each trash.
  - `reveal(_ node: NodeID)` — drills to the node's parent so it is on screen, then hovers it.

Behavior: ⌘-click on a segment/tile toggles selection (plain click still drills). Selected elements: 2 pt outline in primary text color. List rows get a checkbox (hidden for protected rows, which keep the lock). Sidebar = segmented "Elementi" | "Suggerimenti" on top, the current content below, and a selection bar at the bottom whenever `selection` is not empty: "<N> selezionati · <totale>" + "Deseleziona" + "Sposta nel Cestino…" (prominent; disabled while scanning). Suggestions tab: one section per suggestion — title ("Avanzi di app disinstallate", "Cache rigenerabili", "File d'installazione"), total, a one-line explanation, items with checkbox (initial state = `preselected`), name, size, sentence; clicking a section header sets `highlighted` to its items (outlined wherever they are on screen); clicking an item reveals it; the section's "Sposta nel Cestino…" opens the sheet with its checked items. Empty states: "Analizza per vedere i suggerimenti" (no scan), "Nessun suggerimento: qui è tutto in ordine" (none), "Analisi delle app in corso…" (index not ready). Accessibility: action "Seleziona"/"Deseleziona" on chart elements and rows.

- [ ] **Step 1: Implement**; build → exit 0, no warnings.
- [ ] **Step 2: Verify by running** on the fixture: ⌘-click select/deselect in both charts, nested selection rule, protected refuses, suggestions sections and empty states, reveal, selection cleared by a new scan. Screenshots `p3-t10-*`.
- [ ] **Step 3: Design pass** (same three skills) on sidebar, selection bar and suggestions; fix material issues.
- [ ] **Step 4: Commit** — `feat(app): selection and suggestions panel`

---

### Task 11: Confirmation sheet, Trash, result and history

**Files:** Create `Views/Trash/TrashConfirmationSheet.swift`, `Views/Trash/TrashResultView.swift`, `Views/Trash/HistoryPopover.swift`; Modify `ScanModel.swift`, `ContentView.swift`, `SafetyText.swift`, `Localizable.xcstrings`

**Interfaces:**
- Consumes: `ScanStore.topMost`, `trash(_:actions:packages:openFiles:)`, `PrivateSize.freed`, `OpenFileSet.current`, `SystemDiskActions`, `SystemPackageProbe`, `TrashOutcome`.
- Produces (`ScanModel`): `pendingTrash: [NodeID]?` (drives the sheet), `trash(_ ids: [NodeID]) async -> TrashOutcome`, `history: [HistoryEntry]` (`name`, `size`, `date`, `trashedURL`; session only), `lastOutcome: TrashOutcome?`.

Sheet: title "Spostare <N> elementi nel Cestino?"; rows: level dot, name, path (secondary, middle truncation), size; each caution row shows its sentence; cloud rows the sentence verbatim (spec §5.4). On appear, off the main actor: `OpenFileSet.current()` — rows open now are shown dimmed with "Aperto ora in un'app" and left out; `PrivateSize.freed` per row (cancellable when the sheet closes) — footer "Spazio liberato: circa <X>" ("Calcolo…" until done; when `freed < size`: "<size> occupati, parte condivisa con altre copie"). Footnote: "Potrai ripristinarli dal Cestino del Finder." Buttons: "Annulla" (`.cancelAction`) and "Sposta nel Cestino" (`role: .destructive`, **not** the default action, disabled while computing the open-files check or when no row is left). Then `ScanModel.trash` → result sheet: "<N> elementi spostati nel Cestino · liberati circa <X>"; skipped rows with name and `TrashSkip` text ("Non esiste più", "È cambiato dopo l'analisi", "Ora è protetto: <sentence>", "Aperto ora in un'app", "Rifiutato per sicurezza", "Errore: <msg>"); refresh views and suggestions; selection minus moved items. Toolbar "Cronologia" (`clock.arrow.circlepath`, shown when history is not empty) → popover listing entries (name, size, time) with "Mostra nel Cestino" (`NSWorkspace.shared.activateFileViewerSelecting`).

- [ ] **Step 1: Implement**; build → exit 0, no warnings.
- [ ] **Step 2: Verify by running** — **only on a throwaway fixture folder** (`~/MacSpace-p3-fixture` with a fake leftover, an installer, an APFS clone, a file held open by `tail -f`, a `.app`): sheet contents, open file excluded, clone freed ≈ 0, move, result, history, "Mostra nel Cestino", Finder "Rimetti al suo posto" restores one item; rescan matches the in-place update. Remove the fixture and its Trash entries afterwards. Screenshots `p3-t11-*`.
- [ ] **Step 3: Design pass** on sheet, result and history; fix material issues.
- [ ] **Step 4: Commit** — `feat(app): confirmation sheet, move to Trash, result and history`

---

### Task 12: Security review and final verification

**Files:** only fixes found here.

- [ ] **Step 1: Security review** — run `security-review` over the branch diff with this brief: every path to `DiskActions.moveToTrash`; can a protected, essential, bundle-interior, open or changed item reach it; TOCTOU between check and move (document the residual window: `trashItem` is a rename, the item is re-checked just before); symlink handling; path building from the name arena (NFD, newlines, `/` in names impossible). Fix every material finding with a test.
- [ ] **Step 2: Rules audit on the owner's disk** — debug-only helper (not committed) that scans `~/Library` with the real environment and prints every `.safe` item ≥ 10 MB with its reason and owner; review it with the owner before marking the task done; any false positive becomes a rule fix with a test.
- [ ] **Step 3: Benchmark** — `MACSPACE_BENCH=1 swift test -c release --filter startupDiskScan`: duration ≤ Task 1 baseline × 1.05, B/file ≤ 333.
- [ ] **Step 4: Full test run** — `swift test` all pass; app build no warnings; `git status` clean of debug hooks.
- [ ] **Step 5: Owner check** — do NOT mark done until the controller has asked the owner to try the Suggestions panel and one real move to Trash + "Rimetti al suo posto" of their choice, and confirm (controller handles this; implementer reports readiness).
- [ ] **Step 6: Commit** any fixes — `fix: security review findings for plan 3`
