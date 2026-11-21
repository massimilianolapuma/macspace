/// Decides which directories the scanner descends into.
public struct ScanBoundary: Sendable, Equatable {
    public var allowedDevices: Set<Int32>
    public var excludedPaths: Set<String>

    public init(allowedDevices: Set<Int32>, excludedPaths: Set<String>) {
        self.allowedDevices = allowedDevices
        self.excludedPaths = excludedPaths
    }

    /// Descend iff the device is allowed and the path is not excluded.
    /// `isMountPoint` alone does not block: firmlinked directories live on an allowed device.
    public func shouldDescend(path: String, device: Int32, isMountPoint: Bool) -> Bool {
        allowedDevices.contains(device) && !excludedPaths.contains(path)
    }

    public static func forFolder(_ path: String) throws(DirectoryReadError) -> ScanBoundary {
        let entry = try DirectoryReader.stat(path: path)
        return ScanBoundary(allowedDevices: [entry.device], excludedPaths: [])
    }

    /// Container-level volumes are reported as volume info, not as tree nodes.
    public static func forStartupDisk() throws(DirectoryReadError) -> ScanBoundary {
        let root = try DirectoryReader.stat(path: "/")
        let data = try DirectoryReader.stat(path: "/System/Volumes/Data")
        return ScanBoundary(
            allowedDevices: [root.device, data.device],
            excludedPaths: [
                "/System/Volumes/Data", "/Volumes", "/dev", "/System/Volumes/VM",
                "/System/Volumes/Preboot", "/System/Volumes/Update", "/System/Volumes/xarts",
                "/System/Volumes/iSCPreboot", "/System/Volumes/Hardware",
            ])
    }
}
