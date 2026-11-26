/// Assigns a `FileCategory` from a file's extension plus the folder context it inherits.
/// Works on UTF-8 bytes with a rolling FNV-1a hash so classifying a file never allocates.
public struct CategoryClassifier: Sendable {
    private let fileExtensions: [UInt64: FileCategory]
    private let directoryNames: [UInt64: FileCategory]
    private let directoryExtensions: [UInt64: FileCategory]
    private let developmentPrefixes: [[UInt8]]
    private let systemPrefixes: [[UInt8]]
    private let appDataPrefixes: [[UInt8]]

    private static let maxKeyLength = 32

    public init(home: String) {
        var files: [UInt64: FileCategory] = [:]
        func add(_ category: FileCategory, _ list: String) {
            for e in list.split(separator: " ") { files[Self.key(of: Array(e.utf8))] = category }
        }
        add(.video, "mov mp4 m4v avi mkv webm mpg mpeg wmv flv 3gp mts m2ts braw r3d")
        add(.photo, "jpg jpeg png heic heif gif tif tiff bmp webp cr2 cr3 nef arw dng orf rw2 raf psd ai svg")
        add(.music, "mp3 m4a aac wav aif aiff flac alac ogg opus mid midi caf")
        add(.document, "pdf doc docx pages key numbers xls xlsx ppt pptx txt rtf md csv odt ods odp epub")
        add(.archive, "zip rar 7z tar gz tgz bz2 xz zst dmg pkg xip iso sparseimage")
        add(.development, "swift py js mjs ts tsx jsx c h m mm cpp hpp java kt go rs rb php o a dylib")
        fileExtensions = files

        var names: [UInt64: FileCategory] = [:]
        for n in ["node_modules", "DerivedData", ".git", ".build", ".swiftpm", "Pods", "Carthage", ".gradle",
                  ".venv", "venv", "__pycache__", ".tox", ".next", ".nuxt", ".terraform", ".cargo", ".rustup",
                  ".npm", ".pnpm-store", ".yarn", ".ollama", ".lmstudio"] {
            names[Self.key(of: Array(n.utf8))] = .development
        }
        directoryNames = names

        var dirExt: [UInt64: FileCategory] = [:]
        for (e, c) in [("app", FileCategory.app), ("photoslibrary", .photo), ("fcpbundle", .video),
                       ("imovielibrary", .video), ("logicx", .music), ("band", .music),
                       ("sparsebundle", .archive)] {
            dirExt[Self.key(of: Array(e.utf8))] = c
        }
        directoryExtensions = dirExt

        var h = home
        while h.count > 1, h.hasSuffix("/") { h.removeLast() }
        let lib = h + "/Library"
        developmentPrefixes = ["/usr/local", "/opt/homebrew", lib + "/Developer"].map { Array($0.utf8) }
        systemPrefixes = ["/System", "/usr", "/bin", "/sbin", "/private/var", "/private/etc", "/cores",
                          "/Library/Apple"].map { Array($0.utf8) }
        appDataPrefixes = ["/Library/Application Support", "/Library/Caches"]
            .map { Array($0.utf8) }
            + ["Application Support", "Caches", "Containers", "Group Containers", "Saved Application State",
               "HTTPStorages", "WebKit", "Logs", "Preferences", "Cookies"].map { Array((lib + "/" + $0).utf8) }
    }

    /// The category a directory imposes on everything below it, or nil if it imposes none.
    /// `siblingHasCargoToml` tells whether the directory's own folder holds a `Cargo.toml`, which
    /// makes a `target` folder a Rust build directory.
    public func context(forDirectory name: String, path: String, parent: FileCategory?,
                        siblingHasCargoToml: Bool = false) -> FileCategory? {
        if parent == .app { return .app }
        if siblingHasCargoToml, name == "target" { return .development }
        // Model weights downloaded by Hugging Face tools.
        if name == "huggingface", path.hasSuffix("/.cache/huggingface") { return .development }
        var path = path
        return path.withUTF8 { classifyDirectory(name, $0) } ?? parent
    }

    public func category(forFile name: String, context: FileCategory?) -> FileCategory {
        if let context { return context }
        var name = name
        return name.withUTF8 { lookup(fileExtensions, $0) } ?? .other
    }

    // MARK: - Internals

    private func classifyDirectory(_ name: String, _ path: UnsafeBufferPointer<UInt8>) -> FileCategory? {
        if Self.matches(path, developmentPrefixes) { return .development }
        if Self.matches(path, systemPrefixes) { return .system }
        if Self.matches(path, appDataPrefixes) { return .appData }
        var name = name
        return name.withUTF8 { n -> FileCategory? in
            if let c = lookup(directoryExtensions, n) { return c }
            return Self.fullNameKey(n).flatMap { directoryNames[$0] }
        }
    }

    private func lookup(_ table: [UInt64: FileCategory], _ bytes: UnsafeBufferPointer<UInt8>) -> FileCategory? {
        guard let dot = bytes.lastIndex(of: UInt8(ascii: ".")), dot > 0, dot < bytes.count - 1,
              bytes.count - dot - 1 <= Self.maxKeyLength else { return nil }
        var h: UInt64 = 0xcbf29ce484222325
        for i in (dot + 1)..<bytes.count {
            var b = bytes[i]
            if b >= 0x80 { return nil }
            if b >= 65 && b <= 90 { b |= 0x20 }
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return table[h]
    }

    private static func fullNameKey(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt64? {
        guard bytes.count <= maxKeyLength else { return nil }
        var h: UInt64 = 0xcbf29ce484222325
        for var b in bytes {
            if b >= 0x80 { return nil }
            if b >= 65 && b <= 90 { b |= 0x20 }
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return h
    }

    private static func key(of bytes: [UInt8]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for var b in bytes {
            if b >= 65 && b <= 90 { b |= 0x20 }
            h = (h ^ UInt64(b)) &* 0x100000001b3
        }
        return h
    }

    /// Component-wise prefix test: `/usr/local` matches `/usr/local` and `/usr/local/x`, not `/usr/localfoo`.
    private static func matches(_ path: UnsafeBufferPointer<UInt8>, _ prefixes: [[UInt8]]) -> Bool {
        for p in prefixes where path.count >= p.count {
            var i = 0
            while i < p.count, path[i] == p[i] { i += 1 }
            if i == p.count, path.count == p.count || path[p.count] == UInt8(ascii: "/") { return true }
        }
        return false
    }
}
