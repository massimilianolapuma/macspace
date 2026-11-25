import Foundation
import MacSpaceCore

/// Selection for the Trash, the suggestions, and moving around to show their items (spec §5.5, §5.6).
extension ScanModel {
    // MARK: Selection

    /// Selects `node`, or deselects it when selected. The store decides what stays
    /// (`ScanStore.resolveSelection`): the root and protected items are refused, selecting a folder
    /// drops what was selected inside it, and selecting inside a selected folder changes nothing.
    /// The returned task's value says whether the selection changed (false: refused).
    @discardableResult
    func toggleSelection(_ node: NodeID) -> Task<Bool, Never> {
        changeSelection { $0.contains(node) ? $0.subtracting([node]) : $0.union([node]) }
    }

    /// Deselects everything.
    func clearSelection() {
        changeSelection { _ in [] }
    }

    /// Whether `node` is selected, or inside a selected folder. Meant for the children of `center`
    /// (list rows, first-level elements): their folders above are the breadcrumb.
    func isCoveredBySelection(_ node: NodeID) -> Bool {
        selection.contains(node) || breadcrumb.contains { selection.contains($0.id) }
    }

    /// Whether `node` may be offered for selection: not the root and not protected, as far as its
    /// verdict on screen tells (the store checks again).
    func isSelectable(_ node: NodeID?) -> Bool {
        guard let node, node != FileTree.root else { return false }
        return verdicts[node]?.level != .protected
    }

    /// Applies `change` to the selection once every earlier change has landed, and keeps what the
    /// store allows of the result. Changes made for an earlier scan's store are dropped.
    @discardableResult
    func changeSelection(_ change: @escaping (Set<NodeID>) -> Set<NodeID>) -> Task<Bool, Never> {
        let previous = selectionWork
        let store = self.store
        let task = Task { () -> Bool in
            await previous?.value
            guard let store, store === self.store else { return false }
            let before = selection
            let resolved = await store.resolveSelection(change(before))
            guard store === self.store, !Task.isCancelled else { return false }
            let after = Set(resolved.ids)
            if selection != after { selection = after }
            if selectionTotal != resolved.total { selectionTotal = resolved.total }
            return after != before
        }
        selectionWork = Task { _ = await task.value }
        return task
    }

    // MARK: Trash

    /// Why "Sposta nel Cestino…" is unavailable right now (nil: it is available): the scan is still
    /// running (the store refuses it too), or the apps index is not ready, so `~/Library` items have
    /// not been judged yet.
    var trashUnavailableReason: LocalizedStringResource? {
        if isScanning { return "Analisi in corso…" }
        if store != nil, !appsReady { return "Analisi delle app in corso…" }
        return nil
    }

    /// Asks to move `ids` to the Trash: the confirmation sheet opens on them. Nothing moves here.
    func requestTrash(_ ids: [NodeID]) {
        guard trashUnavailableReason == nil, store != nil, !ids.isEmpty else { return }
        pendingTrash = ids
    }

    /// "Sposta nel Cestino…" in the selection bar: the selection, largest first.
    func requestTrashOfSelection() {
        guard let store else { return }
        let ids = selection
        Task {
            let top = await store.topMost(ids)
            guard store === self.store, ids == selection else { return }
            requestTrash(top)
        }
    }

    // MARK: Suggestions

    /// Asks the store for its suggestions again (not while scanning: they would be partial).
    func refreshSuggestions() async {
        guard let store, !isScanning else { return }
        let found = await store.suggestions()
        guard store === self.store, !isScanning else { return }
        suggestions = found
        // The highlight follows the items still suggested.
        if !highlighted.isEmpty {
            let still = Set(found.flatMap(\.items).map(\.id))
            let kept = highlighted.intersection(still)
            if kept != highlighted { highlighted = kept }
        }
    }

    /// Whether `item` is ticked in its suggestion: the user's choice, else `preselected`.
    func isTicked(_ item: SuggestionItem) -> Bool {
        suggestionTicks[item.id] ?? item.preselected
    }

    func setTicked(_ item: SuggestionItem, _ ticked: Bool) {
        suggestionTicks[item.id] = ticked
    }

    /// The ticked items of `suggestion`, in its order.
    func tickedItems(of suggestion: Suggestion) -> [SuggestionItem] {
        suggestion.items.filter(isTicked)
    }

    /// Whether `suggestion`'s items are the highlighted ones.
    func isHighlighted(_ suggestion: Suggestion) -> Bool {
        !highlighted.isEmpty && highlighted == Set(suggestion.items.map(\.id))
    }

    /// Outlines `suggestion`'s items wherever they are on screen, or stops when they already are
    /// highlighted. When none of them is on screen, shows the folder that holds them all.
    func toggleHighlight(_ suggestion: Suggestion) {
        let ids = Set(suggestion.items.map(\.id))
        guard !isHighlighted(suggestion) else {
            highlighted = []
            return
        }
        highlighted = ids
        let onScreen = switch chart {
        case .sunburst: segments.contains { $0.node.map(ids.contains) ?? false }
        case .treemap: tiles.contains { $0.node.map(ids.contains) ?? false }
        }
        guard !onScreen, let store else { return }
        Task {
            guard let folder = await store.commonFolder(of: ids), store === self.store, highlighted == ids else {
                return
            }
            drill(into: folder)
        }
    }

    /// Shows `node`: drills to its folder so it is a first-level element, then hovers it.
    func reveal(_ node: NodeID) {
        guard let store else { return }
        Task {
            guard let folder = await store.commonFolder(of: [node]), store === self.store else { return }
            if folder != center {
                center = folder
                hovered = nil
                hoveredTile = nil
                await refreshViews()
                guard store === self.store, center == folder else { return }
            }
            hoverFirstLevel(node)
        }
    }
}
