import SwiftUI

/// Rows that scroll once there are more than `visibleRows`, and never look complete when they are
/// not: the viewport ends halfway through the next row, the bottom fades while more is below, the
/// scroll bar stays visible, and "+N altri" counts the rows still hidden below.
struct ScrollCueList<Row: View>: View {
    let count: Int
    var visibleRows = 5
    @ViewBuilder let row: (Int) -> Row
    @Environment(\.colorScheme) private var scheme

    /// Each row's measured height, by index.
    @State private var heights: [Int: CGFloat] = [:]
    /// How far the list is scrolled.
    @State private var offset: CGFloat = 0

    /// Viewport height until the rows are measured.
    static var fallbackHeight: CGFloat { 300 }
    /// Height of the fade at the bottom.
    static var fadeHeight: CGFloat { 28 }

    var body: some View {
        if count <= visibleRows {
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { row($0) }
            }
        } else {
            let viewport = viewportHeight
            let below = hiddenBelow(viewport: viewport)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<count, id: \.self) { index in
                            row(index)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[index] = $0 }
                        }
                    }
                }
                .scrollIndicators(.visible)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in offset = y }
                .frame(height: viewport)
                .mask {
                    LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: below > 0 ? 1 - Self.fadeHeight / viewport : 1),
                        .init(color: .black.opacity(below > 0 ? 0.1 : 1), location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                if below > 0 {
                    Text("+\(below) altri")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(FusionPalette.secondaryText(scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 6)
                        .accessibilityHidden(true)  // VoiceOver reads every row anyway
                }
            }
        }
    }

    /// The first `visibleRows` rows and half of the next one, so a cut row always shows more is there.
    private var viewportHeight: CGFloat {
        let measured = (0...visibleRows).compactMap { heights[$0] }
        guard measured.count == visibleRows + 1 else { return Self.fallbackHeight }
        return measured.dropLast().reduce(0, +) + measured[visibleRows] / 2
    }

    /// Rows whose bottom edge lies below what is visible now.
    private func hiddenBelow(viewport: CGFloat) -> Int {
        let visibleBottom = offset + viewport
        var top: CGFloat = 0
        var hidden = 0
        for index in 0..<count {
            let height = heights[index] ?? 0
            if top + height > visibleBottom + 0.5 { hidden += 1 }
            top += height
        }
        return hidden
    }
}
