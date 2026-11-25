import Foundation
import Security

/// One installed application, or a bundle embedded in one (helper, extension, XPC service).
/// Embedded bundles carry the host app's `name` and `path`.
public struct AppRecord: Sendable, Hashable {
    public let bundleID: String
    public let name: String
    public let teamID: String?
    public let path: String

    public init(bundleID: String, name: String, teamID: String?, path: String) {
        self.bundleID = bundleID
        self.name = name
        self.teamID = teamID
        self.path = path
    }
}

/// Lookup table of installed apps used to decide whether a `~/Library` folder belongs to one.
/// All lookups are ASCII case-insensitive.
public struct AppsIndex: Sendable {
    /// Where `build` looks for apps by default.
    public static let defaultRoots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]

    /// An index with no apps.
    public static let empty = AppsIndex(records: [])

    /// Number of records (apps plus embedded bundles).
    public var count: Int { records.count }

    private let records: [AppRecord]
    private let byID: [String: AppRecord]
    /// Every dot-prefix (at least 2 labels, shorter than the whole ID) of each app ID.
    private let byIDPrefix: [String: AppRecord]
    private let byName: [String: AppRecord]
    private let teams: Set<String>

    /// Builds an index over `records`; the first record wins when keys collide.
    public init(records: [AppRecord]) {
        var byID: [String: AppRecord] = [:]
        var byIDPrefix: [String: AppRecord] = [:]
        var byName: [String: AppRecord] = [:]
        var teams: Set<String> = []
        for record in records {
            let id = Self.lower(record.bundleID)
            if byID[id] == nil { byID[id] = record }
            for prefix in Self.dotPrefixes(of: id) where byIDPrefix[prefix] == nil {
                byIDPrefix[prefix] = record
            }
            let fileName = (record.path as NSString).lastPathComponent
            let baseName = fileName.hasSuffix(".app") ? String(fileName.dropLast(4)) : fileName
            for name in [record.name, baseName] {
                let key = Self.lower(name)
                if byName[key] == nil { byName[key] = record }
            }
            if let team = record.teamID, !team.isEmpty { teams.insert(Self.lower(team)) }
        }
        self.records = records
        self.byID = byID
        self.byIDPrefix = byIDPrefix
        self.byName = byName
        self.teams = teams
    }

    /// The app whose bundle ID equals `id`, or where one is a prefix of the other on a `.` boundary
    /// and they share at least 2 labels (`com.foo.helper` and `com.foo`, never `com` and anything).
    public func app(forIdentifier id: String) -> AppRecord? {
        let key = Self.lower(id)
        if let exact = byID[key] { return exact }
        // An app ID that is a dot-prefix of the identifier, longest first.
        var end = key.endIndex
        while let dot = key[..<end].lastIndex(of: ".") {
            let prefix = key[..<dot]
            guard prefix.contains(".") else { break }
            if let record = byID[String(prefix)] { return record }
            end = dot
        }
        // The identifier is a dot-prefix of a longer app ID.
        guard key.contains(".") else { return nil }
        return byIDPrefix[key]
    }

    /// The app whose display name or file name (without `.app`) equals `name`.
    public func app(named name: String) -> AppRecord? {
        byName[Self.lower(name)]
    }

    /// Whether any installed app is signed by `teamID`.
    public func hasTeam(_ teamID: String) -> Bool {
        teams.contains(Self.lower(teamID))
    }

    // MARK: - Building

    /// Scans `roots` (up to 2 levels below each, never into apps) plus `extraAppPaths` for apps and
    /// their embedded bundles. Apps without a bundle ID are skipped; duplicates by path are ignored.
    /// Team IDs are read from the code signature of top-level apps only.
    public static func build(
        roots: [String] = AppsIndex.defaultRoots,
        extraAppPaths: [String] = [],
        readTeamIDs: Bool = true
    ) -> AppsIndex {
        var appPaths: [String] = []
        var seenApps: Set<String> = []
        func add(_ path: String) {
            let clean = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            if seenApps.insert(clean).inserted { appPaths.append(clean) }
        }
        for root in roots {
            for entry in names(in: root) {
                let path = root + "/" + entry
                if isApp(entry) {
                    add(path)
                } else if isDirectory(path) {
                    for child in names(in: path) where isApp(child) { add(path + "/" + child) }
                }
            }
        }
        extraAppPaths.forEach(add)

        let teams = readTeamIDs ? teamIDs(ofCodeAt: appPaths) : [:]
        var records: [AppRecord] = []
        var seenBundles: Set<String> = []
        for appPath in appPaths {
            guard let info = readInfo(bundle: appPath), let id = info.id else { continue }
            let fileName = (appPath as NSString).lastPathComponent
            let name = info.displayName ?? info.name ?? String(fileName.dropLast(4))
            let team = teams[appPath]
            if seenBundles.insert(appPath).inserted {
                records.append(AppRecord(bundleID: id, name: name, teamID: team, path: appPath))
            }
            for embedded in embeddedBundles(inApp: appPath) where seenBundles.insert(embedded).inserted {
                guard let childID = readInfo(bundle: embedded)?.id else { continue }
                records.append(AppRecord(bundleID: childID, name: name, teamID: nil, path: appPath))
            }
        }
        return AppsIndex(records: records)
    }

    // MARK: - Helpers

    /// ASCII-only lowercase, so lookups never depend on Unicode case folding.
    private static func lower(_ string: String) -> String {
        var bytes = Array(string.utf8)
        for index in bytes.indices where bytes[index] >= 0x41 && bytes[index] <= 0x5A { bytes[index] += 0x20 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Proper dot-prefixes of `id` that keep at least 2 labels.
    private static func dotPrefixes(of id: String) -> [String] {
        var result: [String] = []
        var end = id.endIndex
        while let dot = id[..<end].lastIndex(of: ".") {
            let prefix = id[..<dot]
            guard prefix.contains(".") else { break }
            result.append(String(prefix))
            end = dot
        }
        return result
    }

    private static func isApp(_ name: String) -> Bool {
        name.count > 4 && name.lowercased().hasSuffix(".app")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func names(in path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    private struct BundleInfo {
        var id: String?
        var name: String?
        var displayName: String?
    }

    /// Reads `Contents/Info.plist` (or a flat `Info.plist`) of the bundle at `path`.
    private static func readInfo(bundle path: String) -> BundleInfo? {
        for candidate in [path + "/Contents/Info.plist", path + "/Info.plist"] {
            guard let data = FileManager.default.contents(atPath: candidate),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let dict = plist as? [String: Any] else { continue }
            func string(_ key: String) -> String? {
                guard let value = dict[key] as? String, !value.isEmpty else { return nil }
                return value
            }
            return BundleInfo(id: string("CFBundleIdentifier"), name: string("CFBundleName"),
                              displayName: string("CFBundleDisplayName"))
        }
        return nil
    }

    /// Helper apps, extensions, XPC services and launch-services helpers inside an app.
    private static func embeddedBundles(inApp appPath: String) -> [String] {
        let places: [(dir: String, ext: String?)] = [
            ("Contents/Library/LoginItems", "app"), ("Contents/Helpers", "app"),
            ("Contents/PlugIns", "appex"), ("Contents/XPCServices", "xpc"),
            ("Contents/Library/LaunchServices", nil),
        ]
        var result: [String] = []
        for place in places {
            let dir = appPath + "/" + place.dir
            for name in names(in: dir) {
                if let ext = place.ext, (name as NSString).pathExtension.lowercased() != ext { continue }
                result.append(dir + "/" + name)
            }
        }
        return result
    }

    /// Reads team IDs concurrently (code-signature checks dominate the build time).
    private static func teamIDs(ofCodeAt paths: [String]) -> [String: String] {
        let lock = NSLock()
        nonisolated(unsafe) var result: [String: String] = [:]
        DispatchQueue.concurrentPerform(iterations: paths.count) { index in
            guard let team = teamID(ofCodeAt: paths[index]) else { return }
            lock.lock()
            result[paths[index]] = team
            lock.unlock()
        }
        return result
    }

    private static func teamID(ofCodeAt path: String) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        let team = dict[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }
}
