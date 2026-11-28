# Snapshot and Incremental Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Save the scanned tree when a scan ends. Show it at once on the next launch, then rebuild it through the normal scan, reading the disk only where the FSEvents history says something changed.

**Architecture:**
- **Core.** A `SavedScan` value captures a `ScanStore`'s tree and side tables.
  - A restored store is browsable, and `trash` refuses on it.
  - A refresh is an ordinary `Scanner.scan` into a fresh store. Its reader returns the saved listing for every folder the history vouches for whose identity still matches, and reads the disk for the rest.
- **App.** `ScanModel` shows a restored store at once and runs the refresh, or a full scan, into a hidden store. When that ends, it swaps the stores, carrying the center and the selection over by path.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing, CryptoKit (SHA-256), XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-28-snapshot-refresh-design.md` (issue #33)

## Global Constraints

- **Snapshot folder:** `~/Library/Caches/com.massilp.macspace/Snapshots/`.
  - Files: `startup-disk.snapshot` and `folder.snapshot`.
  - Writes are atomic: write to a temporary file in the same folder, then rename.
- **Kept:** the startup disk's snapshot always, plus the last folder's. The target used last is reopened at launch.
- **The Trash on snapshot data:** never. A restored store refuses `trash` and `trashPreview` (`.scanInProgress`) until a scan or refresh of a new store has finished and been swapped in.
- **Full scan instead of a refresh** when any of these holds:
  - the snapshot is older than **7 days** (`7 * 86_400` s, against its scan start);
  - the root's inode differs;
  - Full Disk Access was granted then and is missing now;
  - the saved baseline is nil;
  - the history answers `.untrusted` for the root.
- **History timeouts:** the refresh's history query waits up to **30 s**. `trash` keeps **5 s**.
- **A snapshot that fails validation** (magic, version, checksum, truncation, an index out of range) gives "no snapshot", is deleted, and never crashes.
- **Performance targets** (main spec §7), measured on the owner's disk and reported in the PR:
  - showing a snapshot: < 1 s for about 3 M files;
  - memory: report bytes per file before and after;
  - the two-tree peak: if it exceeds about 1.5 GB, say so before the PR and do not work around it.
- **Copy** (Italian, `App/MacSpace/Resources/Localizable.xcstrings`, edited by hand):
  - "Aggiornato a %@ · Aggiornamento in corso…"
  - "Aggiornato a %@ · Analisi completa in corso…"
  - "Aggiornato a %@" (after a cancel)
  - "Aggiornamento in corso…" (reason the Trash is unavailable)
  - "Analisi completa" (File menu)
- Commits carry no attribution or co-author lines. Never commit `Local.xcconfig`. Leave `docs/macspace-audit.md` and `.impeccable/` alone.

## Review Focus

1. **A folder replaced by another at the same path** (`rm -r A; mv B A`; only the parent reports a change). The new A must be read from disk, never from A's old listing. Test: `refreshReadsReplacedFolderFromDisk` (Task 4).
2. **A corrupt, truncated or foreign snapshot.** No crash, the file is deleted, and the app falls back to a full scan. Tests: `decodingRejectsDamage` (Task 2) and `loadDeletesInvalidAndForeign` (Task 5).
3. **A restored store asked to move something** (a Trash request racing the refresh). It refuses with `.scanInProgress`. Test: `restoredStoreRefusesTrash` (Task 1).
4. **Ages after a week.** A snapshot taken earlier, then shown now, measures ages from now. Test: `restoredAgesMeasureFromNow` (Task 1).
5. **A refresh that is cancelled.** Nothing is saved, the old snapshot stays on disk and on screen, and the Trash stays disabled. Covered by the live test (Task 6, step 4), since the app target has no unit tests.

---

### Task 1: Core: capture and restore a store (`SavedScan`, in memory)

**Files:**
- Create: `MacSpaceCore/Sources/MacSpaceCore/Snapshot/SavedScan.swift`
- Modify:
  - `MacSpaceCore/Sources/MacSpaceCore/Model/FileTree.swift`: add a per-directory device table, `saved()`, and `init(saved:now:)`.
  - `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore.swift`: `insert` records directory devices; `markScanStarted` records the root's device; add `savedScan(...)` and `init(saved:...)`.
  - `MacSpaceCore/Sources/MacSpaceCore/Scan/Scanner.swift`: pass the root's device to `markScanStarted`.
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/SavedScanTests.swift`

**Interfaces:**
- Produces:

