import Foundation
import Testing
@testable import MacSpaceCore

private let testApps = AppsIndex(records: [
    AppRecord(bundleID: "com.spotify.client", name: "Spotify", teamID: "2FNC3A47ZF", path: "/Applications/Spotify.app"),
    AppRecord(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", teamID: "BQR82RBBHL", path: "/Applications/Slack.app"),
])

private let now: UInt32 = 2_000_000_000
private let lib = "/Users/u/Library"

private func environment(
    apps: AppsIndex? = testApps, running: Set<String> = [], runningPaths: Set<String> = [],
    isWritable: @escaping @Sendable (String) -> Bool = { _ in true }
) -> SafetyEnvironment {
    SafetyEnvironment(home: "/Users/u", apps: apps, runningBundleIDs: running, runningAppPaths: runningPaths,
                      now: now, isWritable: isWritable)
}

private func facts(
    _ path: String, kind: NodeKind = .directory, flags: NodeFlags = [], size: UInt64 = 0, lastUsed: UInt32 = 0,
    anchorLastUsed: UInt32? = nil, category: FileCategory = .other, root: Bool = false
) -> NodeFacts {
    NodeFacts(path: path, name: (path as NSString).lastPathComponent, kind: kind, flags: flags, size: size,
              lastUsed: lastUsed, anchorLastUsed: anchorLastUsed, category: category, isScanRoot: root)
}

private func v(
    _ path: String, kind: NodeKind = .directory, flags: NodeFlags = [], size: UInt64 = 0, lastUsed: UInt32 = 0,
    anchorLastUsed: UInt32? = nil, category: FileCategory = .other, root: Bool = false,
    apps: AppsIndex? = testApps, running: Set<String> = [], runningPaths: Set<String> = [], writable: Bool = true
) -> SafetyVerdict {
    SafetyRules.evaluate(
        facts(path, kind: kind, flags: flags, size: size, lastUsed: lastUsed, anchorLastUsed: anchorLastUsed,
              category: category, root: root),
        in: environment(apps: apps, running: running, runningPaths: runningPaths, isWritable: { _ in writable }))
}

private let old: UInt32 = 1_000_000_000

// MARK: - Brief assertions

@Test func protectedRows() {
    #expect(v("/Users/u/Library").reason == .essentialFolder)
    #expect(v("/Users/u/Library/Caches").level == .protected)
    #expect(v("/Applications/Foo.app/Contents", flags: [.insidePackage]).reason == .insidePackage)
    #expect(v("/usr/local/bin/x", kind: .file).reason == .ordinary)            // /usr/local is not system
    #expect(v("/usr/local/bin/x", kind: .file, writable: false).reason == .notWritable)
    #expect(v("/usr/lib/x", kind: .file).reason == .systemLocation)
    #expect(v("/Users/u/.Trash/x").reason == .trash)
    #expect(v("/Volumes/USB/.Trashes/501").reason == .trash)
    #expect(v("/Users/u/Library/Containers/com.apple.Notes/Data").reason == .appleData)
    #expect(v("/Users/u/Pictures/Photos Library.photoslibrary", flags: [.package]).reason == .photosLibrary)
    #expect(v("/Applications/Spotify.app", running: ["com.spotify.client"],
              runningPaths: ["/Applications/Spotify.app"]).reason == .runningApp)
    #expect(v("/Applications/Old.app", writable: false).reason == .notWritable)
}

@Test func cacheRows() {
    #expect(v("/Users/u/Library/Caches/com.spotify.client") == SafetyVerdict(level: .safe, reason: .cacheOfApp, owner: "Spotify"))
    #expect(v("/Users/u/Library/Caches/com.spotify.client/Data/x", kind: .file).level == .safe)   // inherits
    #expect(v("/Users/u/Library/Caches/com.spotify.client", running: ["com.spotify.client"]).reason == .cacheOfRunningApp)
    #expect(v("/Users/u/Library/Caches/com.apple.Safari").reason == .appleCache)
    #expect(v("/Users/u/Library/Developer/Xcode/DerivedData/App-abc").reason == .developerCache)
}

@Test func leftoverRows() {
    #expect(v("/Users/u/Library/Application Support/com.gone.app", lastUsed: old).reason == .leftover)
    #expect(v("/Users/u/Library/LaunchAgents/com.gone.agent.plist", kind: .file).reason == .leftoverLaunchAgent)
    #expect(v("/Users/u/Library/Application Support/Slack").reason == .appData)
    #expect(v("/Users/u/Library/Application Support/Slack", running: ["com.tinyspeck.slackmacgap"]).reason == .runningAppData)
    #expect(v("/Users/u/Library/Application Support/AddressBook").reason == .appleData)   // ruling R19
    #expect(v("/Users/u/Library/Application Support/SomeTool").reason == .ordinary)
}

@Test func recentLeftoverIsCaution() {
    #expect(v("/Users/u/Library/Containers/com.gone.app", lastUsed: now - 86_400).reason == .recentLeftover)
}

@Test func noAppsIndexIsPending() {
    #expect(v("/Users/u/Library/Application Support/com.gone.app", apps: nil).reason == .analysisPending)
}

@Test func cloudInstallersAndAge() {
    #expect(v("/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a.mov", kind: .file)
            == SafetyVerdict(level: .caution, reason: .cloudSynced, owner: "iCloud Drive"))
    #expect(v("/Users/u/Library/CloudStorage/Dropbox-Personal/x", kind: .file).owner == "Dropbox")
    // Not downloaded, but trashing it still deletes it from Dropbox (ruling R42).
    #expect(v("/Users/u/Library/CloudStorage/Dropbox-Personal/x", kind: .file, flags: [.dataless])
            == SafetyVerdict(level: .caution, reason: .cloudSynced, owner: "Dropbox"))
    #expect(v("/Users/u/Downloads/Spotify 1.2.dmg", kind: .file) == SafetyVerdict(level: .safe, reason: .installer, owner: "Spotify"))
    #expect(v("/Users/u/Movies/old.mov", kind: .file, size: 60_000_000, lastUsed: old, category: .video).reason == .notUsedForLong)
    #expect(v("/Users/u/Movies/old.mov", kind: .file, size: 10_000_000, lastUsed: old, category: .video).reason == .ordinary)
    #expect(v("/Users/u/Projects/app", root: true).reason == .scanRoot)
}

