import Foundation
import MacSpaceCore

/// Number, size and date formatting for the UI, in Italian.
enum Formatters {
    private static let locale = Locale(identifier: "it_IT")

    /// Sizes as Finder shows them, with fixed decimals per unit (`ByteFormat`).
    static func bytes(_ value: UInt64) -> String { ByteFormat.string(value, locale: locale) }

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }

    /// `part` as a whole percentage of `total` ("12%").
    static func percent(_ part: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "" }
        let ratio = Double(part) / Double(total)
        if part > 0, ratio < 0.005 { return "<1%" }
        return ratio.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// An estimated last use (seconds since 1970) as a date ("12 mar 2025"); "Sconosciuto" for 0.
    static func lastUsedDate(_ timestamp: UInt32) -> String {
        guard timestamp != 0 else { return String(localized: "Sconosciuto") }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
            .formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale))
    }

    /// An estimated last use relative to now ("3 mesi fa"); "Sconosciuto" for 0.
    static func lastUsedAge(_ timestamp: UInt32, now: Date = .now) -> String {
        guard timestamp != 0 else { return String(localized: "Sconosciuto") }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: min(Date(timeIntervalSince1970: TimeInterval(timestamp)), now),
                                         relativeTo: now)
    }
}
