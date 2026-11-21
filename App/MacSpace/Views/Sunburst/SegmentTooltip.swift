import MacSpaceCore
import SwiftUI

/// Hover card: name, size and share of the current folder, file type, estimated last use, and
/// whether it could be read. Type and age are always in words, whatever the color mode. A folder
/// (or merged "altri") states the age bucket holding most of its bytes and its most recent use;
/// a file, its own last use.
struct SegmentTooltip: View {
    let segment: ArcSegment
    let total: UInt64
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: SunburstView.title(of: segment))
                .font(.callout.weight(.semibold))
                .foregroundStyle(FusionPalette.primaryText(scheme))
                .lineLimit(2)
                .truncationMode(.middle)
            Text(verbatim: "\(Formatters.bytes(segment.size)) · \(Formatters.percent(segment.size, of: total))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(FusionPalette.secondaryText(scheme))
            Group {
                // A merged "altri" segment mixes types: it states no type.
                if segment.node != nil {
                    Text("Tipo: \(String(localized: segment.category.title))")
                }
                if segment.node == nil || segment.hasChildren {
                    Text("Per lo più: \(String(localized: segment.ageBucket.title))")
                    Text("Uso più recente (stimato): \(Formatters.lastUsedDate(segment.lastUsed))")
                } else {
                    Text("Ultimo uso (stimato): \(Formatters.lastUsedDate(segment.lastUsed))")
                }
            }
            .font(.callout)
            .foregroundStyle(FusionPalette.secondaryText(scheme))
            if segment.flags.contains(.unreadable) {
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
