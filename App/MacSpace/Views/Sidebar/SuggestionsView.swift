import MacSpaceCore
import SwiftUI

/// The suggestions of the last scan (spec §5.5): one section per group, with its total, a line on
/// what it is, its items ticked as preselected, and its own "Sposta nel Cestino…". Clicking a
/// section's header outlines its items in the chart; clicking an item shows it there.
struct SuggestionsView: View {
    let model: ScanModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if model.suggestions.isEmpty || !model.scanSettled {
            empty
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if wasCancelled {
                        note("Analisi interrotta: i suggerimenti possono essere incompleti",
                             systemImage: "pause.circle")
                    }
                    if !model.appsReady {
                        note("Analisi delle app in corso…", systemImage: nil)
                    }
                    ForEach(model.suggestions) { suggestion in
                        SuggestionSection(model: model, suggestion: suggestion)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
        }
    }

    private var wasCancelled: Bool {
        if case let .done(summary) = model.phase { return summary.wasCancelled }
        return false
    }

    /// No scan yet; scanning, or its end still landing (no flash of "nothing found"); apps index
    /// not ready; a cancelled scan; or nothing to suggest (in the folders it could read, when some
    /// could not be).
    private var empty: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .idle:
                message("Analizza per vedere i suggerimenti")
            case .scanning:
                ProgressView().controlSize(.small)
                message("Analisi in corso…")
            case .done where !model.scanSettled:
                ProgressView().controlSize(.small)
                message("Analisi in corso…")
            case .done where !model.appsReady:
                ProgressView().controlSize(.small)
                message("Analisi delle app in corso…")
            case .done where wasCancelled:
                Image(systemName: "pause.circle")
                    .font(.title2)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .accessibilityHidden(true)
                message("Analisi interrotta: i suggerimenti possono essere incompleti", emphasized: true)
            case .done:
                Image(systemName: "checkmark.circle")
                    .font(.title2)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .accessibilityHidden(true)
                if model.unreadableFolders > 0 {
                    message("Nessun suggerimento nelle cartelle lette (\(model.unreadableFolders) non leggibili)",
                            emphasized: true)
                } else {
                    message("Nessun suggerimento: qui è tutto in ordine", emphasized: true)
                }
            }
        }
        .font(.callout)
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// An empty state's words: an outcome in the primary ink, a wait or a hint in the secondary.
    private func message(_ key: LocalizedStringKey, emphasized: Bool = false) -> some View {
        Text(key)
            .foregroundStyle(emphasized ? FusionPalette.primaryText(scheme) : FusionPalette.secondaryText(scheme))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A one-line note above the sections: a spinner while waiting, else `systemImage`.
    private func note(_ key: LocalizedStringKey, systemImage: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage).accessibilityHidden(true)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(key).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(FusionPalette.secondaryText(scheme))
        .padding(.horizontal, 10)
    }
}

private struct SuggestionSection: View {
    let model: ScanModel
    let suggestion: Suggestion
    @Environment(\.colorScheme) private var scheme
    /// Every item shows, not only the first `collapsedCount`.
    @State private var expanded = false
    @State private var hoveringHeader = false

    /// Items shown before "Mostra tutti": a cache folder can hold hundreds, and the sections below
    /// must stay in reach.
    static let collapsedCount = 5

    var body: some View {
        let ticked = model.tickedItems(of: suggestion)
        let hidden = suggestion.items.count - Self.collapsedCount
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(expanded || hidden <= 0 ? suggestion.items : Array(suggestion.items.prefix(Self.collapsedCount))) {
                SuggestionItemRow(model: model, item: $0)
            }
            if hidden > 0 {
                Button(expanded ? "Mostra meno" : "Mostra tutti (\(suggestion.items.count))") { expanded.toggle() }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 38)
                    .padding(.vertical, 2)
            }
            HStack(spacing: 8) {
                // Ticks, not the selection: "<n> di <m>" (R37).
                HStack(spacing: 4) {
                    Text("\(ticked.count) di \(suggestion.items.count)")
                    Text(verbatim: "·").accessibilityHidden(true)
                    Text(verbatim: Formatters.bytes(ticked.reduce(0) { $0 + $1.size }))
                }
                .monospacedDigit()
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .font(.caption)
                .foregroundStyle(FusionPalette.secondaryText(scheme))
                .layoutPriority(1)
                Spacer(minLength: 4)
                // Quieter than the selection bar's: one per section.
                TrashButton(model: model, prominent: false, isEnabled: !ticked.isEmpty) {
                    model.requestTrash(ticked.map(\.id))
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
        }
    }

