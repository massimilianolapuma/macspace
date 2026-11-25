import CoreServices
import Foundation

/// Last-use lookups backed by Spotlight metadata.
public enum SpotlightLastUsed {
    /// Seconds since 1970 of the last time Spotlight saw the item at `path` used, or `nil` when the
    /// item is not indexed or has no last-used date.
    public static func lastUsed(path: String) -> UInt32? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, kMDItemLastUsedDate),
              let date = value as? Date else { return nil }
        let seconds = date.timeIntervalSince1970
        guard seconds >= 0, seconds <= Double(UInt32.max) else { return nil }
        return UInt32(seconds)
    }
}

extension AppsIndex {
    /// Paths of every application bundle Spotlight knows about (`kMDItemContentType ==
    /// "com.apple.application-bundle"`), queried synchronously. Empty when Spotlight is off.
    public static func spotlightAppPaths() -> [String] {
        let query = "kMDItemContentType == \"com.apple.application-bundle\""
        guard let mdQuery = MDQueryCreate(kCFAllocatorDefault, query as CFString, nil, nil),
              MDQueryExecute(mdQuery, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var paths: [String] = []
        let count = MDQueryGetResultCount(mdQuery)
        paths.reserveCapacity(count)
        for index in 0..<count {
            guard let raw = MDQueryGetResultAtIndex(mdQuery, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String, path.hasSuffix(".app") {
                paths.append(path)
            }
        }
        return paths
    }
}
