import AppKit
import Foundation
import MacSpaceCore
import Observation

/// Keeps the `SafetyEnvironment` the safety rules judge against up to date: builds the installed
/// apps index once at launch, in the background (until then `apps` is nil and `~/Library` items
/// stay "Analisi delle app in corso…"), and follows apps launching and quitting.
@MainActor @Observable
final class SafetyEnvironmentProvider {
    /// The latest environment; `revision` changes with it.
    private(set) var environment: SafetyEnvironment
    /// Bumped on every new `environment`, for views to observe (the environment is not Equatable).
    private(set) var revision = 0

    /// Coalesces bursts of launch/quit notifications.
    static let runningAppsDebounce: Duration = .milliseconds(500)

    @ObservationIgnored private var apps: AppsIndex?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pendingRefresh: Task<Void, Never>?

    /// Cheap: the work starts in `start()`, so a throwaway instance (SwiftUI may evaluate a
    /// `@State` initial value more than once) costs nothing.
    init() {
        environment = Self.environment(apps: nil)
    }

    /// Starts building the apps index and following launches and quits; later calls do nothing.
    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            // Blocking (file system walk, code signatures, a synchronous Spotlight query): off the main actor.
            let index = await Task.detached(priority: .utility) {
                AppsIndex.build(extraAppPaths: AppsIndex.spotlightAppPaths())
            }.value
            guard let self else { return }
            apps = index
            publish()
        })
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            tasks.append(Task { [weak self] in
                for await _ in center.notifications(named: name) {
                    self?.scheduleRefresh()
                }
            })
        }
    }

    isolated deinit {
        tasks.forEach { $0.cancel() }
        pendingRefresh?.cancel()
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

    /// The environment now: `apps`, and the bundle IDs and bundle paths of the running apps.
    private static func environment(apps: AppsIndex?) -> SafetyEnvironment {
        let running = NSWorkspace.shared.runningApplications
        return .system(home: NSHomeDirectory(), apps: apps,
                       runningBundleIDs: Set(running.compactMap(\.bundleIdentifier)),
                       runningAppPaths: Set(running.compactMap { $0.bundleURL?.path(percentEncoded: false) }))
    }
}