// MARK: - Levels and environment

@Test func onlyProtectedIsNotTrashable() {
    #expect(SafetyLevel.allCases == [.safe, .caution, .normal, .protected])
    #expect(SafetyLevel.allCases.filter { !$0.isTrashable } == [.protected])
}

@Test func tunables() {
    #expect(SafetyRules.longUnusedSeconds == 730 * 86_400)
    #expect(SafetyRules.longUnusedMinSize == 50_000_000)
    #expect(SafetyRules.recentLeftoverSeconds == 30 * 86_400)
    #expect(SafetyRules.suggestionMinSize == 1_000_000)
}

@Test func systemEnvironmentChecksWriteAccess() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let env = SafetyEnvironment.system(home: "/Users/u", apps: nil, runningBundleIDs: [], runningAppPaths: [])
    #expect(env.isWritable(fx.root.path))
    #expect(!env.isWritable("/System"))
    #expect(!env.isWritable(fx.root.path + "/missing"))
    let wallClock = UInt32(Date().timeIntervalSince1970)
    #expect(env.now <= wallClock + 1 && env.now + 60 >= wallClock)
    #expect(env.apps == nil && env.home == "/Users/u")
}

// MARK: - Rule 1–2: scan root, essential folders

@Test func scanRootWinsOverEverything() {
    #expect(v("/Users/u", root: true).reason == .scanRoot)
    #expect(v("/Users/u/Library/Caches/com.gone.x", root: true).level == .protected)
}

@Test func everyEssentialPathIsProtected() throws {
    let paths = SafetyTables.essentialPaths(home: "/Users/u")
    for expected in ["/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/usr", "/opt",
                     "/bin", "/sbin", "/cores", "/etc", "/var", "/tmp", "/Users/u", lib, "/Users/u/Desktop",
                     "/Users/u/Documents", "/Users/u/Downloads", "/Users/u/Movies", "/Users/u/Music",
                     "/Users/u/Pictures", "/Users/u/Public", "/Users/u/Applications", lib + "/Developer",
                     lib + "/Mobile Documents", lib + "/CloudStorage", "/Users/u/.Trash"] {
        #expect(paths.contains(expected), "\(expected)")
    }
    for location in LibraryLocation.allCases {
        #expect(paths.contains(lib + "/" + location.rawValue), "\(location)")
    }
    #expect(paths.count == 29 + LibraryLocation.allCases.count)
    for path in paths {
        // Even facts that would otherwise make it safe (installer name, dataless, old big file).
        let verdict = v(path, kind: .file, flags: [.dataless], size: 1 << 40, lastUsed: old, category: .video)
        #expect(verdict == SafetyVerdict(level: .protected, reason: .essentialFolder, owner: nil), "\(path)")
    }
}

@Test func essentialPathsNormalizeHomeAndIgnoreCase() {
    #expect(SafetyTables.essentialPaths(home: "/Users/u/").contains("/Users/u/Library"))
    let env = SafetyEnvironment(home: "/Users/u//", apps: testApps, runningBundleIDs: [], runningAppPaths: [],
                                now: now, isWritable: { _ in true })
    #expect(SafetyRules.evaluate(facts("/Users/u/Documents"), in: env).reason == .essentialFolder)
    #expect(SafetyRules.evaluate(facts("/Users/u/Library/Caches/com.spotify.client"), in: env).reason == .cacheOfApp)
    #expect(v("/users/U/documents").reason == .essentialFolder)
    #expect(v("/Users/u/Documents/").reason == .essentialFolder)
    #expect(v("/Users/u/Documents/report").reason == .ordinary)
}

// MARK: - Rule 3–5: package interior, system, Trash

@Test func insidePackageBeatsLaterRules() {
    #expect(v("/System/Applications/Mail.app/Contents", flags: [.insidePackage]).reason == .insidePackage)
    #expect(v("/Users/u/Downloads/Foo.app/Contents/Resources/inner.pkg", kind: .file,
              flags: [.insidePackage]).reason == .insidePackage)
    #expect(v(lib + "/Caches/com.gone.x/Thing.bundle/Contents", flags: [.insidePackage]).reason == .insidePackage)
}

@Test func systemPrefixesAreComponentWise() {
    for path in ["/System", "/System/Library/x", "/usr/bin/ls", "/bin/sh", "/sbin/mount", "/private/var/db",
                 "/private/etc/hosts", "/cores/core.1", "/Library/Apple", "/Library/Apple/System/x", "/USR/lib"] {
        #expect(v(path, kind: .file).level == .protected, "\(path)")
    }
    #expect(v("/usr/lib/x", kind: .file).reason == .systemLocation)
    #expect(v("/Library/Apple/x").reason == .systemLocation)
    #expect(v("/usr/local").reason == .ordinary)
    #expect(v("/usr/local/Cellar/x").reason == .ordinary)
    #expect(v("/usrfoo/x").reason == .ordinary)
    #expect(v("/usr/localfoo/x").reason == .systemLocation)
    #expect(v("/Library/Applefoo/x").reason == .ordinary)
    #expect(v("/Library/Application Support/x").reason == .ordinary)
    #expect(v("/var/folders/ab/x").reason == .ordinary)      // ruling R2: only /private is system
}

@Test func trashRows() {
    #expect(v("/Users/u/.Trash").reason == .essentialFolder)
    #expect(v("/Users/u/.Trash/a/b", kind: .file).reason == .trash)
    #expect(v("/Volumes/USB/.Trashes").reason == .trash)
    #expect(v("/Volumes/USB/.Trashes/501/f.mov", kind: .file).reason == .trash)
    #expect(v("/Volumes/USB/.trashes/501").reason == .trash)
    #expect(v("/Users/u/.Trashx").reason == .ordinary)
    #expect(v("/Volumes/USB/.Trashesx/501").reason == .ordinary)
}

