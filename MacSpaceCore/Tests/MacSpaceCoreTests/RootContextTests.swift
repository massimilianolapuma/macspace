import Testing
@testable import MacSpaceCore

@Test func rootInsideBundleIsInsidePackage() {
    let c = CategoryClassifier(home: "/Users/u")
    let r = RootContext.resolve(rootPath: "/Applications/Foo.app/Contents", classifier: c)
    #expect(r.context == .app && r.flags.contains(.insidePackage) && !r.flags.contains(.package))
    let p = RootContext.resolve(rootPath: "/Users/u/Pictures/Photos Library.photoslibrary", classifier: c)
    #expect(p.flags == [.package] && p.context == .photo)
    #expect(RootContext.resolve(rootPath: "/", classifier: c).flags.isEmpty)
}

@Test func packageAndInstallerNamesAreRecognized() {
    let c = CategoryClassifier(home: "/Users/u")
    #expect(c.isPackage(directoryName: "Foo.APP") && c.isPackage(directoryName: "x.xcodeproj"))
    #expect(!c.isPackage(directoryName: "app") && !c.isPackage(directoryName: "plain"))
    #expect(c.isInstaller(fileName: "Setup.DMG") && c.isInstaller(fileName: "a.pkg"))
    #expect(!c.isInstaller(fileName: "a.zip"))
}
