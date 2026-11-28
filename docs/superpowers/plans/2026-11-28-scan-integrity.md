# Scan Integrity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** what `ScanStore.trash` moves is what the user saw and confirmed, and sizes stay right after a move.

**Architecture:**
- The tree gains per-node inodes. Step 7 of `trash` compares them.
- A sparse hard-link map moves bytes to a remaining link.
- A new `ChangeHistory` (FSEvents) records a baseline at scan start. At trash time it reports which folders changed. The store re-lists those folders, and judges any new on-disk content with the scan's own classification and `SafetyRules`, in a scratch tree.
- Everything stays inside the one synchronous `trash` actor call (ruling R41).

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, CoreServices FSEvents, Darwin `getattrlistbulk` (existing `DirectoryReader`), SwiftUI app with a hand-edited `Localizable.xcstrings` (source language "it").

**Spec:** `docs/superpowers/specs/2026-11-28-scan-integrity-design.md` (issue #27). Branch `feat/27-scan-integrity`.

## Global Constraints

- No check may fail open: anything that cannot be verified is skipped (`.containsUnverified` or `.changed`), never moved.
- The check and the moves stay in one `ScanStore.trash` actor call. No `await` may be added inside it.
- Content-check budget: 10 s per `trash` call. Items not yet judged → `.containsUnverified`.
- Memory: ≤ 200 B/file peak on the startup-disk benchmark (it was 169 B/file at the end of plan 3).
- Copy (Italian, exact):
  - "Verifica dei contenuti e spostamento…" (after 0.5 s);
  - "1 cartella letta in parte";
  - "%lld cartelle lette in parte";
  - "1 letta in parte";
  - "%lld lette in parte".
- `Localizable.xcstrings` is edited by hand: empty entries `"key" : {\n\n    },`, sorted case-insensitively.
- No new permissions. Never commit `Local.xcconfig`. Never touch `docs/macspace-audit.md`. No attribution lines in commits.
- Test command: `cd MacSpaceCore && swift test 2>&1 | tail -5` (341 tests pass at start). App build: `xcodebuild -project MacSpace.xcodeproj -scheme MacSpace -configuration Debug -derivedDataPath build/dd27 build 2>&1 | tail -3`, after `xcodegen generate`.

## Review Focus

1. **Symlinked paths.** Item paths under `/var/folders` (real path `/private/var/...`), as in every test fixture: FSEvents reports real paths, yet changes must still map back to the tree's paths. Pinned by the live tests in Task 3, which run in the temporary directory.
2. **A changed folder that cannot be re-listed** (permission denied) must give `.containsUnverified`. One that is gone (not found) is fine. Pinned in Task 4.
3. **A file added directly in the item**, where the event path equals the item path, must be judged. Pinned in Task 4.
4. **Both links of a hard-linked file inside the moved folder:** no reattribution, and `Moved.size` is the full freed size. Pinned in Task 2.
5. **A hand-filled store** with no baseline, as in some existing tests, must fall back to the full walk and still give the same outcomes on an unchanged fixture. Pinned by the existing `TrashTests` staying green in Task 4.

---

### Task 1: Item identity (SEC-01) and the memory measurement

**Files:**
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Model/FileTree.swift` (new `inodes` column, `addChild` parameter, `inode(_:)`, `setInode(_:for:)`)
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore.swift` (`insert` passes `entry.inode`)
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/Scanner.swift` (records the root's inode at scan start)
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore+Trash.swift` (step 7 compares inodes)
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/TrashTests.swift`, `FileTreeTests.swift`

**Interfaces:**
- Produces:
  - `FileTree.addChild(of:name:kind:allocatedSize:flags:category:lastUsed:inode: UInt64 = 0)`;
  - `FileTree.inode(_ id: NodeID) -> UInt64` (0 = unknown);
  - `FileTree.setInode(_ inode: UInt64, for id: NodeID)`;
  - `ScanStore.markScanStarted(rootInode: UInt64)`, which Task 4 extends to also take the change baseline.
  Task 4 relies on `tree.inode(id)` to tell an unchanged entry from a replaced one.

- [ ] **Step 1: Write the failing tests**

In `TrashTests.swift`, each test uses `scanned(fx)` and then changes the fixture on disk:
- `replacedSameNameFolderIsChanged`: create `a/x.bin`, scan, then remove `a` and recreate `a/x.bin` (new inode). `trash([a])` → skipped `.changed`. The new folder still exists.
- `replacedAncestorIsChanged`: create `p/a/x.bin`, scan, then rename `p` to `p-old` and create a fresh `p/a/x.bin`. `trash([a])` → `.changed`. Both copies still exist.
- `unknownInodeIsNotCompared`: for a hand-filled node with inode 0 (as from `addChild` without an inode), step 7 does not compare inodes, and the item moves. This keeps hand-built tests and the root of hand-filled stores working.

In `FileTreeTests.swift`, `inodeRoundTrips`: `addChild(…, inode: 42)` → `inode(id) == 42`; the root → 0 until `setInode`.

- [ ] **Step 2: Run them and see them fail**

Run: `cd MacSpaceCore && swift test --filter "replacedSameNameFolderIsChanged|replacedAncestorIsChanged|unknownInodeIsNotCompared|inodeRoundTrips" 2>&1 | tail -15`
Expected: compile error (no `inode:` parameter), then, once it compiles, the two `replaced…` tests FAIL (the item moves).

- [ ] **Step 3: Implement**

- `FileTree`: a `ContiguousArray<UInt64>` column; the root's entry is 0.
- `ScanStore.insert`: passes `entry.inode`.
- `Scanner.scan`: before the first read, stats `rootPath` with `DirectoryReader.stat` and calls `await store.markScanStarted(rootInode:)`. Pass 0 if the stat fails; the root then gets no inode check, and the scan marks it unreadable anyway.
- Step 7 of `trashBlocker`: the item's fresh `entry.inode` must equal `tree.inode(id)` when that is non-zero. In the ancestor loop, each ancestor's stat must be a directory and, when its stored inode is non-zero, the same inode. Otherwise → `.changed`.
- Update the S3 note in the `trash` doc comment: the identity is now checked by inode too, and only the window between that check and the rename remains.

- [ ] **Step 4: Run the full suite**

Run: `cd MacSpaceCore && swift test 2>&1 | tail -5`
Expected: all pass (341 + 4).

- [ ] **Step 5: Measure memory, and bisect the earlier rise**

Run: `cd MacSpaceCore && MACSPACE_BENCH=1 swift test -c release --filter startupDiskScan 2>&1 | grep BENCH`
Expected: `peakBytesPerFile` ≤ 200.

- Record the figure. Also measure `main` with the same command, in a temporary worktree (`git worktree add ../macspace-bench main`).
- If `main` is above about 140 B/file, bisect the plan-3 range `a6ded90..70714a1` with the same command, at most 6 runs, and name the commit that raised it.
- If the cause is small and local (for example a missing `reserveCapacity` or a duplicated array), fix it in this task with its own commit.
- Otherwise open an issue: `GH_TOKEN=$(gh auth token --user massilp) gh issue create`, titled "Scan memory rose from ~131 to 169 B/file in plan 3", with the bisect result.
- Remove the worktree afterwards.
- Keep the figures for the PR body.

- [ ] **Step 6: Commit**

```bash
git add MacSpaceCore
git commit -m "fix(core): skip an item the scan did not see as the same object (inode check)"
```

---

### Task 2: Hard-link reattribution (CODE-02) and what a move freed

**Files:**
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Model/FileTree.swift` (`credit`)
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore.swift` (`seenHardLinks` → link map)
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore+Trash.swift` (reattribute after `tree.remove`; `Moved.size`)
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Actions/TrashOutcome.swift` (doc of `Moved.size`)
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/TrashTests.swift`, `FileTreeTests.swift`

**Interfaces:**
- Produces:
  - `FileTree.credit(_ bytes: UInt64, to id: NodeID)`: adds `bytes` to a non-directory node's size and to every ancestor's size, category total and age-bucket total, exactly as `addChild` would have, and clears `.hardLinkDuplicate`;
  - `TrashOutcome.Moved.size` now means the bytes the root total dropped by.

- [ ] **Step 1: Write the failing tests**

- `FileTreeTests.creditMatchesAddChild`: build two trees, one adding a file with size 0 and then `credit(4096, to:)`, the other adding it with 4096. Root size, `categoryTotals(root)` and `ageTotals(root)` are equal, and `.hardLinkDuplicate` is cleared.
- `TrashTests.trashingCountedLinkMovesBytesToOtherLink`: the fixture holds `a/f.bin` (1 MB) and `b/f.bin`, a hard link to it (use `link(2)`). Scan. Whichever link is counted (non-zero size), trash its folder:
  - the other folder's size becomes the file's allocated size;
  - the root size is unchanged;
  - `outcome.moved[0].size == 0`.
- `TrashTests.trashingBothLinksFreesTheFile` (Review Focus 4): the same file linked twice inside `c/`. Trash `c`: `moved[0].size` equals the file's allocated size, and no other node changes size.
- `TrashTests.movedSizeIsWhatTheRootLost`: trash an ordinary folder: `moved[0].size` equals the root size before minus after.

- [ ] **Step 2: Run them and see them fail**

Run: `cd MacSpaceCore && swift test --filter "creditMatchesAddChild|trashingCountedLinkMovesBytesToOtherLink|trashingBothLinksFreesTheFile|movedSizeIsWhatTheRootLost" 2>&1 | tail -15`
Expected: compile error (`credit` missing), then `trashingCountedLinkMovesBytesToOtherLink` FAILS (the other link stays 0, and `size` is non-zero).

- [ ] **Step 3: Implement**

- `ScanStore`: replace `seenHardLinks: Set<HardLinkKey>` with `hardLinks: [HardLinkKey: [NodeID]]`, holding every link's ID in insertion order, plus `countedLink: [NodeID: HardLinkKey]` for the one carrying the bytes. Both are filled only for `linkCount > 1`.
- After each `tree.remove(id)` in `trash`, for each counted link inside the removed subtree:
  - walk only that subtree's file nodes that appear in `countedLink`;
  - pick the lowest-ID link of the same key that is not `.removed`;
  - `credit` it with the counted link's former size;
  - make it the counted link.
- `Moved.size` is `rootSize` before `remove` minus after the reattribution.

- [ ] **Step 4: Run the full suite**

Run: `cd MacSpaceCore && swift test 2>&1 | tail -5`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add MacSpaceCore
git commit -m "fix(core): give a hard-linked file's bytes to a remaining link after a move; report what the move freed"
```

---

### Task 3: `ChangeHistory`, the FSEvents wrapper

**Files:**
- Create: `MacSpaceCore/Sources/MacSpaceCore/Scan/ChangeHistory.swift`
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/ChangeHistoryTests.swift`

**Interfaces:**
- Produces:

```swift
/// Where the file system's change history stood when a scan started.
public struct ChangeBaseline: Sendable, Equatable {
    public let eventID: UInt64
    /// FSEvents UUID per device the scan was confined to; a device without history is absent.
    public let deviceUUIDs: [Int32: String]
}

/// What changed at or below one path since a baseline.
public enum PathChanges: Sendable, Equatable {
    /// Folders (at or below the path, in the path's own spelling) whose entries may have changed.
    case folders(Set<String>)
    /// The history cannot say: dropped or wrapped events, the root changed, no history for the
    /// device, a different UUID, or the query timed out. Walk everything.
    case untrusted
}

public protocol ChangeHistory: Sendable {
    func baseline(devices: Set<Int32>) -> ChangeBaseline?
    /// One query for all `paths`; `devices[path]` is the device each lives on.
    func changes(since baseline: ChangeBaseline, under paths: [String], devices: [String: Int32]) -> [String: PathChanges]
}

public struct SystemChangeHistory: ChangeHistory { public init() }
```

- [ ] **Step 1: Write the failing live tests** (temporary directory, real FSEvents)

- `noChangeReportsNoFolders`: fixture `a/x`. Take a baseline, query `[a]` → `.folders([])`.
- `addedFileReportsItsFolder`: baseline, then create `a/sub/new` and query right away, with no sleep → the result contains `a/sub`, spelled under the fixture's `/var/...` path, not `/private/var/...` (Review Focus 1).
- `changeOutsideIsNotReported`: baseline, create `b/new`, query `[a]` → `.folders([])`.
- `unknownDeviceIsUntrusted`: a baseline whose `deviceUUIDs` lacks the device → `.untrusted`.
- `otherUUIDIsUntrusted`: a baseline with a different UUID string for the device → `.untrusted`.

- [ ] **Step 2: Run them and see them fail**

Run: `cd MacSpaceCore && swift test --filter ChangeHistoryTests 2>&1 | tail -10`
Expected: compile error (types missing).

- [ ] **Step 3: Implement `SystemChangeHistory`**

- `baseline`:
  - `FSEventsGetCurrentEventId()`;
  - `FSEventsCopyUUIDForDevice(dev_t(device))` for each device, as a `CFUUIDCreateString` string, leaving nil ones out;
  - nil when no device has history.
- `changes`:
  - any path whose device UUID is missing or differs → `.untrusted`;
  - otherwise one `FSEventStreamCreate` over the real paths (`realpath`) with `sinceWhen: baseline.eventID`, flags `kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot`, latency 0, on a private serial `DispatchQueue`;
  - start it and wait (semaphore, 5 s) for an event with `kFSEventStreamEventFlagHistoryDone`;
  - then `FSEventStreamFlushSync`, `Stop`, `Invalidate`, `Release`;
  - a timeout → every path `.untrusted`;
  - any of `MustScanSubDirs`, `UserDropped`, `KernelDropped`, `EventIdsWrapped` or `RootChanged` at or below a path → that path is `.untrusted`;
  - map each other event path back from its real-path prefix to the requested spelling, drop a trailing `/`, and add it to the path it is at or below, compared by `/` component.

  The callback context is a class box that collects under a lock, so the code is `Sendable`-clean.

- [ ] **Step 4: Run the tests, and the full suite**

Run: `cd MacSpaceCore && swift test --filter ChangeHistoryTests 2>&1 | tail -5 && swift test 2>&1 | tail -3`
Expected: all pass. Run the live tests 3 times; none may flake.

- [ ] **Step 5: Commit**

```bash
git add MacSpaceCore
git commit -m "feat(core): ChangeHistory: which folders changed since a scan started (FSEvents)"
```

---

### Task 4: Judge contents changed after the scan (S4) and the sheet's wait text

**Files:**
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore.swift`:
  - `init` gains `history: any ChangeHistory = SystemChangeHistory()`;
  - `classifier` becomes internal;
  - the per-entry classification in `insert` is moved into a function the scratch walk also calls.
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/Scanner.swift` (calls `markScanStarted` with the baseline)
- Create: `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore+Changes.swift` (the content check)
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore+Trash.swift` (one history query per call; step 8 after step 7; S4 doc)
- Modify: `App/MacSpace/Views/Trash/TrashConfirmationSheet.swift` and `App/MacSpace/Resources/Localizable.xcstrings`
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/TrashChangesTests.swift`, plus a `FakeChangeHistory` in `Tests/MacSpaceCoreTests/Support/`

**Interfaces:**
- Consumes:
  - `ChangeHistory`, `ChangeBaseline`, `PathChanges` (Task 3);
  - `tree.inode(_:)` (Task 1).
- Produces:
  - `ScanStore.markScanStarted(rootInode: UInt64, baseline: ChangeBaseline?)`;
  - the internal `trash(…, mountPoints:, contentBudget: Duration = .seconds(10))`;
  - the shared classification `ScanStore.classify(_ entry: DirectoryEntry, parentPath: String, parentContext: FileCategory?, parentFlags: NodeFlags, siblings: [DirectoryEntry]) -> (category: FileCategory, flags: NodeFlags)`, used by both `insert` and the scratch walk. The name and shape are the builder's call; it must be one function, not a copy.

**Behavior:**
1. **One query per `trash` call.** After the mount table is read, `history.changes(since:under:devices:)` runs once for every `topMost` item. With no baseline (a hand-filled store), every item is `.untrusted`.
2. **Step 8, after step 7 passes:**
   - **`.untrusted`:** judge the item's whole on-disk subtree as new content.
   - **`.folders(set)`:** for each folder in the set, at or below the item and in the tree, re-list it with `DirectoryReader.read`:
     - not found → fine;
     - any other error, or an incomplete listing → `.containsUnverified` (Review Focus 2);
     - entries whose name, kind and non-zero inode match a tree child → fine;
     - others are new content.
   - **A folder in the set that is not in the tree:** it lies inside new content, which is already judged whole. Skip it.
3. **Judging new content.** Build a scratch `FileTree`:
   - its root is the new entry, with the context and flags `classify` gives under its tree parent;
   - walk it with `DirectoryReader.read`, classifying through `classify` and following the scan's rules (no descent into symlinks, dataless folders or mount points);
   - judge every directory, the root included, with `SafetyRules.evaluate` on `NodeFacts` built from the scratch tree (`anchorLastUsed: 0`, `isScanRoot: false`).

   Outcome:
   - a verdict that is protected for one of `subtreeBlockingReasons` → `.containsProtected(reason)`;
   - unreadable, dataless, an incomplete listing, a mount point, or a device outside the scan's devices → `.containsUnverified`;
   - a running app's bundle path at or below the entry (as in `subtreeBlocker`) → `.containsProtected(.runningApp)`;
   - a new entry that is a plain file is judged by its own verdict only.
4. **Budget.** The deadline is `ContinuousClock.now + contentBudget`, set once per call. When it passes, the item being judged, and every later one, → `.containsUnverified`.
5. **Sheet.** While `moving`, after 0.5 s the status line text becomes "Verifica dei contenuti e spostamento…" (a `.task(id: moving)` sleep). Add the key to the catalog.

- [ ] **Step 1: Write the failing tests** (`TrashChangesTests.swift`)

Use real fixtures with `scanned(fx)`, and a `FakeChangeHistory` that returns a fixed baseline and fixed `PathChanges`, injected through `ScanStore(…, history:)`:
- `newPhotosLibraryInsideIsProtected`: after the scan, create `a/sub/New.photoslibrary/database/x`; fake → `.folders([a/sub])`. Result `.containsProtected(.photosLibrary)`; nothing moved.
- `newTrashesFolderIsProtected`: create `a/.Trashes/x`; fake → `.folders([a])` (Review Focus 3: the item itself). Result `.containsProtected(.trash)`.
- `newPlainFilesMove`: create `a/sub/new.txt`; fake → `.folders([a/sub])`. The item moves, and the new file is in the Trash with it (via `RecordingDiskActions`).
- `newRunningAppIsProtected`: create `a/Tool.app/Contents/Info.plist`; pass `runningAppPaths` with that bundle; fake → `.folders([a])`. Result `.containsProtected(.runningApp)`.
- `unlistableChangedFolderIsUnverified`: fake reports `a/sub`, chmod `a/sub` to 000 after the scan. Result `.containsUnverified`. Restore the mode in `defer`.
- `goneChangedFolderIsFine`: fake reports `a/sub`, which was removed after the scan. The item moves.
- `untrustedWalksEverything`: create `a/deep/er/New.photoslibrary/x` inside an unchanged-looking tree; fake → `.untrusted`. Result `.containsProtected(.photosLibrary)`.
- `noBaselineWalksEverything`: a store whose fake returns a nil baseline, with the same fixture as above → `.containsProtected(.photosLibrary)`.
- `budgetExhaustedIsUnverified`: `contentBudget: .zero` with fake `.untrusted` → `.containsUnverified`; nothing moved.
- `replacedEntryIsNewContent`: after the scan, replace `a/sub` (remove, then recreate with a `.photoslibrary` inside, new inode); fake → `.folders([a])`. Result `.containsProtected(.photosLibrary)`.

- [ ] **Step 2: Run them and see them fail**

Run: `cd MacSpaceCore && swift test --filter TrashChangesTests 2>&1 | tail -15`
Expected: compile error (`history:` missing), then FAIL: the protected cases move.

- [ ] **Step 3: Implement the core (behavior 1–4)**

Update the `trash` doc comment:
- the step list gains step 8;
- the S4 residual now covers only changes made during the check itself;
- add the S2 descendant note here (Task 6 relies on it being written here).

- [ ] **Step 4: Run the full suite, live history included**

Run: `cd MacSpaceCore && swift test 2>&1 | tail -5`
Expected: all pass. Existing `TrashTests` now run through the real `SystemChangeHistory`, or through the fallback walk in hand-filled stores, and give their old outcomes (Review Focus 5).

- [ ] **Step 5: Implement the sheet text, and build**

Run: `xcodegen generate && xcodebuild -project MacSpace.xcodeproj -scheme MacSpace -configuration Debug -derivedDataPath build/dd27 build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`, with no new warnings in the changed files.

- [ ] **Step 6: Commit**

```bash
git add MacSpaceCore App/MacSpace
git commit -m "feat: judge contents added after the scan before moving a folder (FSEvents, fallback walk)"
```

---

### Task 5: Coverage copy, counting folders read in part

**Files:**
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/Scanner.swift` (`ScanSummary.partlyRead`)
- Modify: `App/MacSpace/Views/ContentView.swift` (`PathRowFactsContent.State`, `withUnreadable`, `Widest`)
- Modify: `App/MacSpace/Resources/Localizable.xcstrings`
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/ScannerTests.swift`

**Interfaces:**
- Produces: `ScanSummary.partlyRead: Int`, the directories whose listing was incomplete because the file system left an entry out (`!listing.isComplete`), not those cut short by cancellation. `DirectoryResult.read` must carry that distinction separately from `partial`.

- [ ] **Step 1: Write the failing test**

`ScannerTests.partlyReadCountsIncompleteListings`: use the test `reader` init. One directory returns `DirectoryListing(entries: […], isComplete: false)`, the others complete. `summary.partlyRead == 1`, `summary.unreadable == 0`.

- [ ] **Step 2: Run it and see it fail**

Run: `cd MacSpaceCore && swift test --filter partlyReadCountsIncompleteListings 2>&1 | tail -8`
Expected: compile error (`partlyRead` missing).

- [ ] **Step 3: Implement the core and the copy**

The path row appends, after the unreadable part:
- with `unreadable > 0`: " · 1 letta in parte" or " · N lette in parte";
- with `unreadable == 0`: " · 1 cartella letta in parte" or " · N cartelle lette in parte".

Nothing is added when the count is 0. Use `Formatters.count` for N. `State.cancelled` and `.finished` gain `partlyRead: Int`, and `Widest` uses 88_888 for it. Add the four keys to the catalog.

- [ ] **Step 4: Test and build**

Run: `cd MacSpaceCore && swift test 2>&1 | tail -3`, then the app build command.
Expected: all pass; `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add MacSpaceCore App/MacSpace
git commit -m "feat: count folders read only in part in the scan summary"
```

---

### Task 6: Plan-3 minors that touch safety or correctness

**Files:**
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore+Trash.swift` (overload visibility)
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Safety/SafetyRules.swift` (rule order; rule 9)
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Safety/SafetyTypes.swift` (`isRemovable`)
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore.swift` (category for `.app`-named Library folders)
- Test: `SafetyRulesTests.swift`, `TrashTests.swift`, `ScannerTests.swift`

**Interfaces:**
- Produces: `SafetyEnvironment.init(…, isRemovable: @escaping @Sendable (String) -> Bool = { _ in true })`. It takes the item's path. `.system` sets it to the sticky-bit check below.

- [ ] **Step 1: Write the failing tests**

- `SafetyRulesTests.datalessUnderUnknownLibraryChildIsCaution`: a `.dataless` file at `<home>/Library/SomethingUnknown/x` → `.caution`, `.libraryInternal`. Today it gets `.normal`, `.cloudOnly`.
- `SafetyRulesTests.notRemovableIsProtected`: an environment with `isRemovable: { _ in false }` and a writable parent → `.protected`, `.notWritable`.
- `SafetyEnvironmentTests.stickyFolderOthersItemIsNotRemovable`: `SafetyEnvironment.system(…).isRemovable` on an entry of `/private/tmp` owned by another user (found by listing the folder; the test is skipped with `withKnownIssue`-free early return when none exists) → false. `isRemovable` of a file the test creates in `/private/tmp` → true.
- `ScannerTests.appNamedLibraryFolderIsNotAppCategory`: fixture home with `Library/Application Support/com.example.app/data.bin` and no `Contents/Info.plist`. Scan with `home:` set to the fixture:
  - the folder's `dominantCategory` is not `.app`;
  - `data.bin` is still `.insidePackage`.

  A real `Library/Application Support/Real.app/Contents/Info.plist` keeps `.app`.

- [ ] **Step 2: Run them and see them fail**

Run: `cd MacSpaceCore && swift test --filter "datalessUnderUnknownLibraryChildIsCaution|notRemovableIsProtected|stickyFolderOthersItemIsNotRemovable|appNamedLibraryFolderIsNotAppCategory" 2>&1 | tail -15`
Expected: compile error (`isRemovable` missing), then FAIL on each.

- [ ] **Step 3: Implement**

- **Rule order.** Move rule 11 (dataless → `.cloudOnly`) below rule 12b.
- **Rule 9.** `!env.isWritable(parent) || !env.isRemovable(path)` → `.notWritable`. In `.system`, `isRemovable(path)`:
  - `stat` the parent; if `S_ISVTX` is set and `getuid() != 0` and the parent's uid is not `getuid()`, then `lstat(path).st_uid == getuid()`;
  - otherwise true;
  - a failed `stat` → false (fail closed).
- **`.app`-named Library folders.** In `insert`, a directory that gets the `.app` context and sits directly in `<home>/Library/<location>/` (one of the `SafetyTables` locations) takes its parent's context unless `<path>/Contents/Info.plist` exists. Its `.package` flag stays.
- **Overload.** Make the `trash(_:actions:packages:openFiles:expectedVerdicts:)` overload without `environment:` `internal`. The app already uses the one with `environment:` (`ScanModel+Trash.swift:137`).

- [ ] **Step 4: Full suite and app build**

Run: `cd MacSpaceCore && swift test 2>&1 | tail -3`, then the app build command.
Expected: all pass; `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add MacSpaceCore
git commit -m "fix(core): plan-3 minors: dataless rule order, sticky-bit folders, .app-named Library folders, internal trash overload"
```

---

### Task 7: Wrap-up

- [ ] **Step 1:** Delete the plan-3 ledger (`rm -rf .superpowers/sdd/2026-11-25-macspace-3-intelligence-trash`). The spec's "Leftovers" section now holds its remaining items.
- [ ] **Step 2:** Run the full suite and the app build one last time. Expected: all pass; `** BUILD SUCCEEDED **`.
- [ ] **Step 3:** Owner live test of the Trash sheet, then the PR (closes #27), with the memory figures from Task 1.