    /// Title and total, and what the group is; a click outlines the items in the chart.
    private var header: some View {
        let highlighted = model.isHighlighted(suggestion)
        return Button { model.toggleHighlight(suggestion) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(suggestion.kind.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FusionPalette.primaryText(scheme))
                    Spacer(minLength: 6)
                    Text(verbatim: Formatters.bytes(suggestion.total))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(FusionPalette.primaryText(scheme))
                }
                Text(suggestion.kind.explanation)
                    .font(.caption)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(FusionPalette.primaryText(scheme).opacity(hoveringHeader ? 0.05 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(FusionPalette.primaryText(scheme).opacity(highlighted ? 0.55 : 0), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveringHeader = $0 }
        .pointerStyle(.link)
        .help(highlighted ? Text("Togli l'evidenziazione") : Text("Evidenzia nel grafico"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }
}

private struct SuggestionItemRow: View {
    let model: ScanModel
    let item: SuggestionItem
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Toggle(isOn: Binding(get: { model.isTicked(item) }, set: { model.setTicked(item, $0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 24)
                .padding(.leading, 4)
                .accessibilityHidden(true)
            Button { model.reveal(item.id) } label: { content }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .help(Text(verbatim: item.path))
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(FusionPalette.primaryText(scheme).opacity(hovering ? 0.07 : 0))
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: [item.name, item.verdict.level.spokenTitle].compactMap { $0 }
            .joined(separator: ", ")))
        // The tick is the checkbox's own state, said first; it is not the chart selection (R37).
        .accessibilityValue(Text(verbatim: [ticked ? String(localized: "Spuntato") : String(localized: "Non spuntato"),
                                            Formatters.bytes(item.size), folderName, item.verdict.sentence]
            .compactMap { $0 }.joined(separator: ", ")))
        .accessibilityAddTraits(.isToggle)
        .accessibilityAction(named: ticked ? Text("Togli la spunta") : Text("Spunta")) {
            model.setTicked(item, !ticked)
        }
    }

    private var name: some View {
        Text(verbatim: item.name)
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(FusionPalette.primaryText(scheme))
    }

    private var ticked: Bool { model.isTicked(item) }

    /// The name of the folder the item is in, as the chart names it.
    private var folderName: String {
        item.path.split(separator: "/").dropLast().last.map(String.init) ?? ""
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                name
                Spacer(minLength: 6)
                Text(verbatim: Formatters.bytes(item.size))
                    .monospacedDigit()
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .fixedSize()
            }
            // Where it is: two leftovers of one app share a name (in Application Support and in Caches).
            Label {
                Text(verbatim: folderName).lineLimit(1).truncationMode(.middle)
            } icon: {
                Image(systemName: "folder").imageScale(.small)
            }
            .labelStyle(FolderLabelStyle())
            .font(.caption)
            .foregroundStyle(FusionPalette.secondaryText(scheme))
            if let sentence = item.verdict.sentence {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    SafetySwatch(level: item.verdict.level, diameter: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                    Text(verbatim: sentence)
                        .font(.caption)
                        .foregroundStyle(FusionPalette.secondaryText(scheme))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension SuggestionKind {
    var title: LocalizedStringResource {
        switch self {
        case .leftovers: "Avanzi di app disinstallate"
        case .caches: "Cache rigenerabili"
        case .installers: "File d'installazione"
        }
    }

    /// One line on what the group is and why it can go.
    var explanation: LocalizedStringResource {
        switch self {
        case .leftovers: "Dati di app che non sono più su questo Mac."
        case .caches: "Le app le ricreano da sole quando servono."
        case .installers: "Immagini disco e pacchetti che servivano per installare."
        }
    }
}

/// A folder glyph as wide as the safety marker below it, so the two lines start together.
private struct FolderLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.frame(width: 7).accessibilityHidden(true)
            configuration.title
        }
    }
}
