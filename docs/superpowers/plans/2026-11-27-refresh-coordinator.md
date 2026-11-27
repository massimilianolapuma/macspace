# Refresh Coordinator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `ScanModel`'s latest-wins refresh and wait-state logic into a tested `RefreshCoordinator` in MacSpaceCore.

**Architecture:** `ScanModel` holds a `RefreshCoordinator` and delegates `requestRefresh`, `refreshViews`, `noteUserIntent` and `abandonUserIntent` to it. `isWaiting` reads through to the coordinator, which is `@Observable`. Snapshot and apply code stay in the app.

**Tech Stack:** Swift 6.4 strict concurrency, Observation, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-27-refresh-coordinator-design.md`

## Global Constraints

- Keep the behavior identical to `ScanModel` at `658a372`. The threshold stays 150 ms.
- MacSpaceCore stays UI-free: no SwiftUI, no AppKit.
- Commits are conventional, with no attribution lines.

## Review Focus

- **Stuck wait:** `isWaiting` must never stay true after the latest covering refresh ends, after it is superseded, or after the latest intent is abandoned.
- **Wait flashes:** a refresh that lands before the timer fires must never show the wait.
- **Cancelled timer:** when the timer is cancelled and later fires, nothing must change.
- **Isolation:** the work closure runs on the main actor, and `isLatest()` checks the refresh's own task.
- **App behavior unchanged:** drilling, going up, switching charts, scan ticks and the post-scan sequence behave as before.

---

### Task 1: RefreshCoordinator with tests

**Files:**
- Create: `MacSpaceCore/Sources/MacSpaceCore/Refresh/RefreshCoordinator.swift`
- Create: `MacSpaceCore/Tests/MacSpaceCoreTests/RefreshCoordinatorTests.swift`

**Interfaces (produces):**

```swift
@MainActor @Observable public final class RefreshCoordinator {
    public static let defaultThreshold: Duration                       // 150 ms
    public init(threshold: Duration = defaultThreshold,
                wait: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) })
    public private(set) var isWaiting: Bool
    public func request(userInitiated: Bool, _ work: @escaping @MainActor (_ isLatest: @escaping @MainActor () -> Bool) async -> Void)
    public func settled() async
    @discardableResult public func noteUserIntent() -> Int
    public func abandonUserIntent(_ intent: Int)
}
```

- [ ] **Step 1:** Write the nine tests from the spec. Use two test helpers: a `ManualTimer`, which counts arms, resumes on `fire()` and resumes when cancelled, and a `Gate`. Run `swift test --filter RefreshCoordinatorTests`. Expected: a compile failure (RED).
- [ ] **Step 2:** Port the logic from `ScanModel.swift:157-181,316-403` at `658a372`.
- [ ] **Step 3:** Run `swift test --package-path MacSpaceCore`. Expected: all green, 307 plus the new tests.
- [ ] **Step 4:** Commit: `feat(core): RefreshCoordinator — latest-wins refresh and the wait state, tested`.

### Task 2: ScanModel delegates to it

**Files:**
- Modify: `App/MacSpace/ScanModel.swift`

- [ ] **Step 1:** Make the changes:
  - remove the moved state;
  - `isWaiting` becomes `refresher.isWaiting`;
  - `requestRefresh` calls `refresher.request(userInitiated:) { [weak self] isLatest in await self?.performRefresh(isLatest:) }`;
  - `refreshesSettled` calls `refresher.settled()`;
  - `noteUserIntent` and `abandonUserIntent` forward to the coordinator;
  - `performRefresh` uses `isLatest()`.
- [ ] **Step 2:** Run a Debug build with `-quiet`. Expected: exit 0 and no warnings. Run the core tests and confirm they are green.
- [ ] **Step 3:** Launch our own instance (folder scan via a temporary harness, or by hand) and drill, go up and switch charts. Expected: the same behavior as before.
- [ ] **Step 4:** Commit: `refactor(app): ScanModel delegates refresh and the wait state to RefreshCoordinator`.