```swift
public struct SavedScan: Sendable {
    public enum Target: Sendable, Equatable { case startupDisk, folder(path: String) }
    public var target: Target
    public var rootPath: String
    public var rootInode: UInt64
    /// Wall clock at scan start, seconds since 1970.
    public var startedAt: UInt32
    public var baseline: ChangeBaseline?
    public var hadFullDiskAccess: Bool
    // Internal: the tree's arrays (FileTree storage), the directory device table,
    // and the store's side tables (hardLinks, countedLink, installerIDs, unverifiedDirectories, scanDevices).
}
extension ScanStore {
    /// The finished scan as saved; call after `markScanFinished` and before any `trash`.
    public func savedScan(target: SavedScan.Target, startedAt: UInt32, hadFullDiskAccess: Bool) -> SavedScan
    /// A store showing `saved`: browsable and judged, `trash`/`trashPreview` refuse (`scanFinished` stays false).
    public init(saved: SavedScan, home: String = NSHomeDirectory(),
                now: UInt32 = UInt32(clamping: Int64(Date().timeIntervalSince1970)),
                history: any ChangeHistory = SystemChangeHistory())
    /// The directory `id`'s device as listed (its own entry's device; the root's from `markScanStarted`).
    func device(ofDirectory id: NodeID) -> Int32
}
public func markScanStarted(rootInode: UInt64, rootDevice: Int32 = 0, baseline: ChangeBaseline?)
```

- Decisions:
  - **Device table.** The directory device table is indexed by directory slot (`dirSlots`), not per node. A file's device is its parent directory's device.
  - **What is copied.** `saved()` copies the arrays (copy-on-write, so the copy costs nothing until either side writes).
  - **What `init(saved:now:)` recomputes.** It recomputes `ageBytes` against the new `now` from each file's `lastUsedStore` and `sizes`, bottom-up in reverse ID order (children always have larger IDs). It keeps the other derived tables as saved.
  - **Restored root.** `scanFinished` stays false, and `changeBaseline` is the saved one.

- [ ] **Step 1: Write the failing tests**
  - `savedScanRoundTripsTheTree`:
    - Fixture:
      - `a/f` (100 B);
      - `a/h` plus `b/h2`, hard-linked;
      - `s`, a symlink to `a`;
      - `x.dmg`;
      - `pkg.app/Contents/MacOS/bin`;
      - `locked/`, chmod 000;
      - a listing made partial by an injected reader.
    - Scan, then `ScanStore(saved: store.savedScan(...), now: sameNow)`.
    - Every path's `row` is equal: name, size, kind, flags, category, lastUsed, ageBucket.
    - `categoryTotals` and `ageTotals` of the root and of `a` are equal.
    - `installerCount()` is equal.
    - `unverifiedDirectories` and `hardLinks` are equal, compared by path.
  - `restoredAgesMeasureFromNow`:
    - Save with the tree's `now = T`, a file's last use `T - 10` days.
    - Restore with `now = T + 300` days.
    - The file's `ageBucket` equals what `AgeBucket(lastUsed:now: T + 300 days)` gives, and the root's `ageTotals` moves with it.
  - `restoredStoreRefusesTrash`:
    - `trash([a])` gives `skipped == [.scanInProgress]` with `RecordingDiskActions` untouched.
    - `trashPreview([a])` gives `[a: .scanInProgress]`.
  - `directoryDevicesAreRecorded`:
    - After a scan of a fixture, `device(ofDirectory:)` of the root and of `a` equals `DirectoryReader.stat` of each.
    - The same holds after a round trip.

- [ ] **Step 2: Run and see them fail**

Run: `cd MacSpaceCore && swift test --filter SavedScanTests 2>&1 | tail -5`
Expected: compile error (`SavedScan` missing).

- [ ] **Step 3: Implement** the types and members above.

- [ ] **Step 4: Run the full suite, and measure memory**

Run: `cd MacSpaceCore && swift test 2>&1 | tail -3`
Expected: all pass (384 + 4).

Then measure bytes per file the way part 1 did (`Perf.swift` / the memory probe used for the 166 B/file figure), before and after this task. Record both numbers in the ledger. The expected rise is under 1 B/file, since the table is per directory.

- [ ] **Step 5: Commit**

```bash
git add MacSpaceCore
git commit -m "feat(core): SavedScan: capture a finished store and restore it, browsable but not movable"
```

---

### Task 2: Core: encode and decode a `SavedScan`