// MARK: - Rule 6–7: Apple data, Photos

@Test func appleDataRows() {
    for path in [lib + "/Keychains", lib + "/Keychains/login.keychain-db", lib + "/Mail", lib + "/Mail/V10/x",
                 lib + "/Messages/chat.db", lib + "/Containers/com.apple.Notes",
                 lib + "/Group Containers/group.com.apple.notes/x",
                 lib + "/Group Containers/243LU875E5.groups.com.apple.podcasts",
                 lib + "/Group Containers/ABCDE12345.com.apple.foo",
                 lib + "/Application Support/com.apple.sharedfilelist",
                 lib + "/Preferences/com.apple.dock.plist", lib + "/Saved Application State/com.apple.Safari.savedState",
                 lib + "/LaunchAgents/com.apple.foo.plist", lib + "/WebKit/com.apple.Safari/x"] {
        #expect(v(path, lastUsed: old).reason == .appleData, "\(path)")
    }
    // No apps index needed.
    #expect(v(lib + "/Application Support/com.apple.foo", apps: nil).reason == .appleData)
    #expect(v(lib + "/mail/x").reason == .appleData)
    #expect(v(lib + "/Mailbox/x").reason == .ordinary)
    #expect(v(lib + "/Containers/com.applefoo.x", lastUsed: old).reason == .leftover)
    // Caches and Logs are not appleData.
    #expect(v(lib + "/Caches/com.apple.Safari/x", kind: .file) == SafetyVerdict(level: .caution, reason: .appleCache, owner: nil))
    #expect(v(lib + "/Logs/com.apple.foo") == SafetyVerdict(level: .normal, reason: .ordinary, owner: nil))
}

@Test func photosLibraryRows() {
    #expect(v("/Volumes/Ext/Old.PhotosLibrary", flags: [.package]).reason == .photosLibrary)
    #expect(v("/Users/u/Pictures/Photos Library.photoslibrary/database", flags: [.insidePackage]).reason == .insidePackage)
    #expect(v("/Users/u/Pictures/x.photoslibraryx").reason == .ordinary)
}

// MARK: - Rule 8–9: running apps, write access

@Test func runningAppRows() {
    #expect(v("/Applications/Spotify.app", runningPaths: ["/Applications/Spotify.app"])
            == SafetyVerdict(level: .protected, reason: .runningApp, owner: "Spotify"))
    #expect(v("/Users/u/Applications/Tool.app", runningPaths: ["/Users/u/Applications/Tool.app/"]).owner == "Tool")
    #expect(v("/Applications/Spotify.app", runningPaths: ["/applications/spotify.APP"]).reason == .runningApp)
    #expect(v("/Applications/Spotify.app", runningPaths: ["/Applications/Spotify.app"], writable: false).reason == .runningApp)
    #expect(v("/Applications/Spotify.app", running: ["com.spotify.client"]).reason == .ordinary)
}

@Test func writeAccessIsCheckedOnTheParent() {
    let env1 = environment(isWritable: { $0 != "/Applications" })
    #expect(SafetyRules.evaluate(facts("/Applications/Old.app"), in: env1).reason == .notWritable)
    #expect(SafetyRules.evaluate(facts("/Applications/Old.app/Readme", kind: .file), in: env1).reason == .ordinary)
    let env2 = environment(isWritable: { $0 != "/" })
    #expect(SafetyRules.evaluate(facts("/Foo"), in: env2).reason == .notWritable)
    let env3 = environment(isWritable: { $0 == "/" })
    #expect(SafetyRules.evaluate(facts("/Foo"), in: env3).reason == .ordinary)
    let env4 = environment(isWritable: { $0 != "/Users/u/Downloads" })
    #expect(SafetyRules.evaluate(facts("/Users/u/Downloads/a.dmg/", kind: .file), in: env4).reason == .notWritable)
    // A protected-by-location item stays at its earlier reason.
    #expect(v("/usr/lib/x", kind: .file, writable: false).reason == .systemLocation)
}

// MARK: - Rule 10–12: cloud, developer caches

@Test func cloudRows() {
    #expect(v("/Users/u/Documents/x.mov", kind: .file, flags: [.dataless])
            == SafetyVerdict(level: .normal, reason: .cloudOnly, owner: nil))
    #expect(v(lib + "/Caches/com.spotify.client/x", kind: .file, flags: [.dataless]).reason == .cloudOnly)
    #expect(v(lib + "/Mobile Documents/com~apple~CloudDocs/Notes").owner == "iCloud Drive")
    #expect(v(lib + "/CloudStorage/Box/x", kind: .file) == SafetyVerdict(level: .caution, reason: .cloudSynced, owner: "Box"))
    #expect(v(lib + "/CloudStorage/OneDrive-Personal/Work").owner == "OneDrive")
    #expect(v(lib + "/CloudStorage/GoogleDrive-me@x.com/My Drive/a.pdf", kind: .file).owner == "GoogleDrive")
    #expect(v(lib + "/Mobile Documents").reason == .essentialFolder)
    #expect(v(lib + "/CloudStorage").reason == .essentialFolder)
    #expect(v(lib + "/CloudStoragex/a").reason == .ordinary)
    // A cloud installer stays a cloud item.
    #expect(v(lib + "/CloudStorage/Dropbox-Personal/Setup.dmg", kind: .file).reason == .cloudSynced)
}

