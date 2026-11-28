# Scan integrity before moving to the Trash — design

Issue #27. Plan 4, part 1 of 5: the work left over from plan 3. Approved by the owner on 2026-11-28 (approach B, FSEvents history).

## Intent

When MacSpace moves a folder to the Trash, it relies on what the scan saw. Plan 3 left four ways for that picture to be out of date or wrong. Each can either move something the user never confirmed, or show the wrong space. This part closes them. It also clears the plan-3 minors that touch safety or correctness, and records every other leftover here, so the git-ignored plan-3 ledger can be deleted.

- **Goal:** what is moved is what the user saw and confirmed, or it is skipped with a clear reason.
- **Goal:** sizes stay right after a move.
- **Non-goal:** snapshot persistence and the incremental refresh at launch (part 2). This part only lays the FSEvents groundwork that part 2 reuses.
- **Non-goal:** volume info, remove-local-copy, duplicates (parts 3–5).
- **Anti-goal:** the checks must not make the Trash sheet slow in the common case. A move that worked instantly before must still feel instant when nothing changed on disk.
- **Anti-goal:** no check may fail open. Anything that cannot be verified is skipped, never moved.

## Approaches (for the "contents added after the scan" check, S4)

- **A. Re-walk the whole folder on disk before each move.** Simple and complete, but it costs about 2 s per 100,000 files, so the sheet would wait on big folders.
- **B. Ask FSEvents what changed since the scan started, and re-read only that.** Chosen. It is usually instant, as safe as A, and part 2 reuses it. A is kept as B's fallback when the history cannot be trusted.

## Design

### 1. Item identity (SEC-01)

- The tree stores each node's inode (`ContiguousArray<UInt64>`, +8 B per node). The reader already reads it.
- Step 7 of `ScanStore.trash` (on disk, last) also compares the inode of the item and of every folder above it, up to the scan root, with the stored one. A mismatch gives `.changed`. The current copy for `.changed` already tells the user that the item changed since the scan.
- **Memory.** Measure bytes per file with the existing benchmark, before and after. Plan 3 ended at 169 B/file, up from about 131, unexplained. Bisect that rise while measuring, and record both figures in the PR.
  - If the cause is small and local (for example a missing `reserveCapacity` or a duplicated array), fix it here.
  - Otherwise, open an issue for it.
  - This part must stay at or under 200 B/file. *My call.* The spec target stays: well under 1 GB for 3 M files.

### 2. Hard-link reattribution (CODE-02)

- Today a file with several links counts its bytes on the first link seen; later links get size 0 and `.hardLinkDuplicate`.
- The store keeps a sparse map from `(device, inode)` to the node IDs of its links, only for files with a link count above 1.
- When `tree.remove` takes out the counted link, the bytes move to the lowest-ID link still in the tree: its size is set, its `.hardLinkDuplicate` flag is cleared, and the change is propagated to its ancestors (sizes, category and age totals). If no link remains in the tree, nothing happens.
- "Libera circa …" in the sheet is unchanged: `PrivateSize` already counts a multiply-linked file as 0.
- `TrashOutcome.Moved.size`, which the move report and the history show, becomes the bytes the root total actually dropped by: the root's size before the removal minus after. Moving a link whose bytes pass to another link then reports 0, not bytes that were never freed. *My call.*

### 3. Contents changed after the scan (S4), approach B

**At scan start**, before the first directory is read, the store records:
- `FSEventsGetCurrentEventId()`;
- the FSEvents UUID of each device the scan is confined to (`FSEventsCopyUUIDForDevice`).

Changes made while the scan is running are therefore also caught.

**At trash time**, once per `trash` call, for the items that passed steps 1–6:

1. **Can the history be trusted?** For each item's device, read the UUID again. If it is missing, or differs from the recorded one, the history cannot be trusted: use the fallback for that item.
2. **Query.** Open one FSEvents stream over the item paths with `sinceWhen` set to the recorded ID, and collect events until `HistoryDone`. Then call `FSEventStreamFlushSync`, so a change made a moment before the check is included. A builder test must prove this with a live change. Then stop the stream.
3. **Trust per item.** For an item, any of `MustScanSubDirs`, `UserDropped`, `KernelDropped`, `EventIdsWrapped` or `RootChanged` on an event at or below it means the fallback for that item.
4. **Changed folders.** Each event path at or below an item, compared in canonical form, names a folder whose entries may have changed. Re-list it and compare its entries with the tree's children by name, kind and inode:
   - an entry that is unchanged is fine (its own interior changes have events of their own);
   - an entry that is gone is fine;
   - an entry that is new, or whose kind or inode changed, is **new content**.
5. **Judging new content.** Read each new entry's subtree from disk and judge it with the same tests as step 6:
   - the protected-as-a-whole reasons in `subtreeBlockingReasons`, using `SafetyRules` with `NodeFacts` built through the classifier, with the package and category context threaded from the tree;
   - a running app's bundle;
   - a mount point;
   - an unreadable, dataless or incompletely listed folder.

   The outcome is the same `TrashSkip` step 6 gives (`.containsProtected(reason)` or `.containsUnverified`). New content that passes is moved along with the folder, as the Finder would. The user confirmed the folder, and the open-files check (step 5) is already live.
6. **Fallback (approach A).** Judge the item's entire on-disk subtree as new content.
7. **Budget.** Judging stops after 10 s per `trash` call. Items not yet judged are skipped `.containsUnverified`, never moved unchecked.
8. **Where it runs.** Steps 1–7 happen after step 6 and before the on-disk step 7, so the order stays: cheap tree checks first, disk last.