**Files:**
- Create: `MacSpaceCore/Sources/MacSpaceCore/Snapshot/SavedScanCoding.swift`
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/SavedScanCodingTests.swift`

**Interfaces:**
- Consumes: `SavedScan` (Task 1).
- Produces:

```swift
public enum SavedScanError: Error, Equatable { case notASnapshot, unsupportedVersion(UInt32), damaged }
extension SavedScan {
    public static let formatVersion: UInt32 = 1
    public func encoded() -> Data
    public init(decoding data: Data) throws(SavedScanError)
}
```

- Decisions:
  - **Layout.** The file starts with the magic `"MSPSNAP\0"` (8 bytes), then `formatVersion`, then the header fields, then the body.
  - **Body.** Each array is written as a little-endian count followed by its raw bytes. The arrays are POD, so no per-element encoding is needed.
  - **Checksum.** The last 32 bytes are the SHA-256 of everything before them.
  - **Decoding.** It checks the magic, the version and the checksum, then the structure:
    - every array of per-node data has `count` entries;
    - `parents[i] < i`, except for the root at -1;
    - `nameEnds` never decrease and end at the arena size;
    - every slot index is in range;
    - side-table IDs are in range.

    Any failure throws, and nothing traps.

- [ ] **Step 1: Write the failing tests**
  - `codingRoundTrips`: `SavedScan(decoding: s.encoded())` restores a store equal to the one restored from `s`, checked as in `savedScanRoundTripsTheTree`. The header fields (target, root path, root inode, startedAt, baseline, hadFullDiskAccess) are equal.
  - `decodingRejectsDamage`:
    - a different magic gives `.notASnapshot`;
    - version 2 gives `.unsupportedVersion(2)`;
    - one flipped byte in the body gives `.damaged`;
    - truncation at 10 offsets gives `.damaged` or `.notASnapshot`, and never traps;
    - `Data()` gives `.notASnapshot`;
    - a valid checksum over a body whose `parents[1] = 5` gives `.damaged`. The test rebuilds the checksum to reach the structural check.

- [ ] **Step 2: Run and see them fail.** Run: `cd MacSpaceCore && swift test --filter SavedScanCodingTests 2>&1 | tail -5`. Expected: compile error.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite.** Run: `cd MacSpaceCore && swift test 2>&1 | tail -3`. Expected: all pass.
- [ ] **Step 5: Commit**

```bash
git add MacSpaceCore
git commit -m "feat(core): SavedScan binary format with SHA-256 and structural validation"
```

---

### Task 3: Core: the scanner tells the reader which folder it expects

**Files:**
- Modify:
  - `MacSpaceCore/Sources/MacSpaceCore/Scan/Scanner.swift`: a reader that takes a `DirectoryRequest`.
  - `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore.swift`: `Inserted.descend` carries device and inode.
- Test: add to `MacSpaceCore/Tests/MacSpaceCoreTests/ScannerTests.swift` (or the file holding the injected-reader tests).

**Interfaces:**
- Produces:

```swift
/// A folder the scanner is about to list, as its parent's listing named it.
public struct DirectoryRequest: Sendable, Equatable {
    public var path: String
    public var device: Int32
    public var inode: UInt64
}
public typealias ListingReader = @Sendable (DirectoryRequest) throws(DirectoryReadError) -> DirectoryListing
// Scanner: `init(rootPath:boundary:maxConcurrency:listing: ListingReader)`, public.
// The existing path-only `reader` init stays (it wraps). The root's request carries its stat.
// ScanStore.Inserted.descend: [(id: NodeID, path: String, device: Int32, inode: UInt64)]
```

- [ ] **Step 1: Write the failing test**
  - `readerIsToldTheExpectedFolder`:
    - Fixture `a/b/f`.
    - A recording `ListingReader` that delegates to `DirectoryReader.read`.
    - The requests for root, `a` and `a/b` carry `DirectoryReader.stat`'s device and inode for each path.
- [ ] **Step 2: Run and see it fail.** Run: `cd MacSpaceCore && swift test --filter readerIsToldTheExpectedFolder 2>&1 | tail -5`. Expected: compile error.
- [ ] **Step 3: Implement.** Adapt existing call sites of `descend` (tests and `Scanner.process`) to the wider tuple.
- [ ] **Step 4: Run the full suite.** Run: `cd MacSpaceCore && swift test 2>&1 | tail -3`. Expected: all pass, with no existing test's behavior changed.
- [ ] **Step 5: Commit**

```bash
git add MacSpaceCore
git commit -m "feat(core): the scanner hands its reader the folder's expected device and inode"
```

---

### Task 4: Core: refresh plan and the saved-listing reader

**Files:**
- Create: `MacSpaceCore/Sources/MacSpaceCore/Snapshot/Refresh.swift`
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/ChangeHistory.swift`: add a public `init(timeout: DispatchTimeInterval)` on `SystemChangeHistory`.
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/RefreshTests.swift`

**Interfaces:**
- Consumes: `SavedScan` (Tasks 1–2), `DirectoryRequest` / `ListingReader` (Task 3).
- Produces:

```swift
public enum RefreshPlan: Sendable, Equatable {
    /// Folders whose entries may have changed since the snapshot (paths in the tree's spelling).
    case incremental(changed: Set<String>)
    case fullScan(FullScanReason)
}
public enum FullScanReason: Sendable, Equatable {
    case tooOld, rootReplaced, fullDiskAccessLost, noBaseline, historyUntrusted
}
extension SavedScan {
    public static let maxRefreshAge: UInt32 = 7 * 86_400
    /// One history query, at most; reasons are checked in the order of `FullScanReason`.
    public func refreshPlan(now: UInt32, rootInode: UInt64, hasFullDiskAccess: Bool,
                            history: any ChangeHistory) -> RefreshPlan
    /// The reader for an incremental refresh: the saved listing for a folder that is not in `changed`,
    /// is in the snapshot with the request's device and inode, and was neither unreadable nor
    /// unverified there; `disk` otherwise.
    public func listingReader(changed: Set<String>,
                              disk: @escaping ListingReader = { try DirectoryReader.read(path: $0.path) }) -> ListingReader
}
// SystemChangeHistory: public init(timeout: DispatchTimeInterval); `init()` keeps 5 s.
```

- Decisions:
  - **A saved listing** is rebuilt as `DirectoryEntry` values, with:
    - the saved allocated size; for a `.hardLinkDuplicate`, the counted link's size;
    - `linkCount` 2 for a node in `hardLinks`, 1 otherwise;
    - `device`: its own entry's device for a directory, the folder's device for anything else;
    - `isMountPoint` and `isDataless` from the flags;
    - `modificationTime = lastUsed`, `accessTime = 0`.

    Then `isComplete: true`.
  - **Thread safety.** The reader is `@Sendable` and reads only the immutable `SavedScan`. Looking a folder up by path must not walk the root once per folder for every folder; how it does so is the builder's choice. Measure on the owner's disk in Task 6.

- [ ] **Step 1: Write the failing tests.** Fixtures scan with `maxConcurrency: 1`. "Equal" means every path's row, the root's totals and `installerCount` match those of a fresh full scan.
  - `refreshEqualsRescan`:
    - After saving:
      - add `a/new.txt`;
      - remove `a/f`;
      - grow `b/g`;
      - add `c/d/e.txt`;
      - rename `r` to `r2`.
    - `FakeChangeHistory(answer: .folders([a, b, root]))`.
    - Refresh with `listingReader(changed:)` wrapped by a spy on `disk`.
    - The refreshed tree is equal to a full scan.
    - The disk was asked for exactly `{root, a, b, c, c/d, r2}` plus none of the unchanged folders.
  - `refreshReadsReplacedFolderFromDisk` (Review Focus 1):
    - Save with `A/old.txt`.
    - Then `rm -r A; mv B A`, where B holds `New.photoslibrary/x`.
    - History `.folders([root])`.
    - `A` is read from disk, its row's children are B's, and `trashPreview([A]) == [A: .containsProtected(.photosLibrary)]` after `markScanFinished`.
  - `refreshRereadsUnreadableAndPartial`: a folder unreadable in the snapshot (chmod 000, then 755 before the refresh), and one partial there, are read from disk with history `.folders([])`.
  - `planFallsBack`: one case per `FullScanReason`, each with everything else valid.
    - The cases:
      - `now = startedAt + maxRefreshAge + 1`;
      - another root inode;
      - `hadFullDiskAccess: true` with `hasFullDiskAccess: false`;
      - a `nil` baseline;
      - `FakeChangeHistory(answer: .untrusted)`.
    - Plus `planIsIncremental`, which returns the history's folders, and checks that `hadFullDiskAccess: false` with `hasFullDiskAccess: true` stays incremental.
  - `hardLinkAddedSinceSnapshotIsCountedAgain` (documented residual):
    - Save with `a/f` (single link).
    - Add the hard link `b/l` to it.
    - History `.folders([b])`.
    - The refreshed root size is `size(f) * 2`, while a full scan gives `size(f)`.
  - `trashAfterRefreshUsesItsBaseline`:
    - Refresh (incremental).
    - `markScanFinished`.
    - Create `a/sub/New.photoslibrary/x`.
    - With a history whose `answer` names `a/sub`, `trash([a])` skips `.containsProtected(.photosLibrary)`.
- [ ] **Step 2: Run and see them fail.** Run: `cd MacSpaceCore && swift test --filter RefreshTests 2>&1 | tail -5`. Expected: compile error.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the full suite.** Run: `cd MacSpaceCore && swift test 2>&1 | tail -3`. Expected: all pass.
- [ ] **Step 5: Commit**

```bash
git add MacSpaceCore
git commit -m "feat(core): incremental refresh: plan from the history, saved listings where nothing changed"
```

---

### Task 5: Core: the snapshot folder

**Files:**
- Create: `MacSpaceCore/Sources/MacSpaceCore/Snapshot/SnapshotFolder.swift`
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/SnapshotFolderTests.swift`

