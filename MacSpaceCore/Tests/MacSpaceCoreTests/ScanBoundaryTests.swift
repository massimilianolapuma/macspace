import Testing
@testable import MacSpaceCore

@Test func excludesDataVolumeMirror() {
    let b = ScanBoundary(allowedDevices: [1, 2], excludedPaths: ["/System/Volumes/Data", "/Volumes"])
    #expect(b.shouldDescend(path: "/Users", device: 2, isMountPoint: false))
    #expect(!b.shouldDescend(path: "/System/Volumes/Data", device: 2, isMountPoint: true))
    #expect(!b.shouldDescend(path: "/Volumes", device: 1, isMountPoint: false))
}

@Test func otherDevicesAreNotEntered() {
    let b = ScanBoundary(allowedDevices: [1], excludedPaths: [])
    #expect(!b.shouldDescend(path: "/Users/me/elsewhere", device: 9, isMountPoint: false))
}

@Test func mountPointsAreNotEnteredEvenOnAnAllowedDevice() {
    // getattrlistbulk reports a mount-point entry with its PARENT's device (e.g.
    // /Library/Developer/CoreSimulator/Volumes/iOS_…), so the device check alone lets it through.
    let b = ScanBoundary(allowedDevices: [1], excludedPaths: [])
    #expect(!b.shouldDescend(path: "/Library/Developer/CoreSimulator/Volumes/iOS", device: 1, isMountPoint: true))
    // Firmlinks such as /Users and /Applications are not mount points.
    #expect(b.shouldDescend(path: "/Users", device: 1, isMountPoint: false))
}

@Test func startupDiskBoundaryIsReal() throws {
    let b = try ScanBoundary.forStartupDisk()
    let rootDev = try DirectoryReader.stat(path: "/").device
    #expect(b.allowedDevices.contains(rootDev))
    #expect((1...2).contains(b.allowedDevices.count))
    #expect(b.excludedPaths.contains("/System/Volumes/Data"))
    #expect(!b.shouldDescend(path: "/System/Volumes/Data", device: rootDev, isMountPoint: true))
    #expect(b.shouldDescend(path: "/Users", device: rootDev, isMountPoint: false))
}
