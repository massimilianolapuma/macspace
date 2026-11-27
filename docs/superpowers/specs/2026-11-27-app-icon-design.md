# MacSpace app icon — design

Issue #15. Approved by the owner on 2026-11-27.

## Intent

MacSpace has no app icon. The owner wants a mark that is unique to this app and recognizable in the Dock. It may be stylized and need not literally depict what the app does. It comes from the MacSpace design system (Fusion).

## Goals

- A dedicated mark, legible from 16 pt up, in light, dark, tinted and clear appearances.
- It must follow Fusion: neutral sand / graphite, and orange (`accent`) only with its meaning in the app: "this can be removed".

## Non-goals

- A wordmark.
- A marketing logo.
- Icons for documents.

## Anti-goals

- Anything that reads as another disk analyzer's icon.
- Orange used as decoration.
- An icon that turns to mush at 16 pt.

## Approaches considered

1. **Icon Composer `.icon` file**, with layered SVG and automatic Liquid Glass and appearances. **Chosen.** The deployment target is macOS 27, so this is the native format and the only one that gets glass and the tinted and clear variants.
2. **Classic `AppIcon.appiconset` PNGs.** Rejected: no glass, no automatic appearances, and a set of bitmaps to keep in sync.
3. **Both, with PNGs as a fallback.** Rejected: nothing older than macOS 27 runs the app.

## Design (direction "C · Spicchio", picked by the owner from six sketches)

- **Mark:** the sunburst reduced to a sign. It is a neutral ring (inner radius 1/3 of the outer) in two arcs with a hairline gap between them. A 56° orange wedge sits at the top right, lifted outward along its bisector so it reads as a slice coming free.
- **Colors (Fusion):**

  | Part | Light | Dark |
  |---|---|---|
  | Ring arcs | `ring-1` / `ring-2` tones (#5F574E, #918578) | #C7C7CC, #8E8E93 |
  | Background | sand paper (#FAF8F4 → #E8E1D6) | graphite (#3A3A3E → #1C1C1E) |
  | Wedge | `accent` hsl(16, 88%, 57%) | hsl(16, 85%, 56%) |

- **Layers:** background, ring, wedge (on top, so it takes the glass highlight). macOS derives the tinted and clear appearances.
- **Files:**
  - `App/MacSpace/AppIcon.icon` (`icon.json` plus SVG layers), compiled by Xcode as the app icon, wired through `project.yml`;
  - the reproducible source of the geometry under `design/icon/`.
- **Verification:** previews rendered with `ictool`, then checked live in the Dock, Finder, the About window and ⌘⇥, in light, dark and tinted.
- **Design system:** the mark is added to the MacSpace design system (a Logos asset group), and the "Marchio" section is updated.

## Left to the builder

- The exact layer split and glass settings in `icon.json`.
- Fine optical adjustments at small sizes, as long as the geometry above stays recognizable.