**Interfaces:**
- Consumes: `SavedScan` and its coding (Tasks 1–2).
- Produces:

```swift
public struct SnapshotFolder: Sendable {
    /// `~/Library/Caches/com.massilp.macspace/Snapshots/`.
    public static let standard: SnapshotFolder
    public init(url: URL)
    /// Writes atomically; a `.startupDisk` target replaces `startup-disk.snapshot`, a `.folder` one `folder.snapshot`.
    public func save(_ saved: SavedScan) throws
    /// The snapshot for `target`, or nil: missing, invalid (then deleted), or saved for another target
    /// (a `folder.snapshot` of another path: deleted).
    public func load(_ target: SavedScan.Target) -> SavedScan?
    /// Deletes the folder snapshot (the remembered folder no longer exists).
    public func forgetFolder()
}
```

- [ ] **Step 1: Write the failing tests** (in a `Fixture` folder):
  - `saveThenLoad`: one disk snapshot and one folder snapshot, both round trip.
  - Saving another folder replaces `folder.snapshot`.
  - `loadDeletesInvalidAndForeign` (Review Focus 2):
    - a file of random bytes gives nil and is deleted;
    - a valid folder snapshot loaded for another path gives nil and is deleted;
    - a missing file gives nil.
  - `saveIsAtomic`: after `save`, no temporary file is left in the folder.
