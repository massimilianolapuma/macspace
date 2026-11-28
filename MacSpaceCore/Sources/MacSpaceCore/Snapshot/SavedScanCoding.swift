import CryptoKit
import Foundation

/// Why bytes are not a `SavedScan`.
public enum SavedScanError: Error, Equatable {
    /// Too short, or the magic is not there: not a snapshot at all.
    case notASnapshot
    /// A snapshot of another format version.
    case unsupportedVersion(UInt32)
    /// The checksum or the structure does not hold: truncated, altered or inconsistent.
    case damaged
}

/// The binary format, version 1, little-endian:
///
///     "MSPSNAP\0" · version (UInt32) · header · tree · side tables · SHA-256 of all that (32 bytes)
///
/// The header holds the target, the scan start, Full Disk Access and the baseline; the tree, each
/// of `FileTree.Storage`'s arrays as a count (UInt64) and its raw bytes; strings as a byte count
/// and UTF-8. Decoding checks the magic, the version and the checksum, then that the arrays fit
/// together (`FileTree.Storage.isConsistent`), so a tree built from them can never trap or loop.
extension SavedScan {
    public static let formatVersion: UInt32 = 1
    static let magic = Data("MSPSNAP\0".utf8)

    public func encoded() -> Data {
        var w = Writer()
        w.data.append(Self.magic)
        w.put(Self.formatVersion)
        switch target {
        case .startupDisk: w.put(UInt8(0))
        case let .folder(path):
            w.put(UInt8(1))
            w.put(path)
        }
        w.put(startedAt)
        w.put(UInt8(hadFullDiskAccess ? 1 : 0))
        if let baseline {
            w.put(UInt8(1))
            w.put(baseline.eventID)
            let devices = baseline.deviceUUIDs.sorted { $0.key < $1.key }
            w.put(UInt64(devices.count))
            for (device, uuid) in devices {
                w.put(device)
                w.put(uuid)
            }
        } else {
            w.put(UInt8(0))
        }
        w.put(tree.rootPath)
        w.put(tree.parents)
        w.put(tree.firstChildren)
        w.put(tree.nextSiblings)
        w.put(tree.sizes)
        w.put(ContiguousArray(tree.kinds.map(\.rawValue)))
        w.put(ContiguousArray(tree.flags.map(\.rawValue)))
        w.put(tree.nameBytes)
        w.put(tree.nameEnds)
        w.put(tree.categories)
        w.put(tree.lastUsed)
        w.put(tree.dirSlots)
        w.put(tree.categoryBytes)
        w.put(tree.inodes)
        w.put(tree.dirDevices)
        w.put(UInt64(hardLinks.count))
        for link in hardLinks {
            w.put(link.device)
            w.put(link.inode)
            w.put(ContiguousArray(link.links))
            w.put(link.counted ?? -1)
        }
        w.put(ContiguousArray(installerIDs))
        w.put(ContiguousArray(unverifiedDirectories))
        w.put(ContiguousArray(scanDevices))
        w.data.append(contentsOf: SHA256.hash(data: w.data))
        return w.data
    }

