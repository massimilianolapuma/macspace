import MacSpaceCore
import SwiftUI

/// What the chart colors mean, under the chart: one chip per category (by file type) or age
/// bucket (by last use) present in the current folder, with how much it takes. Categories run
/// largest first, buckets in age order. Empty in neutral mode and before a scan.
///
/// The legend always keeps room for two rows, whatever the mode, so switching mode never
/// resizes the chart (it would jump, and every ring label would be refitted).
struct ChartLegend: View {
    let model: ScanModel
    let mode: ColorMode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .top) {
            reservedHeight
            if mode != .neutral, !model.breadcrumb.isEmpty {
                LegendFlow(horizontalSpacing: 16, verticalSpacing: Self.rowSpacing) {
                    switch mode {
                    case .category:
                        ForEach(categories, id: \.category) { entry in
                            LegendChip(color: FusionPalette.swatch(entry.category, scheme: scheme),
                                       title: entry.category.title, detail: Formatters.bytes(entry.bytes))
                        }
                    case .lastUse:
                        ForEach(ages, id: \.bucket) { entry in
                            LegendChip(color: FusionPalette.swatch(entry.bucket, scheme: scheme),
                                       title: entry.bucket.title, detail: Formatters.bytes(entry.bytes))
                        }
                    case .neutral:
                        EmptyView()
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private static let rowSpacing = 6.0

    /// Two rows of chip text, invisible: the room the legend keeps in every mode.
    private var reservedHeight: some View {
        VStack(spacing: Self.rowSpacing) {
            Text(verbatim: "Ag")
            Text(verbatim: "Ag")
        }
        .font(LegendChip.font)
        .hidden()
        .accessibilityHidden(true)
    }

    /// Categories below the current folder by size, descending (ties in a fixed order).
    private var categories: [(category: FileCategory, bytes: UInt64)] {
        model.categoryTotals.map { ($0.key, $0.value) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rawValue < $1.0.rawValue }
    }

    /// Age buckets below the current folder, most recent first, unknown last.
    private var ages: [(bucket: AgeBucket, bytes: UInt64)] {
        AgeBucket.allCases.compactMap { bucket in model.ageTotals[bucket].map { (bucket, $0) } }
    }
}

/// A color dot, its meaning and an optional figure.
private struct LegendChip: View {
    static let font = Font.callout

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
        .font(Self.font)
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
