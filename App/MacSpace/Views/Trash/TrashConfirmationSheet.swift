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
/// to look at first, why; the space emptying the Trash would then recover; and the move itself. On
/// appear, off the main actor, it reads the open files (open items are left out) and estimates each
/// item's private size.
/// The rows follow the store: after an environment update they are read again (changed ones say
/// "Aggiornato"), and right before moving too, so nothing moves with a verdict the user did not see.
/// Nothing moves here: `ScanModel.trash` hands the items to the store, which checks them again.
struct TrashConfirmationSheet: View {
    let model: ScanModel
    /// What "Sposta nel Cestino…" asked for; resolved again when the sheet opens.
    let requested: [NodeID]
    @Environment(\.colorScheme) private var scheme

    /// The rows, largest first, with the verdicts on show; nil until resolved.
    @State private var candidates: [TrashCandidate]?
    /// Rows the store no longer allows (now protected, gone): shown, dimmed, never moved.
    @State private var withdrawn: [NodeID: String] = [:]
    /// Refreshes of the rows running now; the move waits for them.
    @State private var refreshing = 0
    /// Rows whose verdict changed while the sheet was open.
    @State private var updated: Set<NodeID> = []
    @State private var openCheck = OpenCheck.running
    /// `PrivateSize.freed` of each item, as each estimate finishes.
    @State private var freed: [NodeID: PrivateSize.Estimate] = [:]
    @State private var moving = false
    /// The move has run for `slowMoveDelay`: checking what a folder holds now can take a while, so
    /// the status says so instead of looking stuck.
    @State private var movingSlowly = false
    /// `ScanModel.trashUnavailableReason` has lasted `unavailableGrace`: only then the status says
    /// it. A brief re-judging (an app launched or quit) only holds the move button, so the sheet
    /// does not jump.
    @State private var unavailableShown = false
    /// A move was stopped because the rows had changed: they were refreshed for another look.
    @State private var changedBeforeMove = false
    /// Resolving, the open-files check and the estimates; cancelled when the sheet closes or moves.
    @State private var work: Task<Void, Never>?
    /// `ScanModel.storeGeneration` when the items were resolved.
    @State private var generation: Int?
    /// Keyboard focus starts on "Annulla", so Space (Full Keyboard Access) cannot move anything.
    @FocusState private var focus: FocusTarget?

    enum OpenCheck: Equatable {
        case running
        /// The items open right now, with who holds them, in words (`OpenUse.text`, read once).
        case done([NodeID: String])
        /// The list of open files could not be read in full.
        case incomplete
    }

    enum FocusTarget: Hashable {
        case cancel
    }

    static let unavailableGrace: Duration = .seconds(1)
    /// How long a move runs before the status says contents are being checked.
    static let slowMoveDelay: Duration = .milliseconds(500)

