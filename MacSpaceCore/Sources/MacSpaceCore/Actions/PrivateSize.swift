/// Estimates how much space moving an item out of the volume (to the Trash, then emptied)
/// would really free.
///
/// Each file counts its private size (`ATTR_CMNEXT_PRIVATESIZE`: blocks not shared with an APFS
/// clone or snapshot), or its allocated size where the volume does not report one. A file with
/// more than one hard link counts 0: its blocks stay reachable through the other links. That is
/// also a lower bound when a directory holds every link of the file.
///
/// Clones: a clone's private size is ~0, and so is its original's while the clone exists. For
/// a directory holding both an original and its clone each file reports ~0, so the directory
/// sums to ~0 even though removing both frees the shared blocks: the estimate is a lower bound
/// when clones of each other are moved together.
public enum PrivateSize {
    /// Bytes that moving `path` would free: a file's (or symbolic link's) own private size, or
    /// for a directory the sum over its subtree, never following symbolic links nor crossing
    /// onto another device. Unreadable subdirectories are skipped; a missing path frees 0.
    /// When the calling task is cancelled, the walk stops and returns the partial sum.
    public static func freed(path: String) -> UInt64 {
        guard let root = try? DirectoryReader.stat(path: path, includePrivateSize: true) else { return 0 }
        guard root.kind == .directory else { return own(root) }

        var total: UInt64 = 0
        var pending = [path]
        while let directory = pending.popLast() {
            if Task.isCancelled { break }
            guard let entries = try? DirectoryReader.read(path: directory, includePrivateSize: true).entries else {
                continue
            }
            let base = directory.hasSuffix("/") ? directory : directory + "/"
            for entry in entries where entry.device == root.device && !entry.isMountPoint {
                if entry.kind == .directory {
                    pending.append(base + entry.name)
                } else {
                    let (sum, overflow) = total.addingReportingOverflow(own(entry))
                    total = overflow ? .max : sum
                }
            }
        }
        return total
    }

    private static func own(_ entry: DirectoryEntry) -> UInt64 {
        entry.linkCount > 1 ? 0 : entry.privateSize ?? entry.allocatedSize
    }
}
