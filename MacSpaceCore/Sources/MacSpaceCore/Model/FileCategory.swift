/// What kind of content a file holds, used to colour the treemap and filter lists.
public enum FileCategory: UInt8, Sendable, CaseIterable, Hashable {
    case video, photo, music, document, app, development, archive, system, appData, other
}

/// How long ago a file was last used.
public enum AgeBucket: Int, Sendable, CaseIterable {
    case lastMonth, lastSixMonths, lastYear, oneToTwoYears, older, unknown

    /// `lastUsed == 0` means unknown; timestamps in the future count as `.lastMonth`.
    public init(lastUsed: UInt32, now: UInt32) {
        guard lastUsed != 0 else { self = .unknown; return }
        guard lastUsed < now else { self = .lastMonth; return }
        let days = (now - lastUsed) / 86_400
        switch days {
        case ...30: self = .lastMonth
        case ...182: self = .lastSixMonths
        case ...365: self = .lastYear
        case ...730: self = .oneToTwoYears
        default: self = .older
        }
    }
}
