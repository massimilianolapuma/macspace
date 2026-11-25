public enum MacSpaceCore { public static let version = "0.1.0" }

public typealias NodeID = Int32

public enum NodeKind: UInt8, Sendable { case file, directory, symlink, other }

public struct NodeFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let unreadable = NodeFlags(rawValue: 1 << 0)
    public static let dataless = NodeFlags(rawValue: 1 << 1)
    public static let mountPoint = NodeFlags(rawValue: 1 << 2)
    public static let hardLinkDuplicate = NodeFlags(rawValue: 1 << 3)
    /// A directory that is a package (bundle or library).
    public static let package = NodeFlags(rawValue: 1 << 4)
    /// Anything below a package.
    public static let insidePackage = NodeFlags(rawValue: 1 << 5)
    /// Moved to the Trash since the scan.
    public static let removed = NodeFlags(rawValue: 1 << 6)
}

public struct NodeRow: Sendable, Hashable, Identifiable {
    public let id: NodeID
    public let name: String
    public let size: UInt64
    public let kind: NodeKind
    public let flags: NodeFlags
    public let hasChildren: Bool
    /// A file's category; for a directory, its dominant category (`FileTree.dominantCategory`).
    public let category: FileCategory
    /// Seconds since 1970 (0 = unknown); for a directory, the latest over its contents.
    public let lastUsed: UInt32
    /// A file's age bucket; for a directory, the bucket holding most of its bytes.
    public let ageBucket: AgeBucket

    public init(id: NodeID, name: String, size: UInt64, kind: NodeKind, flags: NodeFlags, hasChildren: Bool,
                category: FileCategory = .other, lastUsed: UInt32 = 0, ageBucket: AgeBucket = .unknown) {
        self.id = id
        self.name = name
        self.size = size
        self.kind = kind
        self.flags = flags
        self.hasChildren = hasChildren
        self.category = category
        self.lastUsed = lastUsed
        self.ageBucket = ageBucket
    }
}
