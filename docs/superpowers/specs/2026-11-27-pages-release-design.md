# MacSpace site and first release — design

Issue #18. Approved by the owner on 2026-11-27.

## Intent

The owner wants to use MacSpace and share it with a few friends. That needs a page to send them to and a download that works. Notarization is out of scope for now.

## Goals

- A public page in Italian that says what MacSpace is and shows it, in light and dark.
- The page links to the latest download and explains installation honestly:
  - the first-open warning;
  - Full Disk Access;
  - macOS 27 is required.
- A repeatable local release: one script produces `MacSpace.zip` from a tag.
- An MIT license.

## Non-goals

- Notarization and Developer ID.
- Auto-update.
- A Homebrew cask.
- An English page.
- CI builds of the app. GitHub's runners are unlikely to have Xcode 27 / macOS 27.

## Anti-goals

- A page that hides the Gatekeeper warning or promises more than the app does.
- Screenshots that show personal file names.
- Publishing the specs and plans as part of the site.

## Approaches

- **Signing.**
  - Apple Development certificate. **Chosen.** Its identity is stable across builds, so Full Disk Access granted once survives updates.
  - Ad-hoc. Rejected: TCC would lose the grant on every version.
  - Developer ID plus notarization. Rejected: owner's call, not now.
- **Site.**
  - Hand-written static HTML/CSS in `site/`, deployed by an Actions workflow (`actions/deploy-pages`). **Chosen.** `docs/` holds specs and plans that must not be published.
  - Jekyll or a `gh-pages` branch. Rejected: extra tooling for one page.
- **Build.** A local script. **Chosen.** CI was rejected (see non-goals).

## Decisions

- **License:** MIT, copyright 2026 Massimiliano La Puma.
- **Version:** `MARKETING_VERSION` 0.1.0, `CURRENT_PROJECT_VERSION` 1, both set in `project.yml`.
- **Release asset:** always named `MacSpace.zip` (a `ditto` zip of the signed Release app), so the page can link to `releases/latest/download/MacSpace.zip`. Tag `v0.1.0`.
- **Page:** a single `site/index.html` plus CSS and images:
  - the Fusion palette (sand / graphite, following `prefers-color-scheme`), with orange only where it means "si può liberare";
  - the Spicchio mark;
  - system fonts.
- **Page sections:**
  - hero with the mark, name and one-line pitch, and the download button;
  - light and dark screenshots;
  - three short "cosa fa" points (see where the space goes, the safety levels, nothing deleted without confirmation and always to the Trash);
  - installation steps;
  - requirements;
  - links to the source and the license.
- **Screenshots:** a scan of `/Applications` (no personal names), captured from our own app window, in light and dark.
- **Repository metadata:** description and homepage set to the Pages URL `https://massimilianolapuma.github.io/macspace/`.