@Test func developerCacheRows() throws {
    let caches = SafetyTables.developerCaches(home: "/Users/u")
    #expect(caches.map(\.name) == ["DerivedData", "CoreSimulator", "npm", "Gradle", "Cargo", "Go", "pip", "pnpm", "pnpm"])
    #expect(caches.map(\.path) == [lib + "/Developer/Xcode/DerivedData", lib + "/Developer/CoreSimulator/Caches",
                                   "/Users/u/.npm/_cacache", "/Users/u/.gradle/caches", "/Users/u/.cargo/registry/cache",
                                   "/Users/u/go/pkg/mod/cache", "/Users/u/.cache/pip", lib + "/pnpm/store",
                                   "/Users/u/.pnpm-store"])
    for cache in caches {
        #expect(v(cache.path) == SafetyVerdict(level: .safe, reason: .developerCache, owner: cache.name))
        #expect(v(cache.path + "/a/b.bin", kind: .file).owner == cache.name)
    }
    #expect(v(lib + "/Developer/Xcode/Archives/2026/App.xcarchive", flags: [.package]).reason == .ordinary)
    #expect(v("/Users/u/.npm").reason == .ordinary)
    #expect(v("/Users/u/.npm/_cacachex").reason == .ordinary)
    #expect(v(lib + "/Developer/Xcode/DerivedData/App/x", kind: .file, flags: [.dataless]).reason == .cloudOnly)
}

// MARK: - Rule 13–15: ~/Library locations

@Test func everyLocationIsPendingWithoutIndex() {
    for location in LibraryLocation.allCases {
        let path = lib + "/" + location.rawValue
        #expect(v(path, apps: nil).reason == .essentialFolder)
        #expect(v(path + "/com.gone.app", apps: nil) == SafetyVerdict(level: .normal, reason: .analysisPending, owner: nil),
                "\(location)")
        #expect(v(path + "/com.spotify.client/deep/x", kind: .file, apps: nil).reason == .analysisPending, "\(location)")
        #expect(v(path + "/Some Name", apps: nil, running: ["com.spotify.client"]).reason == .analysisPending)
    }
}

@Test func cacheOwnershipRows() {
    #expect(v(lib + "/Caches/com.gone.x") == SafetyVerdict(level: .safe, reason: .leftover, owner: nil))
    #expect(v(lib + "/Caches/com.gone.x", lastUsed: now).reason == .leftover)   // no recency test in Caches
    #expect(v(lib + "/Caches/Google Chrome") == SafetyVerdict(level: .safe, reason: .cacheOfApp, owner: nil))
    #expect(v(lib + "/Caches/Slack/x", kind: .file) == SafetyVerdict(level: .safe, reason: .cacheOfApp, owner: "Slack"))
    #expect(v(lib + "/Caches/com.spotify.client.helper", running: ["com.spotify.client"])
            == SafetyVerdict(level: .caution, reason: .cacheOfRunningApp, owner: "Spotify"))
    #expect(v(lib + "/Caches/com.spotify.client", running: ["com.spotify.client.helper"]).reason == .cacheOfRunningApp)
    #expect(v(lib + "/Caches/com.spotify.client", running: ["com.spotify"]).reason == .cacheOfRunningApp)  // 2 shared labels
    #expect(v(lib + "/Caches/com.spotify.client", running: ["com.spotifyx.client"]).reason == .cacheOfApp)
    #expect(v(lib + "/Caches/com.spotify.client", running: ["com.tinyspeck.slackmacgap"]).reason == .cacheOfApp)
    // Running only by its bundle path (e.g. an app the index knows without a matching running ID).
    #expect(v(lib + "/Caches/com.tinyspeck.slackmacgap", runningPaths: ["/Applications/Slack.app"]).reason
            == .cacheOfRunningApp)
    // Running-only match (ruling R9): running by construction, owner unknown.
    #expect(v(lib + "/Caches/com.acme.tool/x", kind: .file, running: ["com.acme.tool"])
            == SafetyVerdict(level: .caution, reason: .cacheOfRunningApp, owner: nil))
}

@Test func otherLocationOwnershipRows() {
    #expect(v(lib + "/Logs/com.spotify.client") == SafetyVerdict(level: .caution, reason: .appData, owner: "Spotify"))
    #expect(v(lib + "/Preferences/com.spotify.client.plist", kind: .file).reason == .appData)
    #expect(v(lib + "/Group Containers/BQR82RBBHL.com.tinyspeck.slack").owner == "Slack")
    #expect(v(lib + "/Application Support/Slack/a/b", kind: .file, lastUsed: old)
            == SafetyVerdict(level: .caution, reason: .appData, owner: "Slack"))
    #expect(v(lib + "/Application Support/Slack/a/b", kind: .file, running: ["com.tinyspeck.slackmacgap"])
            == SafetyVerdict(level: .protected, reason: .runningAppData, owner: "Slack"))
    #expect(v(lib + "/Containers/com.acme.tool", running: ["com.acme.tool"])
            == SafetyVerdict(level: .protected, reason: .runningAppData, owner: nil))
    #expect(v(lib + "/LaunchAgents/com.spotify.client.startup.plist", kind: .file).reason == .appData)
    #expect(v(lib + "/LaunchAgents/com.gone.agent.plist", kind: .file, lastUsed: now)
            == SafetyVerdict(level: .caution, reason: .leftoverLaunchAgent, owner: nil))
    #expect(v(lib + "/LaunchAgents/com.gone.agent.plist", kind: .file, lastUsed: old).reason == .leftoverLaunchAgent)
    #expect(v(lib + "/Preferences/loginwindow.plist", kind: .file) == SafetyVerdict(level: .normal, reason: .ordinary, owner: nil))
    #expect(v(lib + "/Application Support/com.gone.app", lastUsed: old)
            == SafetyVerdict(level: .safe, reason: .leftover, owner: nil))
}

