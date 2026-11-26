import MacSpaceCore
import SwiftUI

/// Path from the scan root to the current folder; earlier components jump back up.
///
/// When the whole path does not fit, its middle collapses (measured, `ViewThatFits`): the root,
/// then "…", then the last two components, then the last one alone; the last arrangement may
/// truncate its names in the middle. "…" is a menu of the collapsed folders, each a jump back up.
struct BreadcrumbView: View {
    let model: ScanModel
    @Environment(\.colorScheme) private var scheme

    /// One component on screen: a crumb (its index in the path) or the collapsed middle.
    private enum Item: Identifiable {
        case crumb(Int)
        case collapsed(ClosedRange<Int>)

        var id: Int {
            switch self {
            case let .crumb(index): index
            case .collapsed: -1
            }
        }
    }

    var body: some View {
        let count = model.breadcrumb.count
        ViewThatFits(in: .horizontal) {
            row(Array(0..<count).map(Item.crumb)).fixedSize()
            if count > 3 { row(collapsed(keeping: 2)).fixedSize() }
            if count > 2 { row(collapsed(keeping: 1)).fixedSize() }
            // Last resort: the root as its icon alone, the last name cut in the middle.
            row(count > 2 ? collapsed(keeping: 1) : Array(0..<count).map(Item.crumb), rootIconOnly: true)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The root, "…" for everything between, and the last `keeping` components.
    private func collapsed(keeping: Int) -> [Item] {
        let count = model.breadcrumb.count
        return [.crumb(0), .collapsed(1...(count - keeping - 1))] + (count - keeping..<count).map(Item.crumb)
    }

    private func row(_ items: [Item], rootIconOnly: Bool = false) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                if position > 0 { Self.chevron(scheme) }
                switch item {
                case let .crumb(index): crumb(at: index, iconOnly: rootIconOnly && index == 0 && items.count > 1)
                case let .collapsed(range): middle(range)
                }
            }
        }
    }

    @ViewBuilder
    private func crumb(at index: Int, iconOnly: Bool) -> some View {
        let row = model.breadcrumb[index]
        if index == model.breadcrumb.count - 1 {
            label(row, index: index, iconOnly: iconOnly)
                .fontWeight(.semibold)
                .foregroundStyle(FusionPalette.primaryText(scheme))
                .padding(.horizontal, CrumbButtonStyle.horizontalPadding)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
        } else {
            Button { model.drill(into: row.id) } label: { label(row, index: index, iconOnly: iconOnly) }
                .buttonStyle(CrumbButtonStyle())
                .help(iconOnly ? Text(verbatim: row.name) : Text(verbatim: ""))
                .accessibilityLabel(Text(verbatim: row.name))
        }
    }

    /// "…": the collapsed folders, each a jump back up.
    private func middle(_ range: ClosedRange<Int>) -> some View {
        Menu {
            ForEach(model.breadcrumb[range], id: \.id) { row in
                Button { model.drill(into: row.id) } label: { Text(verbatim: row.name) }
            }
        } label: {
            Text(verbatim: "…")
        }
        .menuStyle(.button)
        .buttonStyle(CrumbButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("Cartelle intermedie"))
        .accessibilityLabel(Text("Cartelle intermedie"))
    }

    /// `iconOnly`: the root's icon without its name, when nothing else fits.
    private func label(_ row: NodeRow, index: Int, iconOnly: Bool) -> some View {
        Label {
            if !iconOnly { Text(verbatim: row.name).truncationMode(.middle) }
        } icon: {
            if index == 0 {
                Image(systemName: model.scansStartupDisk ? "internaldrive" : "folder")
            }
        }
        .labelStyle(CrumbLabelStyle())
    }

    private static func chevron(_ scheme: ColorScheme) -> some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(FusionPalette.secondaryText(scheme).opacity(0.7))
            .accessibilityHidden(true)
    }

    /// The narrowest the path can get, hidden, for the window's minimum: the root's icon, "…" and the
    /// last component with its name cut to "…".
    struct Narrowest: View {
        @Environment(\.colorScheme) private var scheme

        var body: some View {
            HStack(spacing: 2) {
                Image(systemName: "internaldrive")
                    .padding(.horizontal, CrumbButtonStyle.horizontalPadding)
                BreadcrumbView.chevron(scheme)
                Text(verbatim: "…").padding(.horizontal, CrumbButtonStyle.horizontalPadding)
                BreadcrumbView.chevron(scheme)
                Text(verbatim: "…").fontWeight(.semibold).padding(.horizontal, CrumbButtonStyle.horizontalPadding)
            }
            .lineLimit(1)
            .fixedSize()
        }
    }
}

private struct CrumbLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon
            configuration.title
        }
    }
}

/// A path component's chrome (and the list's back button's): a soft highlight while hovered or
/// pressed; dimmed and inert while disabled.
struct CrumbButtonStyle: ButtonStyle {
    static let horizontalPadding: CGFloat = WindowLayout.chromeBleed
    static let verticalPadding: CGFloat = 3

    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let active = isEnabled && hovering
        configuration.label
            .foregroundStyle(active ? FusionPalette.primaryText(scheme) : FusionPalette.secondaryText(scheme))
            .opacity(isEnabled ? 1 : 0.45)
            .padding(.horizontal, Self.horizontalPadding)
            .padding(.vertical, Self.verticalPadding)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(FusionPalette.primaryText(scheme).opacity(
                        isEnabled && configuration.isPressed ? 0.12 : active ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerStyle(isEnabled ? .link : nil)
    }
}