    /// Estimates run at most this many at a time (each walks a folder on disk).
    static let estimateWidth = 4

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
        .defaultFocus($focus, .cancel)
        .interactiveDismissDisabled(moving)
        .onAppear {
            guard work == nil else { return }
            work = Task { await prepare() }
        }
        .onDisappear { work?.cancel() }
        .task(id: moving) {
            guard moving else { movingSlowly = false; return }
            try? await Task.sleep(for: Self.slowMoveDelay)
            if !Task.isCancelled, moving { movingSlowly = true }
        }
        .task(id: model.trashUnavailableReason == nil) {
            guard model.trashUnavailableReason != nil else { unavailableShown = false; return }
            try? await Task.sleep(for: Self.unavailableGrace)
            if !Task.isCancelled { unavailableShown = true }
        }
        .onChange(of: model.verdictRevision) {
            // An environment update landed (an app launched or quit…): show what the store says now.
            guard !moving, let candidates, !candidates.isEmpty else { return }
            Task { _ = await refreshRows() }
        }
    }

    // MARK: Content

    private func confirmation(_ candidates: [TrashCandidate]) -> some View {
        let included = included(of: candidates)
        return VStack(alignment: .leading, spacing: 0) {
            header(count: included.count, restorable: openCheck == .running ? candidates.count : included.count)
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 14)
            Divider()
            ScrollCueList(count: candidates.count) { index in
                let candidate = candidates[index]
                VStack(spacing: 0) {
                    if index > 0 { Divider().padding(.leading, 46) }
                    TrashCandidateRow(candidate: candidate, stays: staysNote(candidate),
                                      isWithdrawn: withdrawn[candidate.id] != nil,
                                      isUpdated: updated.contains(candidate.id),
                                      freed: freed[candidate.id].flatMap { $0.isPartial ? nil : $0.bytes })
                }
            }
            .padding(.vertical, 4)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                if !included.isEmpty { freedSummary(included) }
                status
                buttons(included)
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
    }

    /// The question, with the count once the open files are known (it would otherwise drop as they
    /// are left out), and how to undo; "Niente da spostare" when every row stays.
    private func header(count: Int, restorable: Int) -> some View {
        let nothingMoves = openCheck != .running && count == 0
        return SheetHeader(systemImage: nothingMoves ? "trash.slash" : "trash") {
            if openCheck == .running {
                HStack(spacing: 8) {
                    Text("Controllo dei file aperti…")
                    ProgressView().controlSize(.small)
                }
            } else if nothingMoves {
                Text("Niente da spostare")
            } else {
                Text("Spostare \(count) elementi nel Cestino?")
            }
        } detail: {
            if nothingMoves {
                Text("Gli elementi in grigio restano dove sono.")
            } else {
                RestoreFootnote(count: restorable)
            }
        }
    }

    /// "Spazio recuperabile svuotando il Cestino: circa <X>" over the items that will move ("almeno
    /// <X>" when an estimate could not see everything, "Calcolo…" until every estimate is in): moving
    /// to the Trash frees nothing by itself. When every estimate is complete, also what the items
    /// take when that is more (clones and hard links share their space).
    private func freedSummary(_ included: [TrashCandidate]) -> some View {
        let size = included.reduce(UInt64(0)) { $0 + $1.size }
        let estimates = included.map { freed[$0.id] }
        let total: PrivateSize.Estimate? = estimates.contains(nil) ? nil : .sum(estimates.compactMap { $0 })
        return VStack(alignment: .leading, spacing: 3) {
            if let total {
                let bytes = Formatters.bytes(total.bytes)
                (total.isPartial ? Text("Spazio recuperabile svuotando il Cestino: almeno \(bytes)")
                    : Text("Spazio recuperabile svuotando il Cestino: circa \(bytes)"))
                    .font(.headline)
                    .foregroundStyle(FusionPalette.primaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
                if !total.isPartial, Self.isShared(freed: total.bytes, size: size) {
                    Text("\(Formatters.bytes(size)) occupati: parte dello spazio è condivisa con copie APFS, la stima è per difetto")
                        .font(.callout)
                        .foregroundStyle(FusionPalette.secondaryText(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 6) {
                    Text("Spazio recuperabile svuotando il Cestino:")
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
        if moving, movingSlowly {
            statusLine("Verifica dei contenuti e spostamento…", warning: false, spinner: true)
        } else if moving {
            statusLine("Spostamento nel Cestino…", warning: false, spinner: true)
        } else if changedBeforeMove {
            statusLine("La situazione è cambiata: controlla di nuovo l'elenco", warning: true, spinner: false)
        } else if unavailableShown, let reason = model.trashUnavailableReason {
            statusLine(reason, warning: false, spinner: true)
        } else {
            switch openCheck {
            case .running: EmptyView()  // said in the title
            case .incomplete: statusLine("Impossibile verificare i file aperti", warning: true, spinner: false)
            case let .done(open):
                // Unless the header already says it (nothing moves).
                if !open.isEmpty || !withdrawn.isEmpty, candidates.map(included(of:))?.isEmpty == false {
                    statusLine("Gli elementi in grigio restano dove sono.", warning: false, spinner: false)
                }
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
                .focused($focus, equals: .cancel)
                .disabled(moving)
            // Destructive, and deliberately not the default action: Return must not move anything.
            Button("Sposta nel Cestino", role: .destructive) { move() }
                .disabled(!canMove(included))
        }
        .controlSize(.large)
    }

    /// Every item that was asked for is gone, or now protected.
    private var nothingLeft: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(systemImage: "trash.slash") {
                Text("Niente da spostare")
            } detail: {
                Text("Gli elementi scelti non ci sono più o ora sono protetti.")
            }
            HStack {
                Spacer()
                Button("OK") { model.pendingTrash = nil }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 20)
    }

    // MARK: State

    private var openNotes: [NodeID: String] {
        if case let .done(open) = openCheck { return open }
        return [:]
    }

    /// Why a row stays where it is (open now, or no longer allowed), or nil when it will move.
    private func staysNote(_ candidate: TrashCandidate) -> String? {
        if let note = withdrawn[candidate.id] { return note }
        if let note = openNotes[candidate.id] { return note }
        return nil
    }

    /// The items that will move: all but those open right now or withdrawn.
    private func included(of candidates: [TrashCandidate]) -> [TrashCandidate] {
        let open = openNotes
        return candidates.filter { open[$0.id] == nil && withdrawn[$0.id] == nil }
    }

    /// Only once the open files are known in full, with something left to move, the Trash available
    /// and no move running.
    private func canMove(_ included: [TrashCandidate]) -> Bool {
        guard !moving, refreshing == 0, !included.isEmpty, model.trashUnavailableReason == nil, !model.isTrashing else {
            return false
        }
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
                    openCheck = set.isComplete ? .done(Self.openNotes(of: found, in: set)) : .incomplete
                case let .freed(id, estimate):
                    freed[id] = estimate
                    if let next = queue.next() {
                        group.addTask { .freed(next.id, await Self.estimate(next.path)) }
                    }
                }
            }
            group.cancelAll()
        }
    }

    /// Reads the rows' verdicts again, afresh, and shows what changed, in place (`apply`). The move
    /// button stays disabled while a refresh runs. Returns whether anything changed.
    private func refreshRows() async -> Bool {
        guard let shown = candidates else { return false }
        refreshing += 1
        defer { refreshing -= 1 }
        let current = await model.trashVerdicts(shown.map(\.id))
        guard generation == model.storeGeneration else { return false }
        return apply(current)
    }

    /// Puts `current` on screen: a new verdict marks its row "Aggiornato"; a row the store no longer
    /// allows is withdrawn, with why (gone, now protected, or no longer selectable) and its new
    /// marker. Returns whether anything changed.
    @discardableResult
    private func apply(_ current: TrashVerdicts) -> Bool {
        guard var rows = candidates else { return false }
        var changed = false
        for index in rows.indices {
            let id = rows[index].id
            guard withdrawn[id] == nil else { continue }
            let verdict = current.verdicts[id]
            if let verdict, verdict != rows[index].verdict {
                rows[index].verdict = verdict
                updated.insert(id)
                changed = true
            }
            if !current.allowed.contains(id) {
                withdrawn[id] = Self.withdrawalNote(verdict: verdict, removed: current.removed.contains(id))
                changed = true
            }
        }
        if changed { candidates = rows }
        return changed
    }

    /// Why a row may no longer move, in words.
    private static func withdrawalNote(verdict: SafetyVerdict?, removed: Bool) -> String {
        if removed || verdict == nil { return TrashSkip.missing.text }
        if let verdict, verdict.level == .protected { return TrashSkip.protected(verdict.reason).text }
        return String(localized: "Non più selezionabile")
    }

    private enum Check: Sendable {
        case open(OpenFileSet)
        case freed(NodeID, PrivateSize.Estimate)
    }

    /// The candidates open right now (a folder: or anything inside it), with who holds them.
    private static func openNotes(of candidates: [TrashCandidate], in set: OpenFileSet) -> [NodeID: String] {
        var notes: [NodeID: String] = [:]
        for candidate in candidates {
            notes[candidate.id] = set.use(of: candidate.path, isDirectory: candidate.kind == .directory)?.text
        }
        return notes
    }

    /// MacSpace's own descriptors (the estimates running beside it) are left out.
    @concurrent nonisolated private static func openFiles() async -> OpenFileSet {
        OpenFileSet.current(excludingOwnProcess: true)
    }

    @concurrent nonisolated static func estimate(_ path: String) async -> PrivateSize.Estimate {
        PrivateSize.freed(path: path)
    }

    /// What was on screen when "Sposta nel Cestino" was pressed.
    private struct Shown {
        let verdicts: [NodeID: SafetyVerdict]
        let withdrawn: Set<NodeID>
        /// The rows that were to move, in order.
        let included: [TrashCandidate]
    }

    /// Moves exactly what was on screen at the click, with the verdicts shown then. The rows are read
    /// again afresh first: if any row's verdict or availability differs from that snapshot (an
    /// environment update, a folder turned read-only…), nothing moves, the rows are refreshed and
    /// the user is asked to look again. Otherwise the snapshot's rows and verdicts go to
    /// `ScanModel.trash` (the store skips an item whose fresh verdict is not that one: level, reason
    /// or owner), and the result
    /// replaces the confirmation. The estimates still running stop; the result estimates those items
    /// where they are in the Trash.
    private func move() {
        // Snapshot before anything else can change the rows.
        guard let rows = candidates, canMove(included(of: rows)), generation == model.storeGeneration else { return }
        let shown = Shown(verdicts: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.verdict) }),
                          withdrawn: Set(withdrawn.keys), included: included(of: rows))
        let open = openNotes
        moving = true
        changedBeforeMove = false
        Task {
            refreshing += 1
            let current = await model.trashVerdicts(rows.map(\.id))
            refreshing -= 1
            guard generation == model.storeGeneration else {
                moving = false
                return
            }
            let differs = rows.contains { row in
                guard !shown.withdrawn.contains(row.id) else { return false }
                return !current.allowed.contains(row.id) || current.verdicts[row.id] != shown.verdicts[row.id]
            }
            if differs {
                apply(current)
                moving = false
                changedBeforeMove = true
                return
            }
            work?.cancel()
            let ids = shown.included.map(\.id)
            let expected = Dictionary(uniqueKeysWithValues: shown.included.map { ($0.id, $0.verdict) })
            let known = freed
            let leftOut = rows.compactMap { row -> SkippedItem? in
                if let note = withdrawn[row.id] { return SkippedItem(node: row.id, name: row.name, reason: note) }
                if let note = open[row.id] { return SkippedItem(node: row.id, name: row.name, reason: note) }
                return nil
            }
            let outcome = await model.trash(ids, expectedVerdicts: expected)
            let moved = Set(outcome.moved.map(\.node))
            let skipped = outcome.skipped.map { SkippedItem(node: $0.node, name: $0.name, reason: $0.reason.text) }
            model.trashReport = TrashReport(moved: outcome.moved, skipped: skipped + leftOut,
                                            freed: known.filter { moved.contains($0.key) })
            model.pendingTrash = nil
        }
    }
}

