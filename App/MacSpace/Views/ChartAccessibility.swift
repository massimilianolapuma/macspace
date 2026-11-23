import MacSpaceCore
import SwiftUI

/// What VoiceOver gets from a chart: one element for the whole chart plus its biggest
/// segments or tiles as children. Both charts are `Canvas`es, so nothing in them is a view.
enum ChartAccessibility {
    /// "Scegli cosa analizzare e premi Analizza" before a scan, "<cartella>, <totale>" after.
    @MainActor
    static func label(for model: ScanModel) -> String {
        guard let folder = model.breadcrumb.last else {
            return model.isScanning ? String(localized: "Analisi in corso…")
                                    : String(localized: "Scegli cosa analizzare e premi Analizza")
        }
        return "\(folder.name), \(Formatters.bytes(folder.size))"
    }
}

extension SegmentTooltip.Subject {
    @MainActor init(segment: ArcSegment) {
        self.init(title: SunburstView.title(of: segment), size: segment.size, isMerged: segment.node == nil,
                  hasChildren: segment.hasChildren, category: segment.category,
                  ageBucket: segment.ageBucket, lastUsed: segment.lastUsed, flags: segment.flags)
    }

    @MainActor init(tile: TreemapTile) {
        self.init(title: TreemapView.title(of: tile), size: tile.size, isMerged: tile.node == nil,
                  hasChildren: tile.hasChildren, category: tile.category, ageBucket: tile.ageBucket,
                  lastUsed: tile.lastUsed, flags: tile.flags)
    }

    /// Size, type and last use in words: the tooltip's lines, joined for VoiceOver.
    var spokenValue: String {
        var parts = [Formatters.bytes(size)]
        if !isMerged { parts.append(String(localized: "Tipo: \(String(localized: category.title))")) }
        if isMerged || hasChildren {
            parts.append(String(localized: "Per lo più: \(String(localized: ageBucket.title))"))
            parts.append(String(localized: "Uso più recente (stimato): \(Formatters.lastUsedDate(lastUsed))"))
        } else {
            parts.append(String(localized: "Ultimo uso (stimato): \(Formatters.lastUsedDate(lastUsed))"))
        }
        if flags.contains(.unreadable) { parts.append(String(localized: "Non leggibile")) }
        return parts.joined(separator: ", ")
    }
}

extension View {
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