- [ ] **Step 2: Run and see them fail.** Run: `cd MacSpaceCore && swift test --filter SnapshotFolderTests 2>&1 | tail -5`. Expected: compile error.
- [ ] **Step 3: Implement.** Create the folder on first save. Use `Data.write(to:options: .atomic)`.
- [ ] **Step 4: Run the full suite.** Run: `cd MacSpaceCore && swift test 2>&1 | tail -3`. Expected: all pass.
- [ ] **Step 5: Commit**

```bash
git add MacSpaceCore
git commit -m "feat(core): SnapshotFolder keeps the startup disk's and the last folder's snapshots"
```

---

### Task 6: App: show, refresh, swap

**Files:**
- Modify:
  - `App/MacSpace/ScanModel.swift`:
    - opening a target;
    - the hidden scan;
    - the swap;
    - saving;
    - the shown-snapshot state.
  - `App/MacSpace/ScanModel+Selection.swift`: `trashUnavailableReason`.
  - `App/MacSpace/Views/ContentView.swift`:
    - opening at launch and on a target change;
    - "Analizza";
    - the remembered target;
    - the status facts.
  - `App/MacSpace/MacSpaceApp.swift`: a "Analisi completa" command in the File menu (`CommandGroup(after: .newItem)`), through a focused value as `GoCommands` does.
  - `App/MacSpace/Resources/Localizable.xcstrings`: the five strings in Global Constraints.

**Interfaces:**
- Consumes everything from Tasks 1–5.
- Produces, on `ScanModel`:

```swift
/// When the shown store is a restored snapshot: its scan start; nil once a scanned store is shown.
private(set) var shownSnapshotDate: Date?
enum Update { case refresh, fullScan }
/// The hidden scan running behind a shown snapshot, if any.
private(set) var update: Update?
/// Shows `target`'s snapshot if there is a valid one, then refreshes or fully scans it; without one,
/// a full scan as today (growing tree on screen).
func open(_ target: ScanTarget)
/// Always a full scan; with a snapshot on screen it stays shown until the scan ends.
func fullScan(_ target: ScanTarget)
```

