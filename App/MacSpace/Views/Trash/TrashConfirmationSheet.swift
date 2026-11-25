import MacSpaceCore
import SwiftUI

/// The Trash sheet: the confirmation while `pendingTrash` is set, then the result in its place.
struct TrashSheet: View {
    let model: ScanModel

    var body: some View {
        Group {
            if let report = model.trashReport {
                TrashResultView(report: report) { model.trashReport = nil }
            } else if let ids = model.pendingTrash {
                TrashConfirmationSheet(model: model, requested: ids)
                    .id(ids)  // a new request starts afresh
            }
        }
        .frame(width: 560)
    }
}

/// "Spostare <N> elementi nel Cestino?" (spec §5.6): the items, each with its level and, for those
/// to look at first, why; what moving them frees; and the move itself. On appear, off the main
/// actor, it reads the open files (open items are left out) and estimates each item's private size.
/// Nothing moves here: `ScanModel.trash` hands the items to the store, which checks them again.
struct TrashConfirmationSheet: View {
    let model: ScanModel
    /// What "Sposta nel Cestino…" asked for; resolved again when the sheet opens.
    let requested: [NodeID]
    @Environment(\.colorScheme) private var scheme

    /// The items still allowed, largest first; nil until resolved.
    @State private var candidates: [TrashCandidate]?
    @State private var openCheck = OpenCheck.running
    /// `PrivateSize.freed` of each item, as each estimate finishes.
    @State private var freed: [NodeID: UInt64] = [:]
    @State private var moving = false
    /// Resolving, the open-files check and the estimates; cancelled when the sheet closes or moves.
    @State private var work: Task<Void, Never>?
    /// `ScanModel.storeGeneration` when the items were resolved.
    @State private var generation: Int?

    enum OpenCheck: Equatable {
        case running
        /// The items open right now.
        case done(Set<NodeID>)
        /// The list of open files could not be read in full.
        case incomplete
    }

    /// Estimates run at most this many at a time (each walks a folder on disk).
    static let estimateWidth = 4
    /// More rows than this scroll.
    static let visibleRows = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let candidates {
                if candidates.isEmpty { nothingLeft } else { confirmation(candidates) }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .interactiveDismissDisabled(moving)
        .onAppear {
            guard work == nil else { return }
            work = Task { await prepare() }
        }
        .onDisappear { work?.cancel() }
    }

    // MARK: Content

