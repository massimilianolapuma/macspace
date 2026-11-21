# MacSpace — Design

Date: 2026-11-21 · Status: approved by owner (2026-11-21)

## 1. Intent

The owner wants a personal macOS app that replaces the built-in *System Settings › General › Storage* view, because that view doesn't make it easy to understand **which files and folders take up space**. On top of that, the app must be **intelligent**: tell whether files are still used by an application (e.g. content of `~/Library`), and let the owner **reclaim space safely**, always by moving to the Trash after an explicit confirmation.

It must be **fast** and have **striking, elegant visuals**.

Prior art, in the owner's words: DaisyDisk was fine but is paid; CleanMyMac has too many features and "messes up the Mac". MacSpace is the focused, free, personal alternative: it does one thing well.

Audience: the owner only, on their own Mac. Not distributed.

## 2. Goals, non-goals, anti-goals

**Goals**
- In a few seconds, show where disk space goes, with drill-down into folders.
- For each item, say whether it is still needed by an app and how risky it is to remove it.
- Surface ready-made findings (Suggestions) with space totals.
- Move selected items to the Trash after confirmation; fully recoverable from Finder.
- For cloud-synced files, optionally free space by removing only the local copy (the file stays in the cloud).
- Feel native, fast, and beautiful.

**Non-goals**
- No "optimization", RAM cleaning, antivirus, malware, privacy cleaning, app updater, login-item manager, etc.
- No Mac App Store distribution, no sandbox.
- No permanent deletion inside the app (Trash only; the user empties the Trash in Finder). The only other disk action is "remove local copy" of cloud-synced files (§5.6), which never deletes data from the cloud.
- No deleting APFS local snapshots or touching system-managed purgeable space (shown as information only).

**Anti-goals** (failure even if it technically works)
- Anything that runs when the app is closed: no daemons, no launch agents, no login items, no system/kernel/file-provider extensions, no privileged helper.
- Changing anything on disk other than (a) moving user-confirmed items to the Trash, (b) user-confirmed "remove local copy" of cloud-synced items, and (c) the app's own cache/settings in its own folders.
- Ever moving to the Trash something classified **protected**.
- Automatic or scheduled cleaning of any kind.
- Feature bloat: every new feature must serve "understand where space goes" or "reclaim it safely".

## 3. Constraints

- Owner's machine: macOS 27.2.1, Xcode 27.2, Swift 6.4. **Deployment target: macOS 27** (only this Mac; use the latest SwiftUI freely).
- Native Swift + SwiftUI. Swift 6 language mode with strict concurrency.
- **Not sandboxed**, signed with the owner's free Apple ID (Personal Team) so the *Full Disk Access* (TCC) grant survives rebuilds. The app must detect missing Full Disk Access and guide the user to System Settings with a clear onboarding screen; without it, scan what is readable and mark unreadable folders as such.
- UI language: **Italian**. Code, identifiers, comments, commits: English. Strings go through a String Catalog so other languages are possible later.
- No third-party dependencies unless clearly justified (none expected).

## 4. Approaches considered

| Approach | Trade-offs | Verdict |
|---|---|---|
| **A. All native: Swift + SwiftUI**, scanner on `getattrlistbulk`, charts drawn with SwiftUI `Canvas` | Fastest scanning API on macOS, low memory, native look for free (light/dark, SF fonts, controls), direct access to LaunchServices / Spotlight / libproc / Trash. Charts must be hand-built (known algorithms). One language. | **Chosen by the owner.** |
| B. Tauri: Rust scanner + web UI (D3) | Rust is fast, D3 is great for sunburst/treemap. But the UI is a web page imitating native; two languages; Swift bridges still needed for Spotlight/Trash/LaunchServices. | Rejected: works against "native" and simplicity. |
| Electron | Heavy. | Rejected: opposite of "doesn't mess up the Mac". |
| SwiftUI + Rust core via FFI | Double complexity for speed Swift already reaches. | Rejected. |

## 5. What the owner decided

