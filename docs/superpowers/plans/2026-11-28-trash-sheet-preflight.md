# Trash Sheet Preflight Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the Trash sheet opens, run every check `ScanStore.trash` runs, without moving anything, so the user sees which rows will not move (and why) before confirming.

**Architecture:**
- **Core.** `ScanStore.trash` is split into two parts:
  - the call-level gate, which reads open files, mounts, the history and a deadline once per call;
  - a per-item check covering steps 1–8.

  A new public `trashPreview` runs the same gate and the same per-item check, and returns a reason per blocked item. It never moves anything and never sets the environment.
- **Sheet.** `TrashConfirmationSheet` replaces its own open-files read with `trashPreview`. Blocked rows are dimmed with `TrashSkip.text`, as open rows are now.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI, Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-28-trash-sheet-preflight-design.md`

## Global Constraints

- The preview and the move use one code path. `trash` and `trashPreview` call the same gate and per-item check, never a copy.
- The preview never calls `DiskActions`, never changes the tree and never sets the environment. It judges against the store's current environment.
- The move still re-checks everything, with the live environment (ruling R41). Step 7, the on-disk stat, stays right before each item's move.
- The preview has the same content budget as `trash`: `.seconds(10)`.
- Copy (Italian, in `App/MacSpace/Resources/Localizable.xcstrings`, edited by hand):
  - while the preview runs, the title reads "Controllo degli elementi…";
  - "Controllo dei file aperti…" is removed if nothing else uses it.
- Commits have no attribution or co-author lines. Never commit `Local.xcconfig`. Leave `docs/macspace-audit.md` and `.impeccable/` alone.

## Review Focus

1. **An older preview result lands after a newer one.** The sheet opens, then `verdictRevision` changes and starts a second preview. The first result must not overwrite the second. The sheet keeps a run counter, and only the latest run's result is applied.
2. **A preview result arrives after the store changed** (a rescan, so the generation differs) **or after the sheet closed.** It is dropped. The sheet never shows notes for nodes from another store.
3. **The preview takes long** (the fallback walk, up to 10 s). "Annulla" stays enabled, the move button stays disabled, and the title shows the spinner. The store actor is busy meanwhile, just as at move time.
4. **Every item is blocked by a call-level reason.** For `.cannotCheckOpenFiles`, the sheet shows the warning line "Impossibile verificare i file aperti" and the move button stays disabled. For other reasons, such as `.scanInProgress` or `.containsUnverified` from an unreadable mount table, each row gets its note and the header reads "Niente da spostare".
5. **A clean preview, then a change before the click.** Content is added between the preview and the move: the move still skips it. This is pinned by the core test `trashAfterCleanPreviewStillChecks`.

---

### Task 1: Core: one check for preview and move

**Files:**
- Modify: `MacSpaceCore/Sources/MacSpaceCore/Scan/ScanStore+Trash.swift`:
  - split `trash(…, mountPoints:, contentBudget:)` into a gate and a per-item check;
  - add `trashPreview`;
  - in the doc comment, say that the preview runs steps 1–8 without step 9.
- Test: `MacSpaceCore/Tests/MacSpaceCoreTests/TrashPreviewTests.swift` (new). Reuse `FakeChangeHistory`, `RecordingDiskActions` and `FakePackageProbe` from `Tests/MacSpaceCoreTests/Support/`, with a local `scanned(fx, history:)` helper shaped like the one in `TrashChangesTests.swift`.

**Interfaces:**
- Produces:

```swift
// Public: what the app calls when the sheet opens.
public func trashPreview(_ ids: Set<NodeID>, packages: any PackageProbe,
                         openFiles: @Sendable () -> OpenFileSet,
                         expectedVerdicts: [NodeID: SafetyVerdict]?) -> [NodeID: TrashSkip]
// Internal: the same call, with the mount table and budget injectable for tests.
func trashPreview(_ ids: Set<NodeID>, packages: any PackageProbe, openFiles: @Sendable () -> OpenFileSet,
                  expectedVerdicts: [NodeID: SafetyVerdict]?, mountPoints: () -> [String]?,
                  contentBudget: Duration = .seconds(10)) -> [NodeID: TrashSkip]