    public init(decoding data: Data) throws(SavedScanError) {
        let digestSize = SHA256.byteCount
        guard data.count >= Self.magic.count, data.prefix(Self.magic.count) == Self.magic else { throw .notASnapshot }
        var r = Reader(data: data, end: data.count)
        r.offset = data.startIndex + Self.magic.count
        let version: UInt32 = try r.get()
        guard version == Self.formatVersion else { throw .unsupportedVersion(version) }
        guard data.count >= Self.magic.count + 4 + digestSize else { throw .damaged }
        let bodyEnd = data.endIndex - digestSize
        guard Data(SHA256.hash(data: data[data.startIndex..<bodyEnd])) == data[bodyEnd...] else { throw .damaged }
        r.end = bodyEnd

        let target: Target
        switch try r.get() as UInt8 {
        case 0: target = .startupDisk
        case 1: target = .folder(path: try r.string())
        default: throw .damaged
        }
        let startedAt: UInt32 = try r.get()
        let access: UInt8 = try r.get()
        guard access <= 1 else { throw .damaged }
        var baseline: ChangeBaseline?
        switch try r.get() as UInt8 {
        case 0: break
        case 1:
            let eventID: UInt64 = try r.get()
            let count = try r.count()
            var uuids: [Int32: String] = [:]
            for _ in 0..<count { uuids[try r.get()] = try r.string() }
            baseline = ChangeBaseline(eventID: eventID, deviceUUIDs: uuids)
        default: throw .damaged
        }
        let rootPath = try r.string()
        let parents: ContiguousArray<Int32> = try r.array()
        let firstChildren: ContiguousArray<Int32> = try r.array()
        let nextSiblings: ContiguousArray<Int32> = try r.array()
        let sizes: ContiguousArray<UInt64> = try r.array()
        let kindBytes: ContiguousArray<UInt8> = try r.array()
        let flagBytes: ContiguousArray<UInt8> = try r.array()
        let nameBytes: ContiguousArray<UInt8> = try r.array()
        let nameEnds: ContiguousArray<UInt32> = try r.array()
        let categories: ContiguousArray<UInt8> = try r.array()
        let lastUsed: ContiguousArray<UInt32> = try r.array()
        let dirSlots: ContiguousArray<Int32> = try r.array()
        let categoryBytes: ContiguousArray<UInt64> = try r.array()
        let inodes: ContiguousArray<UInt64> = try r.array()
        let dirDevices: ContiguousArray<Int32> = try r.array()
        var kinds = ContiguousArray<NodeKind>()
        kinds.reserveCapacity(kindBytes.count)
        for raw in kindBytes {
            guard let kind = NodeKind(rawValue: raw) else { throw .damaged }
            kinds.append(kind)
        }
        let tree = FileTree.Storage(
            rootPath: rootPath, parents: parents, firstChildren: firstChildren, nextSiblings: nextSiblings,
            sizes: sizes, kinds: kinds, flags: ContiguousArray(flagBytes.map { NodeFlags(rawValue: $0) }),
            nameBytes: nameBytes, nameEnds: nameEnds, categories: categories, lastUsed: lastUsed, dirSlots: dirSlots,
            categoryBytes: categoryBytes, inodes: inodes, dirDevices: dirDevices)
        guard tree.isConsistent else { throw .damaged }

        let nodes = tree.count
        func node(_ id: NodeID) -> Bool { id >= 0 && Int(id) < nodes }
        var hardLinks: [HardLink] = []
        for _ in 0..<(try r.count()) {
            let device: Int32 = try r.get()
            let inode: UInt64 = try r.get()
            let links = Array(try r.array() as ContiguousArray<NodeID>)
            let counted: NodeID = try r.get()
            guard !links.isEmpty, links.allSatisfy({ node($0) && tree.kinds[Int($0)] != .directory }),
                  counted == -1 || links.contains(counted) else { throw .damaged }
            hardLinks.append(HardLink(device: device, inode: inode, links: links, counted: counted == -1 ? nil : counted))
        }
        let installers = Array(try r.array() as ContiguousArray<NodeID>)
        let unverified = Array(try r.array() as ContiguousArray<NodeID>)
        let devices = Array(try r.array() as ContiguousArray<Int32>)
        guard installers.allSatisfy(node), unverified.allSatisfy(node), r.offset == r.end else { throw .damaged }

        self.init(target: target, startedAt: startedAt, hadFullDiskAccess: access == 1, baseline: baseline,
                  tree: tree, hardLinks: hardLinks, installerIDs: installers, unverifiedDirectories: unverified,
                  scanDevices: devices)
    }
}

