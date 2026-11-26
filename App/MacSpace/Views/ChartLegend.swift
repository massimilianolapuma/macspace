import MacSpaceCore
import SwiftUI

/// What the chart colors mean, in one row under the chart: in "Eliminabili" the three marked levels
/// (safe, caution, protected; normal is the neutral rest); otherwise one chip per category (by file
/// type) or age bucket (by last use) present in the current folder, with how much it takes, plus
/// "Altri (misti)" when the chart shows merged elements. Categories run largest first, buckets in
/// age order.
///
/// The row is always one line, of the same height in every mode, scan state and folder, so the
/// chart never resizes because of the legend. Chips that do not fit the width, from the end, fold
/// into a trailing "+N" chip whose popover lists them; "+N" itself always fits. The fit is measured
/// (`ViewThatFits`): the first candidate, from every chip down to none, whose ideal width fits.
struct ChartLegend: View {
    let model: ScanModel
    let mode: ColorMode
    @Environment(\.colorScheme) private var scheme
    @State private var showsOverflow = false
    /// How many chips the row on screen folds into "+N" (0: none), reported by the chosen candidate.
    @State private var hiddenCount = 0

    /// The levels "Eliminabili" marks; normal elements are the neutral rest of the chart.
    private static let safetyLevels: [SafetyLevel] = [.safe, .caution, .protected]
    private static let spacing: CGFloat = 2 * WindowLayout.gap

    /// One chip's meaning and figure.
    private enum Entry: Hashable {
        case level(SafetyLevel)
        case category(FileCategory, UInt64)
        case age(AgeBucket, UInt64)
        case merged

        /// What the chip stands for, without its figure: stays the same while a scan grows it.
        var key: Key {
            switch self {
            case let .level(level): .level(level)
            case let .category(category, _): .category(category)
            case let .age(bucket, _): .age(bucket)
            case .merged: .merged
            }
        }

        enum Key: Hashable {
            case level(SafetyLevel)
            case category(FileCategory)
            case age(AgeBucket)
            case merged
        }
    }

    /// The popover is about one folder, one mode and one set of folded chips; their sizes may grow
    /// under it while a scan runs.
    private struct OverflowSubject: Equatable {
        let mode: ColorMode
        let center: NodeID
        /// A set: chips swapping places in the fold while a scan grows them change nothing.
        let hidden: Set<Entry.Key>
    }

    var body: some View {
        let entries = entries
        let hidden = Array(entries.suffix(min(hiddenCount, entries.count)))
        ViewThatFits(in: .horizontal) {
            ForEach((0...entries.count).reversed(), id: \.self) { shown in
                HStack(spacing: Self.spacing) {
                    ForEach(entries.prefix(shown), id: \.key) { chip($0) }
                    if shown < entries.count {
                        overflowChip(count: entries.count - shown)
                    }
                }
                .fixedSize()
                .preference(key: HiddenCountKey.self, value: entries.count - shown)
            }
        }
        .onPreferenceChange(HiddenCountKey.self) { count in hiddenCount = count }
        .frame(maxWidth: .infinity)
        .frame(height: WindowLayout.rowHeight)
        // One popover for the row, anchored on whichever "+N" is on screen; its list is always the
        // chips that "+N" folds.
        .overlayPreferenceValue(OverflowAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let rect = proxy[anchor]
                    Color.clear
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                        .popover(isPresented: $showsOverflow, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: WindowLayout.gap) {
                                ForEach(hidden, id: \.key) { chip($0) }
                            }
                            .padding(2 * WindowLayout.gap)
                        }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: OverflowSubject(mode: mode, center: model.center, hidden: Set(hidden.map(\.key)))) {
            if showsOverflow { showsOverflow = false }
        }
    }

    private var entries: [Entry] {
        switch mode {
        case .deletable:
            return Self.safetyLevels.map(Entry.level)
        case .category:
            let categories = model.categoryTotals.map { ($0.key, $0.value) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.rawValue < $1.0.rawValue }
            return categories.map { Entry.category($0.0, $0.1) } + (model.showsMerged ? [.merged] : [])
        case .lastUse:
            // Most recent first, unknown last.
            return AgeBucket.allCases.compactMap { bucket in model.ageTotals[bucket].map { Entry.age(bucket, $0) } }
        }
    }

    @ViewBuilder
    private func chip(_ entry: Entry) -> some View {
        switch entry {
        case let .level(level):
            LegendChip(title: level.title, detail: nil) { SafetySwatch(level: level) }
        case let .category(category, bytes):
            LegendChip(color: FusionPalette.swatch(category, scheme: scheme), title: category.title,
                       detail: Formatters.bytes(bytes))
        case let .age(bucket, bytes):
            LegendChip(color: FusionPalette.swatch(bucket, scheme: scheme), title: bucket.title,
                       detail: Formatters.bytes(bytes))
        case .merged:
            let swatch = FusionPalette.mergedSwatch(scheme: scheme)
            LegendChip(color: swatch.fill, dashedOutline: swatch.outline, title: "Altri (misti)", detail: nil)
        }
    }

    /// "+N": the chips that do not fit; a click lists them in the row's popover.
    private func overflowChip(count: Int) -> some View {
        let words = count == 1 ? String(localized: "Un'altra voce") : String(localized: "Altre \(count) voci")
        return Button { showsOverflow.toggle() } label: {
            Text(verbatim: "+\(count)")
                .font(LegendChip<EmptyView>.font)
                .monospacedDigit()
        }
        .buttonStyle(CrumbButtonStyle())
        .help(Text(verbatim: words))
        .accessibilityLabel(Text(verbatim: words))
        .anchorPreference(key: OverflowAnchorKey.self, value: .bounds) { $0 }
    }
}

/// How many chips the chosen row folds into "+N".
private struct HiddenCountKey: PreferenceKey {
    static let defaultValue = 0
    static func reduce(value: inout Int, nextValue: () -> Int) { value = max(value, nextValue()) }
}

/// Where the "+N" on screen is.
private struct OverflowAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
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
