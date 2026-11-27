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

    // Named exceptions to the 8 pt grid, inside one component rather than between elements.

    /// Between the words, separators and marks of one line of text (the path row's facts).
    static let inlineSpacing: CGFloat = 4
    /// From the checkbox column to the text after it: AppKit's checkbox already leaves its own inset.
    static let checkboxTextGap: CGFloat = 2

    /// The inspector's width range.
    static let inspectorMinWidth: CGFloat = 260
    static let inspectorIdealWidth: CGFloat = 300
    static let inspectorMaxWidth: CGFloat = 420

    /// Between the path and its facts on the path row.
    static let pathRowSpacing: CGFloat = 2 * gap
    /// The path row's need (`ContentView.pathRowNeed`) as measured with the system font, so the
    /// first frame's minimum is already right; the live measurement replaces it.
    static let measuredPathRowNeed: CGFloat = 640
    /// The window's smallest width for the toolbar's controls (target, chart, colors, history,
    /// "Interrompi", inspector button) to stay out of the overflow menu. With the inspector shown the
    /// path row's need plus the inspector's width already exceeds it.
    static let minToolbarWidth: CGFloat = 720
    /// The content's minimum height; with the content under the toolbar, the window's minimum is
    /// 572 pt, as before.
    static let minContentHeight: CGFloat = 468
}
