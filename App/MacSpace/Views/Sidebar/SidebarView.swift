import MacSpaceCore
import SwiftUI

/// The inspector next to the chart: "Elementi" (the largest items here) or "Suggerimenti", and the
/// selection bar at the bottom while something is selected.
struct SidebarView: View {
    let model: ScanModel
    let colorMode: ColorMode
    @Binding var tab: Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Tab: Hashable {
        case items, suggestions
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(selection: $tab) {
                Text("Elementi").tag(Tab.items)
                Text("Suggerimenti").tag(Tab.suggestions)
            } label: {
                EmptyView()
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel(Text("Pannello"))
            // Centered between the margins, on the path row's line across the window.
            .frame(maxWidth: .infinity)
            .frame(height: WindowLayout.rowHeight)
            .padding(.horizontal, WindowLayout.inspectorMargin)
            .padding(.top, WindowLayout.windowMargin)
            Group {
                switch tab {
                case .items: BiggestListView(model: model, colorMode: colorMode)
                case .suggestions: SuggestionsView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if !model.selection.isEmpty {
                SelectionBar(model: model)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Never measured narrower than the column can be: text that wraps instead of truncating
        // would otherwise report a min height for a zero width and stretch the window.
        .frame(minWidth: WindowLayout.inspectorMinWidth)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.selection.isEmpty)
        .onChange(of: tab) {
            // The outlines belong to the suggestions: leaving them clears them.
            if tab == .items, !model.highlighted.isEmpty { model.highlighted = [] }
        }
    }
}

/// "<N> selezionati · <totale>", "Deseleziona" and "Sposta nel Cestino…".
private struct SelectionBar: View {
    let model: ScanModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SelectedCount(count: model.selection.count, total: model.selectionTotal)
                .font(.callout.weight(.semibold))
                .foregroundStyle(FusionPalette.primaryText(scheme))
            HStack(spacing: 8) {
                Button("Deseleziona") { model.clearSelection() }
                Spacer(minLength: 0)
                TrashButton(model: model) { model.requestTrashOfSelection() }
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, WindowLayout.inspectorMargin)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FusionPalette.tooltipFill(scheme))
        .overlay(alignment: .top) { Divider() }
    }
}

/// "Sposta nel Cestino…": prominent, and disabled with the reason as its help while the scan runs
/// or the apps index is not ready.
struct TrashButton: View {
    let model: ScanModel
    var prominent = true
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        let reason = model.trashUnavailableReason
        Group {
            if prominent {
                Button("Sposta nel Cestino…", action: action).buttonStyle(.borderedProminent)
            } else {
                Button("Sposta nel Cestino…", action: action).buttonStyle(.bordered)
            }
        }
        .disabled(reason != nil || !isEnabled)
        .help(reason.map { Text($0) } ?? Text("Apre la conferma prima di spostare"))
    }
}

/// "<N> selezionati · <totale>" ("1 selezionato" in the singular).
private struct SelectedCount: View {
    let count: Int
    let total: UInt64

    var body: some View {
        HStack(spacing: 4) {
            Text("\(count) selezionati")
            Text(verbatim: "·").accessibilityHidden(true)
            Text(verbatim: Formatters.bytes(total))
        }
        .monospacedDigit()
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}
