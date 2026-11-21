import Darwin

/// One directory entry as reported by the file system, without following symbolic links.
public struct DirectoryEntry: Sendable, Equatable {
    public let name: String
    public let kind: NodeKind
    /// Bytes allocated on disk (all forks). Always 0 for directories.
    public let allocatedSize: UInt64
    public let device: Int32
    public let inode: UInt64
    public let linkCount: UInt32
    public let isMountPoint: Bool
    /// Contents live only in the cloud (`SF_DATALESS`); `allocatedSize` reflects the local footprint.
    public let isDataless: Bool
    /// Last modification, seconds since 1970 clamped to `UInt32` (0 = unknown).
    public let modificationTime: UInt32
    /// Last access, seconds since 1970 clamped to `UInt32` (0 = unknown).
    public let accessTime: UInt32

    public init(
        name: String, kind: NodeKind, allocatedSize: UInt64, device: Int32, inode: UInt64,
        linkCount: UInt32, isMountPoint: Bool, isDataless: Bool,
        modificationTime: UInt32 = 0, accessTime: UInt32 = 0
    ) {
        self.name = name
        self.kind = kind
        self.allocatedSize = allocatedSize
        self.device = device
        self.inode = inode
        self.linkCount = linkCount
        self.isMountPoint = isMountPoint
        self.isDataless = isDataless
        self.modificationTime = modificationTime
        self.accessTime = accessTime
    }
}

public enum DirectoryReadError: Error, Equatable {
    case permissionDenied, notFound, nameTooLong, notADirectory, other(Int32)

    init(errno code: Int32) {
        switch code {
        case EACCES, EPERM: self = .permissionDenied
        case ENOENT: self = .notFound
        case ENAMETOOLONG: self = .nameTooLong
        case ENOTDIR: self = .notADirectory
        default: self = .other(code)
        }
    }
}