@Test func leftoverOfAnInstalledVendorIsCaution() {   // ruling R36
    let apps = AppsIndex(records: [
        AppRecord(bundleID: "com.openai.codex", name: "ChatGPT", teamID: nil, path: "/Applications/ChatGPT.app"),
        AppRecord(bundleID: "com.spotify.client", name: "Spotify", teamID: nil, path: "/Applications/Spotify.app"),
    ])
    let vendor = SafetyVerdict(level: .caution, reason: .vendorLeftover, owner: "ChatGPT")
    for location in ["Application Support", "Containers", "Preferences", "HTTPStorages", "WebKit", "Logs"] {
        let name = location == "Preferences" ? "com.openai.chat.plist" : "com.openai.chat"
        #expect(v(lib + "/" + location + "/" + name, lastUsed: old, apps: apps) == vendor, "\(location)")
        #expect(v(lib + "/" + location + "/" + name + "/x", kind: .file, lastUsed: old, apps: apps) == vendor,
                "\(location)")
    }
    #expect(v(lib + "/Saved Application State/com.openai.chat.savedState", lastUsed: old, apps: apps) == vendor)
    #expect(v(lib + "/Group Containers/group.com.openai.chat", lastUsed: old, apps: apps) == vendor)
    // Caches (rule 14) too, whatever the recency.
    #expect(v(lib + "/Caches/com.openai.chat", apps: apps) == vendor)
    #expect(v(lib + "/Caches/com.openai.chat/Cache.db", kind: .file, lastUsed: now, apps: apps) == vendor)
    // A vendor nobody installed stays a leftover.
    #expect(v(lib + "/Application Support/ai.perplexity.mac", lastUsed: old, apps: apps)
            == SafetyVerdict(level: .safe, reason: .leftover))
    #expect(v(lib + "/Caches/ai.perplexity.mac", apps: apps) == SafetyVerdict(level: .safe, reason: .leftover))
    #expect(v(lib + "/Application Support/com.openaix.chat", lastUsed: old, apps: apps).reason == .leftover)
    // Launch agents keep their own caution reason; an installed match is still app data.
    #expect(v(lib + "/LaunchAgents/com.openai.chat.agent.plist", kind: .file, apps: apps).reason == .leftoverLaunchAgent)
    #expect(v(lib + "/Application Support/com.openai.codex", lastUsed: old, apps: apps)
            == SafetyVerdict(level: .caution, reason: .appData, owner: "ChatGPT"))
    // Never safe: not preselected, and the reason says why.
    #expect(SafetyLevel.caution.isTrashable)
}

@Test func leftoverRecencyBoundaries() {
    let path = lib + "/Application Support/com.gone.app"
    #expect(v(path, lastUsed: now - SafetyRules.recentLeftoverSeconds).reason == .leftover)
    #expect(v(path, lastUsed: now - SafetyRules.recentLeftoverSeconds + 1).reason == .recentLeftover)
    #expect(v(path, lastUsed: now).reason == .recentLeftover)
    #expect(v(path, lastUsed: now + 3_600).reason == .recentLeftover)   // future: age 0
    #expect(v(path, lastUsed: 0).reason == .recentLeftover)             // unknown: not known to be old
    #expect(v(path, lastUsed: now - 86_400).level == .caution)
}

@Test func descendantsGetTheirLocationFoldersRecency() {
    let folder = lib + "/Application Support/com.gone.app"
    // Old file inside a recently used leftover folder: the folder's verdict.
    #expect(v(folder + "/sub/old.db", kind: .file, lastUsed: old, anchorLastUsed: now - 86_400).reason == .recentLeftover)
    // Recent file inside an old leftover folder cannot happen in a real tree, but the anchor still decides.
    #expect(v(folder + "/sub/new.db", kind: .file, lastUsed: now, anchorLastUsed: old).reason == .leftover)
    // For the location child itself the anchor defaults to its own last use.
    #expect(facts(folder, lastUsed: 42).anchorLastUsed == 42)
    #expect(facts(folder, lastUsed: 42, anchorLastUsed: 7).anchorLastUsed == 7)
}

// MARK: - Rule 16–18: installers, long unused, otherwise

@Test func installerRows() {
    #expect(v("/Users/u/Downloads/A.dmg", kind: .file) == SafetyVerdict(level: .safe, reason: .installer, owner: nil))
    #expect(v("/Users/u/Downloads/A.dmg", kind: .file, apps: nil).level == .safe)
    #expect(v("/Users/u/Downloads/Sub/A.dmg", kind: .file).level == .safe)
    for name in ["x.DMG", "x.pkg", "x.mpkg", "x.xip"] {
        #expect(v("/Users/u/Downloads/" + name, kind: .file) == SafetyVerdict(level: .safe, reason: .installer),
                "\(name)")
    }
    #expect(SafetyTables.installerExtensions == ["dmg", "pkg", "mpkg", "xip"])
    #expect(v("/Users/u/Downloads/Foo.pkg").reason == .ordinary)               // a directory is no installer
    #expect(v("/Users/u/Downloads/a.zip", kind: .file).reason == .ordinary)
    // Inside ~/Library locations the Library rules decide first.
    #expect(v(lib + "/Caches/com.gone.x/setup.dmg", kind: .file).reason == .leftover)
    #expect(v(lib + "/Application Support/Slack/update.dmg", kind: .file).reason == .appData)
    #expect(v(lib + "/Application Support/Some Name/update.pkg", kind: .file).reason == .ordinary)
}

@Test func installersOutsideDownloadsNeedAnInstalledApp() {   // ruling R17
    #expect(v("/Users/u/Documents/Private.dmg", kind: .file) == SafetyVerdict(level: .caution, reason: .installer))
    #expect(v("/Users/u/Desktop/Spotify 1.2.dmg", kind: .file)
            == SafetyVerdict(level: .safe, reason: .installer, owner: "Spotify"))
    #expect(v("/Users/u/Desktop/Unknown.pkg", kind: .file) == SafetyVerdict(level: .caution, reason: .installer))
    #expect(v("/Users/u/Desktop/Spotify 1.2.dmg", kind: .file, apps: nil).level == .caution)
    #expect(v("/Volumes/Ext/Vault.dmg", kind: .file).level == .caution)
    #expect(v("/Users/u/Downloadsx/A.dmg", kind: .file).level == .caution)
    #expect(v("/Users/u/downloads/A.dmg", kind: .file).level == .safe)
}

