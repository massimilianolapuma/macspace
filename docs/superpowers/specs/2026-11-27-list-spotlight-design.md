# Spotlight for list hover and highlighted suggestions — design

Issue #21. The owner picked direction B ("Riflettore") on 2026-11-27, to try live.

## Intent

When the pointer rests on a row of the Elementi list, the user must see at once which element of the chart it is. Today the only cue is a 12-point lift, which is easy to miss. Items highlighted from Suggerimenti have the same problem: they only get a thin outline.

## Approaches (shown as mockups)

- A. Lift only (today).
- **B. Riflettore** (chosen): every other element dims; the target stays at full strength, with an ink outline.
- C. A pulsing outline.
- D. B plus a single pulse.

## Design

- **Spotlight targets.** The node under a hovered list row (`ScanModel.listFocus`). With no list hover, the highlighted suggestion items (`highlighted`).
- **Mask.** A layer above the chart dims everything except:
  - the targets, each a sunburst sector reaching out through its rings, or a treemap tile;
  - the sunburst center disc.

  It fills with the window background at 0.68 opacity, so the rest shows at about a third. It is drawn in the existing selection layers, which only exist while there is something to draw.
- **Outline.** Targets get the existing "highlighted" outline: ink line plus casing. Selected items keep their own outline.
- **When it does nothing.** A target that is not on screen draws no mask. Mouse hover on the chart itself is unchanged: lift only, no spotlight.
- **Clearing.** `listFocus` is cleared when the pointer leaves the row and on any navigation.
- **Color.** No orange anywhere.

## Left open

- A short fade in and out (not under Reduce Motion), if the instant switch feels abrupt in the live test.
