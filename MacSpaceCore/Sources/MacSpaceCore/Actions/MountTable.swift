import Darwin

/// The volumes mounted right now, as `getfsstat(2)` reports them.
enum MountTable {
    /// Every current mount-on path (`f_mntonname`), or nil when the table cannot be read in full.
    static func current() -> [String]? {
        let estimate = Int(getfsstat(nil, 0, MNT_NOWAIT))
        guard estimate > 0 else { return nil }
        var capacity = estimate + 8
        for _ in 0..<4 {
            // Raw storage: `statfs` names both the struct and a function, so `[statfs]` does not parse.
            let stride = MemoryLayout<Darwin.statfs>.stride
            let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity * stride,
                                                       alignment: MemoryLayout<Darwin.statfs>.alignment)
            defer { raw.deallocate() }
            raw.initializeMemory(as: UInt8.self, repeating: 0, count: capacity * stride)
            let entries = raw.bindMemory(to: Darwin.statfs.self, capacity: capacity)
            let count = Int(getfsstat(entries, Int32(capacity * stride), MNT_NOWAIT))
            guard count > 0 else { return nil }
            // A full buffer may mean more mounts than room: retry larger.
            if count < capacity {
                return (0..<count).map { i in
                    withUnsafeBytes(of: entries[i].f_mntonname) { bytes in
                        String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
                    }
                }
            }
            capacity *= 2
        }
        return nil
    }

    /// `mounts` in `OpenFileSet`'s canonical form (NFC, `/var` `/tmp` `/etc` under `/private`),
    /// trailing slashes removed, `/` left out; a mount below `/System/Volumes/Data` is also listed
    /// at its firmlinked path (`/System/Volumes/Data/Users/u/mnt` as `/Users/u/mnt`).
    static func canonical(_ mounts: [String]) -> [String] {
        let dataVolume = "/System/Volumes/Data/"
        var result: [String] = []
        for mount in mounts {
            let key = OpenFileSet.canonical(SafetyTables.normalized(mount))
            guard key != "/", !key.isEmpty else { continue }
            result.append(key)
            if key.utf8.starts(with: dataVolume.utf8) {
                result.append(OpenFileSet.canonical(String(decoding: key.utf8.dropFirst(dataVolume.utf8.count - 1),
                                                           as: UTF8.self)))
            }
        }
        return result
    }

    /// Whether a canonical mount in `mounts` is at `path` or below it (byte-wise, by component).
    static func hasMount(atOrBelow path: String, in mounts: [String]) -> Bool {
        let key = OpenFileSet.canonical(SafetyTables.normalized(path))
        let prefix = key + "/"
        return mounts.contains { $0.utf8.elementsEqual(key.utf8) || $0.utf8.starts(with: prefix.utf8) }
    }
}