```

  - The result has one entry per `topMost(ids, keepingRemoved: true)` item that would be skipped, with the reason `trash` would give.
  - An item that is absent would move.
  - An empty `ids`, or only the root or stale ids, gives `[:]`.
- The gate and per-item check are private. Their shape is the builder's call, but they must be the only implementation of the gate and of steps 1–8, and `trash` must call them:
  - the gate covers `scanFinished`, `openFiles()` called once with an incomplete set failing every item, mount table, devices, deadline and one `contentChanges` query;
  - the per-item check is `trashBlocker` followed by `contentBlocker` for folders.

- [ ] **Step 1: Write the failing tests** (`TrashPreviewTests.swift`)

Each test builds its fixture with `Fixture`, scans with `ScanStore(…, history:)`, and calls `trashPreview` with `mountPoints: MountTable.current`.
- `previewBlocksContentAddedAfterScan`:
  - fixture `a/sub/old.txt`; history `.folders([a/sub])`;
  - after the scan, create `a/sub/New.photoslibrary/x`;
  - expected: `preview == [a: .containsProtected(.photosLibrary)]`;
  - `store.node(atPath: a)` is still in the tree and not `.removed`.
- `previewGivesTrashReasons`:
  - items:
    - `clean/f`, plain;
    - `open/f`, listed in `OpenFileSet(paths: [<fx>/open/f])`;
    - `gone/f`, removed from disk after the scan;
    - `swapped`, a folder removed and recreated after the scan (new inode);
  - history `.folders([])`;
  - preview all four, then `trash` the same four with a `RecordingDiskActions`, with the same `openFiles` and `expectedVerdicts: nil`;
  - expected:
    - `preview == Dictionary(outcome.skipped.map { ($0.node, $0.reason) })`;
    - `preview[clean] == nil`;
    - `outcome.moved.map(\.node) == [clean]`.
- `previewMovesNothing`:
  - fixture `a/f`;
  - preview `[a]` (clean), then check:
    - `a` is not `.removed`;
    - the root size is unchanged;
    - `store.node(atPath:)` still finds `a/f`.
  - The preview takes no `DiskActions`, so nothing can be moved.
- `trashAfterCleanPreviewStillChecks` (Review Focus 5):
  - fixture `a/sub/old.txt`; history `.folders([a/sub])`;
  - the preview of `[a]` is `[:]`;
  - then create `a/sub/New.photoslibrary/x`, and `trash([a])`;
  - expected: skipped `[.containsProtected(.photosLibrary)]`, and nothing moved.
- `previewIncompleteOpenFilesBlocksAll`:
  - two items, `openFiles` gives `OpenFileSet(paths: [], isComplete: false)`;
  - expected: every value is `.cannotCheckOpenFiles`, with both ids present.
- `previewBudgetExhaustedIsUnverified`:
  - folder `a`, history `.untrusted`, `contentBudget: .zero`;
  - expected: `[a: .containsUnverified]`.

- [ ] **Step 2: Run them and see them fail**

Run: `cd MacSpaceCore && swift test --filter TrashPreviewTests 2>&1 | tail -15`
Expected: compile error (`trashPreview` missing).

- [ ] **Step 3: Implement the split and `trashPreview`**

`trash` keeps its public and internal signatures and its behavior, including `defer { verdictCache.removeAll() }`. The preview clears the verdict cache too: it evaluates fresh verdicts, the same way `trash` does.

- [ ] **Step 4: Run the full suite**

Run: `cd MacSpaceCore && swift test 2>&1 | tail -3`
Expected: all pass (375 + 6). The existing `TrashTests` and `TrashChangesTests` are unchanged and green: the split changed no outcome.

- [ ] **Step 5: Commit**

```bash
git add MacSpaceCore
git commit -m "feat(core): trashPreview: the move's checks without the move, one code path with trash"
```

---

### Task 2: Sheet: show what will not move before the click

**Files:**
- Modify: `App/MacSpace/ScanModel+Trash.swift`. Add a `trashPreview` wrapper next to `trashVerdicts`.
- Modify: `App/MacSpace/Views/Trash/TrashConfirmationSheet.swift`:
  - `OpenCheck` becomes the preview state;
  - `prepare()` and `refreshRows()` start a preview;
  - notes for blocked rows come from the preview;
  - the header text changes;
  - `move()` puts the rows the preview blocked in "left out".
- Modify: `App/MacSpace/Resources/Localizable.xcstrings`.

**Interfaces:**
- Consumes: `ScanStore.trashPreview(_:packages:openFiles:expectedVerdicts:)` from Task 1.
- Produces: `ScanModel.trashPreview(_ ids: [NodeID]) async -> [NodeID: TrashSkip]?`.
  - It returns nil when there is no store, or when the store changed during the call (`store === self.store` after the await).
  - It passes `SystemPackageProbe()`, `{ OpenFileSet.current(excludingOwnProcess: true) }` and `expectedVerdicts: nil`. The sheet's own verdict refresh (`apply`) already shows changed verdicts in place; a `.verdictChanged` note would duplicate it.

**Behavior:**
1. **States.** `OpenCheck` is renamed `Preview`, with these cases:
   - `.running`;
   - `.done([NodeID: String])`, the note per blocked row, `TrashSkip.text`;
   - `.incomplete`, used when every value is `.cannotCheckOpenFiles`.

   The view keeps its current logic everywhere `openCheck` is read today:
   - `canMove`;
   - the header's `restorable` count;
   - `included(of:)`;
   - `staysNote`, where the withdrawn note stays first;
   - the status line.
2. **Runs.**
   - `prepare()` starts the preview where `.open(await Self.openFiles())` runs now, as one more child of the same task group. Estimates still run beside it.
   - `refreshRows()` starts a new preview after `apply(current)`, sets the state to `.running`, and applies the result when it arrives.
   - A run counter (`@State private var previewRun = 0`) means only the latest run's result is applied. A result is also dropped when `generation != model.storeGeneration`, or when the task is cancelled (Review Focus 1 and 2).
   - `openFiles()` and `openNotes(of:in:)` are removed from the sheet once nothing uses them.
3. **Header.** While `.running`, the title is "Controllo degli elementi…" with the small spinner.
4. **Move.** `move()` is unchanged except that its `open` snapshot is now the preview's notes. Rows that the preview blocked go to `leftOut` with their notes, as open rows do today.
5. **Catalog.**
   - Add "Controllo degli elementi…".
   - Remove "Controllo dei file aperti…" if nothing references it (`grep -rn` over `App/`).

- [ ] **Step 1: Implement 1–5**

- [ ] **Step 2: Build**

Run: `xcodegen generate && xcodebuild -project MacSpace.xcodeproj -scheme MacSpace -configuration Debug -derivedDataPath build/dd29 build 2>&1 | grep -E "warning:|error:|BUILD" | grep -v "appintents" | tail -5`
Expected: `** BUILD SUCCEEDED **`, with no new warnings in the changed files.

- [ ] **Step 3: Live test with the owner**

Follow the GUI rules:
- back up the `com.massilp.macspace` defaults and restore them afterwards;
- launch with `open -n -g`;
- quit only our PID;
- send no synthetic input.

Steps:
1. Scan `~/MacSpace-Prova` (`a/sub/file.txt`).
2. Create `a/sub/Prova.photoslibrary/file.txt` after the scan.
3. Open the Trash sheet on `a`.

Expected:
- the title shows "Controllo degli elementi…" briefly;
- then the `a` row is dimmed with "Contiene una libreria di Foto";
- the header reads "Niente da spostare", and the move button is disabled.

Control run: a plain new file instead of the library. Expected: `a` is not dimmed, and it moves.

- [ ] **Step 4: Commit**

```bash
git add App/MacSpace
git commit -m "feat: the Trash sheet runs the move's checks when it opens and greys out what will not move"
```
