import MacSpaceCore
import SwiftUI

/// The largest items in the current folder, in ring-1 order. Hovering a row lights up its
/// segment; clicking a folder drills into it.
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
            let segment = model.segments.first { $0.depth == 1 && $0.node == row.id }
            if model.hovered != segment { model.hovered = segment }
        } else if model.hovered?.node == row.id {
            model.hovered = nil
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
    private var highlighted: Bool { model.hovered?.node == row.id }

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
    }

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

    /// The row's file type (by type), or by last use a folder's dominant age bucket and a file's
    /// relative last use, with its chart color; nothing in neutral mode.
    @ViewBuilder
    private var detail: some View {
        switch colorMode {
        case .neutral:
            EmptyView()
        case .category:
            RowDetail(color: FusionPalette.swatch(row.category, scheme: scheme),
                      text: String(localized: row.category.title))
        case .lastUse where row.kind == .directory:
            // A folder: the age of most of its bytes, not of its latest touch.
            RowDetail(color: FusionPalette.swatch(row.ageBucket, scheme: scheme),
                      text: String(localized: row.ageBucket.title))
                .accessibilityLabel(Text("Per lo più: \(String(localized: row.ageBucket.title))"))
        case .lastUse:
            let age = Formatters.lastUsedAge(row.lastUsed)
            RowDetail(color: FusionPalette.swatch(row.ageBucket, scheme: scheme), text: age)
                .accessibilityLabel(Text("Ultimo uso (stimato): \(age)"))
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

/// A small color dot and the words it stands for, under a row's name.
private struct RowDetail: View {
    let color: Color
    let text: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(FusionPalette.swatchRing(scheme), lineWidth: 0.5))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.caption)
                .foregroundStyle(FusionPalette.secondaryText(scheme))
                .lineLimit(1)
        }
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
