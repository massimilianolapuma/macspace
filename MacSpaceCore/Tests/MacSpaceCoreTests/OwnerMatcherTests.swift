import Foundation
import Testing
@testable import MacSpaceCore

private let apps = AppsIndex(records: [
    AppRecord(bundleID: "com.spotify.client", name: "Spotify", teamID: "2FNC3A47ZF", path: "/Applications/Spotify.app"),
    AppRecord(bundleID: "com.tinyspeck.slackmacgap", name: "Slack", teamID: "BQR82RBBHL", path: "/Applications/Slack.app"),
])

private func own(_ name: String, _ location: LibraryLocation, running: Set<String> = []) -> Ownership {
    OwnerMatcher.ownership(of: name, in: location, apps: apps, running: running)
}

private func isInstalled(_ ownership: Ownership) -> Bool {
    if case .installed = ownership { return true }
    return false
}

@Test func helperPrefixIsInstalled() throws {
    let spotify = try #require(apps.app(named: "Spotify"))
    #expect(own("com.spotify.client.helper", .caches) == .installed(spotify))
}

@Test func teamGroupContainerIsInstalled() {
    #expect(isInstalled(own("BQR82RBBHL.com.tinyspeck.slack", .groupContainers)))
}

@Test func runningIdentifierIsInstalled() {
    #expect(isInstalled(own("com.acme.tool", .applicationSupport, running: ["com.acme.tool"])))
    #expect(isInstalled(own("com.acme.tool.helper", .caches, running: ["com.acme.tool"])))
    #expect(own("com.acme.tool", .applicationSupport) == .unmatchedIdentifier("com.acme.tool"))
}

@Test func suffixesAndApple() {
    #expect(own("com.spotify.client.plist", .preferences) != .unknownName)
    #expect(isInstalled(own("com.spotify.client.plist", .preferences)))
    #expect(own("com.apple.Safari.savedState", .savedState) == .apple)
    #expect(own("COM.APPLE.dock.plist", .preferences) == .apple)
    #expect(own("group.com.apple.notes", .groupContainers) == .apple)
    #expect(own("systemgroup.com.apple.configurationprofiles", .groupContainers) == .apple)
    #expect(own("com.gone.app.plist", .preferences) == .unmatchedIdentifier("com.gone.app"))
    #expect(own("com.gone.app.binarycookies", .httpStorages) == .unmatchedIdentifier("com.gone.app"))
    #expect(own("homebrew.mxcl.postgresql.plist", .launchAgents) == .unmatchedIdentifier("homebrew.mxcl.postgresql"))
}

@Test func suffixesOnlyStrippedInTheirLocation() {
    #expect(OwnerMatcher.identifier(from: "com.gone.app.plist", in: .caches) == "com.gone.app.plist")
    #expect(OwnerMatcher.identifier(from: "com.gone.app.plist", in: .preferences) == "com.gone.app")
}

@Test func groupContainerPrefixes() {
    #expect(own("group.com.gone.app", .groupContainers) == .unmatchedIdentifier("com.gone.app"))
    #expect(own("ABCDE12345.com.gone.app", .groupContainers) == .unmatchedIdentifier("com.gone.app"))
    #expect(isInstalled(own("group.com.spotify.client", .groupContainers)))
    // The same prefixes mean nothing outside Group Containers.
    #expect(OwnerMatcher.identifier(from: "group.com.gone.app", in: .caches) == "group.com.gone.app")
}

@Test func namesAreNotIdentifiers() {
    #expect(isInstalled(own("Slack", .applicationSupport)))
    #expect(own("AddressBook", .applicationSupport) == .unknownName)
    #expect(own("cache.db", .caches) == .unknownName)          // one dot, not a TLD
    #expect(own("Google Chrome", .caches) == .unknownName)
    #expect(own("my app.v2.thing", .caches) == .unknownName)   // spaces
    #expect(own("foo..bar.baz", .caches) == .unknownName)      // empty label
    #expect(own("", .caches) == .unknownName)
    #expect(own(".plist", .preferences) == .unknownName)
}

@Test func twoLabelIdentifiersNeedATLD() {
    #expect(OwnerMatcher.identifier(from: "com.foo", in: .caches) == "com.foo")
    #expect(OwnerMatcher.identifier(from: "Foo.Bar", in: .caches) == nil)
    #expect(OwnerMatcher.identifier(from: "homebrew.mxcl.x", in: .caches) == "homebrew.mxcl.x")
    #expect(OwnerMatcher.identifier(from: "IO.foo", in: .caches) == "IO.foo")
}

@Test func spotlightOnlyAppIsInstalled() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.plist("Elsewhere/Qux.app/Contents/Info.plist", ["CFBundleIdentifier": "net.qux.app"])
    let index = AppsIndex.build(roots: [], extraAppPaths: [fx.root.path + "/Elsewhere/Qux.app"], readTeamIDs: false)
    #expect(isInstalled(OwnerMatcher.ownership(of: "net.qux.app", in: .caches, apps: index, running: [])))
    #expect(isInstalled(OwnerMatcher.ownership(of: "net.qux.app.plist", in: .preferences, apps: index, running: [])))
}
