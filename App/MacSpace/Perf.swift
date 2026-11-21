import os

/// Signpost intervals for the main-thread work that must stay inside a frame (Instruments →
/// Points of Interest, subsystem `com.massilp.macspace`).
enum Perf {
    static let signposter = OSSignposter(subsystem: "com.massilp.macspace", category: .pointsOfInterest)

    static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }
}
