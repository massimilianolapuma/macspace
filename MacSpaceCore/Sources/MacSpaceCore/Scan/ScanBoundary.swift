/// Decides which directories below the scan root the scanner descends into. The root itself is
/// always read, even when it is a mount point (e.g. a chosen `/Volumes/USB`).
public struct ScanBoundary: Sendable, Equatable {
    public var allowedDevices: Set<Int32>
    public var excludedPaths: Set<String>

    public init(allowedDevices: Set<Int32>, excludedPaths: Set<String>) {
        self.allowedDevices = allowedDevices
        self.excludedPaths = excludedPaths
    }

    /// Descend iff the entry is not a mount point, its device is allowed and its path is not
    /// excluded. Mount points must be checked explicitly: `getattrlistbulk` reports a mount-point
    /// entry with its parent's device, so the device check alone would cross into the mounted
    /// volume. Firmlinks of the system volume group (`/Users`, `/Applications`, …) are not mount
    /// points, so they are still descended.
    public func shouldDescend(path: String, device: Int32, isMountPoint: Bool) -> Bool {
        !isMountPoint && allowedDevices.contains(device) && !excludedPaths.contains(path)
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
