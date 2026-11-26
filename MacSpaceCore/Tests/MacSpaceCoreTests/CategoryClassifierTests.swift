import Testing
@testable import MacSpaceCore

private let c = CategoryClassifier(home: "/Users/me")

@Test func extensionsMap() {
    #expect(c.category(forFile: "Intervista.MOV", context: nil) == .video)
    #expect(c.category(forFile: "x.heic", context: nil) == .photo)
    #expect(c.category(forFile: "Xcode_27.xip", context: nil) == .archive)
    #expect(c.category(forFile: "README", context: nil) == .other)
    #expect(c.category(forFile: ".zshrc", context: nil) == .other)
    #expect(c.category(forFile: "disk.sparseimage", context: nil) == .archive)
    #expect(c.category(forFile: "trailing.", context: nil) == .other)
    #expect(c.category(forFile: "caf\u{E9}.mp3", context: nil) == .music)
    #expect(c.category(forFile: "a.m\u{E9}v", context: nil) == .other)
}
@Test func contextWinsOverExtension() {
    let caches = c.context(forDirectory: "Caches", path: "/Users/me/Library/Caches", parent: nil)
    #expect(caches == .appData)
    #expect(c.category(forFile: "clip.mp4", context: caches) == .appData)
}
@Test func appBundleIsSealed() {
    let app = c.context(forDirectory: "Xcode.app", path: "/Applications/Xcode.app", parent: nil)
    #expect(app == .app)
    #expect(c.context(forDirectory: "node_modules", path: "/Applications/Xcode.app/x/node_modules", parent: app) == .app)
}
@Test func developmentAndSystem() {
    #expect(c.context(forDirectory: "node_modules", path: "/Users/me/p/node_modules", parent: nil) == .development)
    #expect(c.context(forDirectory: "Developer", path: "/Users/me/Library/Developer", parent: nil) == .development)
    #expect(c.context(forDirectory: "System", path: "/System", parent: nil) == .system)
    #expect(c.context(forDirectory: "local", path: "/usr/local", parent: .system) == .development)
    #expect(c.context(forDirectory: "Documents", path: "/Users/me/Documents", parent: nil) == nil)
}
@Test func pathPrefixesAreComponentWise() {
    #expect(c.context(forDirectory: "localfoo", path: "/usr/localfoo", parent: nil) == .system)
    #expect(c.context(forDirectory: "x", path: "/usr/local/x", parent: .system) == .development)
    #expect(c.context(forDirectory: "Systemic", path: "/Systemic", parent: nil) == nil)
    #expect(c.context(forDirectory: "NODE_MODULES", path: "/Users/me/p/NODE_MODULES", parent: nil) == .development)
    #expect(c.context(forDirectory: "Caches", path: "/Users/me/Library/Caches2", parent: nil) == nil)
}
@Test func packageContexts() {
    #expect(c.context(forDirectory: "Foto.photoslibrary", path: "/Users/me/Pictures/Foto.photoslibrary", parent: nil) == .photo)
    #expect(c.context(forDirectory: "Lib.fcpbundle", path: "/Users/me/Movies/Lib.fcpbundle", parent: nil) == .video)
}
@Test func ageBuckets() {
    let now: UInt32 = 1_800_000_000, day: UInt32 = 86_400
    #expect(AgeBucket(lastUsed: now - 10 * day, now: now) == .lastMonth)
    #expect(AgeBucket(lastUsed: now - 200 * day, now: now) == .lastYear)
    #expect(AgeBucket(lastUsed: now - 800 * day, now: now) == .older)
    #expect(AgeBucket(lastUsed: 0, now: now) == .unknown)
    #expect(AgeBucket(lastUsed: now + 5 * day, now: now) == .lastMonth)
    #expect(AgeBucket(lastUsed: now - 100 * day, now: now) == .lastSixMonths)
    #expect(AgeBucket(lastUsed: now - 500 * day, now: now) == .oneToTwoYears)
}
@Test func classifierIsAllocationLight() {
    let start = ContinuousClock.now
    var n = 0
    for i in 0..<1_000_000 { if c.category(forFile: i & 1 == 0 ? "photo_0001.JPG" : "notes.txt", context: nil) == .photo { n += 1 } }
    #expect(n == 500_000)
    #expect(ContinuousClock.now - start < .seconds(2))   // debug-build bound; the release benchmark (Task 3) is the real gate
}

@Test func localModelStoresAreDevelopment() {
    #expect(c.context(forDirectory: ".ollama", path: "/Users/me/.ollama", parent: nil) == .development)
    #expect(c.context(forDirectory: ".lmstudio", path: "/Users/me/.lmstudio", parent: nil) == .development)
    #expect(c.context(forDirectory: "huggingface", path: "/Users/me/.cache/huggingface", parent: nil) == .development)
    // Only the cache one: a folder that merely shares the name keeps no context.
    #expect(c.context(forDirectory: "huggingface", path: "/Users/me/Documents/huggingface", parent: nil) == nil)
}

@Test func cargoTargetIsDevelopmentOnlyBesideCargoToml() {
    let path = "/Users/me/p/cubelite/target"
    #expect(c.context(forDirectory: "target", path: path, parent: nil, siblingHasCargoToml: true) == .development)
    #expect(c.context(forDirectory: "target", path: path, parent: nil, siblingHasCargoToml: false) == nil)
    #expect(c.context(forDirectory: "target", path: path, parent: nil) == nil)
    #expect(c.context(forDirectory: "other", path: "/Users/me/p/other", parent: nil, siblingHasCargoToml: true) == nil)
}
