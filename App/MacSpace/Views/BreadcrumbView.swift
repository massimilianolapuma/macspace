import MacSpaceCore
import SwiftUI

/// Path from the scan root to the current folder; earlier components jump back up.
struct BreadcrumbView: View {
    let model: ScanModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FusionPalette.secondaryText(scheme).opacity(0.7))
                        .accessibilityHidden(true)
                }
                if index == model.breadcrumb.count - 1 {
                    crumb(row, index: index)
                        .fontWeight(.semibold)
                        .foregroundStyle(FusionPalette.primaryText(scheme))
                        .padding(.horizontal, CrumbButtonStyle.horizontalPadding)
                        .layoutPriority(1)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    Button { model.drill(into: row.id) } label: { crumb(row, index: index) }
                        .buttonStyle(CrumbButtonStyle())
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func crumb(_ row: NodeRow, index: Int) -> some View {
        Label {
            Text(verbatim: row.name).truncationMode(.middle)
        } icon: {
            if index == 0 {
                Image(systemName: model.scansStartupDisk ? "internaldrive" : "folder")
            }
        }
        .labelStyle(CrumbLabelStyle())
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
