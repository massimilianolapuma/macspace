import Foundation
import MacSpaceCore

/// One item moved to the Trash in this session (spec §5.6: name, size, date, "Mostra nel Cestino").
struct HistoryEntry: Identifiable, Sendable {
    let id = UUID()
    let name: String
    /// What it took in the tree when it was moved.
    let size: UInt64
    let date: Date
    /// Where it is inside the Trash; nil when the system did not say.
    let trashedURL: URL?
}

/// An item the confirmation sheet lists, as the store sees it when the sheet opens.
struct TrashCandidate: Identifiable, Sendable {
    let id: NodeID
    let name: String
    let path: String
    let kind: NodeKind
    let size: UInt64
    /// As shown; replaced when a refresh finds another one.
    var verdict: SafetyVerdict
}

/// What the store says about the sheet's items right now (`ScanModel.trashVerdicts`).
struct TrashVerdicts: Sendable {
    /// The items `resolveSelection` still allows.
    var allowed: Set<NodeID>
    /// Each item's current verdict; absent for an item no longer in the tree.
    var verdicts: [NodeID: SafetyVerdict]
    /// Items taken out of the tree (moved, or inside something moved).
    var removed: Set<NodeID>
}

/// An item that was not moved, and why, in words.
struct SkippedItem: Sendable {
    let node: NodeID
    let name: String
    let reason: String
}

/// What the sheet shows once a move ended.
struct TrashReport: Sendable {
    /// What moved, largest first.
    var moved: [TrashOutcome.Moved]
    /// What stayed: the store's skips, then the rows the sheet left out (open, withdrawn).
    var skipped: [SkippedItem]
    /// The estimate of the space each moved item frees once the Trash is emptied
    /// (`PrivateSize.freed`, partial or not), when the sheet had finished it before the move; the
    /// result view estimates the others in the Trash.
    var freed: [NodeID: PrivateSize.Estimate]
}

extension PrivateSize.Estimate {
    /// The estimates added up (saturating); partial when any of them is.
    static func sum(_ estimates: some Sequence<PrivateSize.Estimate>) -> PrivateSize.Estimate {
        estimates.reduce(PrivateSize.Estimate(bytes: 0, isPartial: false)) { total, next in
            let (bytes, overflow) = total.bytes.addingReportingOverflow(next.bytes)
            return PrivateSize.Estimate(bytes: overflow ? .max : bytes, isPartial: total.isPartial || next.isPartial)
        }
    }
}

/// Moving confirmed items to the Trash (spec §5.6). `ScanStore.trash` re-checks every item and is
/// the only code that moves anything; this side refreshes what is on screen and keeps the history.
extension ScanModel {
    /// The items of `ids` that may still be moved, as `ScanStore.resolveSelection` keeps them now
    /// (never protected, top-most, largest first), with what the sheet shows of each. Items that
    /// left the tree or changed store meanwhile are dropped.
    func trashCandidates(_ ids: [NodeID]) async -> [TrashCandidate] {
        guard let store else { return [] }
        let resolved = await store.resolveSelection(Set(ids))
        var candidates: [TrashCandidate] = []
        for id in resolved.ids {
            guard let row = await store.row(id), let path = await store.path(of: id),
                  let verdict = await store.verdict(id), verdict.level.isTrashable else { continue }
            candidates.append(TrashCandidate(id: id, name: row.name, path: path, kind: row.kind, size: row.size,
                                             verdict: verdict))
        }
        guard store === self.store else { return [] }
        return candidates
    }

    /// Which of `ids` the store still allows, and their verdicts now, judged afresh (the cache is
    /// dropped first, so a folder that became read-only shows): what the sheet compares its rows
    /// with after an environment update and right before moving.
    func trashVerdicts(_ ids: [NodeID]) async -> TrashVerdicts {
        guard let store else { return TrashVerdicts(allowed: [], verdicts: [:], removed: Set(ids)) }
        await store.invalidateVerdicts()
        let allowed = Set(await store.resolveSelection(Set(ids)).ids)
        var verdicts: [NodeID: SafetyVerdict] = [:]
        var removed: Set<NodeID> = []
        for id in ids {
            guard let row = await store.row(id) else {
                removed.insert(id)
                continue
            }
            if row.flags.contains(.removed) { removed.insert(id) }
            if let verdict = await store.verdict(id) { verdicts[id] = verdict }
        }
        return TrashVerdicts(allowed: allowed, verdicts: verdicts, removed: removed)
    }