    private func confirmation(_ candidates: [TrashCandidate]) -> some View {
        let included = included(of: candidates)
        return VStack(alignment: .leading, spacing: 0) {
            header(count: included.count)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 14)
            Divider()
            rows(candidates)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                freedSummary(included)
                status
                buttons(included)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "trash")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(FusionPalette.secondaryText(scheme))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Spostare \(count) elementi nel Cestino?")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FusionPalette.primaryText(scheme))
                    .accessibilityAddTraits(.isHeader)
                Text("Potrai ripristinarli dal Cestino del Finder.")
                    .font(.callout)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func rows(_ candidates: [TrashCandidate]) -> some View {
        let list = VStack(spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                if index > 0 { Divider().padding(.leading, 46) }
                TrashCandidateRow(candidate: candidate, isOpen: openIDs.contains(candidate.id),
                                  freed: freed[candidate.id])
            }
        }
        .padding(.vertical, 4)
        if candidates.count > Self.visibleRows {
            ScrollView { list }.frame(height: 330)
        } else {
            list
        }
    }

    /// "Spazio liberato: circa <X>" over the items that will move ("Calcolo…" until every estimate
    /// is in), and what they take when that is more (clones and hard links share their space).
    private func freedSummary(_ included: [TrashCandidate]) -> some View {
        let size = included.reduce(UInt64(0)) { $0 + $1.size }
        let estimates = included.map { freed[$0.id] }
        let total: UInt64? = estimates.contains(nil) ? nil : estimates.reduce(UInt64(0)) { $0 + ($1 ?? 0) }
        return VStack(alignment: .leading, spacing: 3) {
            if let total {
                Text("Spazio liberato: circa \(Formatters.bytes(total))")
                    .font(.headline)
                    .foregroundStyle(FusionPalette.primaryText(scheme))
                if Self.isShared(freed: total, size: size) {
                    Text("\(Formatters.bytes(size)) occupati, parte condivisa con altre copie")
                        .font(.callout)
                        .foregroundStyle(FusionPalette.secondaryText(scheme))
                }
            } else {
                HStack(spacing: 6) {
                    Text("Spazio liberato:")
                        .foregroundStyle(FusionPalette.primaryText(scheme))
                    Text("Calcolo…")
                        .foregroundStyle(FusionPalette.secondaryText(scheme))
                }
                .font(.headline)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    /// Why the move button waits, or what is happening: a spinner or a warning, in words.
    @ViewBuilder
    private var status: some View {
        if moving {
            statusLine("Spostamento nel Cestino…", warning: false, spinner: true)
        } else if let reason = model.trashUnavailableReason {
            statusLine(reason, warning: false, spinner: true)
        } else {
            switch openCheck {
            case .running: statusLine("Controllo dei file aperti…", warning: false, spinner: true)
            case .incomplete: statusLine("Impossibile verificare i file aperti", warning: true, spinner: false)
            case let .done(open) where !open.isEmpty:
                statusLine("Gli elementi aperti in un'app restano dove sono.", warning: false, spinner: false)
            case .done: EmptyView()
            }
        }
    }

    private func statusLine(_ text: LocalizedStringResource, warning: Bool, spinner: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if spinner {
                ProgressView().controlSize(.mini).alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            } else {
                Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(warning ? FusionPalette.primaryText(scheme) : FusionPalette.secondaryText(scheme))
                    .accessibilityHidden(true)
            }
            Text(text)
                .foregroundStyle(warning ? FusionPalette.primaryText(scheme) : FusionPalette.secondaryText(scheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }

    private func buttons(_ included: [TrashCandidate]) -> some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Button("Annulla") { model.pendingTrash = nil }
                .keyboardShortcut(.cancelAction)
                .disabled(moving)
            // Destructive, and deliberately not the default action: Return must not move anything.
            Button("Sposta nel Cestino", role: .destructive) { move(included) }
                .disabled(!canMove(included))
        }
        .controlSize(.large)
    }

    /// Every item that was asked for is gone, or now protected.
    private var nothingLeft: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Niente da spostare")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FusionPalette.primaryText(scheme))
                Text("Gli elementi scelti non ci sono più o ora sono protetti.")
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("OK") { model.pendingTrash = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
    }

    // MARK: State

    private var openIDs: Set<NodeID> {
        if case let .done(open) = openCheck { return open }
        return []
    }

    /// The items that will move: all but those open right now.
    private func included(of candidates: [TrashCandidate]) -> [TrashCandidate] {
        let open = openIDs
        return open.isEmpty ? candidates : candidates.filter { !open.contains($0.id) }
    }

    /// Only once the open files are known in full, with something left to move, the Trash available
    /// and no move running.
    private func canMove(_ included: [TrashCandidate]) -> Bool {
        guard !moving, !included.isEmpty, model.trashUnavailableReason == nil, !model.isTrashing else { return false }
        if case .done = openCheck { return true }
        return false
    }

    /// Whether `freed` is visibly less than `size`, as the sizes read on screen.
    static func isShared(freed: UInt64, size: UInt64) -> Bool {
        freed < size && Formatters.bytes(freed) != Formatters.bytes(size)
    }

    /// Resolves the items again, then reads the open files and estimates each item, side by side.
    private func prepare() async {
        generation = model.storeGeneration
        let found = await model.trashCandidates(requested)
        guard !Task.isCancelled else { return }
        candidates = found
        guard !found.isEmpty else { return }
        await withTaskGroup(of: Check.self) { group in
            group.addTask { .open(await Self.openFiles()) }
            var queue = found.makeIterator()
            for _ in 0..<Self.estimateWidth {
                guard let next = queue.next() else { break }
                group.addTask { .freed(next.id, await Self.estimate(next.path)) }
            }
            for await check in group {
                // A cancelled estimate returns a partial sum: never shown.
                guard !Task.isCancelled else { break }
                switch check {
                case let .open(set):
                    openCheck = set.isComplete ? .done(Set(found.filter { Self.isOpen($0, in: set) }.map(\.id))) : .incomplete
                case let .freed(id, bytes):
                    freed[id] = bytes
                    if let next = queue.next() {
                        group.addTask { .freed(next.id, await Self.estimate(next.path)) }
                    }
                }
            }
            group.cancelAll()
        }
    }

    private enum Check: Sendable {
        case open(OpenFileSet)
        case freed(NodeID, UInt64)
    }

    private static func isOpen(_ candidate: TrashCandidate, in set: OpenFileSet) -> Bool {
        set.isOpen(candidate.path) || (candidate.kind == .directory && set.hasOpen(under: candidate.path))
    }

    @concurrent nonisolated private static func openFiles() async -> OpenFileSet { OpenFileSet.current() }

    @concurrent nonisolated static func estimate(_ path: String) async -> UInt64 { PrivateSize.freed(path: path) }

    /// Hands what will move to `ScanModel.trash`, then shows the result in place of the confirmation.
    /// The estimates still running stop; the result estimates those items where they are in the Trash.
    private func move(_ included: [TrashCandidate]) {
        guard canMove(included), let candidates, generation == model.storeGeneration else { return }
        moving = true
        work?.cancel()
        let ids = included.map(\.id)
        let known = freed
        let leftOut = candidates.filter { openIDs.contains($0.id) }
            .map { TrashOutcome.Skipped(node: $0.id, name: $0.name, reason: .openNow) }
        Task {
            let outcome = await model.trash(ids)
            let moved = Set(outcome.moved.map(\.node))
            model.trashReport = TrashReport(moved: outcome.moved, skipped: outcome.skipped + leftOut,
                                            freed: known.filter { moved.contains($0.key) })
            model.pendingTrash = nil
        }
    }
}

/// One item: level marker, name, folder, size, and why it needs a look (caution, cloud) or why it
/// stays (open now).
private struct TrashCandidateRow: View {
    let candidate: TrashCandidate
    let isOpen: Bool
    /// Its estimate, once known.
    let freed: UInt64?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            SafetySwatch(level: candidate.verdict.level, diameter: 9)
                .frame(width: 10)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .opacity(isOpen ? Self.dimmed : 1)
            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: candidate.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(FusionPalette.primaryText(scheme))
                        Spacer(minLength: 8)
                        Text(verbatim: Formatters.bytes(candidate.size))
                            .monospacedDigit()
                            .foregroundStyle(FusionPalette.primaryText(scheme))
                            .fixedSize()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(verbatim: folder)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let freed, TrashConfirmationSheet.isShared(freed: freed, size: candidate.size) {
                            Text("libera circa \(Formatters.bytes(freed))")
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                }
                .opacity(isOpen ? Self.dimmed : 1)
                if let note {
                    Text(verbatim: note)
                        .font(.callout)
                        .foregroundStyle(notePrimary ? FusionPalette.primaryText(scheme) : FusionPalette.secondaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 24)
        .padding(.vertical, 9)
        .help(Text(verbatim: candidate.path))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: [candidate.name, candidate.verdict.level.spokenTitle].compactMap { $0 }
            .joined(separator: ", ")))
        .accessibilityValue(Text(verbatim: [Formatters.bytes(candidate.size), folder, note].compactMap { $0 }
            .joined(separator: ", ")))
    }

    /// Opacity of an item that stays (open now); its note keeps full contrast.
    static let dimmed = 0.45

    /// A note to read before moving (caution, open now) is in the primary ink; a safe item's is not.
    private var notePrimary: Bool { isOpen || candidate.verdict.level == .caution }

    /// The folder it is in, the home folder as "~".
    private var folder: String {
        ((candidate.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }

    /// "Aperto ora in un'app" when it stays; else the reason to look first (caution, cloud) or, for
    /// a safe item, what it is. Ordinary items have none.
    private var note: String? {
        if isOpen { return String(localized: "Aperto ora in un'app") }
        return candidate.verdict.sentence
    }
}
