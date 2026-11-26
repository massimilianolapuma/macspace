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
}

public struct NodeRow: Sendable, Hashable, Identifiable {
    public let id: NodeID
    public let name: String
    public let size: UInt64
    public let kind: NodeKind
    public let flags: NodeFlags
    public let hasChildren: Bool

    public init(id: NodeID, name: String, size: UInt64, kind: NodeKind, flags: NodeFlags, hasChildren: Bool) {
        self.id = id
        self.name = name
        self.size = size
        self.kind = kind
        self.flags = flags
        self.hasChildren = hasChildren
    }
}
