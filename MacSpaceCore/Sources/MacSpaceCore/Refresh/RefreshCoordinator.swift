import Observation

/// Runs view refreshes latest-wins and tells when a user's request has been pending too long.
///
/// - **Latest wins.** Each `request` cancels the previous refresh and bumps a generation; a refresh
///   superseded before it starts never runs its work, and the work's `isLatest` turns false the moment
///   a newer one is requested, so a stale result is never applied.
/// - **Wait state.** A user intent (`noteUserIntent`, or a `request(userInitiated: true)`) arms a
///   timer for a deadline fixed at that moment; if it passes before the intent is resolved,
///   `isWaiting` turns true. A burst keeps the first deadline. The wait ends when the latest refresh,
///   of any kind, ends (landed or dropped) with every intent covered by a refresh, or when the latest
///   intent is abandoned with no refresh in flight. Refreshes nobody waits for (a scan's periodic one)
///   never arm it, and never end a wait an unresolved intent still holds.
@MainActor @Observable
public final class RefreshCoordinator {
    /// How long a user's request may stay pending before the wait state shows.
    nonisolated public static let defaultThreshold: Duration = .milliseconds(150)

    /// Whether a user's request has been pending for the threshold without being resolved.
    public private(set) var isWaiting = false

    @ObservationIgnored private let threshold: Duration
    @ObservationIgnored private let wait: @MainActor (Duration) async -> Void
    /// The latest refresh; each new one cancels it.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Bumped by every `request`: a refresh's work is wanted only while its number is the latest.
    @ObservationIgnored private var generation = 0
    /// Whether the latest refresh has not yet returned.
    @ObservationIgnored private var refreshInFlight = false
    /// User intents noted so far, and how many a refresh has been issued for: a refresh that ends
    /// while `coveredIntents == intentCount` resolves the latest intent.
    @ObservationIgnored private var intentCount = 0
    @ObservationIgnored private var coveredIntents = 0
    /// The armed wait timer; `endWaiting` cancels it, so a timer that wakes after that does nothing.
    @ObservationIgnored private var waitTimer: Task<Void, Never>?

    /// - Parameters:
    ///   - threshold: how long an intent may stay pending before `isWaiting` turns true.
    ///   - wait: sleeps for the given duration (what is left of the threshold when the timer task
    ///     starts); may return early when its task is cancelled. Injected by tests.
    public init(threshold: Duration = defaultThreshold,
                wait: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.threshold = threshold
        self.wait = wait
    }

    /// Starts a refresh, cancelling the previous one. `work` runs on the main actor unless a newer
    /// request supersedes this one first; it should check `isLatest()` after each suspension and apply
    /// nothing once it is false. Call `isLatest` from within `work`, not from a task it spawns: it also
    /// reads the calling task's cancellation. `userInitiated`: something the user is waiting for
    /// (navigation, chart change); it counts as a user intent, resolved by this refresh.
    public func request(userInitiated: Bool,
                        _ work: @escaping @MainActor (_ isLatest: @escaping @MainActor () -> Bool) async -> Void) {
        if userInitiated {
            noteUserIntent()
            coveredIntents = intentCount
        }
        refreshTask?.cancel()
        generation += 1
        let number = generation
        refreshInFlight = true
        refreshTask = Task {
            // However the latest refresh ends (landed or dropped), the wait is over, unless a user
            // intent is still pending that no refresh has been issued for yet (a goUp or reveal that is
            // resolving its target): a refresh issued by anyone else must not hide that wait.
            defer {
                if number == generation {
                    refreshInFlight = false
                    if coveredIntents == intentCount { endWaiting() }
                }
            }
            // Superseded before it started (several requests in one turn): no work at all.
            guard isLatest(number) else { return }
            await work { self.isLatest(number) }
        }
    }

    /// Returns once the latest refresh has ended, following any newer one that supersedes it meanwhile.
    public func settled() async {
        while let task = refreshTask {
            await task.value
            if refreshTask == task { return }
        }
    }

    /// The user asked for something that will change the views: the wait arms now, not when the
    /// refresh is issued (which may follow an actor round trip). Call synchronously at the top of the
    /// action; every call must end in a `request(userInitiated: true)` or an `abandonUserIntent`.
    /// Returns the intent's number.
    @discardableResult
    public func noteUserIntent() -> Int {
        intentCount += 1
        guard waitTimer == nil else { return intentCount }
        // The deadline is fixed now: a busy main actor must not push the wait later.
        let deadline = ContinuousClock.now.advanced(by: threshold)
        waitTimer = Task { [weak self, wait] in
            await wait(ContinuousClock.now.duration(to: deadline))
            // Cancelled by `endWaiting` (the intent resolved, or a new timer replaced this one).
            guard let self, !Task.isCancelled else { return }
            setWaiting(true)
        }
        return intentCount
    }

    /// The action that noted `intent` ended without refreshing anything. Unless a newer intent is
    /// pending, or a refresh is still under way (its end clears the wait), the wait ends now.
    public func abandonUserIntent(_ intent: Int) {
        guard intent == intentCount else { return }
        coveredIntents = intentCount
        if !refreshInFlight { endWaiting() }
    }

    private func isLatest(_ number: Int) -> Bool {
        !Task.isCancelled && number == generation
    }

    private func endWaiting() {
        waitTimer?.cancel()
        waitTimer = nil
        setWaiting(false)
    }

    private func setWaiting(_ value: Bool) {
        if isWaiting != value { isWaiting = value }
    }
}