**Behavior:**
1. **Remembered target.** `UserDefaults` key `"lastScanTarget"` holds `"startupDisk"` or a folder path.
   - At launch, `ContentView` restores `target` from it. A folder that no longer exists becomes `.startupDisk`, and `SnapshotFolder.standard.forgetFolder()` is called.
   - Then `model.open(target)` runs, only when that target has a snapshot. Otherwise the app waits for "Analizza", as today.
   - Picking a target calls `open`. The remembered target is written whenever `target` changes.
2. **`open` with a snapshot.**
   - The restored store is installed with the same reset `run` does today. Factor that reset into one `install(_ store:)` used by both.
   - `shownSnapshotDate` is set, and `phase` stays `.done`-like for the facts.
   - Then `refreshPlan`:
     - `.incremental` runs `Scanner(…, listing: saved.listingReader(changed:))` into a new hidden `ScanStore`;
     - `.fullScan` runs the plain scanner into a hidden store and logs its reason (`os.Logger`, category "snapshot").
   - The history passed in is `SystemChangeHistory(timeout: .seconds(30))`.
3. **When the hidden scan ends uncancelled:**
   - `install` the new store, carrying `center` and `selection` over by path (`store.path(of:)` → `node(atPath:)`), and dropping anything not found;
   - clear `shownSnapshotDate`;
   - judge, refresh the views and the suggestions, as `run` does after a scan;
   - capture `savedScan(...)` **before** setting `scanSettled`, then write it with `SnapshotFolder.standard.save` off the main actor.
4. **When it is cancelled** ("Interrompi"): the snapshot stays, with `update = nil`, and nothing is saved.
5. **"Analizza"** with a snapshot shown calls `open`, which refreshes. **"Analisi completa"** calls `fullScan`. Without a snapshot, both behave as today and save at the end. A full scan from today's path also saves when it ends uncancelled.
6. **Status facts while `shownSnapshotDate != nil`:**
   - with `update == .refresh`: "Aggiornato a <date> · Aggiornamento in corso…";
   - with `.fullScan`: "Aggiornato a <date> · Analisi completa in corso…", plus the startup disk's progress bar from the hidden scan's `ScanProgress`, or the small spinner for a folder;
   - with no update: "Aggiornato a <date>".
   - The date uses `.dateTime.day().month(.abbreviated).hour().minute()`.
7. **The Trash.** `trashUnavailableReason` returns "Aggiornamento in corso…" while `shownSnapshotDate != nil`.
   - The button and the suggestions' move stay disabled with it.
   - The store refuses anyway (Task 1).
8. **"Interrompi"** shows while `update != nil`, and "Analizza" otherwise.

- [ ] **Step 1: Implement 1–8.**
- [ ] **Step 2: Build.**
  - Run: `xcodegen generate && xcodebuild -project MacSpace.xcodeproj -scheme MacSpace -configuration Debug -derivedDataPath build/dd33 build 2>&1 | grep -E "warning:|error:|BUILD" | grep -v appintents | tail -5`
  - Expected: `** BUILD SUCCEEDED **`, with no new warnings.
- [ ] **Step 3: Measure on the owner's disk** (record in the ledger and the PR):
  - the snapshot file's size;
  - the time from launch to the chart drawn from the snapshot (target < 1 s);
  - the refresh's duration and how many folders it read from disk;
  - the peak resident memory during the refresh;
  - bytes per file.
- [ ] **Step 4: Live test with the owner.** Follow the GUI rules:
  - back up and restore the `com.massilp.macspace` defaults;
  - launch with `open -n -g`;
  - quit only our PID;
  - send no synthetic input.

  Steps:
  1. Full scan of the startup disk, then quit. Relaunch: the chart appears at once with "Aggiornato a …", the Trash is disabled, and after the refresh the label goes and the Trash is enabled.
  2. Quit, create `~/MacSpace-Prova/a/new.bin` (10 MB), relaunch. After the refresh, `~/MacSpace-Prova` shows the new file.
  3. Pick a folder, then the disk again: the disk's snapshot shows at once.
  4. Start "Analisi completa" and press "Interrompi": the snapshot stays, labelled "Aggiornato a …". The Trash is disabled, and the snapshot file's modification date is unchanged.
  5. Corrupt `startup-disk.snapshot` (append a byte) and relaunch: no crash, no snapshot shown, and the file is gone.
- [ ] **Step 5: Commit**

```bash
git add App/MacSpace
git commit -m "feat: reopen the last target from its snapshot and refresh only what changed"
```
