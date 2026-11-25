import Darwin
import Foundation
import Testing
@testable import MacSpaceCore

private let spotifyIndex = AppsIndex(records: [
    AppRecord(bundleID: "com.spotify.client", name: "Spotify", teamID: "2FNC3A47ZF", path: "/Applications/Spotify.app"),
])

/// Scans `fx` as a home folder with the Spotify-only apps index.
private func scanned(_ fx: Fixture) async throws -> ScanStore {
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path)
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    await store.setEnvironment(.system(home: fx.root.path, apps: spotifyIndex))
    return store
}

private func age(_ url: URL, years: Int) {
    let t = time(nil) - time_t(years * 365 * 86_400)
    var times = [timeval(tv_sec: t, tv_usec: 0), timeval(tv_sec: t, tv_usec: 0)]
    utimes(url.path, &times)
}

@Test func suggestsLeftoversCachesAndInstallers() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Library/Caches/com.spotify.client/a", bytes: 2_000_000)
    try fx.file("Library/Caches/com.apple.y/a", bytes: 2_000_000)
    try fx.file("Library/Caches/com.gone.x/a", bytes: 2_000_000)
    let old = try fx.file("Library/Application Support/com.gone.editor/a", bytes: 3_000_000)
    age(old, years: 3)
    try fx.file("Library/Caches/tiny/a", bytes: 10_000)
    try fx.file("Downloads/A.dmg", bytes: 4_000_000)
    try fx.file("Foo.app/Contents/Resources/inner.pkg", bytes: 4_000_000)
    let store = try await scanned(fx)

    let s = await store.suggestions()
    #expect(s.map(\.kind) == [.leftovers, .caches, .installers])
    #expect(Set(s[0].items.map(\.name)) == ["com.gone.editor", "com.gone.x"] && s[0].total >= 5_000_000)
    #expect(s[0].items.first { $0.name == "com.gone.editor" }?.preselected == true)
    #expect(s[0].items.first { $0.name == "com.gone.x" }?.preselected == true)   // unmatched cache folders are safe (rule 14)
    #expect(Set(s[1].items.map(\.name)) == ["com.spotify.client", "com.apple.y"])
    #expect(s[1].items.first { $0.name == "com.apple.y" }?.preselected == false)
    #expect(s[1].items.first { $0.name == "com.spotify.client" }?.preselected == true)
    #expect(s[2].items.map(\.name) == ["A.dmg"])
    #expect(s.allSatisfy { $0.total == $0.items.reduce(0) { $0 + $1.size } })
}

@Test func hardLinkedInstallerAppearsOnce() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let a = try fx.file("Downloads/A.dmg", bytes: 4_000_000)
    try fx.hardLink("Downloads/B.dmg", to: a)
    let store = try await scanned(fx)
    let s = await store.suggestions()
    #expect(s.map(\.kind) == [.installers])
    #expect(s[0].items.count == 1)
}

@Test func installerOutsideDownloadsIsCautionNotPreselected() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Projects/Setup.pkg", bytes: 4_000_000)
    let store = try await scanned(fx)
    let item = try #require(await store.suggestions().first?.items.first)
    #expect(item.verdict.level == .caution && !item.preselected)
}

@Test func nothingWithoutAppsIndexOrSmallOrProtected() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file("Library/Caches/com.gone.x/a", bytes: 2_000_000)
    try fx.file("Library/Mobile Documents/com.gone.y/a", bytes: 2_000_000)
    let store = ScanStore(rootName: "home", rootPath: fx.root.path, home: fx.root.path)
    _ = await Scanner(rootPath: fx.root.path, boundary: try .forFolder(fx.root.path)).scan(into: store)
    // No apps index yet: nothing in Library is a leftover.
    #expect(await store.suggestions().isEmpty)
    await store.setEnvironment(.system(home: fx.root.path, apps: spotifyIndex))
    let s = await store.suggestions()
    #expect(s.flatMap(\.items).allSatisfy { $0.verdict.level == .safe || $0.verdict.level == .caution })
    #expect(!s.flatMap(\.items).contains { $0.name == "com.gone.y" })
}

@Test func developerCacheRootIsListed() async throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.file(".npm/_cacache/x", bytes: 2_000_000)
    try fx.file("Library/Developer/Xcode/DerivedData/App-abc/x", bytes: 2_000_000)
    let store = try await scanned(fx)
    let items = await store.suggestions().first { $0.kind == .caches }?.items ?? []
    #expect(Set(items.map(\.name)) == ["_cacache", "DerivedData"])
    #expect(items.allSatisfy { $0.verdict.reason == .developerCache })
}

@Test func vendorLeftoverIsListedButNotPreselected() async throws {   // ruling R36
    let fx = try Fixture(); defer { fx.cleanup() }
    let data = try fx.file("Library/Application Support/com.spotify.legacy/a", bytes: 2_000_000)
    age(data, years: 3)
    try fx.file("Library/Caches/com.spotify.legacy/a", bytes: 2_000_000)
    let store = try await scanned(fx)

    let leftovers = try #require(await store.suggestions().first { $0.kind == .leftovers })
    #expect(leftovers.items.count == 2)
    #expect(leftovers.items.allSatisfy {
        $0.verdict == SafetyVerdict(level: .caution, reason: .vendorLeftover, owner: "Spotify") && !$0.preselected
    })
}
