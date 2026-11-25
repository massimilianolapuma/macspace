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
}
