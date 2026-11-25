import AppKit
import SwiftUI

/// "Cronologia": what was moved to the Trash in this session, newest first, each with "Mostra nel
/// Cestino" while it is still there (spec §5.6).
struct HistoryPopover: View {
    let entries: [HistoryEntry]
    @Environment(\.colorScheme) private var scheme
    /// Entries whose item is still at its place in the Trash, checked when the popover opens.
    @State private var inTrash: Set<UUID> = []

    /// More rows than this scroll.
    static let visibleRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Spostati nel Cestino")
                    .font(.headline)
                    .foregroundStyle(FusionPalette.primaryText(scheme))
                    .accessibilityAddTraits(.isHeader)
                Text("In questa sessione")
                    .font(.caption)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Divider()
            ScrollCueList(count: entries.count, visibleRows: Self.visibleRows) { index in
                VStack(spacing: 0) {
                    if index > 0 { Divider().padding(.leading, 16) }
                    HistoryRow(entry: entries[index], inTrash: inTrash.contains(entries[index].id))
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 360)
        .onAppear {
            inTrash = Set(entries.filter { entry in
                entry.trashedURL.map { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) } ?? false
            }.map(\.id))
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let inTrash: Bool
    @Environment(\.colorScheme) private var scheme

    private static let time = Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "it_IT"))

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(FusionPalette.primaryText(scheme))
                HStack(spacing: 4) {
                    Text(verbatim: Formatters.bytes(entry.size))
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text(verbatim: entry.date.formatted(Self.time))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(FusionPalette.secondaryText(scheme))
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let url = entry.trashedURL {
                if inTrash {
                    Button("Mostra nel Cestino") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .controlSize(.small)
                        // Every row has one: VoiceOver says which item it shows.
                        .accessibilityLabel(Text("Mostra \(entry.name) nel Cestino"))
                } else {
                    Text("Non più nel Cestino")
                        .font(.caption)
                        .foregroundStyle(FusionPalette.secondaryText(scheme))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
