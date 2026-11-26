import MacSpaceCore
import SwiftUI

/// Hover card: name, size and share of the current folder, file type, last use, safety level with
/// its reason and owning app, and whether it could be read. Type, age and safety are always in
/// words, whatever the color mode. A folder (or merged "altri") states the age bucket holding most
/// of its bytes and its most recent use; a file, Spotlight's last use when it has one, else the
/// estimate from its timestamps. Merged "altri" mix levels, so they state none. Shared by both charts.
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
        /// The node's safety verdict; nil for merged "altri" (and before the first one arrives).
        var verdict: SafetyVerdict?
        /// Spotlight's last use of a file, when known: shown as a fact, not an estimate.
        var spotlightLastUsed: UInt32?
    }

    let subject: Subject
    let total: UInt64
    @Environment(\.colorScheme) private var scheme

    init(subject: Subject, total: UInt64) {
        self.subject = subject
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
                } else if let date = subject.spotlightLastUsed {
                    Text("Ultimo uso: \(Formatters.lastUsedDate(date))")
                } else {
                    Text("Ultimo uso (stimato): \(Formatters.lastUsedDate(subject.lastUsed))")
                }
            }
            .font(.callout)
            .foregroundStyle(FusionPalette.secondaryText(scheme))
            if let verdict = subject.verdict {
                safety(verdict)
            }
            if subject.flags.contains(.unreadable) {
                Label("Non leggibile", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
            }
        }
        .frame(maxWidth: Self.width, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(FusionPalette.tooltipFill(scheme), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    /// Widest the card gets: long names and reasons wrap inside it.
    static let width = 280.0

    /// The level with its marker, the reason and the owning app, set apart by a little space.
    private func safety(_ verdict: SafetyVerdict) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                // Normal has no mark: no empty slot either, so the line stays flush with the others.
                if verdict.level != .normal { SafetySwatch(level: verdict.level) }
                Text("Sicurezza: \(String(localized: verdict.level.title))")
                    .foregroundStyle(FusionPalette.primaryText(scheme))
            }
            Group {
                if let sentence = verdict.sentence {
                    Text(verbatim: sentence)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let app = verdict.appName {
                    Text("App: \(app)")
                }
            }
            .foregroundStyle(FusionPalette.secondaryText(scheme))
        }
        .font(.callout)
        .padding(.top, 3)
    }
}