**What the sheet shows.** The check and the moves stay inside the one `trash` actor call, so no other change can land between them (ruling R41). The core API does not change. The sheet already shows "Spostamento nel Cestino…" while the call runs. If the call lasts more than 0.5 s, the sheet's own timer switches the text to "Verifica dei contenuti e spostamento…", so a fallback walk does not look frozen. Other store queries wait behind the actor meanwhile. That is acceptable: the sheet is modal, and the common case is instant. *My call.*

**Residuals** (documented in `ScanStore.trash`, as today):
- S3, the window between the last check and the rename, stays.
- S4 shrinks to changes made during the check itself.

The FSEvents code lives in its own small type in MacSpaceCore, behind a protocol, so tests inject the history: none, events, dropped, or a different UUID. Part 2 reuses it.

### 4. Coverage copy

- The scan summary also counts folders listed only in part (the `partial` case the scanner already records).
- The path row reads e.g. "12.345 file · 3 cartelle non leggibili · 2 lette in parte". Each part appears only when its count is above 0, with the singular "1 cartella letta in parte".
- Dataless (cloud-only) folders are **not** counted. They hold no local data, so the scan misses no local space by not reading them. My call: the audit carry suggested counting them, but that would overstate the gap.

### 5. Plan-3 minors folded in

These touch safety or correctness. The builder first checks that each still applies on `main`; one already fixed is dropped with a note in the PR.

1. Make the public `trash` overload without an environment internal (test-only). The app must always pass the live environment (ruling R41).
2. Rule order: a dataless item under an unknown `~/Library` child must get at least `.caution`. Today rule 11 (dataless) comes after 12b, which can give it less. Swap so the stronger warning wins, and add a test.
3. A foreign or stale node ID must never trap. Today `row`, `rows`, `path`, `breadcrumb` and `verdict` assume the ID is in the tree; the store guard covers only the snapshot and Spotlight. Guard them all, with tests.
4. A `~/Library` folder whose name looks like a bundle ID ending in ".app" (seen live: `com.usebruno.app`) is taken for a package and shows as category App. Fix only the category: inside `~/Library/<location>/`, a folder with that name and no `Contents/Info.plist` gets the category its contents give, not App. Keep its contents protected as `.insidePackage`. The live LaunchServices check at move time (step 4) also treats it as a package, so relaxing the protection would only make its items look trashable and then fail. The folder itself can still be moved as a whole. *My call.* Add a test.
5. Sticky-bit folders (`/tmp`, `/Users/Shared`): an item the user does not own there looks trashable, then fails. Judge it `.notWritable` up front.
6. The `TrashGuard` U+FFFD descendant residual (S2): document it in the `trash` doc comment, as for S3 and S4.

### Leftovers not in this part

Each is recorded here and nowhere else.

- **Tests only:**
  - vacuous spotlight/teamID assertions;
  - `#expect(a && b)` conjunctions;
  - depth-3 exclusion, duplicate IDs and symlinked app in the apps index;
  - rule-order pairs (16/17, 2/3, 5/6, 6/7, runningAppData via bundle path);
  - case-insensitive anchor and root `/`;
  - removed and dataless skip in suggestions, essential-root children, ordering;
  - R26 other reasons;
  - the cancellation test only cancels before the scan starts;
  - team-prefixed vendor case.
- **Performance:**
  - running-ID matching per unmatched item is O(unmatched × running);
  - `OwnerMatcher` runs again for every node below the Library locations;
  - `trashCandidates` makes 3 store hops per ID;
  - size read twice in suggestions;
  - `reserveCapacity` for the per-folder category and age arrays.
- **Labels and copy:**
  - InstallerMatcher generic stems name the wrong owner;
  - vendor wording may name an unrelated app (com.electron, io.github);
  - running-only apps are not vendors;
  - the unknown-name caches (Homebrew, pip) stay pending until the apps index is ready;
  - VoiceOver speaks a stale level on rows that are gone;
  - BiggestList's covered row has no VoiceOver selected state.
- **Drawing:**
  - slivers narrower than the hatch pitch lose the hatch;
  - the highlight is not drawn when the chart shows everything;
  - a selected tile too small for an outline gets none.
- **Documented residuals:**
  - case folding reduces protection on case-sensitive volumes;
  - NFC/NFD compare;
  - `MNT_NOWAIT` staleness;
  - the open-file check sees descriptors only (apps are covered by their bundle paths);
  - firmlink paths under `/System/Volumes/Data`;
  - a `home == "/"` guard.
- **Structure:**
  - extract the Trash sheet's state machine into a testable model;
  - batch store calls;
  - drop the `= nil` default on core `trash` expected levels;
  - scan-start `now` vs `Date.now` for ages. Keep the scan-start time for the whole scan: ages then agree across the tree.

## Constraints

- Swift 6 strict concurrency.
- MacSpaceCore tests (Swift Testing) for every behavior above. FSEvents is tested through the injected history, plus one live test in a temporary folder.
- No new permissions; FSEvents history needs none beyond reading the folder.
- Copy is Italian, in the string catalog.

## Left to the builder

- The FSEvents wrapper's shape, its run-loop or queue handling, and its timeouts, within the rules above.
- How `NodeFacts` for new content get their context, as long as they match what a scan would have given.
- The data structure for the hard-link map.
- Task order, as long as identity (1) lands before the S4 check (3), which compares inodes.