@Test func classifierInstallerTableComesFromSafetyTables() {
    let c = CategoryClassifier(home: "/Users/u")
    for ext in SafetyTables.installerExtensions {
        #expect(c.isInstaller(fileName: "a." + ext) && c.isInstaller(fileName: "a." + ext.uppercased()))
    }
    #expect(!c.isInstaller(fileName: "dmg") && !c.isInstaller(fileName: "a.dmgx"))
    // Rule 16 and the scanner share one predicate.
    for name in ["a.dmg", "A.PKG", "x.mpkg", "y.xip", ".dmg", "dmg", "a.dmg.zip", "a.", "a.dmgx", "é.dmg"] {
        #expect(CategoryClassifier.isInstallerName(name) == c.isInstaller(fileName: name), "\(name)")
        let isInstallerVerdict = v("/Users/u/Downloads/" + name, kind: .file).reason == .installer
        #expect(isInstallerVerdict == c.isInstaller(fileName: name), "\(name)")
    }
}

private let longMin = SafetyRules.longUnusedMinSize
private let longEdge = now - SafetyRules.longUnusedSeconds

private func longReason(_ path: String = "/Users/u/Movies/a.mov", kind: NodeKind = .file, size: UInt64 = longMin,
                        lastUsed: UInt32 = longEdge, category: FileCategory = .video) -> SafetyReason {
    v(path, kind: kind, size: size, lastUsed: lastUsed, category: category).reason
}

@Test func longUnusedBoundaries() {
    #expect(longReason() == .notUsedForLong)    // exactly longUnusedMinSize and exactly longUnusedSeconds
    #expect(v("/Users/u/Movies/a.mov", kind: .file, size: longMin, lastUsed: longEdge, category: .video)
            == SafetyVerdict(level: .caution, reason: .notUsedForLong, owner: nil))
    #expect(longReason(size: longMin - 1) == .ordinary)
    #expect(longReason(lastUsed: longEdge + 1) == .ordinary)
    #expect(longReason(lastUsed: 0) == .ordinary)
    #expect(longReason(lastUsed: now + 10) == .ordinary)
    for category in [FileCategory.video, .photo, .music, .document, .archive] {
        #expect(longReason(category: category) == .notUsedForLong, "\(category)")
    }
    for category in [FileCategory.app, .development, .system, .appData, .other] {
        #expect(longReason(category: category) == .ordinary, "\(category)")
    }
    #expect(longReason(kind: .directory) == .ordinary)
    #expect(longReason("/Users/u/Library/Movies/a.mov") == .ordinary)
    #expect(longReason("/Users/u/library/a.mov") == .ordinary)
    #expect(longReason("/Users/u/Library/Application Support/Some Name/a.mov") == .ordinary)
    #expect(longReason("/Volumes/Ext/a.mov") == .ordinary)
    #expect(longReason("/Users/other/a.mov") == .ordinary)
    #expect(longReason("/Users/u/a.mov") == .notUsedForLong)
    #expect(longReason("/Users/uu/a.mov") == .ordinary)
}

@Test func otherwiseOrdinary() {
    #expect(v("/Users/u/Documents/report.pdf", kind: .file) == SafetyVerdict(level: .normal, reason: .ordinary, owner: nil))
    #expect(v("/Applications/Foo.app", flags: [.package]).reason == .ordinary)
    #expect(v(lib + "/Fonts/x.ttf", kind: .file).reason == .ordinary)
}

// MARK: - InstallerMatcher

private let installerApps = AppsIndex(records: [
    AppRecord(bundleID: "org.mozilla.firefox", name: "Firefox", teamID: nil, path: "/Applications/Firefox.app"),
    AppRecord(bundleID: "com.spotify.client", name: "Spotify", teamID: nil, path: "/Applications/Spotify.app"),
    AppRecord(bundleID: "com.microsoft.VSCode", name: "Code", teamID: nil, path: "/Applications/Visual Studio Code.app"),
    AppRecord(bundleID: "com.google.Chrome", name: "Google Chrome", teamID: nil, path: "/Applications/Google Chrome.app"),
])

@Test func installerMatcherFindsInstalledApps() {
    func match(_ name: String) -> String? { InstallerMatcher.app(forInstaller: name, apps: installerApps)?.name }
    #expect(match("Firefox 132.0.dmg") == "Firefox")
    #expect(match("Spotify 1.2.dmg") == "Spotify")
    #expect(match("SpotifyInstaller.zip.dmg") == nil)
    #expect(match("FIREFOX.DMG") == "Firefox")
    #expect(match("firefox-132.0.pkg") == "Firefox")
    #expect(match("Firefox_Setup.pkg") == "Firefox")
    #expect(match("Firefox(1).dmg") == "Firefox")
    #expect(match("Spot.dmg") == "Spotify")                       // app name starts with the stem
    #expect(match("Visual Studio Code.dmg") == "Code")           // cut at the space: "visual" prefixes the file name
    #expect(match("Google Chrome.dmg") == "Google Chrome")
}

@Test func installerMatcherRejectsShortAndUnrelatedStems() {
    func match(_ name: String) -> AppRecord? { InstallerMatcher.app(forInstaller: name, apps: installerApps) }
    #expect(match("Fi 1.dmg") == nil)
    #expect(match("F.dmg") == nil)
    #expect(match("12.0.dmg") == nil)
    #expect(match(".dmg") == nil)
    #expect(match("-Firefox.dmg") == nil)
    #expect(match("Zoom.pkg") == nil)
    #expect(match("Firefoxy.dmg") == nil)                         // the stem is longer than the name
    #expect(match("Firefox 1.dmg")?.name == "Firefox")
    #expect(InstallerMatcher.app(forInstaller: "Firefox.dmg", apps: .empty) == nil)
}

// MARK: - Fix round 1: unusual paths, cloud roots, Apple data, rule order

