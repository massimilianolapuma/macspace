import SwiftUI

/// Text showing a number that counts towards each new value instead of jumping. Interpolating
/// the number and re-laying out one line is far cheaper than `.numericText()`, whose per-glyph
/// transitions are rasterized on the main thread every frame — too costly for values that
/// change four times a second during a scan.
struct CountingText: View, Animatable {
    var value: Double
    let text: (UInt64) -> Text

    init(_ value: UInt64, text: @escaping (UInt64) -> Text) {
        self.value = Double(value)
        self.text = text
    }

    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        text(UInt64(max(value, 0).rounded()))
    }
}
