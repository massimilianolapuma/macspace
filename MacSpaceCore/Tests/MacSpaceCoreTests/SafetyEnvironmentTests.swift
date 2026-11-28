import Darwin
import Foundation
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

    /// `/private/tmp` is sticky: only an entry's owner (or the folder's, or root) may remove it.
    @Test func stickyFolderOthersItemIsNotRemovable() throws {
        let env = SafetyEnvironment.system(home: "/Users/u", apps: nil)
        let mine = "/private/tmp/MacSpaceTests-\(UUID().uuidString)"
        #expect(FileManager.default.createFile(atPath: mine, contents: Data()))
        defer { unlink(mine) }
        #expect(env.isRemovable(mine))
        let names = try FileManager.default.contentsOfDirectory(atPath: "/private/tmp")
        guard let theirs = names.map({ "/private/tmp/" + $0 }).first(where: { path in
            var info = Darwin.stat()
            return lstat(path, &info) == 0 && info.st_uid != getuid()
        }) else { return }   // nothing of another user's here on this Mac
        #expect(!env.isRemovable(theirs))
    }
}
