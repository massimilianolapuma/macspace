/// Tunable lists the safety rules read; kept apart from the logic so they are easy to review.
public enum SafetyTables {
    /// Lowercase extensions of directories that macOS treats as a single package (bundle or library).
    public static let packageExtensions: Set<String> = [
        "app", "appex", "xpc", "framework", "bundle", "plugin", "kext", "qlgenerator", "mdimporter", "saver",
        "prefpane", "systemextension", "photoslibrary", "photolibrary", "aplibrary", "musiclibrary", "tvlibrary",
        "fcpbundle", "imovielibrary", "logicx", "band", "xcarchive", "xcodeproj", "xcworkspace", "playground",
        "rtfd", "pages", "key", "numbers", "sparsebundle", "dsym", "mlmodelc", "docc",
    ]
}
