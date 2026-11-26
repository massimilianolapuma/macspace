import SwiftUI

/// A string fitted to a width, with the width it takes.
struct FittedText {
    let string: String
    let width: Double
}

/// Fits chart label text to the room it has, shared by the sunburst and the treemap. Widths
/// are bucketed to 4 pt, and results are kept for the current and the previous generation
/// (`newGeneration()`), so a chart refresh re-measures only text whose string or room changed;
/// the cache never holds more than two generations.
@MainActor
final class TextFitter<Line: Hashable> {
    private struct Key: Hashable {
        let string: String
        let bucket: Int
        let line: Line
    }

    /// The styled text for `string` on `line`, as it is drawn.
    private let text: (String, Line) -> Text
    /// Whether a line too long for its room is cut with "…" (names) or dropped (sizes).
    private let truncates: (Line) -> Bool
    private var texts: [Key: FittedText?] = [:]
    private var previousTexts: [Key: FittedText?] = [:]

    init(text: @escaping (String, Line) -> Text, truncates: @escaping (Line) -> Bool) {
        self.text = text
        self.truncates = truncates
    }

    /// Starts a generation: the last one's results stay reusable until the next call.
    func newGeneration() {
        swap(&texts, &previousTexts)
        texts.removeAll(keepingCapacity: true)
    }

    /// `string` (for a truncating line, its longest "…" prefix) that fits `width`, with its
    /// width; nil when nothing useful fits.
    func fitted(_ string: String, width: Double, line: Line, in context: GraphicsContext) -> FittedText? {
        guard width > 20 else { return nil }
        let bucket = Int(width / 4)
        let key = Key(string: string, bucket: bucket, line: line)
        if let hit = texts[key] { return hit }
        if let hit = previousTexts[key] {
            texts[key] = hit
            return hit
        }
        func measure(_ s: String) -> Double {
            context.resolve(text(s, line)).measure(in: CGSize(width: 10_000, height: 40)).width
        }
        let limit = Double(bucket * 4)
        var result: FittedText?
        let full = measure(string)
        if full <= limit {
            result = FittedText(string: string, width: full)
        } else if truncates(line) {
            let characters = Array(string)
            var low = 0, high = characters.count
            while low < high {
                let mid = (low + high + 1) / 2
                if measure(String(characters[..<mid]) + "…") <= limit { low = mid } else { high = mid - 1 }
            }
            if low >= 3 {
                let text = String(characters[..<low]).trimmingCharacters(in: .whitespaces) + "…"
                result = FittedText(string: text, width: measure(text))
            }
        }
        texts[key] = result
        return result
    }
}