extension FileTree.Storage {
    /// Whether a `FileTree` built from these arrays is sound: every per-node array has one entry per
    /// node; the root is node 0, a directory with slot 0; every other node's parent comes before it
    /// and is a directory; child lists only link a parent's own children, in strictly decreasing IDs
    /// (as `addChild` builds them), so walking them always ends; names tile the arena; kinds and
    /// slots agree (directories own distinct slots, nothing else has one); per-slot tables have one
    /// row per slot; categories are known.
    var isConsistent: Bool {
        let n = parents.count
        guard n >= 1, n < Int(Int32.max),
              [firstChildren.count, nextSiblings.count, sizes.count, kinds.count, flags.count, nameEnds.count,
               categories.count, lastUsed.count, dirSlots.count, inodes.count].allSatisfy({ $0 == n })
        else { return false }
        let slots = dirDevices.count
        let categoryCount = FileCategory.allCases.count
        guard categoryBytes.count == slots * categoryCount, parents[0] == -1, kinds[0] == .directory,
              dirSlots[0] == 0 else { return false }
        var slotSeen = [Bool](repeating: false, count: slots)
        var previousEnd: UInt32 = 0
        for i in 0..<n {
            let parent = parents[i]
            if i > 0 {
                guard parent >= 0, Int(parent) < i, kinds[Int(parent)] == .directory else { return false }
            }
            let first = firstChildren[i]
            guard first == -1 || (Int(first) > i && Int(first) < n && parents[Int(first)] == Int32(i)) else { return false }
            let next = nextSiblings[i]
            guard next == -1 || (i > 0 && next > 0 && Int(next) < i && parents[Int(next)] == parent) else { return false }
            guard nameEnds[i] >= previousEnd else { return false }
            previousEnd = nameEnds[i]
            guard Int(categories[i]) < categoryCount else { return false }
            let slot = dirSlots[i]
            if kinds[i] == .directory {
                guard slot >= 0, Int(slot) < slots, !slotSeen[Int(slot)] else { return false }
                slotSeen[Int(slot)] = true
            } else {
                guard slot == -1 else { return false }
            }
        }
        return Int(previousEnd) == nameBytes.count && slotSeen.allSatisfy { $0 }
    }
}

/// Appends little-endian values.
private struct Writer {
    var data = Data()

    mutating func put<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func put(_ string: String) {
        let bytes = Array(string.utf8)
        put(UInt64(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func put<T: FixedWidthInteger>(_ array: ContiguousArray<T>) {
        put(UInt64(array.count))
        if T.self == UInt8.self || (1 as T).littleEndian == 1 {   // little-endian host: raw bytes as they are
            array.withUnsafeBytes { data.append(contentsOf: $0) }
        } else {
            for value in array { put(value) }
        }
    }
}

/// Reads what `Writer` wrote, never past `end`.
private struct Reader {
    let data: Data
    var offset: Data.Index
    var end: Data.Index

    init(data: Data, end: Int) {
        self.data = data
        offset = data.startIndex
        self.end = data.startIndex + end
    }

    mutating func bytes(_ count: Int) throws(SavedScanError) -> Data {
        guard count >= 0, end - offset >= count else { throw .damaged }
        defer { offset += count }
        return data[offset..<(offset + count)]
    }

    mutating func get<T: FixedWidthInteger>() throws(SavedScanError) -> T {
        let raw = try bytes(MemoryLayout<T>.size)
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { $0.copyBytes(from: raw) }
        return T(littleEndian: value)
    }

    /// An element count, which must fit in what is left.
    mutating func count() throws(SavedScanError) -> Int {
        let raw: UInt64 = try get()
        guard raw <= UInt64(end - offset) else { throw .damaged }
        return Int(raw)
    }

    mutating func string() throws(SavedScanError) -> String {
        String(decoding: try bytes(try count()), as: UTF8.self)
    }

    mutating func array<T: FixedWidthInteger>() throws(SavedScanError) -> ContiguousArray<T> {
        let count = try count()
        let raw = try bytes(count * MemoryLayout<T>.size)
        var array = ContiguousArray<T>(repeating: 0, count: count)
        array.withUnsafeMutableBytes { $0.copyBytes(from: raw) }
        if (1 as T).littleEndian != 1 {
            for i in array.indices { array[i] = T(littleEndian: array[i]) }
        }
        return array
    }
}
