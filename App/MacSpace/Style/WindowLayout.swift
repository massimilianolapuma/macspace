import CoreGraphics

/// The window's spacing, in one place: a 20 pt margin from the window's edges to the content, an
/// 8 pt grid between elements, and one inner margin inside the inspector.
enum WindowLayout {
    /// From the content area's edges (below the toolbar) to the path row, the chart and the legend.
    static let windowMargin: CGFloat = 20
    /// Between stacked elements.
    static let gap: CGFloat = 8
    /// From the inspector's edges to its content: the segmented control, the list header, the rows'
    /// content and the selection bar.
    static let inspectorMargin: CGFloat = 16
    /// How far a hover highlight (a path component, a list row) reaches past the edge its content
    /// aligns to, so the text lines up and the highlight still has room around it.
    static let chromeBleed: CGFloat = 6
    /// The path row above the chart and the list's header row; as tall as a regular control, so the
    /// path row and the inspector's segmented control share one line.
    static let rowHeight: CGFloat = 24
    /// A list row's checkbox column, and the back button above it: the smallest comfortable target.
    static let rowSlot: CGFloat = 24

    /// The inspector's width range.
    static let inspectorMinWidth: CGFloat = 260
    static let inspectorIdealWidth: CGFloat = 300
    static let inspectorMaxWidth: CGFloat = 420

    /// The smallest window, inspector shown or not: the toolbar's widest state (a startup-disk
    /// scan's progress bar and "Analisi in corso… 8.888.888 file · 888,88 GB", plus "Interrompi"
    /// and the inspector button) fits without any item going into the overflow menu. The content
    /// area's minimum is this less the inspector's current width.
    static let minWindowWidth: CGFloat = 1100
    /// The content's minimum height; with the content under the toolbar, the window's minimum is
    /// 572 pt, as before.
    static let minContentHeight: CGFloat = 468
}
