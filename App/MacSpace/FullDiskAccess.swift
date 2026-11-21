import AppKit

/// Full Disk Access (TCC) detection and the shortcut to its System Settings pane.
enum FullDiskAccess {
    /// The TCC database is readable only by processes granted Full Disk Access.
    static var isGranted: Bool {
        FileManager.default.isReadableFile(atPath: "/Library/Application Support/com.apple.TCC/TCC.db")
    }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
