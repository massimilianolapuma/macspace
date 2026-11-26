import AppKit
import Foundation
import MacSpaceCore
import Observation

/// Keeps the `SafetyEnvironment` the safety rules judge against up to date: builds the installed
/// apps index at launch, in the background (until then `apps` is nil and `~/Library` items stay
/// "Analisi delle app in corso…"), again at each scan start (`rebuildApps`), and follows apps
/// launching and quitting. The launch and quit notifications skip background-only and
/// `LSUIElement` apps, so `runningApplications` is also observed through KVO, which reports every
/// change to the list.
@MainActor @Observable
final class SafetyEnvironmentProvider {
    /// The latest environment; `revision` changes with it.
    private(set) var environment: SafetyEnvironment
    /// Bumped on every new `environment`, for views to observe (the environment is not Equatable).
    private(set) var revision = 0

    /// Coalesces bursts of launch/quit notifications. Only the views wait for it: `ScanModel.trash`
    /// reads the running apps itself right before moving.
    static let runningAppsDebounce: Duration = .milliseconds(500)

    @ObservationIgnored private var apps: AppsIndex?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?
    @ObservationIgnored private var runningObservation: NSKeyValueObservation?
    /// The apps index build running now, if any.
    @ObservationIgnored private var building: Task<Void, Never>?
    /// `rebuildApps` was asked again while a build ran: one more follows it.
    @ObservationIgnored private var rebuildPending = false

    /// Cheap: the work starts in `start()`, so a throwaway instance (SwiftUI may evaluate a
    /// `@State` initial value more than once) costs nothing.
    init() {
        environment = Self.environment(apps: nil)
    }

    /// Starts building the apps index and following launches and quits; later calls do nothing.
    func start() {
        guard tasks.isEmpty, building == nil else { return }
        buildApps()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tasks.append(Task { [weak self] in
                for await _ in center.notifications(named: name) {
                    self?.scheduleRefresh()
                }
            })
        }
        // Every change to the list, agents and background-only apps included.
        runningObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    /// Indexes the installed apps again, in the background; the current index stays in use until
    /// the new one lands. A request during a build queues one more build after it. Before `start`
    /// it does nothing.
    func rebuildApps() {
        guard !tasks.isEmpty || building != nil else { return }
        if building != nil {
            rebuildPending = true
        } else {
            buildApps()
        }
    }

    /// Builds the apps index off the main actor, then publishes it (and any build queued meanwhile).
    private func buildApps() {
        building = Task { [weak self] in
            // Blocking (file system walk, code signatures, a synchronous Spotlight query): off the main actor.
            let index = await Task.detached(priority: .utility) {
                AppsIndex.build(extraAppPaths: AppsIndex.spotlightAppPaths())
            }.value
            guard let self else { return }
            building = nil
            apps = index
            publish()
            if rebuildPending {
                rebuildPending = false
                buildApps()
            }
        }
    }

    isolated deinit {
        tasks.forEach { $0.cancel() }
        building?.cancel()
        pendingRefresh?.cancel()
        runningObservation?.invalidate()
    }

    /// Publishes a fresh environment `runningAppsDebounce` after the last launch or quit.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.runningAppsDebounce)
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }

    private func publish() {
        environment = Self.environment(apps: apps)
        revision += 1
    }

    /// The environment now: `apps`, the bundle IDs and bundle paths of the apps running at this
    /// moment, and the home folders iCloud Drive syncs.
    static func environment(apps: AppsIndex?) -> SafetyEnvironment {
        let running = NSWorkspace.shared.runningApplications
        return .system(home: NSHomeDirectory(), apps: apps,
                       runningBundleIDs: Set(running.compactMap(\.bundleIdentifier)),
                       runningAppPaths: Set(running.compactMap { $0.bundleURL?.path(percentEncoded: false) }))
    }
}
