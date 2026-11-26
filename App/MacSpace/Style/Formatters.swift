import Foundation

/// Number and size formatting for the UI: Italian locale; sizes as Finder computes them
/// (allocated bytes, `.file` count style), always numeric ("0 byte", never "Zero kB") and with a
/// fixed number of decimals per unit, so sizes line up ("2,70 GB" next to "142,87 GB").
enum Formatters {
    private static let locale = Locale(identifier: "it_IT")
    /// Decimals per unit: `.file` style rounds to these, but drops trailing zeros.
    private static let decimals = ["MB": 1, "GB": 2, "TB": 2, "PB": 2]

    static func bytes(_ value: UInt64) -> String {
        let text = Int64(clamping: value).formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
        guard let space = text.lastIndex(where: \.isWhitespace),
              let wanted = decimals[String(text[text.index(after: space)...])] else { return text }
        var number = String(text[..<space])
        let have = number.firstIndex(of: ",").map { number.distance(from: $0, to: number.endIndex) - 1 } ?? -1
        if have < wanted {
            number += (have < 0 ? "," : "") + String(repeating: "0", count: wanted - max(have, 0))
        }
        return number + text[space...]
    }

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
}
