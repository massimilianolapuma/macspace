import Darwin
import Foundation

/// The files open right now through a file descriptor of a process this user can inspect, as
/// reported by libproc. It does not see mapped executables or libraries, working directories, or
/// processes of other users (root daemons, setuid helpers), which may not be inspected. It never
/// reports a file that is not open.
///
/// `isComplete` is false exactly when one of these happened, so a file this user's processes hold
/// open may be missing from the set:
/// - the process list could not be read in full;
/// - a process's owner could not be read, for a reason other than the process having exited;
/// - a process of this user's descriptor list could not be read, for a reason other than the
///   process having exited (a list of zero descriptors is a complete, empty list);
/// - a process of this user's descriptor list was still truncated after the retries.
/// Then callers must not treat the set as authoritative (`ScanStore.trash` skips everything as
/// `.cannotCheckOpenFiles`). Anything else keeps it complete: a process that exited meanwhile, or
/// another user's process (skipped).
///
/// Residual (documented): a descriptor whose path cannot be read, for whatever reason (any errno —
/// closed meanwhile, a revoked terminal or dead vnode, a file this process may not examine, as on
/// Apple's own agents in normal use — a short read, an empty path, a path with no NUL), is skipped:
/// its file is not seen as open. Such files are assumed to sit in folders the scan cannot list
/// either (a per-entry error makes a listing incomplete, so its folder is unverified), or to no
/// longer name a file at all; that is reasoned, not proven for every case. Per-descriptor reasons
/// are an open set, and counting any of them as incomplete would block every move.
///
/// Each open file also records who holds it (`OpenFileHolder`, see `holder(of:record:)`), named
/// while the processes are inspected; `use(of:isDirectory:)` answers both whether and by whom.
///
/// Paths are compared in NFC, byte by byte. The root-level symbolic links `/var`, `/tmp` and
/// `/etc` are mapped to `/private/…` (the kernel's form) on both sides, so either spelling matches.
public struct OpenFileSet: Sendable {
    /// Unique canonical paths, sorted by their UTF-8 bytes.
    private let paths: [String]
    /// Who holds each of `paths` open (same index); empty when no holder could be named.
    private let holders: [Set<OpenFileHolder>]
    /// Whether every process of this user was listed in full (see the type's documentation).
    public let isComplete: Bool

    /// A complete set holding exactly `paths`, with no holders named.
    public init(paths: [String]) {
        self.init(paths: paths, isComplete: true)
    }

    init(paths: [String], isComplete: Bool) {
        self.init(held: Dictionary(paths.map { ($0, Set<OpenFileHolder>()) }, uniquingKeysWith: { $0.union($1) }),
                  isComplete: isComplete)
    }

