import MacSpaceCore
import SwiftUI

/// What VoiceOver gets from a chart: one element for the whole chart plus its biggest
/// segments or tiles as children. Both charts are `Canvas`es, so nothing in them is a view.
enum ChartAccessibility {
    /// VoiceOver stays usable only with a short list: the largest elements get a child each.
    static let childLimit = 50

    /// "Scegli cosa analizzare e premi Analizza" before a scan, "<cartella>, <totale>" after.
    @MainActor
    static func label(for model: ScanModel) -> String {
        guard let folder = model.breadcrumb.last else {
            return model.isScanning ? String(localized: "Analisi in corso…")
                                    : String(localized: "Scegli cosa analizzare e premi Analizza")
        }
        return "\(folder.name), \(Formatters.bytes(folder.size))"
    }

    /// The `limit` largest of `items`, biggest first.
    static func largest<T>(_ items: [T], limit: Int = childLimit, size: (T) -> UInt64) -> [T] {
        Array(items.sorted { size($0) > size($1) }.prefix(limit))
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
    /// "Torna su" on the chart itself, when there is a level above.
    func chartUpAction(enabled: Bool, _ goUp: @escaping () -> Void) -> some View {
        accessibilityAction(named: Text("Torna su")) { if enabled { goUp() } }
    }
}
