import MacSpaceCore
import SwiftUI

/// What the chart colors mean, under the chart. By file type: one chip per category present in
/// the current folder, largest first, with how much it takes. By last use: the six age buckets
/// in order. Hidden in neutral mode and before a scan.
struct ChartLegend: View {
    let model: ScanModel
    let mode: ColorMode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if mode != .neutral, !model.breadcrumb.isEmpty {
            LegendFlow(horizontalSpacing: 16, verticalSpacing: 6) {
                switch mode {
                case .category:
                    ForEach(categories, id: \.category) { entry in
                        LegendChip(color: FusionPalette.swatch(entry.category, scheme: scheme),
                                   title: entry.category.title, detail: Formatters.bytes(entry.bytes))
                    }
                case .lastUse:
                    ForEach(AgeBucket.allCases, id: \.self) { bucket in
                        LegendChip(color: FusionPalette.swatch(bucket, scheme: scheme), title: bucket.title,
                                   detail: nil)
                    }
                case .neutral:
                    EmptyView()
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    /// Categories below the current folder by size, descending (ties in a fixed order).
    private var categories: [(category: FileCategory, bytes: UInt64)] {
        model.categoryTotals.map { ($0.key, $0.value) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rawValue < $1.0.rawValue }
    }
}

/// A color dot, its meaning and an optional figure.
private struct LegendChip: View {
    let color: Color
    let title: LocalizedStringResource
    let detail: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(FusionPalette.swatchRing(scheme), lineWidth: 0.5))
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(FusionPalette.primaryText(scheme))
            if let detail {
                Text(verbatim: detail)
                    .monospacedDigit()
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
            }
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Lays chips out in centered rows, wrapping when the next one does not fit.
private struct LegendFlow: Layout {
    let horizontalSpacing: Double
    let verticalSpacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + verticalSpacing * Double(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width = 0.0
        var height = 0.0
    }

    private func rows(width: Double, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + horizontalSpacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + horizontalSpacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
