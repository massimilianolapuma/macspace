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
                        .padding(.horizontal, 6)
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

private struct CrumbButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? FusionPalette.primaryText(scheme) : FusionPalette.secondaryText(scheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(FusionPalette.primaryText(scheme).opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerStyle(.link)
    }
}
