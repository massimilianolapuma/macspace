# Refresh coordinator in MacSpaceCore — design

Issue #17. Approved by the owner on 2026-11-27 (approach 1).

## Intent

Lock down, with automated tests, the navigation logic added in #12:

- the latest view refresh wins;
- the 150 ms wait state;
- user intents that resolve their target asynchronously (going up, reveal, highlight).

Today this logic lives inside `ScanModel` and is verified only by reading the code. A future edit could break it silently.

## Approaches

1. **Move the logic into `MacSpaceCore`** as a UI-free `RefreshCoordinator`, tested with `swift test`, with the timer and the work injected. `ScanModel` delegates to it. **Chosen.** Tests are fast and deterministic and run with the other 307.
2. **Add an app-hosted unit-test target** that tests `ScanModel` as it is. Rejected:
   - every test run would launch the app, through slow `xcodebuild` runs;
   - simulating a slow store would need a hook inside `ScanStore` anyway.

## Design

- `MacSpaceCore/Sources/MacSpaceCore/Refresh/RefreshCoordinator.swift` is a `@MainActor @Observable public final class` with:
  - `isWaiting` (observable);
  - `request(userInitiated:_:)`;
  - `settled()`;
  - `noteUserIntent()`;
  - `abandonUserIntent(_:)`.
- The work closure receives an `isLatest` check. The wait timer is an injected `wait: (Duration) async -> Void`, by default a cancellable `Task.sleep`.
- The behavior is exactly today's:
  - latest wins, by generation number and cancellation;
  - a superseded refresh never starts its work;
  - the wait arms on the user's intent, and a burst keeps the earliest deadline;
  - the wait clears when a refresh that covers the latest intent ends, or when the latest intent is abandoned with no refresh in flight;
  - scan-ticker (non-user) refreshes never arm the wait, and never clear a pending intent's wait.
- `ScanModel` keeps:
  - its public API (`requestRefresh`, `refreshViews`, `noteUserIntent`, `abandonUserIntent`);
  - `isWaiting`, now read through to the coordinator;
  - the snapshot and apply code, and `shownChart`.

## Tests (Swift Testing, deterministic: manual timer and gated work)

- A fast refresh never waits.
- A slow refresh waits after the threshold and clears on landing.
- A burst arms a single timer and only the last refresh applies.
- A refresh superseded in the same turn never runs its work.
- Ticker refreshes never arm the wait.
- A pending intent keeps the wait across a non-user refresh, and the user refresh that covers it clears it.
- Abandoning the latest intent ends the wait, unless a refresh is in flight; then the landing clears it.
- Abandoning an older intent is ignored.
- `settled()` follows supersessions to the last refresh.

## Out of scope

- `shownChart`, and the apply-side checks (store, center and chart identity) stay in `ScanModel`. They need a real store, so the app check covers them.
- An app test target is not added (approach 2).