@Test func unusualPathsFailClosed() {   // ruling R16
    for path in ["/Users/u/Library/Containers//com.apple.Notes/x", "/Users/u//Library/Keychains/x",
                 "/Users/u/Documents/../Library/Keychains/x", "/Users/u/./Documents", "/Users/u/Downloads/..",
                 "Users/u/Downloads/A.dmg", "./A.dmg", "A.dmg", "", "//Users"] {
        #expect(v(path, kind: .file) == SafetyVerdict(level: .protected, reason: .unusualPath), "\(path)")
    }
    #expect(v("relative/dir", root: true).reason == .unusualPath)          // before rule 1
    #expect(v("/").reason == .essentialFolder)
    #expect(v("//").reason == .essentialFolder)                             // trailing slashes stripped: "/"
    #expect(v("/Users/u/Downloads/").reason == .essentialFolder)           // trailing slashes are fine
    #expect(v("/Users/u/Downloads//").reason == .essentialFolder)
    #expect(v("/Users/u/Downloads/..x/a", kind: .file).reason == .ordinary)
    #expect(v("/Users/u/Downloads/.x", kind: .file).reason == .ordinary)
}

@Test func cloudDriveRootsAreEssential() {   // ruling R18
    for path in [lib + "/Mobile Documents/com~apple~CloudDocs", lib + "/Mobile Documents/iCloud~com~x~y",
                 lib + "/CloudStorage/Dropbox-Personal", lib + "/CloudStorage/Box", lib + "/cloudstorage/OneDrive-X"] {
        #expect(v(path) == SafetyVerdict(level: .protected, reason: .essentialFolder), "\(path)")
        #expect(v(path, flags: [.dataless]).reason == .essentialFolder)
    }
    #expect(v(lib + "/Mobile Documents/iCloud~com~x~y/Documents/a.txt", kind: .file)
            == SafetyVerdict(level: .caution, reason: .cloudSynced, owner: "iCloud Drive"))
    #expect(v(lib + "/CloudStorage/Dropbox-Personal/Photos", kind: .directory).reason == .cloudSynced)
}

@Test func appleUserDataFoldersAreNeverTouched() {   // ruling R19
    for folder in ["Accounts", "Calendars", "Safari", "IdentityServices", "Application Support/AddressBook",
                   "Application Support/CallHistoryDB", "Application Support/Knowledge", "Keychains", "Mail",
                   "Messages"] {
        #expect(v(lib + "/" + folder).reason == .appleData, "\(folder)")
        #expect(v(lib + "/" + folder + "/x/y.db", kind: .file, apps: nil).reason == .appleData, "\(folder)")
    }
    #expect(v(lib + "/Safarix").reason == .ordinary)
    #expect(v(lib + "/Application Support/AddressBookx").reason == .ordinary)
    #expect(v(lib + "/Application Support/KnowledgeBase").reason == .ordinary)
}

@Test func ruleOrder() {
    // 2 before 3: an essential folder flagged inside a package.
    #expect(v(lib + "/Caches", flags: [.insidePackage]).reason == .essentialFolder)
    // 5 before 6: a `.Trashes` component inside Apple data.
    #expect(v(lib + "/Keychains/.Trashes/x", kind: .file).reason == .trash)
    // 6 before 7: a Photos library inside an Apple container.
    #expect(v(lib + "/Containers/com.apple.Photos/Data/P.photoslibrary", flags: [.package]).reason == .appleData)
    // 16 before 17: an old, large disk image in the home folder.
    #expect(v("/Users/u/Movies/old.dmg", kind: .file, size: 60_000_000, lastUsed: old, category: .archive)
            == SafetyVerdict(level: .caution, reason: .installer))
    // `.runningAppData` reached through the running bundle path only.
    #expect(v(lib + "/Application Support/Slack", runningPaths: ["/Applications/Slack.app"])
            == SafetyVerdict(level: .protected, reason: .runningAppData, owner: "Slack"))
}

@Test func homeInAnotherUnicodeFormFailsClosed() {   // security review: NFC/NFD home vs disk names
    let nfc = "/Users/Jos\u{E9}", nfd = "/Users/Jose\u{301}"
    func verdict(home: String, path: String) -> SafetyVerdict {
        SafetyRules.evaluate(
            NodeFacts(path: path, name: (path as NSString).lastPathComponent, kind: .directory, flags: [], size: 0,
                      lastUsed: old, category: .other, isScanRoot: false),
            in: SafetyEnvironment(home: home, apps: testApps, runningBundleIDs: [], runningAppPaths: [], now: now,
                                  isWritable: { _ in true }))
    }
    // Same form: the Library rules apply.
    #expect(verdict(home: nfc, path: nfc + "/Library/Containers/com.apple.Notes").reason == .appleData)
    #expect(verdict(home: nfd, path: nfd + "/Library/Containers/com.apple.Notes").reason == .appleData)
    #expect(verdict(home: nfd, path: nfd + "/Projects/x").reason == .ordinary)
    // Other form: the home-relative rules cannot be trusted, so everything below home is protected.
    for (home, disk) in [(nfc, nfd), (nfd, nfc)] {
        #expect(verdict(home: home, path: disk + "/Library/Containers/com.apple.Notes")
                == SafetyVerdict(level: .protected, reason: .unusualPath))
        #expect(verdict(home: home, path: disk + "/.Trash/x").reason == .unusualPath)
        #expect(verdict(home: home, path: disk + "/Projects/x").reason == .unusualPath)
        #expect(verdict(home: home, path: "/Users/Shared/x").reason == .ordinary)   // not below home
    }
    // An ASCII home is unaffected by non-ASCII names below it.
    #expect(verdict(home: "/Users/u", path: "/Users/u/Caf\u{E9}").reason == .ordinary)
}

// MARK: - Shared team containers (final review I2)

private let officeApps = AppsIndex(records: [
    AppRecord(bundleID: "com.microsoft.Excel", name: "Microsoft Excel", teamID: "UBF8T346G9",
              path: "/Applications/Microsoft Excel.app"),
    AppRecord(bundleID: "com.microsoft.Outlook", name: "Microsoft Outlook", teamID: "UBF8T346G9",
              path: "/Applications/Microsoft Outlook.app"),
])

