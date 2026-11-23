import MacSpaceCore
import SwiftUI

/// Hover card: name, size and share of the current folder, file type, estimated last use, and
/// whether it could be read. Type and age are always in words, whatever the color mode. A folder
/// (or merged "altri") states the age bucket holding most of its bytes and its most recent use;
/// a file, its own last use. Shared by both charts.
struct SegmentTooltip: View {
    /// What the card describes: a sunburst segment or a treemap tile.
    struct Subject {
        var title: String
        var size: UInt64
        /// A merged "altri" element (`node == nil`).
        var isMerged: Bool
        var hasChildren: Bool
        var category: FileCategory
        var ageBucket: AgeBucket
        var lastUsed: UInt32
        var flags: NodeFlags
    }

    let subject: Subject
    let total: UInt64
    @Environment(\.colorScheme) private var scheme

    init(segment: ArcSegment, total: UInt64) {
        subject = Subject(title: SunburstView.title(of: segment), size: segment.size, isMerged: segment.node == nil,
                          hasChildren: segment.hasChildren, category: segment.category,
                          ageBucket: segment.ageBucket, lastUsed: segment.lastUsed, flags: segment.flags)
        self.total = total
    }

    init(tile: TreemapTile, total: UInt64) {
        subject = Subject(title: TreemapView.title(of: tile), size: tile.size, isMerged: tile.node == nil,
                          hasChildren: tile.hasChildren, category: tile.category, ageBucket: tile.ageBucket,
                          lastUsed: tile.lastUsed, flags: tile.flags)
        self.total = total
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: subject.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(FusionPalette.primaryText(scheme))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(verbatim: "\(Formatters.bytes(subject.size)) · \(Formatters.percent(subject.size, of: total))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(FusionPalette.secondaryText(scheme))
            Group {
                // A merged "altri" element mixes types: it states no type.
                if !subject.isMerged {
                    Text("Tipo: \(String(localized: subject.category.title))")
                }
                if subject.isMerged || subject.hasChildren {
                    Text("Per lo più: \(String(localized: subject.ageBucket.title))")
                    Text("Uso più recente (stimato): \(Formatters.lastUsedDate(subject.lastUsed))")
                } else {
                    Text("Ultimo uso (stimato): \(Formatters.lastUsedDate(subject.lastUsed))")
                }
            }
            .font(.callout)
            .foregroundStyle(FusionPalette.secondaryText(scheme))
            if subject.flags.contains(.unreadable) {
                Label("Non leggibile", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(FusionPalette.tooltipFill(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}