    /// Moves `ids` to the Trash through `ScanStore.trash`, which re-checks each one right before
    /// moving it (still there and unchanged, not open, not protected, not inside a package, and with
    /// the verdict in `expectedVerdicts`, level, reason and owner alike: what the user saw and
    /// confirmed; an item missing from it is skipped) and skips with a reason whatever fails. The
    /// store gets the apps running at this moment with the move itself (ruling R41), not the
    /// debounced environment the views show: an app launched since protects its data and bundle,
    /// and a verdict that changed with it skips `.verdictChanged`.
    /// Then: the history gains what moved, the selection, ticks and outlines lose it, the views and
    /// suggestions are refreshed (the tree was updated in place).
    /// Refused while another move runs or while the Trash is unavailable: nothing is moved then.
    func trash(_ ids: [NodeID], expectedVerdicts: [NodeID: SafetyVerdict]) async -> TrashOutcome {
        guard let store else { return TrashOutcome() }
        guard !isTrashing else { return TrashOutcome() }
        guard trashUnavailableReason == nil, let environment else {
            // Said as it is: the scan has not settled, or verdicts are still being updated.
            let reason: TrashSkip = isScanning || !scanSettled ? .scanInProgress : .appsAnalysisInProgress
            var skipped: [TrashOutcome.Skipped] = []
            for id in ids {
                guard let row = await store.row(id) else { continue }
                skipped.append(.init(node: id, name: row.name, reason: reason))
            }
            return TrashOutcome(skipped: skipped)
        }
        isTrashing = true
        defer { isTrashing = false }
        // The running apps (and iCloud sync) read now. Kept as the model's environment too, so an
        // update queued meanwhile hands the store this one, not an older one, after the move.
        let live = SafetyEnvironmentProvider.environment(apps: environment.apps)
        let changed = !live.judgesRunningAppsLike(environment)
        self.environment = live
        // On the store's actor: blocking file system calls, off the main actor. The store takes the
        // live environment and moves in one actor call, so no queued update can slip in between.
        let outcome = await store.trash(Set(ids), environment: live, actions: SystemDiskActions(),
                                        packages: SystemPackageProbe(),
                                        // MacSpace's own descriptors (scan, estimates) never hold an item back.
                                        openFiles: { OpenFileSet.current(excludingOwnProcess: true) },
                                        expectedVerdicts: expectedVerdicts)
        // Whatever happened to the scan meanwhile, these really are in the Trash now.
        let now = Date.now
        history.insert(contentsOf: outcome.moved.map {
            HistoryEntry(name: $0.name, size: $0.size, date: now, trashedURL: $0.trashedPath.map { URL(filePath: $0) })
        }, at: 0)
        // Verdicts on screen still follow the older environment: refresh them all, as an update does.
        if changed, store === self.store { updateEnvironment(live) }
        guard store === self.store, !outcome.moved.isEmpty else { return outcome }

        let moved = Set(outcome.moved.map(\.node))
        for id in moved { suggestionTicks[id] = nil }
        highlighted.subtract(moved)
        if let listFocus, moved.contains(listFocus) { self.listFocus = nil }
        hovered = nil
        hoveredTile = nil
        // The folder on screen may have gone too (a suggestion moved a folder above it).
        let crumb = await store.breadcrumb(to: center)
        if let gone = crumb.firstIndex(where: { $0.flags.contains(.removed) }) {
            beginNavigation()  // a goUp still resolving from the removed folder must not apply
            center = gone > 0 ? crumb[gone - 1].id : FileTree.root
        }
        // The store drops removed items itself; subtracting `moved` keeps the intent explicit.
        changeSelection { $0.subtracting(moved) }
        await refreshViews()
        await selectionWork?.value
        await refreshSuggestions()
        return outcome
    }
}
