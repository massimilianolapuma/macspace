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
    let record = AppRecord(bundleID: "com.acme.tool", name: "", teamID: nil, path: "")
    #expect(own("com.acme.tool", .applicationSupport, running: ["com.acme.tool"]) == .installed(record))
    #expect(own("com.acme.tool.helper", .caches, running: ["com.acme.tool"]) == .installed(record))
    // Several related running IDs: the lowest one is reported.
    #expect(own("com.acme.tool.x", .caches, running: ["com.acme.tool.x", "com.acme.tool"]) == .installed(record))
    #expect(own("com.acme.tool", .applicationSupport) == .unmatchedIdentifier("com.acme.tool"))
}

@Test func suffixesAndApple() {
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
    #expect(OwnerMatcher.identifier(from: "com.gone.app.savedState", in: .caches) == "com.gone.app.savedState")
    #expect(OwnerMatcher.identifier(from: "com.gone.app.savedState", in: .savedState) == "com.gone.app")
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

@Test func teamAloneLinksGroupContainerToRealRecord() throws {
    let slack = try #require(apps.app(named: "Slack"))
    #expect(own("BQR82RBBHL.com.other.thing", .groupContainers) == .installed(slack))
    #expect(own("bqr82rbbhl.com.other.thing", .groupContainers) == .unmatchedIdentifier("bqr82rbbhl.com.other.thing"))
    #expect(own("BQR82RBBH.com.other.thing", .groupContainers) == .unmatchedIdentifier("BQR82RBBH.com.other.thing"))
    #expect(own("BQR82RBBHLX.com.other.thing", .groupContainers) == .unmatchedIdentifier("BQR82RBBHLX.com.other.thing"))
    #expect(own("UNKNOWN123.com.other.thing", .groupContainers) == .unmatchedIdentifier("com.other.thing"))
    // The team link only exists in Group Containers.
    #expect(own("BQR82RBBHL.com.other.thing", .caches) == .unmatchedIdentifier("BQR82RBBHL.com.other.thing"))
}

@Test func appleGroupContainers() {
    #expect(own("243LU875E5.groups.com.apple.podcasts", .groupContainers) == .apple)
    #expect(own("243LU875E5.whatever", .groupContainers) == .apple)
    #expect(own("group.is.workflow.my.workflows", .groupContainers) == .apple)
    #expect(own("ABCDE12345.com.apple.x", .groupContainers) == .apple)
    #expect(own("group.com.gone.apple", .groupContainers) == .unmatchedIdentifier("com.gone.apple"))
}

@Test func fileExtensionsAreNotIdentifierLabels() {
    #expect(own("app.log", .logs) == .unknownName)
    #expect(own("it.db", .caches) == .unknownName)
    #expect(own("foo.bar.cache", .caches) == .unknownName)
    #expect(own("com.gone.app.log", .logs) == .unmatchedIdentifier("com.gone.app"))
    #expect(isInstalled(own("com.spotify.client.log", .logs)))
    #expect(OwnerMatcher.identifier(from: "com.foo.app.LOG", in: .logs) == "com.foo.app")
}

@Test func suffixAndPrefixEdgeCases() {
    #expect(own("com.gone.app.PLIST", .preferences) == .unmatchedIdentifier("com.gone.app"))
    #expect(own("group.", .groupContainers) == .unknownName)
    #expect(own("com.gone.app.SAVEDSTATE", .savedState) == .unmatchedIdentifier("com.gone.app"))
    #expect(own("GROUP.com.gone.app", .groupContainers) == .unmatchedIdentifier("com.gone.app"))
}

@Test func runningAppsFollowTheAppsIndexPrefixRule() {   // final review I5: one index per environment
    let running = RunningApps(bundleIDs: ["com.acme.tool", "com.acme.tool.x", "org.other.app"],
                              paths: ["/Applications/Tool.app/", "/Applications/Café.app"])
    #expect(running.id(relatedTo: "com.acme.tool.x") == "com.acme.tool")      // lowest related ID
    #expect(running.id(relatedTo: "COM.ACME.TOOL.helper") == "com.acme.tool")
    #expect(running.id(relatedTo: "com.acme") == "com.acme.tool")             // a prefix of a running ID
    #expect(running.id(relatedTo: "org.other") == "org.other.app")
    #expect(running.id(relatedTo: "com") == nil)                              // fewer than 2 shared labels
    #expect(running.id(relatedTo: "com.acmex.tool") == nil)
    #expect(running.id(relatedTo: "") == nil)
    #expect(running.isRunning(path: "/applications/tool.APP"))
    #expect(running.isRunning(path: "/Applications/Cafe\u{301}.app"))          // NFD spelling of the same name
    #expect(running.isRunning(path: "/Applications/CAFÉ.app"))
    #expect(!running.isRunning(path: "/Applications/Tool.app/Contents"))
    #expect(!RunningApps(bundleIDs: [], paths: []).isRunning(path: "/Applications/Tool.app"))
}

// MARK: - Shared team containers (final review I2)

private let office = AppsIndex(records: [
    AppRecord(bundleID: "com.microsoft.Excel", name: "Microsoft Excel", teamID: "UBF8T346G9",
              path: "/Applications/Microsoft Excel.app"),
    AppRecord(bundleID: "com.microsoft.Outlook", name: "Microsoft Outlook", teamID: "UBF8T346G9",
              path: "/Applications/Microsoft Outlook.app"),
    AppRecord(bundleID: "com.microsoft.Outlook.helper", name: "Microsoft Outlook", teamID: nil,
              path: "/Applications/Microsoft Outlook.app"),
])

private func officeOwner(_ name: String, _ location: LibraryLocation = .groupContainers,
                         running: Set<String> = []) -> String? {
    if case let .installed(app) = OwnerMatcher.ownership(of: name, in: location, apps: office, running: running) {
        return app.name
    }
    return nil
}

@Test func teamContainerPrefersARunningTeamMember() {
    // Not running: the lowest-path app of the team, as before.
    #expect(officeOwner("UBF8T346G9.com.microsoft.oneauth") == "Microsoft Excel")
    // Outlook running: the shared container is its data too.
    #expect(officeOwner("UBF8T346G9.com.microsoft.oneauth", running: ["com.microsoft.Outlook"]) == "Microsoft Outlook")
    #expect(officeOwner("UBF8T346G9.com.microsoft.oneauth", running: ["com.microsoft.Outlook.helper"])
            == "Microsoft Outlook")
    // Even when the name itself matches the app that is not running.
    #expect(officeOwner("UBF8T346G9.com.microsoft.Excel", running: ["com.microsoft.Outlook"]) == "Microsoft Outlook")
    #expect(officeOwner("UBF8T346G9.com.microsoft.Excel") == "Microsoft Excel")
}

@Test func teamPrefixedPlainNamesUseTheTeam() {
    #expect(officeOwner("UBF8T346G9.Office") == "Microsoft Excel")
    #expect(officeOwner("UBF8T346G9.Office", running: ["com.microsoft.Outlook"]) == "Microsoft Outlook")
    #expect(officeOwner("UBF8T346G9.OfficeOsfWebHost") == "Microsoft Excel")
    // A plain name matching an app still names it; an unknown team stays unknown.
    #expect(own("BQR82RBBHL.Slack", .groupContainers) == .installed(apps.app(named: "Slack")!))
    #expect(OwnerMatcher.ownership(of: "ZZZZZ99999.Office", in: .groupContainers, apps: office, running: [])
            == .unknownName)
    // The team link only exists in Group Containers.
    #expect(OwnerMatcher.ownership(of: "UBF8T346G9.Office", in: .applicationSupport, apps: office, running: [])
            == .unknownName)
}