@Test func runningTeamMemberProtectsSharedContainers() {
    let gc = lib + "/Group Containers/"
    for name in ["UBF8T346G9.com.microsoft.oneauth", "UBF8T346G9.Office"] {
        #expect(v(gc + name, apps: officeApps)
                == SafetyVerdict(level: .caution, reason: .appData, owner: "Microsoft Excel"), "\(name)")
        let running = SafetyVerdict(level: .protected, reason: .runningAppData, owner: "Microsoft Outlook")
        #expect(v(gc + name, apps: officeApps, running: ["com.microsoft.Outlook"]) == running, "\(name)")
        #expect(v(gc + name + "/Library/x", kind: .file, apps: officeApps, running: ["com.microsoft.Outlook"])
                == running, "\(name)")
        // Running known only by its bundle path.
        #expect(v(gc + name, apps: officeApps, runningPaths: ["/Applications/Microsoft Outlook.app"]) == running,
                "\(name)")
    }
}

@Test func teamPrefixedLeftoverOfAnInstalledVendorIsCaution() {   // R36 in Group Containers
    let apps = AppsIndex(records: [
        AppRecord(bundleID: "com.openai.codex", name: "ChatGPT", teamID: "2DC432GLL2", path: "/Applications/ChatGPT.app"),
    ])
    #expect(v(lib + "/Group Containers/ABCDE12345.com.openai.chat", lastUsed: old, apps: apps)
            == SafetyVerdict(level: .caution, reason: .vendorLeftover, owner: "ChatGPT"))
    // The app's own team: its data, not a leftover.
    #expect(v(lib + "/Group Containers/2DC432GLL2.com.openai.shared", lastUsed: old, apps: apps)
            == SafetyVerdict(level: .caution, reason: .appData, owner: "ChatGPT"))
}

// MARK: - Cloud deletions (final review I3, ruling R42)

@Test func datalessItemsInACloudRootWarnLikeDownloadedOnes() {
    let iCloud = SafetyVerdict(level: .caution, reason: .cloudSynced, owner: "iCloud Drive")
    #expect(v(lib + "/Mobile Documents/com~apple~CloudDocs/a.mov", kind: .file, flags: [.dataless]) == iCloud)
    #expect(v(lib + "/Mobile Documents/com~apple~CloudDocs/Folder", flags: [.dataless]) == iCloud)
    #expect(v(lib + "/CloudStorage/Dropbox-Personal/x.zip", kind: .file, flags: [.dataless])
            == SafetyVerdict(level: .caution, reason: .cloudSynced, owner: "Dropbox"))
    // Elsewhere a dataless item stays "only in the cloud".
    #expect(v("/Users/u/Movies/x.mov", kind: .file, flags: [.dataless])
            == SafetyVerdict(level: .normal, reason: .cloudOnly, owner: nil))
    // Earlier protected rules still win.
    #expect(v(lib + "/Mobile Documents/com~apple~CloudDocs", flags: [.dataless]).reason == .essentialFolder)
    #expect(v(lib + "/CloudStorage/Box/x", kind: .file, flags: [.dataless], writable: false).reason == .notWritable)
}

private func synced(_ path: String, kind: NodeKind = .directory, flags: NodeFlags = [], size: UInt64 = 0,
                    lastUsed: UInt32 = 0, category: FileCategory = .other,
                    folders: Set<String> = ["/Users/u/Desktop", "/Users/u/Documents/"]) -> SafetyVerdict {
    let env = SafetyEnvironment(home: "/Users/u", apps: testApps, runningBundleIDs: [], runningAppPaths: [],
                                syncedHomeFolders: folders, now: now, isWritable: { _ in true })
    return SafetyRules.evaluate(facts(path, kind: kind, flags: flags, size: size, lastUsed: lastUsed,
                                      category: category), in: env)
}

@Test func iCloudDesktopAndDocumentsAreSynced() {
    let iCloud = SafetyVerdict(level: .caution, reason: .cloudSynced, owner: "iCloud Drive")
    #expect(synced("/Users/u/Documents/Taxes/2025.pdf", kind: .file) == iCloud)
    #expect(synced("/Users/u/Documents/Project") == iCloud)
    #expect(synced("/Users/u/desktop/Setup.dmg", kind: .file) == iCloud)              // case-insensitive
    #expect(synced("/Users/u/Desktop/old.mov", kind: .file, flags: [.dataless]) == iCloud)
    #expect(synced("/Users/u/Desktop/a.mov", kind: .file, size: 100_000_000, lastUsed: 1, category: .video)
            == iCloud)                                                                   // not "unused for long"
    // The folders themselves stay essential; other folders are not synced.
    #expect(synced("/Users/u/Documents").reason == .essentialFolder)
    #expect(synced("/Users/u/Desktop").reason == .essentialFolder)
    #expect(synced("/Users/u/Documentsx/a", kind: .file).reason == .ordinary)
    #expect(synced("/Users/u/Movies/a.mov", kind: .file).reason == .ordinary)
    #expect(synced("/Users/u/Movies/a.mov", kind: .file, flags: [.dataless]).reason == .cloudOnly)
    // Protected items inside stay protected.
    #expect(synced("/Users/u/Documents/Lib.photoslibrary", flags: [.package]).reason == .photosLibrary)
    #expect(synced("/Users/u/Documents/App.app/Contents", flags: [.insidePackage]).reason == .insidePackage)
    // Without sync, Documents holds ordinary items.
    #expect(synced("/Users/u/Documents/Taxes/2025.pdf", kind: .file, folders: []).reason == .ordinary)
}

@Test func syncedHomeFoldersOfAPlainFolderAreNone() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.write("Desktop/a.txt", data: Data("a".utf8))
    try fx.write("Documents/b.txt", data: Data("b".utf8))
    #expect(SafetyEnvironment.iCloudSyncedHomeFolders(home: fx.root.path).isEmpty)
    #expect(SafetyEnvironment.system(home: fx.root.path, apps: nil).syncedHomeFolders.isEmpty)
}