/// "Potrai ripristinarlo/ripristinarli dal Cestino del Finder.": two strings, since the number
/// is not in the sentence (a catalog plural must show it).
struct RestoreFootnote: View {
    let count: Int

    var body: some View {
        if count == 1 {
            Text("Potrai ripristinarlo dal Cestino del Finder.")
        } else {
            Text("Potrai ripristinarli dal Cestino del Finder.")
        }
    }
}

/// The sheets' header: a neutral glyph in a circle, a title and one line under it.
struct SheetHeader<Title: View, Detail: View>: View {
    let systemImage: String
    @ViewBuilder let title: () -> Title
    @ViewBuilder let detail: () -> Detail
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(FusionPalette.secondaryText(scheme))
                .frame(width: 44, height: 44)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                title()
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(FusionPalette.primaryText(scheme))
                    .accessibilityAddTraits(.isHeader)
                detail()
                    .font(.callout)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }
}

/// One item: level marker, name, folder, size, and why it needs a look (caution, cloud) or why it
/// stays (open now, no longer allowed). "Aggiornato" when its verdict changed while on screen.
private struct TrashCandidateRow: View {
    let candidate: TrashCandidate
    /// Why it stays where it is; nil when it will move.
    let stays: String?
    /// The store no longer allows it: its marker shows its state now, not the old level.
    let isWithdrawn: Bool
    let isUpdated: Bool
    /// Its estimate, once known and complete ("recuperabili circa <X>"); a partial one only counts
    /// towards the total, as "almeno".
    let freed: UInt64?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            levelMarker
                .frame(width: 10)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                .opacity(stays != nil ? Self.dimmed : 1)
            VStack(alignment: .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: candidate.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(FusionPalette.primaryText(scheme))
                        if isUpdated { updatedBadge }
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
                            Text("recuperabili circa \(Formatters.bytes(freed))")
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                }
                .opacity(stays != nil ? Self.dimmed : 1)
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
        .accessibilityLabel(Text(verbatim: [candidate.name, spokenLevel,
                                            isUpdated ? String(localized: "Aggiornato") : nil]
            .compactMap { $0 }.joined(separator: ", ")))
        .accessibilityValue(Text(verbatim: [Formatters.bytes(candidate.size), folder, note].compactMap { $0 }
            .joined(separator: ", ")))
    }

    /// The level as VoiceOver says it: the same state the marker shows, so a withdrawn row that is
    /// not now protected (gone, no longer selectable) speaks no level; its note says why it stays.
    private var spokenLevel: String? {
        isWithdrawn && candidate.verdict.level != .protected ? nil : candidate.verdict.level.spokenTitle
    }

    /// The level's swatch; a hollow ring for an ordinary item, or a withdrawn one that is not now
    /// protected (gone, no longer selectable), so every row has a marker in the column.
    @ViewBuilder
    private var levelMarker: some View {
        if candidate.verdict.level == .normal || (isWithdrawn && candidate.verdict.level != .protected) {
            Circle()
                .strokeBorder(FusionPalette.secondaryText(scheme), lineWidth: 1)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
        } else {
            SafetySwatch(level: candidate.verdict.level, diameter: 9)
        }
    }

    /// "Aggiornato": the verdict changed while the sheet was open.
    private var updatedBadge: some View {
        Text("Aggiornato")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FusionPalette.primaryText(scheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().strokeBorder(FusionPalette.primaryText(scheme).opacity(0.55), lineWidth: 1))
            .fixedSize()
    }

    /// Opacity of an item that stays; its note keeps full contrast.
    static let dimmed = 0.45

    /// A note to read before moving (caution, staying, changed) is in the primary ink; a safe item's is not.
    private var notePrimary: Bool { stays != nil || isUpdated || candidate.verdict.level == .caution }

    /// The folder it is in, the home folder as "~".
    private var folder: String {
        ((candidate.path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
    }

    /// Why it stays, when it does; else the reason to look first (caution, cloud) or, for a safe
    /// item, what it is. Ordinary items have none.
    private var note: String? {
        stays ?? candidate.verdict.sentence
    }
}
