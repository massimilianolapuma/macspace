# Site and First Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship MacSpace v0.1.0 as a downloadable zip, with an MIT license and a one-page Italian site on GitHub Pages.

**Architecture:** A local shell script builds, signs (Apple Development), verifies and zips the Release app. A static `site/` is deployed by an Actions workflow. Screenshots come from our own app instance scanning `/Applications`.

**Tech Stack:** bash, xcodebuild, XcodeGen, ditto, gh, static HTML/CSS, GitHub Actions (`actions/upload-pages-artifact`, `actions/deploy-pages`).

**Spec:** `docs/superpowers/specs/2026-11-27-pages-release-design.md`

## Global Constraints

- Italian copy follows the design system's voice: informal "tu", sentence case, «…» for commands, no exclamation marks, no emoji.
- Orange is only for "si può liberare". Use the Fusion surfaces: #F6F3EE / #1C1C1E; ink: #1F1B16 / #FFFFFF.
- The release asset name is always `MacSpace.zip`. The tag is `v0.1.0`.
- No personal file names in any image.
- Commits are conventional, with no attribution lines. Never commit `Local.xcconfig`.

## Review Focus

- **Gatekeeper first open:** the steps on the page must match what macOS 27 actually shows for a quarantined, non-notarized app (Impostazioni di Sistema › Privacy e sicurezza › «Apri comunque»).
- **Download link:** `releases/latest/download/MacSpace.zip` must resolve after the release.
- **The zip:** it must keep the code signature. Check with `codesign --verify --deep --strict` on an unzipped copy.
- **Pages:** the workflow must deploy only `site/`. The page needs relative asset paths, because it is served under `/macspace/`.
- **Dark mode:** the page must follow `prefers-color-scheme` and show the dark screenshot in dark mode.

---

### Task 1: License, version, README

**Files:**
- Create: `LICENSE`
- Modify: `project.yml`, `README.md`

- [ ] **Step 1:** `LICENSE`: the MIT text, `Copyright (c) 2026 Massimiliano La Puma`.
- [ ] **Step 2:** `project.yml`, target `MacSpace`: set `MARKETING_VERSION: "0.1.0"` and `CURRENT_PROJECT_VERSION: "1"`.
- [ ] **Step 3:** `README.md`: add an Install section for users and a License line. Install covers:
  - downloading the zip from Releases;
  - moving the app to Applications;
  - the first open;
  - Full Disk Access.
- [ ] **Step 4:** Run `xcodegen generate -q` and a Debug build. Expected: `CFBundleShortVersionString` = 0.1.0 and `CFBundleVersion` = 1 in the built Info.plist.
- [ ] **Step 5:** Commit: `chore: MIT license, version 0.1.0, install notes`.

### Task 2: Release script

**Files:**
- Create: `scripts/release.sh`

- [ ] **Step 1:** Write `scripts/release.sh`. It must:
  - stop on any error;
  - require a clean tree, apart from untracked files;
  - read the version from `project.yml`;
  - run `xcodegen generate`, then `xcodebuild -configuration Release` into `build/`;
  - run `codesign --verify --deep --strict` and print the signing authority;
  - create `build/MacSpace.zip` with `ditto -c -k --keepParent`;
  - unzip it to a temporary folder and verify that copy again;
  - print the zip's sha256.
- [ ] **Step 2:** Run it. Expected: the authority is "Apple Development: …", both verifies pass, and the zip exists. Add `build/` to `.gitignore` if it is missing.
- [ ] **Step 3:** Commit: `build: local release script (signed zip)`.

### Task 3: Screenshots

- [ ] **Step 1:** Add an uncommitted DEBUG-only hook. When the env var `MACSPACE_SCAN` is set, the app starts a scan of that folder at launch. Launch our own instance with `open -n -g --env MACSPACE_SCAN=/Applications`, back up the defaults first, and set the color mode to Eliminabili. Capture our window with `screencapture -l<id>` in light and in dark (`-AppleInterfaceStyle Dark` via `--args`, or by switching the app's appearance in the harness).
- [ ] **Step 2:** Check that the images show no personal names. Save them as `site/img/app-light.png` and `site/img/app-dark.png`, resized to 1600 px wide. Restore the defaults, quit only our PID, and revert the hook.

### Task 4: Site and Pages workflow

**Files:**
- Create: `site/index.html`, `site/style.css`, `site/img/mark-light.svg`, `site/img/mark-dark.svg`, `site/img/icon.png` (`ictool` Default, 512)
- Create: `.github/workflows/pages.yml`

- [ ] **Step 1:** Write the page with the sections from the spec. The download button points to `https://github.com/massimilianolapuma/macspace/releases/latest/download/MacSpace.zip`. Use relative asset paths, and swap the light and dark images with `<picture>` and `prefers-color-scheme`.
- [ ] **Step 2:** Write the workflow:
  - triggers: push to main on `site/**`, plus `workflow_dispatch`;
  - permissions: `pages: write`, `id-token: write`;
  - steps: `upload-pages-artifact` with path `site`, then `deploy-pages`.
- [ ] **Step 3:** Render the page locally in light and dark (a headless capture or a quick look). Check the copy against the design system's voice.
- [ ] **Step 4:** Commit: `feat(site): one-page site and Pages workflow`.

### Task 5: Publish

- [ ] **Step 1:** Enable Pages with the `workflow` build type (`gh api -X POST repos/:owner/:repo/pages -f build_type=workflow`). Set the repository description and homepage.
- [ ] **Step 2:** Review the branch, then the owner checks, then open the PR and merge it. The site deploys from main.
- [ ] **Step 3:** On main:
  - tag `v0.1.0` and run `scripts/release.sh`;
  - run `gh release create v0.1.0 build/MacSpace.zip`, titled "MacSpace 0.1.0", with Italian notes (what it is, install steps, requirement).
- [ ] **Step 4:** Verify:
  - the Pages URL returns 200;
  - `releases/latest/download/MacSpace.zip` redirects to the asset;
  - a downloaded and unzipped copy passes `codesign --verify`.
