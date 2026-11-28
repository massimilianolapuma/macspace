# Snapshot and incremental refresh — Design (plan 4, part 2)

## Intent

Today every launch starts empty. The target is always the startup disk, and the owner presses "Analizza" and waits for a full scan, about 60 s on the whole disk. The main spec (§5.3, "middle way for speed") already decided the fix:
- save a snapshot of the tree when a scan ends;
- on the next launch, show it at once, marked with when it was taken;
- then refresh only what changed, found through the FSEvents history, which covers the time the app was closed;
- fall back to a full rescan when the history cannot be trusted.

Part 1 (#27, `2026-11-28-scan-integrity-design.md`) built `ChangeHistory` / `SystemChangeHistory` with this part in mind.

## Goals

- **Instant reopen.** After a launch, the last target's chart is on screen within the spec's budget: "reopen from snapshot < 1 s", for about 3 M files. It is labelled as taken at a given time.
- **Cheap refresh.** The refresh reads from disk only the folders the history names, plus what cannot be vouched for. A day's ordinary use costs a few seconds, not a full scan.
- **Same tree as a full scan.** When the refresh ends, the tree is the one a full scan at refresh start would have built. The only exceptions are the residuals listed below.
- **Snapshots kept (owner's choice, option B):**
  - the startup disk's snapshot, always;
  - the snapshot of the last folder scanned.

  The target used last is remembered and reopened at launch.

## Non-goals

- Volume info, remove-local-copy and duplicates. Those are parts 3–5.
- Any background work while the app is closed. That is an anti-goal of the main spec: no daemon, agent or login item. The history is read only at launch or when a target is opened.
- Snapshots of more than one folder.

## Anti-goals

- **A Trash move judged on snapshot data.** The Trash stays disabled until the refresh has finished. The refreshed tree then goes through the move's checks exactly as a scanned tree does (`trash`, `trashPreview`, steps 1–9).
- **A corrupt or foreign snapshot that crashes the app, or enters the tree unnoticed.** A snapshot that fails validation is discarded and deleted, and the app falls back to a full scan.
- **Trusting the history beyond what it can vouch for.** Every doubt means a re-read from disk, never a guess.

## Constraints

- macOS 27, Swift 6 strict concurrency, no third-party dependencies. Core logic lives in MacSpaceCore and is tested with `swift test`.
- Snapshots live in the app's own cache folder: `~/Library/Caches/com.massilp.macspace/Snapshots/`.
  - They hold every file name of the target, so they never leave the Mac, which is implied by the folder.
  - They are written atomically: a temporary file, then a rename.
- Memory: the main spec says "well under 1 GB for 3 M files"; part 1 measured 166 B/file.
  - Fields added to the live tree for the snapshot's sake must be measured. The builder reports bytes per file before and after.
  - The refresh briefly holds two trees: the one on screen and the one being built. The builder measures the peak on the owner's disk and reports it (see "Left to the builder").
- UI copy is Italian, in `Localizable.xcstrings`, edited by hand.

## Approaches (owner picked 2)

1. **Patch the shown tree in place.**
   - How: re-list each changed folder, diff it against its children, then remove, add, resize and propagate sizes, categories, ages and hard-link credit up the tree.
   - Pro: the fastest refresh.
   - Con: it needs new tree mutations, each a new place for size, category, age and hard-link bookkeeping to drift. Removed nodes also pile up as tombstones.
2. **Rebuild through the normal scan, reading the snapshot where nothing changed.** Chosen.
   - How: the refresh is an ordinary `Scanner.scan` into a fresh `ScanStore`. The scanner's `reader` (already injectable) returns the snapshot's listing for every folder the history vouches for, and reads the disk for the rest.
   - Pro: classification, `SafetyRules`, hard-link dedupe and inode identity all run through today's tested insert path.
   - Con: the whole tree is rebuilt in memory, which costs CPU seconds but no disk reads. Figures change all at once when it ends.
3. **Full rescan in the background with the snapshot on screen.**
   - Pro: the simplest.
   - Con: every launch re-reads the whole disk, against "refresh only what changed". It is kept as approach 2's fallback.

## Design

### What a snapshot is

A snapshot is one file per target: `startup-disk.snapshot`, and `folder.snapshot` for the one folder kept.

Its header carries:
- a magic number and format version (a mismatch makes the snapshot ignored);
- the target (startup disk, or the folder's real path);
- the root's inode;
- when the scan started (wall clock);
- the scan's `ChangeBaseline` (event ID, plus the FSEvents UUID of each device);
- whether Full Disk Access was granted when it was taken;
- a checksum of the body.

The body is:
- the tree's nodes in ID order (parents before children);
- per directory, whether its listing was complete, partial or unreadable;
- every `DirectoryEntry` field the insert path reads, so that a listing rebuilt from the snapshot inserts exactly as the disk listing did:
  - name, kind, allocated size, device, inode, link count;
  - mount point and dataless flags;
  - modification and access times.

Hard-link duplicates must keep their real allocated size and link count, not the 0 the tree shows. Derived tables (sizes, category and age totals) need not be stored if they can be rebuilt fast enough at load (see "Showing it").

### When snapshots are written

A snapshot is written when a scan or refresh ends without cancellation. It is written off the main actor, after the views have settled, and it replaces the target's previous snapshot.
- A scan of a new folder replaces `folder.snapshot`.
- A cancelled scan writes nothing and keeps the old snapshot.
- Trash moves do not rewrite the snapshot: the history reports the folders they touched, and the next refresh re-reads them.

### Showing it (launch, or picking a target)

1. **At launch.** The app reopens the target used last: the startup disk, or the remembered folder if it still resolves. If that target has a valid snapshot, it is loaded into a store and shown.
   - The load builds the tree directly. It does not replay listings through the scanner, which would not meet the < 1 s budget.
   - Ages are measured from the launch time, not the snapshot's.
   - With no snapshot, the app behaves as today and waits for "Analizza".
2. **Picking a target** in the toolbar with a valid snapshot shows it the same way, then refreshes it. Without a snapshot, nothing changes from today.
3. **The status row while a snapshot is on screen** reads "Aggiornato a <data e ora> · Aggiornamento in corso…". It uses the existing small progress style, not the scan's progress bar, since there is no meaningful percentage. The words are final copy; the placement is the builder's call within the existing status area.
4. **Browsing during the refresh.** The user can drill, hover, select and open suggestions. "Sposta nel Cestino…" is disabled with the reason "Aggiornamento in corso…", and the sheet cannot open.
5. **When the refresh ends**, the new store replaces the shown one, with the same bookkeeping `run` does today (`storeGeneration`, cleared node-ID state).
   - The center and the selection are carried over by path; anything no longer found is dropped.
   - If the user cancels, or starts a full scan, the snapshot stays on screen with its date and the Trash stays disabled.

### The refresh

1. **When it falls back to a full scan instead** (approach 3):
   - the snapshot is older than **7 days** (a margin against history purged without a UUID change, the residual in `SystemChangeHistory`);
   - the root's inode differs;
   - Full Disk Access is missing now but was granted then, because events inside protected folders may then go unseen;
   - the history answers `.untrusted` for the root;
   - the baseline is nil, or a device's UUID differs.
2. **Otherwise**, one `changes(since:under:[root])` query gives the set of changed folders.
   - **The query's timeout.** The refresh waits up to **30 s**, while `trash` keeps its 5 s. This needs an injectable timeout on `SystemChangeHistory`.
     - Measured on the owner's Mac (2026-11-28), from the history of the last 24 h on `/`:
       - 70,528 events over 12,821 distinct folders;
       - the replay took 8–9 s;
       - no `MustScanSubDirs`, dropped, wrapped or `RootChanged` events;
       - paths come spelled `/Users/…`, the tree's spelling, never `/System/Volumes/Data/…`, so no path mapping is needed.
   - **An untrusting event anywhere makes the whole root `.untrusted`** (part 1's rule). That gives a full scan. (My call: no per-subtree answer for now. None was seen in a day, and a finer `PathChanges` would also change `trash`'s step 8. The builder logs each fallback's reason, so the frequency shows.) A refresh is a `Scanner` over a fresh `ScanStore` and the current `ScanBoundary`. `markScanStarted` takes a new baseline before any read, as every scan does, so changes made during the refresh count for the next one and for `trash`.

   The reader is: **disk** for a folder that is
   - in the changed set;
   - absent from the snapshot (new, or renamed: its new path is not in the snapshot);
   - unreadable or partial in the snapshot;
   - whose entry in its parent's listing, as just inserted (from disk or from the snapshot), has a device or inode different from the snapshot's node at that path;

   and **the snapshot's listing** for every other folder.

   The identity check catches a folder replaced by another at the same path, for example `rm -r A; mv B A`. Only the parent reports a change, so without the check A's old listing would be reused, and `trash` could then miss a protected item inside the new A. If the parent's listing itself came from the snapshot, the parent did not change, so its folders cannot have been swapped. The check therefore needs no extra disk call. (My call: the reader gets the expected device and inode with the path.)
3. **When the refresh ends**, `markScanFinished` and everything after it run as for a scan. The tree is then a scanned tree, and the Trash is enabled once `scanSettled`. The new snapshot is written.
4. **What is on screen during a full scan with a snapshot shown** (owner's choice, option A; it applies to a fallback and to "Analisi completa" alike):
   - The snapshot stays on screen and stays browsable until the scan ends. The scan fills a store that is not shown, then replaces the shown one in a single step, exactly as a refresh does (step 5 of "Showing it").
   - The status row reads "Aggiornato a <data e ora> · Analisi completa in corso…".
     - For the startup disk, it also shows the scan's progress bar (`DiskUsage.progress`).
     - For a folder, it shows the small progress style.
   - Cancelling keeps the snapshot, as for a refresh.
   - With no snapshot (a first scan, or a new folder), the scan shows its growing tree as today.
5. **"Analizza"** with a snapshot on screen runs this refresh. **"Analisi completa"**, a new menu command in the app's File menu, always does the full scan. (My call: the refresh is as safe as the scan, so the main button takes the fast path.)

### Residuals (documented, accepted)

- **Access times.** They change without folder events, so a file's last use can lag in folders the history did not name. Age buckets are slightly stale. Modification times are covered, since a content change reports the parent folder.
- **History purged without a UUID change and without a flagged gap.** This is part 1's residual. The 7-day limit bounds it.
- **A renamed folder.** It is re-read in full under its new path. That is correct, just not optimal.
- **Hard links changed since the snapshot.**
  - Adding, removing or writing through a link reports only the folder of that link. A link in an unchanged folder keeps its old link count and size.
  - A file hard-linked since the snapshot can therefore count its bytes twice, or carry a stale size, until the next full scan.
  - This affects sizes only. Trash safety does not depend on it: steps 7 and 8 read the disk and the history.
  - The 7-day limit bounds it, and so does "Analisi completa". (My call. Exact equality would need a `(device, inode)` index of the whole snapshot on every refresh, and hard links are rare on a user's disk.)
- **A folder moved away, changed and moved back while the app was closed** (for example the Trash, then "Put Back"). The folder-level history names only its parent and the temporary path, so the folder keeps its inode, is reused from the snapshot, and stays stale. This can affect the Trash's content check. Owner's ruling (final review I1): fix it in the very next change, #34, using the file-level history, which carries inodes, so moved folders are re-read; until then it is a known limit.
- **Device numbers renumbered after a reboot.** For example, an external disk attached at boot. The FSEvents UUID check then fails, and the app does a full scan instead of remapping devices. (My call. The internal volumes mount in a fixed order.)

## Tests (Core, TDD)

- **Round trip.** Scan a fixture (hard links, symlinks, an unreadable folder, a partial listing, a package, a mount-point stand-in), write it, load it. The loaded tree equals the scanned one: node by node, names, sizes, flags, inodes, category and age totals (ages against the load's `now`).
- **Validation.**
  - A bad magic, version or checksum, a truncated file, or an out-of-range parent or name offset each give "no snapshot", never a crash.
  - The file is deleted.
- **Refresh equals rescan**, using `FakeChangeHistory` and a scan with `maxConcurrency: 1`, so which hard link carries the bytes is deterministic.
  - Fixture changes after the snapshot:
    - add, remove and resize a file;
    - add a folder with content;
    - rename a folder;
    - replace a folder by another at the same path (`rm -r A; mv B A`): the new A's content is read from disk.
  - With the changed folders reported, the refreshed tree equals a fresh full scan.
  - A reader spy shows that the unchanged folders were not read from disk.
- **Hard-link residual.** A test pins the documented behavior. A link added in a changed folder to a file in an unchanged folder is counted again. A full scan counts it once.
- **Fallbacks.** Each condition in "The refresh" step 1 gives a full read: every folder from disk.
- **Unreadable or partial in the snapshot.** Read from disk even when the history says unchanged.
- **Trash after refresh.**
  - `trash` refuses before `markScanFinished` of the refresh.
  - After it, a content-added-after-refresh case is still caught: step 8 uses the refresh's baseline.

The app side is verified by running it. The owner live-tests:
- launch with a snapshot;
- a change while the app was closed;
- a target switch;
- "Analisi completa".

## Left to the builder

- The binary layout, the checksum algorithm (CryptoKit's SHA-256 is fine), and whether derived tables are stored or rebuilt. These are bounded by the < 1 s load on about 3 M files; measure on the owner's disk.
- How the scan gets each entry's raw fields (device, link count, raw size for duplicates, both times) to the snapshot writer: kept in the tree, or rebuilt at write time. Measure the memory per file and report it.
- **The two-tree peak during a refresh.**
  - Measure it on the owner's disk.
  - If the peak exceeds about 1.5 GB, say so before the PR rather than work around it silently.
  - Possible ways out are the owner's to choose: drop the shown tree's chart caches during the refresh, or memory-map the snapshot for the reader.
- Where the last target is remembered (`UserDefaults`), and what happens when the remembered folder no longer exists: fall back to the startup disk and delete `folder.snapshot`.
