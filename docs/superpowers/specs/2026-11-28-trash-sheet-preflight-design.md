# Trash sheet: check before the move (issue #29), design

Short design (small change). Approved by the owner on 2026-11-28.

## Intent

The sheet asks the user to confirm items that the move then refuses. In the live test of #28, a Photos library was added inside `a` after the scan. The sheet offered to move `a`, and only after the click did the user read "Non spostati — a contiene una libreria di Foto". The owner put it this way: "non ha senso fare l'azione se non è possibile farla". The sheet has to show what will not move before the user confirms.

## Goals

- When the sheet opens, every check that `ScanStore.trash` runs is run without moving anything. This covers steps 1–8, the contents added after the scan included. Each blocked row shows its reason, dimmed, the way rows held by open files show today.
- One code path for the two: `trash` calls the same check function right before each move. The preview and the move cannot judge differently, only at different times.
- The check at move time stays. If something changes between the preview and the click, the result sheet reports it as today ("Non spostati").

## Non-goals

- Disabling "Sposta nel Cestino…" in the menus and toolbar before the sheet opens. That would need a disk check on every selection change.
- Watching the disk while the sheet is open.
- Changing what the checks decide.

## Anti-goals

- A preview that says "will move" for something the move would refuse, because the two run different code.
- A sheet that jumps or flashes while the check runs.

## Approaches

1. **Chosen: extend the sheet's existing open-files check to the store's whole check.** The sheet already runs a check when it opens ("Controllo dei file aperti…" in the title, the button disabled until done, held rows dimmed with a note). The store's check replaces that open-files read: it reads the open files itself (step 5) and names the holders the same way (`TrashSkip.openNow(use).text`). Little new UI, and the visual language stays the same.
2. Keep the sheet's own open-files check and add a separate content check. Rejected: that would mean two checks that overlap, and two paths that can disagree.
3. Check from the main window as soon as items are selected. Rejected: too costly, and it is the non-goal above.

## Decisions

### Core (`MacSpaceCore`)

- **One check function, used by both.** The per-item check of `trash` is split out:
  - the call-level gates: nothing left, scan not finished, open files incomplete, mount table unreadable;
  - steps 1–8 per item, with one history query and one content budget per call.

  `trash` calls it, then moves every item that passes, one by one. **Builder's call:** whether `trash` calls the check per item, right before each move, or once for all items. Per item keeps step 7 "right before the move" as today; it must stay that way.
- **A public preview.** It takes ids, packages, openFiles and expectedVerdicts and returns what each `topMost` item would get, as `[NodeID: TrashSkip]` (an absent item would move). It never calls `DiskActions`, never changes the tree and never sets the environment: it judges against the environment the store has now, the one the rows on screen show. The move still gets the live environment (R41).
- **Its own budget.** The preview has the same 10 s budget as `trash`. Past it, items are `.containsUnverified`, the same fail-closed outcome.

### Sheet (`TrashConfirmationSheet`)

- **When it runs.** `prepare()` runs the preview where the open-files read runs now, side by side with the estimates. It runs again whenever the rows are refreshed (`verdictRevision`, environment updates). Results from an older run or another store generation are dropped.
- **While it runs.** The title reads **"Controllo degli elementi…"** with the small spinner, replacing "Controllo dei file aperti…". The move button stays disabled until the preview is in.
- **Blocked rows.** A row the preview blocks is dimmed with `TrashSkip.text` as its note, as rows held by open files are now, and it is left out of the move. "Gli elementi in grigio restano dove sono." and "Niente da spostare" behave as today.
- **Reasons that apply to every item.**
  - `.cannotCheckOpenFiles`: the warning line "Impossibile verificare i file aperti", with the button disabled (as `.incomplete` today).
  - `.scanInProgress` and `.appsAnalysisInProgress`: the sheet already handles them through `trashUnavailableReason`.
- **At the click.** The move sends only the included rows, as now. Rows the preview blocked go to the result's "left out" list with their notes, as open rows do now.

### Copy

- New catalog key: "Controllo degli elementi…".
- "Controllo dei file aperti…" goes if nothing else uses it.

## Left to the builder

- The names of the check function and the preview.
- Whether `OpenCheck` becomes a preview state or is replaced.
- How the open-file holder note and the preview note merge; there is one note per row.

## Testing

- **Core tests:**
  - the preview blocks with the same reasons `trash` would skip with: protected content added after the scan, an open file, an item gone, a replaced item;
  - the preview moves nothing and leaves the tree and the environment unchanged;
  - a `trash` right after a clean preview still re-checks: content added between the preview and the move is caught.
- **App:** build. Then the owner's live test: add a Photos library after the scan, open the sheet, and see `a` dimmed with "contiene una libreria di Foto" before any click.
