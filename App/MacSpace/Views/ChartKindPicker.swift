import AppKit
import SwiftUI

/// "Raggiera" | "Treemap" with their symbols. A SwiftUI segmented `Picker` drops a `Label`'s
/// symbol in the toolbar, so this is the AppKit control, which shows both.
struct ChartKindPicker: NSViewRepresentable {
    @Binding var selection: ChartKind

    private static let kinds: [(kind: ChartKind, title: String, symbol: String)] = [
        (.sunburst, String(localized: "Raggiera"), "chart.pie"),
        (.treemap, String(localized: "Treemap"), "square.grid.2x2"),
    ]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: Self.kinds.map(\.title), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        for (index, kind) in Self.kinds.enumerated() {
            control.setImage(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil), forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        control.setAccessibilityLabel(String(localized: "Vista"))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = Self.kinds.firstIndex { $0.kind == selection } ?? 0
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator: NSObject {
        var selection: Binding<ChartKind>

        init(selection: Binding<ChartKind>) { self.selection = selection }

        @MainActor @objc func changed(_ control: NSSegmentedControl) {
            selection.wrappedValue = ChartKindPicker.kinds[max(control.selectedSegment, 0)].kind
        }
    }
}
