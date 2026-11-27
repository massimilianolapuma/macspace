import Testing
@testable import MacSpaceCore

@Suite struct SafetyEnvironmentTests {
    private func env(running: Set<String> = ["com.a"], paths: Set<String> = ["/Applications/A.app"],
                     synced: Set<String> = [], now: UInt32 = 100) -> SafetyEnvironment {
        SafetyEnvironment(home: "/Users/u", apps: nil, runningBundleIDs: running, runningAppPaths: paths,
                          syncedHomeFolders: synced, now: now, isWritable: { _ in true })
    }

    @Test func sameRunningStateIgnoresTheClock() {
        #expect(env(now: 100).judgesRunningAppsLike(env(now: 500)))
    }

    @Test func aLaunchOrQuitChangesTheRunningState() {
        #expect(!env().judgesRunningAppsLike(env(running: ["com.a", "com.b"])))
        #expect(!env().judgesRunningAppsLike(env(running: [])))
    }

    @Test func anAppMovedChangesTheRunningState() {
        #expect(!env().judgesRunningAppsLike(env(paths: ["/Users/u/Applications/A.app"])))
    }

    @Test func iCloudSyncChangesTheRunningState() {
        #expect(!env().judgesRunningAppsLike(env(synced: ["/Users/u/Desktop"])))
    }
}