    /// Each open path with its holders; paths equal once canonical are merged.
    init(held: [String: Set<OpenFileHolder>], isComplete: Bool) {
        var merged: [String: Set<OpenFileHolder>] = [:]
        for (path, who) in held { merged[Self.canonical(path), default: []].formUnion(who) }
        let sorted = merged.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        paths = sorted.map(\.key)
        holders = sorted.map(\.value)
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
    /// `excludingOwnProcess` leaves this process out: MacSpace only reads what it scans (folder
    /// listings, size estimates), and those descriptors must not keep an item from moving.
    public static func current(excludingOwnProcess: Bool = false) -> OpenFileSet {
        guard var pids = allPIDs() else { return OpenFileSet(paths: [], isComplete: false) }
        if excludingOwnProcess {
            let own = getpid()
            pids.removeAll { $0 == own }
        }
        var fds = DescriptorBuffer()
        let user = geteuid()
        // Parents are shared (a shell, an app's helpers): each process is read once.
        var records: [pid_t: ProcessRecord?] = [:]
        func record(_ pid: pid_t) -> ProcessRecord? {
            if let known = records[pid] { return known }
            let found = processRecord(pid)
            records[pid] = found
            return found
        }
        return collect(pids: pids, inspect: { inspect($0, user: user, fds: &fds) },
                       holder: { holder(of: $0, record: record) })
    }

    /// The set built from `inspect` of each pid (pid 0, the kernel, is never inspected): complete
    /// unless a process is `.failed` or `.listed` truncated. A pid holding paths is named once by
    /// `holder` (nil: `.unnamed`).
    static func collect(pids: [pid_t], inspect: (pid_t) -> Inspection,
                        holder: (pid_t) -> OpenFileHolder? = { _ in nil }) -> OpenFileSet {
        var found: [String: Set<OpenFileHolder>] = [:]
        var complete = true
        for pid in pids where pid > 0 {
            switch inspect(pid) {
            case .gone, .otherUser:
                continue
            case .failed:
                complete = false
            case let .listed(paths, truncated):
                if truncated { complete = false }
                guard !paths.isEmpty else { continue }
                let who = holder(pid) ?? .unnamed
                for path in paths { found[path, default: []].insert(who) }
            }
        }
        return OpenFileSet(held: found, isComplete: complete)
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

    /// Whether `path` is open, and by whom: the item itself, or for a directory anything inside it
    /// too (`onlyInside` when only the latter). Nil when nothing there is open.
    public func use(of path: String, isDirectory: Bool) -> OpenUse? {
        let key = Self.canonical(path)
        var who = Set<OpenFileHolder>()
        var itself = false
        var inside = false
        let index = lowerBound(key)
        if index < paths.count, paths[index].utf8.elementsEqual(key.utf8) {
            itself = true
            who.formUnion(holders[index])
        }
        if isDirectory {
            let prefix = key.utf8.last == UInt8(ascii: "/") ? key : key + "/"
            var next = lowerBound(prefix)
            while next < paths.count, paths[next].utf8.starts(with: prefix.utf8) {
                inside = true
                who.formUnion(holders[next])
                next += 1
            }
        }
        guard itself || inside else { return nil }
        return OpenUse(holders: who, onlyInside: !itself)
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

    // MARK: - Holders

    /// What naming a holder needs to know of a process.
    struct ProcessRecord: Sendable, Equatable {
        var parent: pid_t
        /// The kernel's short name (`p_comm`, at most 16 bytes); may be empty.
        var name: String
        /// Its executable's path; nil when it cannot be read.
        var executable: String?
    }

    /// Who holds a file open for `pid`, looking at it and then its parents (up to launchd, pid 1,
    /// a parent that cannot be read, 32 steps or a loop):
    /// 1. the first that runs an app's binary (its own, a helper app's, an XPC service's): a shell
    ///    in Terminal is Terminal's, `git` that `xcrun` runs from Xcode for Terminal too;
    /// 2. else the first whose executable is inside an app (a tool the app ships, daemonized: its
    ///    shells too);
    /// 3. else the process itself, by name: its short name, or its executable's file name when
    ///    that name was cut (15 bytes) or is empty.
    /// Nil when `pid` cannot be read or has no name. Apps inside a framework (Python.app) are none.
    static func holder(of pid: pid_t, record: (pid_t) -> ProcessRecord?) -> OpenFileHolder? {
        guard let own = record(pid) else { return nil }
        var chain = [own]
        var seen: Set<pid_t> = [pid]
        while chain.count < 32, let parent = chain.last?.parent, parent > 1, seen.insert(parent).inserted,
              let next = record(parent) {
            chain.append(next)
        }
        for binaryOnly in [true, false] {
            for process in chain {
                if let app = process.executable.flatMap({ appBundle($0, binaryOnly: binaryOnly) }) {
                    return .app(path: app)
                }
            }
        }
        let file = own.executable.map { ($0 as NSString).lastPathComponent } ?? ""
        let cut = own.name.utf8.count >= 15 && file.hasPrefix(own.name)
        let name = own.name.isEmpty || cut ? file : own.name
        return name.isEmpty ? nil : .process(name: name)
    }

    /// The outermost `.app` folder of `path` (any case), unless it is inside a framework
    /// (Python.app). With `binaryOnly`, only when `path` is a bundle's binary inside it (some
    /// `Contents/MacOS/` below it: its own, a helper app's, an XPC service's), not a tool it merely
    /// ships (`xcrun`'s targets in `Xcode.app/Contents/Developer`, resources).
    static func appBundle(_ path: String, binaryOnly: Bool = true) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = parts.firstIndex(where: { $0.count > 4 && $0.lowercased().hasSuffix(".app") }),
              !parts[..<index].contains(where: { $0.lowercased().hasSuffix(".framework") }) else { return nil }
        let rest = parts[(index + 1)...]
        let isBinary = zip(rest, rest.dropFirst()).contains { $0 == "Contents" && $1 == "MacOS" }
        return isBinary || !binaryOnly ? parts[...index].joined(separator: "/") : nil
    }

    /// `pid`'s parent, short name and executable, read live; nil when it cannot be read.
    static func processRecord(_ pid: pid_t) -> ProcessRecord? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: &info.pbsi_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))  // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let executable = length > 0 ? String(decoding: buffer.prefix(Int(length)), as: UTF8.self) : nil
        return ProcessRecord(parent: pid_t(info.pbsi_ppid), name: name, executable: executable)
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
        switch fds.descriptors(of: pid) {
        case let .failure(error):
            return failure(error.code)
        case let .success(listed):
            return listing(listed.descriptors, truncated: listed.truncated) { vnodePath(pid: pid, fd: $0) }
        }
    }

    /// A process's inspection from its descriptor list: the paths `path` gives for its vnode
    /// descriptors. A descriptor whose path cannot be read (nil) is skipped and leaves the listing
    /// complete (see the type's residual); only `truncated` makes it incomplete.
    static func listing(_ descriptors: some Sequence<proc_fdinfo>, truncated: Bool,
                        path: (Int32) -> String?) -> Inspection {
        var paths: [String] = []
        for fd in descriptors where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            if let found = path(fd.proc_fd) { paths.append(found) }
        }
        return .listed(paths: paths, truncated: truncated)
    }

    /// How one `PROC_PIDLISTFDS` call ended.
    enum ListCall: Equatable {
        /// It filled this many bytes; 0 (with no error) means the process has no descriptors.
        case bytes(Int)
        /// The process exited (`ESRCH`).
        case gone
        case failed(errno: Int32)
    }

    /// Reads a `PROC_PIDLISTFDS` call's `result` and the `errno` it left (cleared before the call).
    static func listCall(result: Int32, errno code: Int32) -> ListCall {
        if result > 0 { return .bytes(Int(result)) }
        switch code {
        case 0: return .bytes(0)
        case ESRCH: return .gone
        default: return .failed(errno: code)
        }
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

        /// The pid's descriptors (none for a process that has none), and whether the table was
        /// still full after the retries (then the ones read are valid, but there may be more); the
        /// `errno` when they cannot be read (`ESRCH`: it exited).
        mutating func descriptors(
            of pid: pid_t
        ) -> Result<(descriptors: ArraySlice<proc_fdinfo>, truncated: Bool), ProcError> {
            let stride = MemoryLayout<proc_fdinfo>.stride
            errno = 0
            let estimate = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            let needed: Int
            switch listCall(result: estimate, errno: errno) {
            case .bytes(0): return .success(([], false))
            case .bytes(let bytes): needed = bytes
            case .gone: return .failure(ProcError(code: ESRCH))
            case .failed(let code): return .failure(ProcError(code: code))
            }
            var capacity = needed / stride + 32
            for attempt in 0..<4 {
                if storage.count < capacity {
                    storage = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
                }
                errno = 0
                let result = storage.withUnsafeMutableBytes {
                    proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
                }
                let bytes: Int
                switch listCall(result: result, errno: errno) {
                case .bytes(let filled): bytes = filled
                case .gone: return .failure(ProcError(code: ESRCH))
                case .failed(let code): return .failure(ProcError(code: code))
                }
                let count = min(bytes / stride, storage.count)
                if count < storage.count || attempt == 3 {
                    return .success((storage.prefix(count), count >= storage.count))
                }
                capacity = storage.count * 2
            }
            return .failure(ProcError(code: EOVERFLOW))   // not reached: the last attempt returns
        }
    }

    /// The path of `pid`'s descriptor `fd`; nil when it cannot be read, for whatever reason (any
    /// errno, a short read, an empty path, no NUL inside the buffer): the caller skips it.
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

/// Who holds a file open: an app (by its bundle's path, for the app to name it as Finder does), or
/// a process in no app, by its name.
public enum OpenFileHolder: Sendable, Hashable {
    case app(path: String)
    case process(name: String)
    /// A process that could not be read (it exited, or has no name).
    case unnamed
}

/// How an item is open right now (`OpenFileSet.use(of:isDirectory:)`).
public struct OpenUse: Sendable, Hashable {
    /// Who holds it, or the files inside it, open; empty when the set recorded no holders.
    public var holders: Set<OpenFileHolder>
    /// A folder whose files inside are open, not the folder itself.
    public var onlyInside: Bool

    public init(holders: Set<OpenFileHolder>, onlyInside: Bool) {
        self.holders = holders
        self.onlyInside = onlyInside
    }
}
