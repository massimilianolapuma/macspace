/// Why `ScanStore.trash` left an item where it was.
public enum TrashSkip: Sendable, Hashable {
    /// No longer on disk, or already moved to the Trash.
    case missing
    /// On disk it is no longer what was scanned: another kind of object (a folder now a symbolic
    /// link, a file now a folder), a folder above it replaced, now a mount point, or on another volume.
    case changed
    /// The safety rules, re-evaluated right before moving, protect it.
    case protected(SafetyReason)
    /// A folder holding something the rules protect as a whole (a running app, a Photos library,
    /// Apple data…), for the given reason; the folder itself may not be protected.
    case containsProtected(SafetyReason)
    /// Its fresh safety verdict (level, reason or owner) is not the one the user confirmed
    /// (`trash`'s `expectedVerdicts`), or it has no confirmed verdict there.
    case verdictChanged
    /// The app was still applying a new environment (apps index, apps launched or quit), so verdicts
    /// were not final and nothing was moved. `ScanStore.trash` never returns it; the app does.
    case appsAnalysisInProgress
    /// It, or a file inside it, is open in some process.
    case openNow
    /// A folder above it is a package (per LaunchServices), so only the package as a whole may move.
    case insidePackage
    /// `TrashGuard` refused it.
    case refused
    /// The list of open files could not be read in full, so nothing was moved.
    case cannotCheckOpenFiles
    /// A folder whose contents were not all seen (a mount point, an unreadable or dataless folder, a
    /// folder a cancelled scan did not finish listing, or one whose listing left an entry out), so
    /// what it holds cannot be checked.
    case containsUnverified
    /// The scan is still running, so nothing was moved.
    case scanInProgress
    /// Checking or moving it failed; the message says why.
    case failed(String)
}

/// What `ScanStore.trash` did with each top-most selected item.
public struct TrashOutcome: Sendable {
    public struct Moved: Sendable, Hashable {
        public var node: NodeID
        public var name: String
        /// Its size in the tree right before it was removed.
        public var size: UInt64
        /// Where it is now inside the Trash; nil when the system reported no resulting path.
        public var trashedPath: String?

        public init(node: NodeID, name: String, size: UInt64, trashedPath: String?) {
            self.node = node
            self.name = name
            self.size = size
            self.trashedPath = trashedPath
        }
    }

    public struct Skipped: Sendable, Hashable {
        public var node: NodeID
        public var name: String
        public var reason: TrashSkip

        public init(node: NodeID, name: String, reason: TrashSkip) {
            self.node = node
            self.name = name
            self.reason = reason
        }
    }

    /// In the order they were moved (largest first).
    public var moved: [Moved]
    public var skipped: [Skipped]

    public init(moved: [Moved] = [], skipped: [Skipped] = []) {
        self.moved = moved
        self.skipped = skipped
    }
}
