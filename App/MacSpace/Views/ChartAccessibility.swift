import AppKit
import MacSpaceCore
import SwiftUI

/// What VoiceOver gets from a chart: one element for the whole chart plus its biggest
/// segments or tiles as children. Both charts are `Canvas`es, so nothing in them is a view.
enum ChartAccessibility {
    /// The empty state's words before a scan ("Nessuna analisi. Scegli cosa analizzare e premi
    /// Analizza"), "<cartella>, <totale>" after (and the disk's used space and capacity at the root
    /// of a finished startup-disk scan).
    @MainActor
    static func label(for model: ScanModel) -> String {
        let label = baseLabel(for: model)
        return model.isWaiting ? label + ", " + String(localized: "aggiornamento in corso") : label
    }

    @MainActor
    private static func baseLabel(for model: ScanModel) -> String {
        guard let folder = model.breadcrumb.last else {
            if model.isScanning { return String(localized: "Analisi in corso…") }
            return String(localized: "Nessuna analisi") + ". "
                + String(localized: "Scegli cosa analizzare e premi Analizza")
        }
        let label = "\(folder.name), \(Formatters.bytes(folder.size))"
        guard let disk = model.diskAtRoot else { return label }
        // Short: the full explanation is spoken once, on the center (sunburst) or the header (treemap).
        return label + ". " + disk.summary
    }
}

extension SegmentTooltip.Subject {
    /// `verdict` is the segment's node's (nil for merged "altri"); `spotlightLastUsed`, a file's
    /// Spotlight last use when known.
    @MainActor init(segment: ArcSegment, verdict: SafetyVerdict?, spotlightLastUsed: UInt32? = nil) {
        self.init(title: SunburstView.title(of: segment), size: segment.size, isMerged: segment.node == nil,
                  hasChildren: segment.hasChildren, category: segment.category,
                  ageBucket: segment.ageBucket, lastUsed: segment.lastUsed, flags: segment.flags,
                  verdict: segment.node == nil ? nil : verdict, spotlightLastUsed: spotlightLastUsed)
    }

    @MainActor init(tile: TreemapTile, verdict: SafetyVerdict?, spotlightLastUsed: UInt32? = nil) {
        self.init(title: TreemapView.title(of: tile), size: tile.size, isMerged: tile.node == nil,
                  hasChildren: tile.hasChildren, category: tile.category, ageBucket: tile.ageBucket,
                  lastUsed: tile.lastUsed, flags: tile.flags,
                  verdict: tile.node == nil ? nil : verdict, spotlightLastUsed: spotlightLastUsed)
    }

    /// The element's name and, unless normal, its safety level: VoiceOver's label.
    var spokenTitle: String {
        [title, verdict?.level.spokenTitle].compactMap { $0 }.joined(separator: ", ")
    }

    /// Size, type, last use and the safety reason in words: the tooltip's lines, joined for VoiceOver.
    var spokenValue: String {
        var parts = [Formatters.bytes(size)]
        if !isMerged { parts.append(String(localized: "Tipo: \(String(localized: category.title))")) }
        if isMerged || hasChildren {
            parts.append(String(localized: "Per lo più: \(String(localized: ageBucket.title))"))
            parts.append(String(localized: "Uso più recente (stimato): \(Formatters.lastUsedDate(lastUsed))"))
        } else if let spotlightLastUsed {
            parts.append(String(localized: "Ultimo uso: \(Formatters.lastUsedDate(spotlightLastUsed))"))
        } else {
            parts.append(String(localized: "Ultimo uso (stimato): \(Formatters.lastUsedDate(lastUsed))"))
        }
        if let sentence = verdict?.sentence { parts.append(sentence) }
        if let app = verdict?.appName { parts.append(String(localized: "App: \(app)")) }
        if flags.contains(.unreadable) { parts.append(String(localized: "Non leggibile")) }
        return parts.joined(separator: ", ")
    }
}

/// Selecting chart elements and list rows for the Trash.
enum ChartSelection {
    /// Whether the click being handled was a ⌘-click: the click event's own modifiers, not the keys
    /// held by the time the gesture fires.
    @MainActor
    static var isSelectClick: Bool {
        (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.command)
    }

    /// Selects or deselects `node` (nil: a merged "altri" element, never selectable); the Mac beeps
    /// when the store refuses it (the root, a protected item, or one inside a selected folder).
    @MainActor
    static func toggle(_ node: NodeID?, in model: ScanModel) {
        guard let node, model.isSelectable(node) else {
            NSSound.beep()
            return
        }
        let change = model.toggleSelection(node)
        Task { if await !change.value { NSSound.beep() } }
    }
}

extension View {
    /// "Seleziona" or "Deseleziona" on a segment, tile or list row that may be selected, and the
    /// selected trait while it is; inside a selected folder, no action but the selected trait and a
    /// hint saying why. The selection is read in the modifier, so a change to it
    /// re-evaluates only the elements, not the chart around them.
    func selectionAction(node: NodeID?, model: ScanModel) -> some View {
        modifier(SelectionAction(node: node, model: model))
    }

    /// "Torna su" on the chart itself; registered only while there is a level above.
    @ViewBuilder
    func chartUpAction(enabled: Bool, _ goUp: @escaping () -> Void) -> some View {
        if enabled { accessibilityAction(named: Text("Torna su"), goUp) } else { self }
    }

    /// "Apri" on a segment or tile: drills into `node` when it has children to show.
    @ViewBuilder
    func chartOpenAction(node: NodeID?, hasChildren: Bool, _ open: @escaping (NodeID) -> Void) -> some View {
        if let node, hasChildren { accessibilityAction(named: Text("Apri")) { open(node) } } else { self }
    }
}

private struct SelectionAction: ViewModifier {
    let node: NodeID?
    let model: ScanModel

    func body(content: Content) -> some View {
        if let node, model.isInsideSelection(node) {
            // Goes with its selected folder: nothing to select on its own, but say so.
            content
                .accessibilityAddTraits(.isSelected)
                .accessibilityHint(Text("Fa già parte di una cartella selezionata"))
        } else if let node, model.isSelectable(node) {
            let selected = model.selection.contains(node)
            content
                .accessibilityAction(named: selected ? Text("Deseleziona") : Text("Seleziona")) {
                    model.toggleSelection(node)
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            content
        }
    }
}
