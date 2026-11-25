import Foundation

/// Tells whether a path is a package (a directory the Finder shows as a single file).
public protocol PackageProbe: Sendable {
    func isPackage(_ path: String) -> Bool
}

/// Asks LaunchServices (`URLResourceValues.isPackage`), so it also recognises package types
/// registered by installed apps that are not in `SafetyTables.packageExtensions`.
public struct SystemPackageProbe: PackageProbe {
    public init() {}

    public func isPackage(_ path: String) -> Bool {
        (try? URL(filePath: path).resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
    }
}

/// The only disk writes the app makes on items: moving them to the Trash.
public protocol DiskActions: Sendable {
    /// Moves the item at `path` to the Trash and returns its new path inside the Trash.
    func moveToTrash(_ path: String) throws -> String
}

/// Moves items with `FileManager.trashItem`, so the Finder's "Put Back" works.
/// Never used by tests: it touches the real Trash.
public struct SystemDiskActions: DiskActions {
    public init() {}

    /// Throws whatever `FileManager.trashItem(at:resultingItemURL:)` throws. Returns an empty
    /// string if the system moved the item without reporting where.
    public func moveToTrash(_ path: String) throws -> String {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: URL(filePath: path), resultingItemURL: &resulting)
        return resulting?.path ?? ""
    }
}
