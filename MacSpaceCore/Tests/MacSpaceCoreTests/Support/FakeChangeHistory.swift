@testable import MacSpaceCore

/// Test double for `ChangeHistory`: a fixed baseline (nil: no history), and the same answer for
/// every path asked about.
struct FakeChangeHistory: ChangeHistory {
    var start: ChangeBaseline? = ChangeBaseline(eventID: 1, deviceUUIDs: [:])
    var answer: PathChanges = .folders([])

    func baseline(devices: Set<Int32>) -> ChangeBaseline? { start }

    func changes(since baseline: ChangeBaseline, under paths: [String],
                 devices: [String: Int32]) -> [String: PathChanges] {
        Dictionary(paths.map { ($0, answer) }, uniquingKeysWith: { a, _ in a })
    }
}
