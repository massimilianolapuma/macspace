import Foundation

/// Where saved scans live (#33): one file for the startup disk, one for the last folder scanned.
/// They hold every file name of what was scanned, so they stay in the app's own cache folder.
public struct SnapshotFolder: Sendable {
    public let url: URL

    /// `~/Library/Caches/com.massilp.macspace/Snapshots/`.
    public static let standard = SnapshotFolder(url: URL.cachesDirectory
        .appending(path: "com.massilp.macspace", directoryHint: .isDirectory)
        .appending(path: "Snapshots", directoryHint: .isDirectory))

    public init(url: URL) { self.url = url }

    /// Writes `saved` atomically (a temporary file in the same folder, then a rename), replacing
    /// the snapshot of the same kind: the startup disk's, or the folder's (whichever folder it was).
    public func save(_ saved: SavedScan) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try saved.encoded().write(to: file(for: saved.target), options: .atomic)
    }

    /// The snapshot saved for `target`; nil when there is none, when it is not valid (it is then
    /// deleted), or when the folder snapshot is another folder's (deleted too: only the last folder
    /// is kept).
    public func load(_ target: SavedScan.Target) -> SavedScan? {
        let file = file(for: target)
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return nil }
        guard let saved = try? SavedScan(decoding: data), saved.target == target else {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
        return saved
    }

    /// Deletes the folder snapshot (the folder it was taken of is gone).
    public func forgetFolder() {
        try? FileManager.default.removeItem(at: file(for: .folder(path: "")))
    }

    private func file(for target: SavedScan.Target) -> URL {
        switch target {
        case .startupDisk: url.appending(path: "startup-disk.snapshot", directoryHint: .notDirectory)
        case .folder: url.appending(path: "folder.snapshot", directoryHint: .notDirectory)
        }
    }
}
