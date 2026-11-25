import Darwin
import Foundation
import Synchronization
@testable import MacSpaceCore

/// Test double for `DiskActions`: records each path and renames the item into a fixture
/// "trash" folder instead of the real Trash.
final class RecordingDiskActions: DiskActions {
    let trash: String
    private let log = Mutex<[String]>([])

    init(trash: String) { self.trash = trash }

    /// Paths passed to `moveToTrash`, in call order.
    var moved: [String] { log.withLock { $0 } }

    func moveToTrash(_ path: String) throws -> String {
        log.withLock { $0.append(path) }
        let destination = trash + "/" + (path as NSString).lastPathComponent
        guard rename(path, destination) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return destination
    }
}
