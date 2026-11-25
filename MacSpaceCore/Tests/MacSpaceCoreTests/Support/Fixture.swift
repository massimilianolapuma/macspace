import Darwin
import Foundation

/// Builds a throwaway directory tree under the temporary directory for file-system tests.
///
/// All creation goes through `*at` system calls relative to an open parent descriptor, one
/// path component at a time, so trees deeper than `PATH_MAX` can be created and removed.
struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacSpaceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    /// Creates a regular file of exactly `bytes` bytes, creating missing parent directories.
    @discardableResult
    func file(_ rel: String, bytes: Int) throws -> URL {
        try withParent(of: rel) { parent, name in
            let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw Self.posixError() }
            defer { close(fd) }
            let chunk = [UInt8](repeating: 0xA5, count: 64 * 1024)
            var remaining = bytes
            while remaining > 0 {
                let n = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, min(remaining, $0.count)) }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                remaining -= n
            }
        }
        return root.appendingPathComponent(rel, isDirectory: false)
    }

    /// Creates a regular file holding `data`, creating missing parent directories.
    @discardableResult
    func write(_ rel: String, data: Data) throws -> URL {
        try withParent(of: rel) { parent, name in
            let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard fd >= 0 else { throw Self.posixError() }
            defer { close(fd) }
            var offset = 0
            while offset < data.count {
                let n = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, data.count - offset) }
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Self.posixError()
                }
                offset += n
            }
        }
        return root.appendingPathComponent(rel, isDirectory: false)
    }

    /// Creates a property list file from `dict` (XML format), creating missing parent directories.
    @discardableResult
    func plist(_ rel: String, _ dict: [String: Any]) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        return try write(rel, data: data)
    }

    /// Creates a directory (and any missing ancestors). Works beyond `PATH_MAX`.
    @discardableResult
    func dir(_ rel: String) throws -> URL {
        let parts = Self.components(rel)
        guard !parts.isEmpty else { return root }
        let fd = try Self.openDirectoryChain(root: root, parts[...])
        close(fd)
        return root.appendingPathComponent(rel, isDirectory: true)
    }

    /// Creates a symbolic link at `rel` pointing to `to` (the target is not required to exist).
    func symlink(_ rel: String, to target: URL) throws {
        try withParent(of: rel) { parent, name in
            guard symlinkat(target.path, parent, name) == 0 else { throw Self.posixError() }
        }
    }

    /// Creates a hard link at `rel` to the existing file `to`.
    func hardLink(_ rel: String, to target: URL) throws {
        try withParent(of: rel) { parent, name in
            guard linkat(AT_FDCWD, target.path, parent, name, 0) == 0 else { throw Self.posixError() }
        }
    }

    /// Removes the whole tree, first restoring owner permissions on every directory.
    /// Walks with descriptors (`openat`/`unlinkat`), so trees deeper than `PATH_MAX` are removed too.
    func cleanup() {
        chmod(root.path, 0o755)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd >= 0 {
            Self.removeContents(of: fd)
            close(fd)
        }
        rmdir(root.path)
        assert(!FileManager.default.fileExists(atPath: root.path), "Fixture cleanup left \(root.path) behind")
    }

    // MARK: - Helpers

    private func withParent(of rel: String, _ body: (Int32, String) throws -> Void) throws {
        let parts = Self.components(rel)
        guard let name = parts.last else { throw POSIXError(.EINVAL) }
        let parent = try Self.openDirectoryChain(root: root, parts.dropLast())
        defer { close(parent) }
        try body(parent, name)
    }

    private static func components(_ rel: String) -> [String] {
        rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Opens `root`, then creates (if missing) and opens each component relative to the previous
    /// descriptor. Returns an open descriptor for the last directory; the caller closes it.
    private static func openDirectoryChain(root: URL, _ parts: ArraySlice<String>) throws -> Int32 {
        var fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        for part in parts {
            if mkdirat(fd, part, 0o755) != 0, errno != EEXIST {
                let error = posixError()
                close(fd)
                throw error
            }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let error = next < 0 ? posixError() : nil
            close(fd)
            if let error { throw error }
            fd = next
        }
        return fd
    }

    private static func removeContents(of dirFD: Int32) {
        for name in entryNames(of: dirFD) {
            name.withUnsafeBufferPointer { buffer in
                let cName = buffer.baseAddress!
                var info = Darwin.stat()
                guard fstatat(dirFD, cName, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return }
                if info.st_mode & S_IFMT == S_IFDIR {
                    fchmodat(dirFD, cName, 0o755, 0)
                    let child = openat(dirFD, cName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    if child >= 0 {
                        removeContents(of: child)
                        close(child)
                    }
                    unlinkat(dirFD, cName, AT_REMOVEDIR)
                } else {
                    unlinkat(dirFD, cName, 0)
                }
            }
        }
    }

    /// Raw, NUL-terminated entry names (excluding "." and ".."), collected before any removal.
    private static func entryNames(of dirFD: Int32) -> [[CChar]] {
        let dupFD = dup(dirFD)
        guard dupFD >= 0, let dir = fdopendir(dupFD) else {
            if dupFD >= 0 { close(dupFD) }
            return []
        }
        defer { closedir(dir) }
        var names: [[CChar]] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            var name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                raw.prefix(length).map { CChar(bitPattern: $0) }
            }
            if name == [0x2E] || name == [0x2E, 0x2E] { continue }
            name.append(0)
            names.append(name)
        }
        return names
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
