import Darwin

/// A directory's entries, and whether they are all of them.
public struct DirectoryListing: Sendable, Equatable {
    public var entries: [DirectoryEntry]
    /// False when an entry was left out (the file system reported an error for it, or its record
    /// was malformed) or reading stopped early because the task was cancelled: the directory may
    /// hold more than `entries`.
    public var isComplete: Bool

    public init(entries: [DirectoryEntry], isComplete: Bool) {
        self.entries = entries
        self.isComplete = isComplete
    }
}

/// Reads directory entries with `getattrlistbulk(2)`: one system call returns many entries
/// together with the attributes the scanner needs, and symbolic links are never followed.
public enum DirectoryReader {
    static let bulkBufferSize = 256 * 1024

    /// Lists the entries of the directory at `path` ("." and ".." are never reported).
    /// The listing is complete only when every entry the file system returned was parsed: an entry
    /// it reports a per-entry error for, or a malformed record, is left out (parsing goes on with the
    /// next record) and makes `isComplete` false; so does a record length of 0 or past the buffer,
    /// which ends its batch, since the records after it cannot be located (`parseBatch`).
    /// When the calling task is cancelled, reading stops between batches and the listing so far
    /// is returned, incomplete, without throwing.
    /// With `includePrivateSize`, each entry also carries `privateSize` where the volume reports
    /// it; the scanner leaves it off, so its request stays exactly as without the option.
    public static func read(
        path: String, includePrivateSize: Bool = false
    ) throws(DirectoryReadError) -> DirectoryListing {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DirectoryReadError(errno: errno) }
        defer { close(fd) }

