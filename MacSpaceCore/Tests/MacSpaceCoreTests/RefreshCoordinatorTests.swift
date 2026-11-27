import Testing
@testable import MacSpaceCore

/// A wait timer the test fires by hand: deterministic, no real time involved.
@MainActor
final class ManualTimer {
    private var pending: [CheckedContinuation<Void, Never>] = []
    private(set) var armed = 0

    func wait(_: Duration) async {
        armed += 1
        await withCheckedContinuation { pending.append($0) }
    }

    /// Lets every armed timer's sleep end (cancelled ones included: the coordinator must ignore them).
    func fire() async {
        await settle()  // armed timers reach their sleep first
        let all = pending
        pending = []
        all.forEach { $0.resume() }
        await settle()
    }
}

/// Work that blocks until the test opens it, to stand for a slow snapshot.
@MainActor
final class Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func pass() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() async {
        isOpen = true
        let all = waiters
        waiters = []
        all.forEach { $0.resume() }
        await settle()
    }
}

/// Lets queued main-actor tasks run to their next suspension.
@MainActor
func settle() async {
    for _ in 0..<20 { await Task.yield() }
}

@MainActor
@Suite struct RefreshCoordinatorTests {
    let timer = ManualTimer()
    let coordinator: RefreshCoordinator

    init() {
        let timer = timer
        coordinator = RefreshCoordinator(wait: { await timer.wait($0) })
    }

    @Test func fastRefreshNeverWaits() async {
        var applied = 0
        coordinator.request(userInitiated: true) { isLatest in if isLatest() { applied += 1 } }
        await coordinator.settled()
        await timer.fire()
        #expect(applied == 1)
        #expect(!coordinator.isWaiting)
    }

    @Test func slowRefreshWaitsAfterThresholdAndClearsOnLanding() async {
        let gate = Gate()
        coordinator.request(userInitiated: true) { _ in await gate.pass() }
        await settle()
        #expect(!coordinator.isWaiting)
        await timer.fire()
        #expect(coordinator.isWaiting)
        await gate.open()
        await coordinator.settled()
        #expect(!coordinator.isWaiting)
    }

    @Test func burstArmsOneTimerAndOnlyTheLastApplies() async {
        let gate = Gate()
        var applied: [Int] = []
        for n in 1...3 {
            coordinator.request(userInitiated: true) { isLatest in
                await gate.pass()
                if isLatest() { applied.append(n) }
            }
            await settle()
        }
        #expect(timer.armed == 1)
        await timer.fire()
        #expect(coordinator.isWaiting)
        await gate.open()
        await coordinator.settled()
        #expect(applied == [3])
        #expect(!coordinator.isWaiting)
    }

    @Test func refreshSupersededInTheSameTurnNeverRunsItsWork() async {
        var started: [Int] = []
        coordinator.request(userInitiated: false) { _ in started.append(1) }
        coordinator.request(userInitiated: false) { _ in started.append(2) }
        await coordinator.settled()
        #expect(started == [2])
    }

    @Test func tickerRefreshNeverArmsTheWait() async {
        let gate = Gate()
        coordinator.request(userInitiated: false) { _ in await gate.pass() }
        await settle()
        #expect(timer.armed == 0)
        await timer.fire()
        #expect(!coordinator.isWaiting)
        await gate.open()
        await coordinator.settled()
    }

    @Test func pendingIntentKeepsTheWaitAcrossNonUserRefreshes() async {
        coordinator.noteUserIntent()  // a goUp still resolving its target
        coordinator.request(userInitiated: false) { _ in }
        await coordinator.settled()
        await timer.fire()
        #expect(coordinator.isWaiting)
        coordinator.request(userInitiated: true) { _ in }  // the goUp's own refresh covers it
        await coordinator.settled()
        #expect(!coordinator.isWaiting)
    }

    @Test func abandoningTheLatestIntentEndsTheWait() async {
        let intent = coordinator.noteUserIntent()
        await timer.fire()
        #expect(coordinator.isWaiting)
        coordinator.abandonUserIntent(intent)
        #expect(!coordinator.isWaiting)
    }

    @Test func abandoningWhileARefreshIsInFlightLeavesTheWaitToItsLanding() async {
        let gate = Gate()
        coordinator.request(userInitiated: true) { _ in await gate.pass() }
        let intent = coordinator.noteUserIntent()
        await timer.fire()
        #expect(coordinator.isWaiting)
        coordinator.abandonUserIntent(intent)
        #expect(coordinator.isWaiting)
        await gate.open()
        await coordinator.settled()
        #expect(!coordinator.isWaiting)
    }

    @Test func abandoningAnOlderIntentIsIgnored() async {
        let older = coordinator.noteUserIntent()
        coordinator.noteUserIntent()
        coordinator.abandonUserIntent(older)
        await timer.fire()
        #expect(coordinator.isWaiting)
    }

    @Test func settledFollowsSupersessionsToTheLastRefresh() async {
        let first = Gate()
        var landed: [Int] = []
        coordinator.request(userInitiated: false) { isLatest in
            await first.pass()
            if isLatest() { landed.append(1) }
        }
        await settle()
        let waiter = Task { await coordinator.settled(); return landed }
        coordinator.request(userInitiated: false) { isLatest in if isLatest() { landed.append(2) } }
        await first.open()
        #expect(await waiter.value == [2])
    }
}
