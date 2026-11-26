import Darwin
import Foundation

/// The files open right now through a file descriptor of a process this user can inspect, as
/// reported by libproc. It does not see mapped executables or libraries, working directories, or
/// processes of other users (root daemons, setuid helpers), which may not be inspected. It never
/// reports a file that is not open.
///
/// `isComplete` is false when a process this user owns might have an open file the set does not
/// hold: the process list could not be read in full, or one of this user's processes could not be
/// examined (its owner or its descriptor list could not be read, other than because it exited) or
/// its descriptor list was still truncated after the retries. Then callers must not treat the set as
/// authoritative (`ScanStore.trash` skips everything as `.cannotCheckOpenFiles`). Benign, and still
/// complete: a process that exited meanwhile; another user's process; a descriptor closed meanwhile
/// (`EBADF`); a descriptor whose file this process may not examine (`EPERM`/`EACCES`, as for files
/// in Apple's protected data folders, seen on own-user system agents in normal use; such files are
/// in folders the scan cannot list either, which are then unverified).
///
/// Paths are compared in NFC, byte by byte. The root-level symbolic links `/var`, `/tmp` and
/// `/etc` are mapped to `/private/…` (the kernel's form) on both sides, so either spelling matches.
public struct OpenFileSet: Sendable {
    /// Unique canonical paths, sorted by their UTF-8 bytes.
    private let paths: [String]
    /// Whether every process of this user was listed in full (see the type's documentation).
    public let isComplete: Bool

    /// A complete set holding exactly `paths`.
    public init(paths: [String]) {
        self.init(paths: paths, isComplete: true)
    }

    init(paths: [String], isComplete: Bool) {
        self.paths = Set(paths.map(Self.canonical)).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        self.isComplete = isComplete
    }

    /// What examining one process found.
    enum Inspection: Sendable, Equatable {
        /// It exited meanwhile (`ESRCH`).
        case gone
        /// Its effective user is not this one: it may not be inspected, and is skipped.
        case otherUser
        /// This user's, but its owner or its descriptors could not be read, for `errno`.
        case failed(errno: Int32)
        /// This user's: the paths of its vnode descriptors; `truncated` when the descriptor list
        /// was still full after the retries, so it may hold more.
        case listed(paths: [String], truncated: Bool)
    }

    /// Snapshot of every vnode file descriptor of every process this user may inspect.
    public static func current() -> OpenFileSet {
        guard let pids = allPIDs() else { return OpenFileSet(paths: [], isComplete: false) }
        var fds = DescriptorBuffer()
        let user = geteuid()
        return collect(pids: pids) { inspect($0, user: user, fds: &fds) }
    }

    /// The set built from `inspect` of each pid (pid 0, the kernel, is never inspected): complete
    /// unless a process is `.failed` or `.listed` truncated.
    static func collect(pids: [pid_t], inspect: (pid_t) -> Inspection) -> OpenFileSet {
        var found = Set<String>()
        var complete = true
        for pid in pids where pid > 0 {
            switch inspect(pid) {
            case .gone, .otherUser:
                continue
            case .failed:
                complete = false
            case let .listed(paths, truncated):
                found.formUnion(paths)
                if truncated { complete = false }
            }
        }
        return OpenFileSet(paths: Array(found), isComplete: complete)
    }

    /// Every process's inspection, as `current` sees them, for diagnostics; nil when the process
    /// list cannot be read in full.
    static func inspectAll() -> [(pid: pid_t, inspection: Inspection)]? {
        guard let pids = allPIDs() else { return nil }
        var fds = DescriptorBuffer()
        let user = geteuid()
        return pids.filter { $0 > 0 }.map { ($0, inspect($0, user: user, fds: &fds)) }
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

    /// Examines `pid`: its effective user (`PROC_PIDT_SHORTBSDINFO`, readable for any process),
    /// then, when it is `user`, the paths of its vnode descriptors.
    private static func inspect(_ pid: pid_t, user: uid_t, fds: inout DescriptorBuffer) -> Inspection {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        errno = 0
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else {
            return failure(errno)
        }
        guard info.pbsi_uid == user else { return .otherUser }
        let listed: (descriptors: ArraySlice<proc_fdinfo>, truncated: Bool)
        switch fds.descriptors(of: pid) {
        case let .failure(error): return failure(error.code)
        case let .success(value): listed = value
        }
        var paths: [String] = []
        for fd in listed.descriptors where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            switch vnodePath(pid: pid, fd: fd.proc_fd) {
            case .path(let path): paths.append(path)
            case .skipped: continue
            case .gone: return .gone
            case .failed(let code): return .failed(errno: code)
            }
        }
        return .listed(paths: paths, truncated: listed.truncated)
    }

    /// `.gone` for `ESRCH` (the process exited), else `.failed`.
    private static func failure(_ code: Int32) -> Inspection {
        code == ESRCH ? .gone : .failed(errno: code)
    }

    /// A libproc call's `errno`.
    private struct ProcError: Error {
        let code: Int32
    }

    /// Reusable buffer for `PROC_PIDLISTFDS`, grown on demand.
    private struct DescriptorBuffer {
        private var storage: [proc_fdinfo] = []

        /// The pid's descriptors, and whether the table was still full after the retries (then the
        /// ones read are valid, but there may be more); the `errno` when they cannot be read.
        mutating func descriptors(of pid: pid_t) -> Result<(descriptors: ArraySlice<proc_fdinfo>, truncated: Bool), ProcError> {
            let stride = MemoryLayout<proc_fdinfo>.stride
            errno = 0
            let needed = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0))
            guard needed > 0 else { return .failure(ProcError(code: errno)) }
            var capacity = needed / stride + 32
            for attempt in 0..<4 {
                if storage.count < capacity {
                    storage = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
                }
                errno = 0
                let bytes = Int(storage.withUnsafeMutableBytes {
                    proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
                })
                guard bytes > 0 else { return .failure(ProcError(code: errno)) }
                let count = min(bytes / stride, storage.count)
                if count < storage.count || attempt == 3 {
                    return .success((storage.prefix(count), count >= storage.count))
                }
                capacity = storage.count * 2
            }
            return .failure(ProcError(code: EOVERFLOW))   // not reached: the last attempt returns
        }
    }

    /// What reading one descriptor's path gave.
    private enum PathRead {
        case path(String)
        /// Benign: closed meanwhile (`EBADF`), a file this process may not examine (`EPERM`,
        /// `EACCES`), or a vnode with no path.
        case skipped
        /// The process exited (`ESRCH`).
        case gone
        case failed(Int32)
    }

    private static func vnodePath(pid: pid_t, fd: Int32) -> PathRead {
        var info = vnode_fdinfowithpath()
        let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        errno = 0
        let read = proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size)
        guard read == size else {
            switch errno {
            case EBADF, EPERM, EACCES: return .skipped
            case ESRCH: return .gone
            case 0: return .failed(EIO)   // a short read
            case let code: return .failed(code)
            }
        }
        return withUnsafeBytes(of: &info.pvip.vip_path) { raw -> PathRead in
            let bytes = raw.prefix(while: { $0 != 0 })
            if bytes.isEmpty { return .skipped }
            // No NUL inside the buffer: the path was cut.
            guard bytes.count < raw.count else { return .failed(ENAMETOOLONG) }
            return .path(String(decoding: bytes, as: UTF8.self))
        }
    }
}