        var request = attributeRequest(includeError: true, includePrivateSize: includePrivateSize)
        let options = includePrivateSize ? UInt64(FSOPT_ATTR_CMN_EXTENDED) : 0
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bulkBufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var listing = DirectoryListing(entries: [], isComplete: true)
        while true {
            if Task.isCancelled {
                listing.isComplete = false
                break
            }
            let count = getattrlistbulk(fd, &request, buffer, bulkBufferSize, options)
            if count < 0 {
                if errno == EINTR { continue }
                throw DirectoryReadError(errno: errno)
            }
            if count == 0 { break }
            let batch = parseBatch(UnsafeRawBufferPointer(start: buffer, count: bulkBufferSize), count: Int(count))
            listing.entries += batch.entries
            if !batch.complete { listing.isComplete = false }
        }
        return listing
    }

    /// Parses the `count` packed records `getattrlistbulk` wrote at the start of `buffer`.
    /// `complete` is false when any record was left out: one reporting an error or malformed
    /// (`parseRecord` → nil), or one whose length is 0 or runs past `buffer`, which also ends the
    /// batch (the records after it cannot be located), so fewer than `count` were parsed.
    static func parseBatch(_ buffer: UnsafeRawBufferPointer, count: Int) -> (entries: [DirectoryEntry], complete: Bool) {
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(count)
        var complete = true
        var offset = 0
        for _ in 0..<max(0, count) {
            guard offset + MemoryLayout<UInt32>.size <= buffer.count else {
                complete = false
                break
            }
            let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            guard length > 0, length <= buffer.count - offset else {
                complete = false
                break
            }
            if let entry = parseRecord(UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + length)])) {
                entries.append(entry)
            } else {
                complete = false
            }
            offset += length
        }
        return (entries, complete)
    }

    /// Describes the object at `path` itself (a trailing symbolic link is not followed).
    /// For a mount point this reports the mounted volume's root, so `device` is that volume's.
    /// `includePrivateSize` works as in `read(path:includePrivateSize:)`.
    public static func stat(
        path: String, includePrivateSize: Bool = false
    ) throws(DirectoryReadError) -> DirectoryEntry {
        var request = attributeRequest(includeError: false, includePrivateSize: includePrivateSize)
        let options = UInt32(FSOPT_NOFOLLOW) | (includePrivateSize ? UInt32(FSOPT_ATTR_CMN_EXTENDED) : 0)
        // Room for the fixed attributes plus the longest possible name (255 UTF-16 units as UTF-8).
        let size = 4096
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        guard getattrlist(path, &request, buffer, size, options) == 0 else {
            throw DirectoryReadError(errno: errno)
        }
        let length = min(Int(buffer.loadUnaligned(as: UInt32.self)), size)
        guard let entry = parseRecord(UnsafeRawBufferPointer(start: buffer, count: length)) else {
            throw .other(EIO)
        }
        return entry
    }

    // MARK: - Attribute buffer

    private static let commonAttributes: attrgroup_t =
        attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_DEVID)
        | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_ACCTIME)
        | attrgroup_t(ATTR_CMN_FLAGS) | attrgroup_t(ATTR_CMN_FILEID)

    /// `includePrivateSize` adds `ATTR_CMNEXT_PRIVATESIZE` to `forkattr`, which the call must
    /// reinterpret as extended common attributes (`FSOPT_ATTR_CMN_EXTENDED`).
    private static func attributeRequest(includeError: Bool, includePrivateSize: Bool) -> attrlist {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        // ATTR_CMN_ERROR is only valid for getattrlistbulk.
        request.commonattr = commonAttributes | (includeError ? attrgroup_t(ATTR_CMN_ERROR) : 0)
        request.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        request.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        if includePrivateSize { request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) }
        return request
    }

    /// Parses one packed record: `UInt32` length, `attribute_set_t` of returned attributes, then
    /// `ATTR_CMN_ERROR` (when returned), then each returned attribute in bit order — common, dir,
    /// file, then extended common (`forkattr`, only ever requested as such) — each starting on a
    /// 4-byte boundary. Attributes not in the returned set are absent.
    /// Returns nil for records that report an error or are malformed (`read` then marks its
    /// listing incomplete).
    static func parseRecord(_ record: UnsafeRawBufferPointer) -> DirectoryEntry? {
        var cursor = Cursor(record: record, offset: MemoryLayout<UInt32>.size)
        guard let returned = cursor.read(attribute_set_t.self) else { return nil }
        let common = returned.commonattr

        if common & attrgroup_t(ATTR_CMN_ERROR) != 0 {
            guard let error = cursor.read(UInt32.self), error == 0 else { return nil }
        }

        // attr_dataoffset is relative to the attrreference_t itself.
        let nameRefOffset = cursor.offset
        guard common & attrgroup_t(ATTR_CMN_NAME) != 0,
              let nameRef = cursor.read(attrreference_t.self),
              let name = decodeName(record, at: nameRefOffset + Int(nameRef.attr_dataoffset),
                                    length: Int(nameRef.attr_length))
        else { return nil }

        var device: Int32 = 0
        if common & attrgroup_t(ATTR_CMN_DEVID) != 0 {
            guard let value = cursor.read(dev_t.self) else { return nil }
            device = value
        }
        var objectType: fsobj_type_t?
        if common & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
            guard let value = cursor.read(fsobj_type_t.self) else { return nil }
            objectType = value
        }
        var modificationTime: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
            guard let value = cursor.read(timespec.self) else { return nil }
            modificationTime = clampedSeconds(value)
        }
        var accessTime: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_ACCTIME) != 0 {
            guard let value = cursor.read(timespec.self) else { return nil }
            accessTime = clampedSeconds(value)
        }
        var flags: UInt32 = 0
        if common & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
            guard let value = cursor.read(UInt32.self) else { return nil }
            flags = value
        }
        var inode: UInt64 = 0
        if common & attrgroup_t(ATTR_CMN_FILEID) != 0 {
            guard let value = cursor.read(UInt64.self) else { return nil }
            inode = value
        }

        var mountStatus: UInt32 = 0
        if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
            guard let value = cursor.read(UInt32.self) else { return nil }
            mountStatus = value
        }

        var linkCount: UInt32 = 1
        if returned.fileattr & attrgroup_t(ATTR_FILE_LINKCOUNT) != 0 {
            guard let value = cursor.read(UInt32.self) else { return nil }
            linkCount = value
        }
        var allocatedSize: UInt64 = 0
        if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
            guard let value = cursor.read(off_t.self) else { return nil }
            allocatedSize = UInt64(clamping: value)
        }

        var privateSize: UInt64?
        if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
            guard let value = cursor.read(off_t.self) else { return nil }
            privateSize = UInt64(clamping: value)
        }

        let kind = nodeKind(objectType)
        return DirectoryEntry(
            name: name,
            kind: kind,
            allocatedSize: kind == .directory ? 0 : allocatedSize,
            device: device,
            inode: inode,
            linkCount: linkCount,
            isMountPoint: mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT) != 0,
            isDataless: flags & UInt32(SF_DATALESS) != 0,
            modificationTime: modificationTime,
            accessTime: accessTime,
            privateSize: privateSize
        )
    }

    private static func clampedSeconds(_ time: timespec) -> UInt32 {
        UInt32(clamping: max(0, time.tv_sec))
    }

    /// `attr_length` counts the trailing NUL; the bytes must lie entirely inside the record.
    private static func decodeName(_ record: UnsafeRawBufferPointer, at offset: Int, length: Int) -> String? {
        guard length > 0, offset >= 0, offset + length <= record.count else { return nil }
        var bytes = UnsafeRawBufferPointer(rebasing: record[offset..<(offset + length)])
        if let nul = bytes.firstIndex(of: 0) {
            bytes = UnsafeRawBufferPointer(rebasing: bytes[..<nul])
        }
        guard !bytes.isEmpty else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func nodeKind(_ type: fsobj_type_t?) -> NodeKind {
        switch type {
        case fsobj_type_t(VREG.rawValue): .file
        case fsobj_type_t(VDIR.rawValue): .directory
        case fsobj_type_t(VLNK.rawValue): .symlink
        default: .other
        }
    }

    /// Sequential reader over a packed attribute record; each attribute occupies its size
    /// rounded up to 4 bytes. Loads are unaligned-safe (64-bit values are only 4-byte aligned).
    private struct Cursor {
        let record: UnsafeRawBufferPointer
        var offset: Int

        mutating func read<T>(_: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= record.count else { return nil }
            let value = record.loadUnaligned(fromByteOffset: offset, as: T.self)
            offset += (size + 3) & ~3
            return value
        }
    }
}
