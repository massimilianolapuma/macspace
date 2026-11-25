import Foundation
import Testing
@testable import MacSpaceCore

@Test func indexReadsBundlesAndHelpers() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.plist("Apps/Foo.app/Contents/Info.plist", ["CFBundleIdentifier": "com.foo.Foo", "CFBundleName": "Foo"])
    try fx.plist("Apps/Foo.app/Contents/Library/LoginItems/FooHelper.app/Contents/Info.plist",
                 ["CFBundleIdentifier": "com.foo.helper"])
    try fx.plist("Apps/Utilities/Bar.app/Contents/Info.plist", ["CFBundleIdentifier": "org.bar.app"])
    try fx.dir("Apps/NoPlist.app")
    let idx = AppsIndex.build(roots: [fx.root.path + "/Apps"], readTeamIDs: false)
    #expect(idx.count == 3)
    #expect(idx.app(forIdentifier: "com.foo.helper")?.name == "Foo")
    #expect(idx.app(forIdentifier: "COM.FOO.FOOBAR") == nil)   // not a dot-boundary prefix
    #expect(idx.app(forIdentifier: "COM.FOO.FOO.savedState")?.bundleID == "com.foo.Foo")   // dot-boundary prefix
    #expect(idx.app(forIdentifier: "org.bar.app.extension")?.bundleID == "org.bar.app")
    #expect(idx.app(named: "bar")?.bundleID == "org.bar.app")
}

@Test func embeddedKindsAndDisplayNameAndExtraPaths() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    try fx.plist("Apps/Baz.app/Contents/Info.plist",
                 ["CFBundleIdentifier": "com.baz.app", "CFBundleDisplayName": "Baz Pro", "CFBundleName": "Baz"])
    try fx.plist("Apps/Baz.app/Contents/PlugIns/Share.appex/Contents/Info.plist", ["CFBundleIdentifier": "com.baz.app.share"])
    try fx.plist("Apps/Baz.app/Contents/XPCServices/Svc.xpc/Contents/Info.plist", ["CFBundleIdentifier": "com.baz.svc"])
    try fx.plist("Apps/Baz.app/Contents/Helpers/H.app/Contents/Info.plist", ["CFBundleIdentifier": "com.baz.hlp"])
    try fx.plist("Elsewhere/Qux.app/Contents/Info.plist", ["CFBundleIdentifier": "net.qux.app"])
    let apps = fx.root.path + "/Apps"
    let extra = fx.root.path + "/Elsewhere/Qux.app"
    let idx = AppsIndex.build(roots: [apps], extraAppPaths: [extra, extra, apps + "/Baz.app"], readTeamIDs: false)
    #expect(idx.count == 5)
    #expect(idx.app(named: "Baz Pro")?.bundleID == "com.baz.app")
    #expect(idx.app(named: "Baz")?.bundleID == "com.baz.app")   // file name without .app
    #expect(idx.app(forIdentifier: "com.baz.svc")?.name == "Baz Pro")
    #expect(idx.app(forIdentifier: "com.baz.hlp")?.path == apps + "/Baz.app")
    #expect(idx.app(forIdentifier: "net.qux.app") != nil)
}

@Test func binaryPlistsAreRead() throws {
    let fx = try Fixture(); defer { fx.cleanup() }
    let data = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "com.bin.app"], format: .binary, options: 0)
    try fx.write("Apps/Bin.app/Contents/Info.plist", data: data)
    let idx = AppsIndex.build(roots: [fx.root.path + "/Apps"], readTeamIDs: false)
    #expect(idx.app(forIdentifier: "com.bin.app") != nil)
}

@Test func prefixMatchNeedsTwoLabels() {
    let idx = AppsIndex(records: [AppRecord(bundleID: "com.foo", name: "Foo", teamID: "ABCDE12345", path: "/A/Foo.app")])
    #expect(idx.app(forIdentifier: "com.foo.mac") != nil && idx.app(forIdentifier: "com") == nil)
    #expect(idx.app(forIdentifier: "com.foobar") == nil && idx.hasTeam("abcde12345"))
}

@Test func appIDLongerThanIdentifierMatches() {
    let idx = AppsIndex(records: [AppRecord(bundleID: "com.foo.mac.app", name: "Foo", teamID: nil, path: "/A/Foo.app")])
    #expect(idx.app(forIdentifier: "com.foo.mac") != nil)
    #expect(idx.app(forIdentifier: "com.foo") != nil)
    #expect(idx.app(forIdentifier: "com") == nil)
    #expect(idx.app(forIdentifier: "com.foo.macx") == nil)
    #expect(idx.app(forIdentifier: "com.fo") == nil)
    #expect(AppsIndex.empty.count == 0 && AppsIndex.empty.app(forIdentifier: "com.foo") == nil)
}

@Test func spotlightHelpersDoNotCrash() {
    #expect(AppsIndex.spotlightAppPaths().allSatisfy { $0.hasSuffix(".app") })
    #expect(SpotlightLastUsed.lastUsed(path: "/nonexistent/x") == nil)
}

@Test func realIndexFindsSystemApps() throws {   // tolerant smoke test on the owner's Mac
    let idx = AppsIndex.build()
    #expect(idx.app(forIdentifier: "com.apple.calculator") != nil)
    let calc = try #require(idx.app(forIdentifier: "com.apple.calculator"))
    #expect(calc.teamID == nil || !calc.teamID!.isEmpty)
}

/// Opt-in: `MACSPACE_BENCH=1 swift test -c release --filter appsIndexTiming`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MACSPACE_BENCH"] == "1"))
func appsIndexTiming() {
    let clock = ContinuousClock()
    var idx = AppsIndex.empty
    let elapsed = clock.measure { idx = AppsIndex.build(extraAppPaths: AppsIndex.spotlightAppPaths()) }
    print("APPSINDEX records=\(idx.count) seconds=\(elapsed)")
}
