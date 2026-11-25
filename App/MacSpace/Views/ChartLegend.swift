import MacSpaceCore
import SwiftUI

/// What the chart colors mean, under the chart: in "Eliminabili" the three marked levels (safe,
/// caution, protected; normal is the neutral rest); otherwise one chip per category (by file type)
/// or age bucket (by last use) present in the current folder, with how much it takes, plus "Altri
/// (misti)" when the chart shows merged elements. Categories run largest first, buckets in age
/// order. Empty before a scan.
///
/// Ruling AE: the legend always keeps the room the fullest legend could need at the current
/// width (every category, "Altri (misti)", every bucket, each with the widest figure, in the order
/// that wraps worst, and the safety levels), so a scan, a drill, a mode or chart switch never
/// resizes the chart.
struct ChartLegend: View {
    let model: ScanModel
    let mode: ColorMode
    @Environment(\.colorScheme) private var scheme

    /// Wider than any figure `Formatters.bytes` writes (digits are monospaced).
    private static let widestFigure = "888,88 GB"
    /// The levels "Eliminabili" marks; normal elements are the neutral rest of the chart.
    private static let safetyLevels: [SafetyLevel] = [.safe, .caution, .protected]

    var body: some View {
        LegendFlow(horizontalSpacing: 16, verticalSpacing: 6,
                   reservedGroups: [FileCategory.allCases.count + 1, AgeBucket.allCases.count,
                                    Self.safetyLevels.count]) {
            reserve
            if !model.breadcrumb.isEmpty {
                switch mode {
                case .deletable:
                    ForEach(Self.safetyLevels, id: \.self) { level in
                        LegendChip(title: level.title, detail: nil) { SafetySwatch(level: level) }
                    }
                case .category:
                    ForEach(categories, id: \.category) { entry in
                        LegendChip(color: FusionPalette.swatch(entry.category, scheme: scheme),
                                   title: entry.category.title, detail: Formatters.bytes(entry.bytes))
                    }
                    if model.showsMerged {
                        let swatch = FusionPalette.mergedSwatch(scheme: scheme)
                        LegendChip(color: swatch.fill, dashedOutline: swatch.outline, title: "Altri (misti)",
                                   detail: nil)
                    }
                case .lastUse:
                    ForEach(ages, id: \.bucket) { entry in
                        LegendChip(color: FusionPalette.swatch(entry.bucket, scheme: scheme),
                                   title: entry.bucket.title, detail: Formatters.bytes(entry.bytes))
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The fullest legends, invisible, for `LegendFlow` to measure: every category and "Altri
    /// (misti)", then every age bucket, then the safety levels (`reservedGroups`).
    @ViewBuilder
    private var reserve: some View {
        Group {
            ForEach(FileCategory.allCases, id: \.self) { category in
                LegendChip(color: .clear, title: category.title, detail: Self.widestFigure)
            }
            LegendChip(color: .clear, title: "Altri (misti)", detail: nil)
            ForEach(AgeBucket.allCases, id: \.self) { bucket in
                LegendChip(color: .clear, title: bucket.title, detail: Self.widestFigure)
            }
            ForEach(Self.safetyLevels, id: \.self) { level in
                LegendChip(color: .clear, title: level.title, detail: nil)
            }
        }
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

/// A mark, its meaning and an optional figure. The mark is a color dot (the merged "Altri
/// (misti)" one drawn as merged elements are: its recessive fill inside a dashed outline) or a
/// safety level's marker.
private struct LegendChip<Mark: View>: View {
    static var font: Font { .callout }

    let title: LocalizedStringResource
    let detail: String?
    @ViewBuilder let mark: Mark
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            mark
                .frame(width: LegendDot.size, height: LegendDot.size)
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

extension LegendChip where Mark == LegendDot {
    init(color: Color, dashedOutline: Color? = nil, title: LocalizedStringResource, detail: String?) {
        self.init(title: title, detail: detail) { LegendDot(color: color, dashedOutline: dashedOutline) }
    }
}

/// A legend color dot with a hairline ring, or a dashed outline for "Altri (misti)".
private struct LegendDot: View {
    static let size = 9.0

    let color: Color
    var dashedOutline: Color?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(color)
            .overlay {
                if let dashedOutline {
                    // The line's center runs 0.5 pt inside the dot's edge.
                    Circle().strokeBorder(dashedOutline,
                                          style: MergedOutline.style(perimeter: .pi * (Self.size - 1)))
                } else {
                    Circle().strokeBorder(FusionPalette.swatchRing(scheme), lineWidth: 0.5)
                }
            }
    }
}

/// Lays chips out in centered rows, wrapping when the next one does not fit. The first subviews
/// are the hidden reserve, in groups of `reservedGroups` counts: the height is the most rows any
/// group's chips could need, in any subset and order (`FlowRows.worstCase`), so it depends only
/// on the width. The chips after the reserve are the ones shown.
private struct LegendFlow: Layout {
    let horizontalSpacing: Double
    let verticalSpacing: Double
    let reservedGroups: [Int]

    struct Cache {
        /// Last proposed width and the height reserved for it.
        var width: Double?
        var height = 0.0
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    private var reservedCount: Int { reservedGroups.reduce(0, +) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(width: width, subviews: subviews)
        if cache.width != width {
            cache.width = width
            cache.height = reservedHeight(width: width, subviews: subviews)
        }
        let height = max(cache.height, height(of: rows))  // max() only guards the exact bound
        return CGSize(width: width.isFinite ? width : rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for index in subviews.indices.prefix(reservedCount) {
            subviews[index].place(at: bounds.origin, proposal: .unspecified)
        }
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

    private func height(rows: Int, rowHeight: Double) -> Double {
        rows > 0 ? Double(rows) * rowHeight + verticalSpacing * Double(rows - 1) : 0
    }

    private func height(of rows: [Row]) -> Double {
        rows.map(\.height).reduce(0, +) + verticalSpacing * Double(max(rows.count - 1, 0))
    }

    /// The most rows any reserve group could need at `width`, as a height.
    private func reservedHeight(width: Double, subviews: Subviews) -> Double {
        var start = 0
        var height = 0.0
        for count in reservedGroups {
            let sizes = subviews[start..<start + count].map { $0.sizeThatFits(.unspecified) }
            start += count
            let rows = FlowRows.worstCase(sizes.map { Double($0.width) }, spacing: horizontalSpacing, width: width)
            height = max(height, self.height(rows: rows, rowHeight: Double(sizes.map(\.height).max() ?? 0)))
        }
        return height
    }

    /// The shown chips (after the reserve) in rows, wrapping as `FlowRows.rows` does.
    private func rows(width: Double, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices.dropFirst(reservedCount) {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !row.indices.isEmpty, row.width + horizontalSpacing + size.width > width {
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
