import MacSpaceCore
import SwiftUI

/// What a move to the Trash did: "<N> elementi spostati nel Cestino · circa <X> da recuperare
/// svuotando il Cestino" ("almeno <X>" when an estimate could not see everything), then what stayed
/// and why. Moving frees nothing until the Trash is emptied: the space is the estimate of what really
/// moved, never the tree sizes; an item moved before its estimate finished is estimated where it now
/// is in the Trash.
struct TrashResultView: View {
    let report: TrashReport
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme

    /// Estimates made here, in the Trash, for moved items the sheet had not finished.
    @State private var trashEstimates: [NodeID: PrivateSize.Estimate] = [:]
    /// Some moved item still has no estimate (only those with a known place in the Trash get one).
    @State private var estimating: Bool

    /// More skipped rows than this scroll.
    static let visibleRows = 5

    init(report: TrashReport, done: @escaping () -> Void) {
        self.report = report
        self.done = done
        _estimating = State(initialValue: report.moved.contains { report.freed[$0.node] == nil && $0.trashedPath != nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, report.skipped.isEmpty ? 20 : 14)
            if !report.skipped.isEmpty {
                Divider()
                skipped
                Divider()
            }
            HStack {
                Spacer()
                Button("Fine", action: done)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.top, report.skipped.isEmpty ? 0 : 14)
            .padding(.bottom, 20)
        }
        .task { await estimateInTrash() }
    }

    private var header: some View {
        SheetHeader(systemImage: report.moved.isEmpty ? "exclamationmark.triangle" : "checkmark") {
            if report.moved.isEmpty {
                Text("Nessun elemento spostato nel Cestino")
            } else {
                summary
            }
        } detail: {
            if !report.moved.isEmpty {
                RestoreFootnote(count: report.moved.count)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "<N> elementi spostati nel Cestino · circa <X> da recuperare svuotando il Cestino" ("almeno
    /// <X>" when partial, "Calcolo…" while estimating).
    private var summary: some View {
        // One line while it fits; else the space freed goes under the count, never truncated.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                movedCount
                Text(verbatim: "·").accessibilityHidden(true)
                freedText
            }
            VStack(alignment: .leading, spacing: 2) {
                movedCount
                freedText
            }
        }
        .monospacedDigit()
    }

    private var movedCount: some View {
        Text("\(report.moved.count) elementi spostati nel Cestino").fixedSize()
    }

    @ViewBuilder
    private var freedText: some View {
        if let freed = freedTotal {
            let bytes = Formatters.bytes(freed.bytes)
            (freed.isPartial ? Text("almeno \(bytes) da recuperare svuotando il Cestino")
                : Text("circa \(bytes) da recuperare svuotando il Cestino")).fixedSize()
        } else {
            Text("Calcolo…").foregroundStyle(FusionPalette.secondaryText(scheme))
        }
    }

    private var skipped: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Non spostati")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FusionPalette.secondaryText(scheme))
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ScrollCueList(count: report.skipped.count, visibleRows: Self.visibleRows) { index in
                let item = report.skipped[index]
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(FusionPalette.primaryText(scheme))
                    Text(verbatim: item.reason)
                        .font(.callout)
                        .foregroundStyle(FusionPalette.secondaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.bottom, 8)
    }

    /// The sum of the estimates of the moved items, partial when any is; nil while some are still
    /// being estimated. An item with no estimate and no known place in the Trash counts nothing, and
    /// makes the sum partial.
    private var freedTotal: PrivateSize.Estimate? {
        if estimating { return nil }
        return .sum(report.moved.map {
            report.freed[$0.node] ?? trashEstimates[$0.node] ?? PrivateSize.Estimate(bytes: 0, isPartial: true)
        })
    }

    /// Estimates, where they now are in the Trash, the moved items the sheet had not finished;
    /// cancelled when the sheet closes.
    private func estimateInTrash() async {
        let missing = report.moved.filter { report.freed[$0.node] == nil }
        for item in missing {
            guard let path = item.trashedPath else { continue }
            let estimate = await TrashConfirmationSheet.estimate(path)
            guard !Task.isCancelled else { return }
            trashEstimates[item.node] = estimate
        }
        estimating = false
    }
}
