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
    /// What `freed` found.
    public struct Estimate: Sendable, Equatable {
        public var bytes: UInt64
        /// Part of the item could not be measured (a subfolder could not be read or listed in full,
        /// the walk was cancelled, or the item itself could not be examined): `bytes` is then only
        /// what was seen, so the space freed may be more.
        public var isPartial: Bool

        public init(bytes: UInt64, isPartial: Bool) {
            self.bytes = bytes
            self.isPartial = isPartial
        }
    }

    /// Bytes that moving `path` would free: a file's (or symbolic link's) own private size, or
    /// for a directory the sum over its subtree, never following symbolic links nor crossing
    /// onto another device. A missing path frees 0, and that is complete. Partial (see
    /// `Estimate.isPartial`): the path cannot be examined for another reason (0 bytes), a
    /// subdirectory cannot be read (skipped) or is listed only in part (`DirectoryListing`), or the
    /// calling task is cancelled (the walk stops with the sum so far).
    public static func freed(path: String) -> Estimate {
        let root: DirectoryEntry
        do {
            root = try DirectoryReader.stat(path: path, includePrivateSize: true)
        } catch .notFound {
            return Estimate(bytes: 0, isPartial: false)
        } catch {
            return Estimate(bytes: 0, isPartial: true)
        }
        guard root.kind == .directory else { return Estimate(bytes: own(root), isPartial: false) }

        var total: UInt64 = 0
        var partial = false
        var pending = [path]
        while let directory = pending.popLast() {
            if Task.isCancelled {
                partial = true
                break
            }
            let listing: DirectoryListing
            do {
                listing = try DirectoryReader.read(path: directory, includePrivateSize: true)
            } catch .notFound {
                continue   // gone meanwhile: it frees nothing
            } catch {
                partial = true
                continue
            }
            if !listing.isComplete { partial = true }
            let base = directory.hasSuffix("/") ? directory : directory + "/"
            for entry in listing.entries where entry.device == root.device && !entry.isMountPoint {
                if entry.kind == .directory {
                    pending.append(base + entry.name)
                } else {
                    let (sum, overflow) = total.addingReportingOverflow(own(entry))
                    total = overflow ? .max : sum
                }
            }
        }
        return Estimate(bytes: total, isPartial: partial)
    }

    private static func own(_ entry: DirectoryEntry) -> UInt64 {
        entry.linkCount > 1 ? 0 : entry.privateSize ?? entry.allocatedSize
    }
}
