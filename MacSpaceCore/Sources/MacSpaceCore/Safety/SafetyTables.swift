/// Tunable lists the safety rules read; kept apart from the logic so they are easy to review.
public enum SafetyTables {
    /// Lowercase extensions of directories that macOS treats as a single package (bundle or library).
    public static let packageExtensions: Set<String> = [
        "app", "appex", "xpc", "framework", "bundle", "plugin", "kext", "qlgenerator", "mdimporter", "saver",
        "prefpane", "systemextension", "photoslibrary", "photolibrary", "aplibrary", "musiclibrary", "tvlibrary",
        "fcpbundle", "imovielibrary", "logicx", "band", "xcarchive", "xcodeproj", "xcworkspace", "playground",
        "rtfd", "pages", "key", "numbers", "sparsebundle", "dsym", "mlmodelc", "docc",
    ]

    /// Identifier prefixes (lowercase) that belong to Apple although they do not contain `com.apple`.
    public static let appleIdentifierPrefixes = ["is.workflow."]

    /// Team ID of Apple's own Group Containers.
    public static let appleTeamID = "243LU875E5"

    /// Trailing labels (lowercase) that are file extensions, not part of an identifier (`com.foo.app.log`).
    public static let fileExtensionLabels: Set<String> = [
        "log", "txt", "json", "db", "sqlite", "sqlite3", "plist", "cache", "tmp", "lock", "xml", "dat", "bak",
        "old", "crash", "ips", "diag", "gz", "zip",
    ]

    /// Lowercase extensions of installer files (disk images and packages).
    public static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip"]

    /// Folders that are never trashable themselves (rule 2, exact match). `home` may end with `/`.
    public static func essentialPaths(home: String) -> Set<String> {
        let h = normalized(home)
        let lib = h + "/Library"
        var paths: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/usr", "/opt", "/bin",
            "/sbin", "/cores", "/etc", "/var", "/tmp", h, lib, h + "/.Trash",
        ]
        for folder in ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications"] {
            paths.insert(h + "/" + folder)
        }
        for location in LibraryLocation.allCases { paths.insert(lib + "/" + location.rawValue) }
        for folder in ["Developer", "Mobile Documents", "CloudStorage"] { paths.insert(lib + "/" + folder) }
        return paths
    }

    /// macOS-owned trees (rule 4): everything at or below them is protected, except `systemExceptions`.
    public static let systemPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private", "/cores", "/Library/Apple"]

    /// Trees inside `systemPrefixes` that belong to the user (Homebrew and friends).
    public static let systemExceptions = ["/usr/local"]

    /// Never-touch folders of `~/Library` holding Apple data (rule 6), relative to `~/Library`.
    public static let appleDataFolders = ["Keychains", "Mail", "Messages"]

    /// Lowercase name prefixes of Apple's own `~/Library/Containers` entries (rule 6).
    public static let appleContainerPrefixes = ["com.apple."]

    /// Lowercase name prefixes, and infixes, of Apple's own `~/Library/Group Containers` entries (rule 6).
    public static let appleGroupContainerPrefixes = ["group.com.apple."]
    public static let appleGroupContainerInfixes = [".com.apple."]

    /// Provider name shown for `~/Library/Mobile Documents` (rule 11).
    public static let iCloudDriveName = "iCloud Drive"

    /// Caches that developer tools rebuild on demand (rule 12), with their display names, in a fixed order.
    /// Xcode `Archives` is user data and deliberately absent.
    public static func developerCaches(home: String) -> [(name: String, path: String)] {
        let h = normalized(home)
        let lib = h + "/Library"
        return [
            ("DerivedData", lib + "/Developer/Xcode/DerivedData"),
            ("CoreSimulator", lib + "/Developer/CoreSimulator/Caches"),
            ("npm", h + "/.npm/_cacache"),
            ("Gradle", h + "/.gradle/caches"),
            ("Cargo", h + "/.cargo/registry/cache"),
            ("Go", h + "/go/pkg/mod/cache"),
            ("pip", h + "/.cache/pip"),
            ("pnpm", lib + "/pnpm/store"),
            ("pnpm", h + "/.pnpm-store"),
        ]
    }

    /// `path` without trailing slashes (`/` stays `/`).
    static func normalized(_ path: String) -> String {
        var result = path
        while result.utf8.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }
}
