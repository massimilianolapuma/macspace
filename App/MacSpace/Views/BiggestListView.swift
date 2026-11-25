import MacSpaceCore
import SwiftUI

/// The largest items in the current folder, in ring-1 order. Hovering a row lights up its
/// segment or tile; clicking a folder drills into it.
struct BiggestListView: View {
    let model: ScanModel
    let colorMode: ColorMode
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.biggest.isEmpty, let folder = model.breadcrumb.last {
                Text("Più pesanti in \(folder.name)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .padding(.horizontal, 18)
                    .padding(.top, 14)
                    .padding(.bottom, 6)
                    .accessibilityAddTraits(.isHeader)
            }
            if isIdle {
                Text("Gli elementi più pesanti appariranno qui")
                    .font(.callout)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        ScrollView {
            VStack(spacing: 0) {  // at most `ScanModel.biggestLimit` rows: no need for lazy loading
                ForEach(model.biggest) { row in
                    BiggestRow(model: model, row: row, total: model.breadcrumb.last?.size ?? 0,
                               colorMode: colorMode,
                               hover: { hover(row, $0) },
                               open: { model.drill(into: row.id) })
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var isIdle: Bool {
        if case .idle = model.phase { return true }
        return false
    }

    private func hover(_ row: NodeRow, _ inside: Bool) {
        if inside {
            model.hoverFirstLevel(row.id)
        } else if model.hoveredNode == row.id {
            model.hoverFirstLevel(nil)
        }
    }
}

private struct BiggestRow: View {
    let model: ScanModel
    let row: NodeRow
    let total: UInt64
    let colorMode: ColorMode
    let hover: (Bool) -> Void
    let open: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var canOpen: Bool { row.kind == .directory && row.hasChildren }

    /// Read here, per row, so a hover change re-evaluates the rows only, not the list.
    private var highlighted: Bool { model.hoveredNode == row.id }

    var body: some View {
        // Folders are buttons, so they take keyboard focus and VoiceOver can open them.
        Group {
            if canOpen {
                Button(action: open) { content }
                    .buttonStyle(RowButtonStyle(highlighted: highlighted))
                    .pointerStyle(.link)
            } else {
                content.background(RowButtonStyle.fill(highlighted: highlighted, pressed: false, scheme: scheme))
            }
        }
        .onHover(perform: hover)
        .accessibilityElement(children: .combine)
        // Spelled out, so VoiceOver says the level and its reason whatever the color mode.
        .accessibilityLabel(Text(verbatim: spokenLabel))
        .accessibilityValue(Text(verbatim: spokenValue))
    }

    private var verdict: SafetyVerdict? { model.verdicts[row.id] }

    /// Name, the safety level unless normal, and "Non leggibile".
    private var spokenLabel: String {
        var parts = [row.name]
        if let level = (verdict?.level ?? row.safety).spokenTitle { parts.append(level) }
        if row.flags.contains(.unreadable) { parts.append(String(localized: "Non leggibile")) }
        return parts.joined(separator: ", ")
    }

    /// Size, the detail line in words (type or last use; nothing extra in "Eliminabili") and the
    /// safety reason.
    private var spokenValue: String {
        var parts = [Formatters.bytes(row.size)]
        switch colorMode {
        case .deletable:
            break
        case .category:
            parts.append(String(localized: "Tipo: \(String(localized: row.category.title))"))
        case .lastUse where isFolderWithContents:
            parts.append(String(localized: "Per lo più: \(String(localized: row.ageBucket.title))"))
        case .lastUse:
            parts.append(String(localized: "Ultimo uso (stimato): \(Formatters.lastUsedAge(row.lastUsed))"))
        }
        if let sentence = verdict?.sentence { parts.append(sentence) }
        return parts.joined(separator: ", ")
    }

    private var isFolderWithContents: Bool { row.kind == .directory && row.hasChildren }

    private var content: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(FusionPalette.secondaryText(scheme))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(verbatim: row.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(FusionPalette.primaryText(scheme))
                    if row.flags.contains(.unreadable) {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(FusionPalette.secondaryText(scheme))
                            .accessibilityLabel(Text("Non leggibile"))
                    }
                    Spacer(minLength: 6)
                    Text(verbatim: Formatters.bytes(row.size))
                        .monospacedDigit()
                        .foregroundStyle(FusionPalette.secondaryText(scheme))
                }
                detail
                share
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    /// The row's safety level and reason (Eliminabili), file type (by type), or by last use a
    /// folder's dominant age bucket and a file's relative last use, each with its chart mark.
    /// Worded as the hover card words it: a folder with contents says "Per lo più: <bucket>"; an
    /// empty folder, like a file, its own last use. An ordinary item has no reason: no line.
    @ViewBuilder
    private var detail: some View {
        switch colorMode {
        case .deletable:
            if let verdict, let sentence = verdict.sentence {
                // Up to two lines, so the consequence is not cut off; the help tag has it all.
                RowDetail(text: sentence, lines: 2) {
                    SafetySwatch(level: verdict.level, diameter: ColorDot.size)
                }
                    .help(Text(verbatim: sentence))
            }
        case .category:
            RowDetail(color: FusionPalette.swatch(row.category, scheme: scheme),
                      text: String(localized: row.category.title))
        case .lastUse where isFolderWithContents:
            // A folder: the age of most of its bytes, not of its latest touch.
            RowDetail(color: FusionPalette.swatch(row.ageBucket, scheme: scheme),
                      text: String(localized: "Per lo più: \(String(localized: row.ageBucket.title))"))
        case .lastUse:
            RowDetail(color: FusionPalette.swatch(row.ageBucket, scheme: scheme),
                      text: Formatters.lastUsedAge(row.lastUsed))
        }
    }

    /// Thin bar: the row's share of the current folder.
    private var share: some View {
        GeometryReader { proxy in
            let fraction = total > 0 ? min(Double(row.size) / Double(total), 1) : 0
            Capsule()
                .fill(FusionPalette.secondaryText(scheme).opacity(0.14))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(FusionPalette.secondaryText(scheme).opacity(0.55))
                        .frame(width: max(proxy.size.width * fraction, fraction > 0 ? 2 : 0))
                }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch row.kind {
        case .directory: "folder"
        case .symlink: "link"
        case .file, .other: "doc"
        }
    }
}

/// A small mark (a color dot, or a safety level's marker) and the words it stands for, under a
/// row's name.
private struct RowDetail<Marker: View>: View {
    let text: String
    /// Most lines the text may take before it is cut with "…".
    var lines = 1
    @ViewBuilder let marker: Marker
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            marker
                // Centered on the first line's lowercase letters, also when the text wraps.
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 3.5 }
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.caption)
                .foregroundStyle(FusionPalette.secondaryText(scheme))
                .lineLimit(lines)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension RowDetail where Marker == ColorDot {
    init(color: Color, text: String) {
        self.init(text: text) { ColorDot(color: color) }
    }
}

/// A chart color as a small dot with a hairline ring.
private struct ColorDot: View {
    static let size = 7.0

    let color: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(FusionPalette.swatchRing(scheme), lineWidth: 0.5))
            .frame(width: Self.size, height: Self.size)
    }
}

/// Row chrome: hover/linked highlight and pressed state.
private struct RowButtonStyle: ButtonStyle {
    let highlighted: Bool
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Self.fill(highlighted: highlighted, pressed: configuration.isPressed, scheme: scheme))
    }

    static func fill(highlighted: Bool, pressed: Bool, scheme: ColorScheme) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(FusionPalette.primaryText(scheme).opacity(pressed ? 0.11 : highlighted ? 0.07 : 0))
    }
}
