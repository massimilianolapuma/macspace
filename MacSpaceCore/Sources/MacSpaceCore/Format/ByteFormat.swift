import Foundation

/// Sizes as Finder shows them (allocated bytes, `.file` count style), always numeric ("0 byte",
/// never "Zero kB") and with a fixed number of decimals per unit, so sizes line up ("2,70 GB"
/// next to "142,87 GB").
public enum ByteFormat {
    /// Decimals per unit: `.file` style rounds to these, but drops trailing zeros.
    private static let decimals = ["MB": 1, "GB": 2, "TB": 2, "PB": 2]

    public static func string(_ bytes: UInt64, locale: Locale = Locale(identifier: "it_IT")) -> String {
        let text = Int64(clamping: bytes).formatted(.byteCount(style: .file, spellsOutZero: false).locale(locale))
        guard let space = text.lastIndex(where: \.isWhitespace),
              let wanted = decimals[String(text[text.index(after: space)...])] else { return text }
        let separator = locale.decimalSeparator ?? ","
        var number = String(text[..<space])
        let have = number.range(of: separator).map { number.distance(from: $0.upperBound, to: number.endIndex) } ?? -1
        if have < wanted {
            number += (have < 0 ? separator : "") + String(repeating: "0", count: wanted - max(have, 0))
        }
        return number + text[space...]
    }
}