### 5.1 Views
- Two chart views with a segmented switcher in the toolbar: **Raggiera** (sunburst — default on first launch) and **Treemap** (squarified, "curated" look: rounded corners, gaps between blocks, discreet section headers inside parent blocks). The app remembers the last used view.
- Both views show the same data and share **selection** and **current folder**: switching view keeps context.
- Sunburst: center = current folder with total size; rings = deeper levels (show 3 levels below the current folder at once). Click a segment = drill in; click center / breadcrumb / ⌘↑ = go up.
- Treemap: parent blocks contain child blocks; click = drill in; same navigation.
- Next to the chart: a list of the biggest items at the current level (name, size, safety marker), plus breadcrumbs for the path.
- Hover on any segment/block shows a tooltip with name, size, last used date, owning app (if known) and safety level. Labels only appear where there is room.
- Coloring modes (toggle): **default "deletable highlight"**, **by category**, **by last use** (age heat — the idea kept from the rejected isometric "City" view).
- **"By category" means by file type** (owner decided 2026-11-21, option B): each file gets one category; a folder takes the color of the category that weighs most inside it. Categories (Italian labels): Video · Foto e immagini · Musica e audio · Documenti · App · Sviluppo · Archivi e installer · Sistema · **Dati delle app e cache** · Altro. Classification by extension plus context (inside an `.app` bundle → App; inside developer folders such as `node_modules`, `DerivedData`, `.git` → Sviluppo; system locations → Sistema; `~/Library` app data → Dati delle app e cache). *"Dati delle app e cache" was added by the builder because `~/Library` is usually the biggest area and would otherwise be "Altro".*
- **"Last use" in plan 2 is an estimate** from file timestamps (most recent of modification and access time; a folder's value is the most recent of anything inside). Plan 3 refines it with Spotlight's last-used date. UI says "Ultimo uso (stimato)".
- Until the safety rules exist (plan 3), the default coloring is **neutral** (plain Fusion); "deletable highlight" replaces it as default in plan 3.
- A legend under the chart shows the colors in use; in category mode it also lists how much each category takes in the current folder.

### 5.2 Visual style: "Fusion"
- Follows the system appearance automatically.
- Light: warm neutral sand tones (paper-like background `#f6f3ee`-ish, neutrals around `hsl(30,10%,34–80%)`).
- Dark: graphite neutrals (`#1c1c1e`-ish background, `hsl(240,4%,26–58%)`).
- Everything is neutral **except what can be removed, which lights up in orange** (accent around `hsl(14–18, 85–90%, 56–58%)`). This is the core visual idea: the eye goes straight to what can be deleted.
- Typography: system font (SF Pro). Native controls (segmented picker, toolbar, sheets).
- Safety levels in this style:
  - 🟢 **safe** → solid orange
  - 🟡 **caution** → soft/hatched orange ("look before deleting")
  - ⚪ **normal** → neutral, selectable (standard confirmation)
  - 🔴 **protected** → neutral with a small lock glyph; not selectable for Trash
- Must be legible: never rely on color alone (lock glyph, hatching, labels in tooltip/list). Respect *Reduce Motion*.
- Reference mockups (throwaway HTML) live in `.superpowers/brainstorm/` — not committed; the description above is authoritative.

### 5.3 Scanning & speed
- Default target: the startup volume (**Macintosh HD**, whole disk). The user can also pick another mounted volume or any folder.
- Live progressive rendering: the chart fills in while the scan runs.
- **Middle way for speed (no background process):** on scan completion, persist a snapshot of the tree to the app's cache folder. On next launch: show the last snapshot instantly (clearly marked "aggiornato a <time>"), then refresh only what changed. Changed directories are found with **FSEvents history** (`FSEventStreamCreate` with `sinceWhen` = last saved event ID, which works even though the app was not running); fall back to a full rescan if history is unavailable (e.g. event ID invalidated, volume changed).
- Sizes are **allocated size on disk**. Hard links counted once (by inode/device). Do not follow symlinks. Do not cross into other volumes/mount points during a scan (firmlinks of the system volume group must not double count `/System/Volumes/Data`).
- APFS clones: where available, use the file's private size (`ATTR_CMNEXT_PRIVATESIZE`) to report "space actually freed if removed" alongside total size.
- Show at volume level: capacity, used, available, and (as info) purgeable space and local snapshots, explaining why totals can differ from Finder/System Settings.

### 5.4 Intelligence
Every node gets: owning app (if any), last used date, "open right now" flag (checked on demand), safety level, and a reason string in Italian ("Cache di Spotify, app non in esecuzione: si rigenera da sola").

Signals:
1. **Installed apps index**: bundle IDs, names, team IDs and paths of installed apps (`/Applications`, `~/Applications`, `/System/Applications`, plus Spotlight query for application bundles elsewhere). Used to map `~/Library` folders to apps.
2. **Leftovers**: folders in `Application Support`, `Caches`, `Containers`, `Group Containers`, `Preferences`, `Saved Application State`, `HTTPStorages`, `WebKit`, `Logs`, `LaunchAgents` whose bundle ID / name / team prefix matches no installed app.
3. **Last used**: Spotlight `kMDItemLastUsedDate`, falling back to access/modification dates.
4. **Open now**: files held open by running processes the user can inspect (libproc). Running apps via `NSWorkspace.runningApplications`.

Safety levels: **four**. Owner confirmed the cloud handling; the "normal" level and the never-touch list were proposed after the builder check and are marked *(builder-check call, owner to confirm on review)*.

Safety rules (initial set; thresholds are the builder's call and must be easy to tune in one place):
- **Never-touch list → protected** *(builder-check call)*: Apple per-user data whose removal breaks apps even if recoverable — `~/Library/Keychains`, `~/Library/Mail`, `~/Library/Messages`, `~/Library/Containers/com.apple.*` data of system apps, Photos libraries (`*.photoslibrary`, as a whole), `~/Library/Mobile Documents` root itself, and the **interior of any package/bundle** (apps, libraries): a package can be shown with its size and drilled into for information, but only the package as a whole is selectable (and only if its level allows it).
- **Protected**: anything on the sealed system volume or SIP-protected locations; anything the user cannot write/move; files currently open; the data (non-cache) folders of currently running apps; the user's Trash itself; iCloud-managed placeholders treated carefully (never mark dataless items as space savers).
- **Caution**: data of installed apps (not caches); user documents/media not used for a long time; anything uncertain.
- **Normal** *(builder-check call)*: ordinary user items that match no rule (recent videos, project folders, apps in `/Applications`, etc.). Drawn **neutral**, never suggested, but selectable and trashable with the standard confirmation. Most of the chart is "normal" — this keeps the core visual idea (only removable things light up).
- **Safe**: caches of apps not currently running; leftovers of uninstalled apps; installers (`.dmg`, `.pkg`, `.xip`) — especially when the corresponding app is already installed; known regenerable developer caches (e.g. Xcode `DerivedData`, package-manager caches).

**Cloud-synced locations** (owner decided): iCloud Drive (incl. synced Desktop/Documents, `~/Library/Mobile Documents`), `~/Library/CloudStorage/*` (Dropbox, OneDrive, Google Drive…), iCloud-synced Photos.
- Downloaded synced items are at least **caution**, with an explicit warning in tooltip and confirmation sheet: *"Verrà eliminato anche da iCloud/<provider> e dagli altri dispositivi."*
- Dataless placeholders (not downloaded) occupy ~0 local space: show them as such, never count them as reclaimable.
- New action **"Rimuovi solo la copia locale"** (see §5.6) is offered for downloaded synced items and is the recommended way to reclaim space there; a dedicated suggestion lists large downloaded cloud items.
- iCloud Photos library: protected as a whole; tooltip hints at Photos › Settings › "Ottimizza spazio".

### 5.5 Suggestions panel
Automatic findings computed during the normal scan:
1. **Avanzi di app disinstallate** (leftovers)
2. **Cache rigenerabili** (🟢 if owning app not running, 🟡 if running)
3. **File d'installazione** (.dmg/.pkg/.xip anywhere, with "<App> è già installata" hint when matched)
4. **Copie locali di file nel cloud** — large downloaded cloud-synced items; action = "Rimuovi solo la copia locale" (not Trash)

Each suggestion shows a total and its items (all pre-selected except 🟡), highlights them in the chart on click, and offers "Sposta nel Cestino…".

**Duplicates — on demand only**: a "Cerca duplicati…" button shows a warning first (reads file contents, may take minutes and warm up the Mac; continue?). Algorithm: group by size → partial hash → full hash; ignore files < 1 MB; detect APFS clones and label them "non occupano spazio doppio"; cancellable at any time with progress.

### 5.6 Deleting
- Selection works from chart, list or suggestions; protected items can't be selected.
- "Sposta nel Cestino…" opens a confirmation sheet: list of items, total space freed (using private size where relevant), warnings for each 🟡 item.
- Immediately before moving, re-check each item (still exists, not open now, still not protected). Skip and report any that changed.
- Move via the system Trash API so Finder's "Put Back" works. Report result (freed space, failures with reasons). Update the tree in place without a full rescan.
- **Remove local copy** (cloud items only): separate button and its own confirmation ("Il file resta su iCloud/<provider>; verrà riscaricato quando lo apri"). Uses the system eviction API for iCloud items (`FileManager.evictUbiquitousItem(at:)`); for third-party File Provider locations use the supported system mechanism if one is available to non-provider apps — if not, the builder documents the limitation and the app only shows the warning + a "Mostra nel Finder" button (Finder offers "Rimuovi download"). Never fall back to deleting.
- Keep an in-app history of moves for the session (name, size, date, "Mostra nel Cestino").

## 6. Architecture (agreed shape)

- **`MacSpaceCore`** — local Swift package, no UI, fully unit-testable with `swift test`:
  - scanner (`getattrlistbulk`, parallel with Swift concurrency, cancellable, progress stream)
  - compact tree model designed for millions of nodes
  - snapshot persistence + FSEvents-based incremental refresh
  - apps index, leftovers detection, last-used lookup, open-files check
  - safety rules engine, suggestions, duplicates finder
  - disk actions (`moveToTrash`, `evictLocalCopy`) behind a protocol so tests don't touch the real Trash or cloud
- **`MacSpace`** — SwiftUI app target: window, toolbar, sunburst & treemap renderers (`Canvas`), list, breadcrumbs, suggestions, confirmation sheet, onboarding for Full Disk Access, settings.
- Layout algorithms (sunburst angles, squarified treemap) live in Core as pure functions so they are testable; rendering stays in the app.

## 7. Quality bar

- Performance targets (Apple Silicon, internal SSD): first chart visible < 1 s after starting a scan; full scan of ~1 TB / ~3 M files ≲ 60 s; reopen from snapshot < 1 s; smooth (60 fps+) hover and drill-in animations; memory well under 1 GB for 3 M files.
- Tests: TDD for Core (scanner on temporary fixture trees incl. hard links, symlinks, permission-denied folders; rules; suggestions; layout math; snapshot round-trip; duplicates). UI verified by running the app.
- Safety is the top priority: a bug that could trash a protected item is a release blocker.

## 8. Skills to use while building (agreed with the owner)

- Process: `superpowers:writing-plans` → `superpowers:subagent-driven-development` (or `executing-plans`), `superpowers:test-driven-development`, `superpowers:verification-before-completion`, `superpowers:finishing-a-development-branch`.
- Visual design: `ui-ux-pro-max` (SwiftUI stack guidance, palettes, a11y), `impeccable` (direction, hierarchy, motion, polish), `dataviz` (sunburst/treemap color & legibility).
- Quality: `security-review` (the app moves files to Trash), `code-review`, `simplify`, `run` to launch and see the app. Swift LSP plugin is active.

## 9. Left to the builder

- Exact data structures for the tree and snapshot file format.
- Exact thresholds (e.g. what "not used for a long time" means), the list of known regenerable caches, and the leftovers matching heuristics — kept in one tunable place.
- Animation details, exact color tokens within the described palette, window layout proportions, iconography (SF Symbols).
- App icon (optional, later).
- Project/Xcode setup details, bundle ID, test target layout.
