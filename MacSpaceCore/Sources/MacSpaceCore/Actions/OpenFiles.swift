import Darwin

/// The files open in any process right now, as reported by libproc. Processes or descriptors
/// that cannot be inspected (other users' processes without privileges, races with exits)
/// are skipped silently, so the set may be incomplete but never reports a file that is not open.
///
/// Paths are kept in the kernel's form; the root-level symbolic links `/var`, `/tmp` and `/etc`
/// are mapped to `/private/…` on both sides, so either spelling matches.
public struct OpenFileSet: Sendable {
    /// Sorted, unique, canonical paths.
    private let paths: [String]

    public init(paths: [String]) {
        self.paths = Array(Set(paths.map(Self.canonical))).sorted()
    }

    /// Snapshot of every vnode file descriptor of every process this user may inspect.
    public static func current() -> OpenFileSet {
        var found = Set<String>()
        var fds = DescriptorBuffer()
        for pid in allPIDs() where pid > 0 {
            for fd in fds.vnodeDescriptors(of: pid) {
                if let path = vnodePath(pid: pid, fd: fd) { found.insert(path) }
            }
        }
        return OpenFileSet(paths: Array(found))
    }

    /// Whether the file at exactly `path` is open.
    public func isOpen(_ path: String) -> Bool {
        let key = Self.canonical(path)
        let index = lowerBound(key)
        return index < paths.count && paths[index] == key
    }

    /// Whether any open file lies anywhere inside `directory` (the directory itself excluded).
    public func hasOpen(under directory: String) -> Bool {
        let base = Self.canonical(directory)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        let index = lowerBound(prefix)
        return index < paths.count && paths[index].hasPrefix(prefix)
    }

    /// First index whose path is ≥ `key`.
    private func lowerBound(_ key: String) -> Int {
        var low = 0, high = paths.count
        while low < high {
            let mid = (low + high) / 2
            if paths[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static let privateAliases = ["/var", "/tmp", "/etc"]

    static func canonical(_ path: String) -> String {
        for alias in privateAliases where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    // MARK: - libproc

    private static func allPIDs() -> [pid_t] {
        var capacity = Int(proc_listallpids(nil, 0)) + 64
        for _ in 0..<4 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = Int(pids.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            })
            guard count >= 0 else { return [] }
            if count < capacity { return Array(pids.prefix(count)) }
            capacity = count * 2
        }
        return []
    }

    /// Reusable buffer for `PROC_PIDLISTFDS`, grown on demand.
    private struct DescriptorBuffer {
        private var storage: [proc_fdinfo] = []

        mutating func vnodeDescriptors(of pid: pid_t) -> [Int32] {
            let stride = MemoryLayout<proc_fdinfo>.stride
            let needed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
            guard needed > 0 else { return [] }
            var capacity = needed / stride + 32
            for _ in 0..<4 {
                if storage.count < capacity {
                    storage = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
                }
                let bytes = Int(storage.withUnsafeMutableBytes {
                    proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
                })
                guard bytes > 0 else { return [] }
                let count = bytes / stride
                if count < storage.count {
                    return storage.prefix(count)
                        .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) }
                        .map(\.proc_fd)
                }
                capacity = storage.count * 2
            }
            return []
        }
    }

    private static func vnodePath(pid: pid_t, fd: Int32) -> String? {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String? in
            let bytes = raw.prefix(while: { $0 != 0 })
            guard !bytes.isEmpty, bytes.count < raw.count else { return nil }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
