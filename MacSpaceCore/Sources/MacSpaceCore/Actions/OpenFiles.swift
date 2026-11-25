import Darwin
import Foundation

/// The files open right now through a file descriptor of a process this user can inspect, as
/// reported by libproc. It does not see mapped executables or libraries, working directories,
/// or processes of other users it may not inspect; descriptors that cannot be read (races with
/// exits, permissions) are skipped silently. It never reports a file that is not open.
///
/// `isComplete` is false when the process list itself could not be read in full: then a path
/// not in the set may still be open, and callers must not treat the set as authoritative.
///
/// Paths are compared in NFC, byte by byte. The root-level symbolic links `/var`, `/tmp` and
/// `/etc` are mapped to `/private/…` (the kernel's form) on both sides, so either spelling matches.
public struct OpenFileSet: Sendable {
    /// Unique canonical paths, sorted by their UTF-8 bytes.
    private let paths: [String]
    /// Whether every process could be listed (see the type's documentation).
    public let isComplete: Bool

    /// A complete set holding exactly `paths`.
    public init(paths: [String]) {
        self.init(paths: paths, isComplete: true)
    }

    init(paths: [String], isComplete: Bool) {
        self.paths = Set(paths.map(Self.canonical)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        self.isComplete = isComplete
    }

    /// Snapshot of every vnode file descriptor of every process this user may inspect.
    public static func current() -> OpenFileSet {
        var found = Set<String>()
        var fds = DescriptorBuffer()
        guard let pids = allPIDs() else { return OpenFileSet(paths: [], isComplete: false) }
        for pid in pids where pid > 0 {
            for fd in fds.vnodeDescriptors(of: pid) {
                if let path = vnodePath(pid: pid, fd: fd) { found.insert(path) }
            }
        }
        return OpenFileSet(paths: Array(found), isComplete: true)
    }

    /// Whether the file at exactly `path` is open.
    public func isOpen(_ path: String) -> Bool {
        let key = Self.canonical(path)
        let index = lowerBound(key)
        return index < paths.count && paths[index].utf8.elementsEqual(key.utf8)
    }

    /// Whether any open file lies anywhere inside `directory` (the directory itself excluded).
    /// Paths with a common byte prefix are contiguous in the sorted list, so the first path
    /// at or after `directory + "/"` decides.
    public func hasOpen(under directory: String) -> Bool {
        let base = Self.canonical(directory)
        let prefix = base.utf8.last == UInt8(ascii: "/") ? base : base + "/"
        let index = lowerBound(prefix)
        return index < paths.count && paths[index].utf8.starts(with: prefix.utf8)
    }

    /// First index whose path is ≥ `key` (UTF-8 byte order).
    private func lowerBound(_ key: String) -> Int {
        var low = 0, high = paths.count
        while low < high {
            let mid = (low + high) / 2
            if paths[mid].utf8.lexicographicallyPrecedes(key.utf8) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static let privateAliases = ["/var", "/tmp", "/etc"]

    /// NFC, with the `/private` aliases expanded. Prefix tests are byte-wise, not by grapheme.
    static func canonical(_ path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        let bytes = normalized.utf8
        for alias in privateAliases where bytes.starts(with: alias.utf8) {
            let rest = bytes.dropFirst(alias.utf8.count)
            if rest.isEmpty || rest.first == UInt8(ascii: "/") { return "/private" + normalized }
        }
        return normalized
    }

    // MARK: - libproc

    /// Every pid, or nil when the list cannot be read in full (call failed, or the buffer was
    /// still full after the retries, so the list may be truncated).
    private static func allPIDs() -> [pid_t]? {
        let estimate = Int(proc_listallpids(nil, 0))
        guard estimate > 0 else { return nil }
        var capacity = estimate + 64
        for _ in 0..<4 {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = Int(pids.withUnsafeMutableBytes {
                proc_listallpids($0.baseAddress, Int32($0.count))
            })
            guard count > 0 else { return nil }
            if count < capacity { return Array(pids.prefix(count)) }
            capacity = count * 2
        }
        return nil
    }

    /// Reusable buffer for `PROC_PIDLISTFDS`, grown on demand.
    private struct DescriptorBuffer {
        private var storage: [proc_fdinfo] = []

        /// The pid's vnode descriptors; [] when it cannot be inspected. If the table is still
        /// full after the retries, the descriptors read so far are returned (all are valid).
        mutating func vnodeDescriptors(of pid: pid_t) -> [Int32] {
            let stride = MemoryLayout<proc_fdinfo>.stride
            let needed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
            guard needed > 0 else { return [] }
            var capacity = needed / stride + 32
            for attempt in 0..<4 {
                if storage.count < capacity {
                    storage = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
                }
                let bytes = Int(storage.withUnsafeMutableBytes {
                    proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
                })
                guard bytes > 0 else { return [] }
                let count = min(bytes / stride, storage.count)
                if count < storage.count || attempt == 3 {
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
