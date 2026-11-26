import AppKit
import MacSpaceCore
import SwiftUI

struct ContentView: View {
    @State private var model = ScanModel()
    @State private var target: ScanTarget = .startupDisk
    /// The folder picked with "Scegli cartella…" and its display name, resolved once.
    @State private var chosenFolder: (url: URL, name: String)?
    @State private var choosingFolder = false
    @State private var showOnboarding = false
    @State private var showHistory = false
    /// The inspector's tab, kept here so hiding and showing the inspector keeps it.
    @State private var inspectorTab = SidebarView.Tab.items
    /// Whether the inspector shows; app-wide and kept across launches (window restoration is off
    /// whenever "Close windows when quitting an app" is on, the system default).
    @AppStorage("inspectorShown") private var inspectorShown = true
    /// The inspector's current width: the content's minimum is what the window's minimum leaves beside it.
    @State private var inspectorWidth = WindowLayout.inspectorIdealWidth
    /// Shared by every window (`MacSpaceApp`); starts itself once, on the first window.
    @Environment(SafetyEnvironmentProvider.self) private var safety
    @AppStorage(ColorMode.storageKey) private var colorMode: ColorMode = .deletable
    @AppStorage(ChartKind.storageKey) private var chart: ChartKind = .sunburst
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minWidth: WindowLayout.minWindowWidth - (inspectorShown ? inspectorWidth : 0),
                   minHeight: WindowLayout.minContentHeight)
            // One surface from the window's top edge down: the toolbar floats over it, no band.
            .containerBackground(FusionPalette.background(scheme), for: .window)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .inspector(isPresented: $inspectorShown) {
                SidebarView(model: model, colorMode: colorMode, tab: $inspectorTab)
                    .inspectorColumnWidth(min: WindowLayout.inspectorMinWidth, ideal: WindowLayout.inspectorIdealWidth,
                                          max: WindowLayout.inspectorMaxWidth)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { inspectorWidth = $0 }
            }
            .background {
                // ⌘↑ and ⌘[ go up a level, as in Finder.
                ZStack {
                    upShortcut(.upArrow)
                    upShortcut("[")
                }
            }
            .goesUpOnMouseBack(model: model)
            .onChange(of: chart, initial: true) {
                // Only relays out the current folder: a running scan carries on.
                model.chart = chart
            }
            .onChange(of: safety.revision, initial: true) {
                model.updateEnvironment(safety.environment)
            }
            .task { safety.start() }
            .navigationTitle(Text(verbatim: model.breadcrumb.last?.name ?? "MacSpace"))
            .toolbar(removing: .title)
            .toolbar { toolbar }
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result {
                    // Resolved here, once: the toolbar reads the name on every progress update.
                    chosenFolder = (url, ScanModel.root(of: .folder(url)).name)
                    target = .folder(url)
                }
            }
            .onChange(of: target) {
                // Picking another target mid-scan replaces the running scan.
                if model.isScanning { startScan() }
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(dismiss: { showOnboarding = false })
            }
            .sheet(isPresented: trashSheetShown) {
                TrashSheet(model: model)
            }
            .onAppear { showOnboarding = !FullDiskAccess.isGranted }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                if FullDiskAccess.isGranted { showOnboarding = false }
            }
    }

    /// Before any scan, one empty state; from the moment a scan starts, the path row, the chart and
    /// the legend row, at fixed places.
    @ViewBuilder
    private var content: some View {
        if model.hasScan {
            VStack(spacing: WindowLayout.gap) {
                HStack(spacing: 12) {
                    BreadcrumbView(model: model)
                    // Never cut: the path gives way first.
                    PathRowFacts(model: model, showsTotal: chart == .treemap)
                        .layoutPriority(1)
                }
                .frame(height: WindowLayout.rowHeight)
                // The path's text, not its hover highlight, lines up with the chart's edge.
                .padding(.leading, -WindowLayout.chromeBleed)
                Group {
                    switch chart {
                    case .sunburst: SunburstView(model: model, colorMode: colorMode)
                    case .treemap: TreemapView(model: model, colorMode: colorMode)
                    }
                }
                .reportsChartSize(to: model)
                ChartLegend(model: model, mode: colorMode)
            }
            .padding(WindowLayout.windowMargin)
        } else {
            ContentUnavailableView {
                Label("Nessuna analisi", systemImage: "internaldrive")
            } description: {
                Text("Scegli cosa analizzare e premi Analizza")
            }
        }
    }

    /// A hidden button carrying a "go up a level" shortcut (⌘ + `key`).
    private func upShortcut(_ key: KeyEquivalent) -> some View {
        Button { model.goUp() } label: { EmptyView() }
            .keyboardShortcut(key, modifiers: .command)
            .disabled(model.breadcrumb.count < 2)
            .opacity(0)
            .accessibilityHidden(true)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                Picker(selection: $target) {
                    Text(verbatim: ScanModel.startupDiskName).tag(ScanTarget.startupDisk)
                    if let chosenFolder {
                        Text(verbatim: chosenFolder.name).tag(ScanTarget.folder(chosenFolder.url))
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
                Divider()
                Button("Scegli cartella…") { choosingFolder = true }
            } label: {
                Label(targetName, systemImage: target == .startupDisk ? "internaldrive" : "folder")
                    .labelStyle(.titleAndIcon)
            }
        }
        ToolbarItem(placement: .status) {
            ChartKindPicker(selection: $chart)
                .fixedSize()
                .help(Text("Vista"))
        }
        ToolbarItem(placement: .status) {
            Menu {
                Picker("Colori", selection: $colorMode) {
                    ForEach(ColorMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Colori", systemImage: "paintpalette")
            }
            .help(Text("Colori"))
        }
        ToolbarItem(placement: .primaryAction) {
            if !model.history.isEmpty {
                Button("Cronologia", systemImage: "clock.arrow.circlepath") { showHistory.toggle() }
                    .help(Text("Elementi spostati nel Cestino in questa sessione"))
                    .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                        HistoryPopover(entries: model.history)
                    }
            }
        }
        ToolbarItem(placement: .primaryAction) {
            if model.isScanning {
                Button("Interrompi", systemImage: "stop.fill") { model.cancel() }
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Analizza", systemImage: "play.fill") { startScan() }
                    .labelStyle(.titleAndIcon)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Pannello", systemImage: "sidebar.trailing") { inspectorShown.toggle() }
                .help(Text("Mostra o nasconde il pannello"))
        }
    }

    /// Scans `target`; the installed apps are indexed again meanwhile (apps installed or removed
    /// since launch), keeping the previous index until the new one lands.
    private func startScan() {
        safety.rebuildApps()
        model.start(target)
    }

    /// Up while the Trash confirmation or its result shows; closing it (never during a move)
    /// drops both.
    private var trashSheetShown: Binding<Bool> {
        Binding {
            model.pendingTrash != nil || model.trashReport != nil
        } set: { shown in
            guard !shown, !model.isTrashing else { return }
            model.pendingTrash = nil
            model.trashReport = nil
        }
    }

    /// The target's name after resolving links, as the chart root shows it.
    private var targetName: String {
        switch target {
        case .startupDisk: ScanModel.startupDiskName
        case .folder: chosenFolder?.name ?? ""
        }
    }
}

/// Tells the model the chart area's size, whichever chart is on screen, so the treemap is laid out
/// for the current size even when the window was resized while the sunburst showed. Resizing
/// relays out only once the size has held for `resizeDebounce`; the first report is immediate.
private struct ChartSizeReporter: ViewModifier {
    let model: ScanModel
    @State private var size: CGSize?
    @State private var reported = false

    static let resizeDebounce: Duration = .milliseconds(100)

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .task(id: size) {
                guard let size else { return }
                if reported {
                    try? await Task.sleep(for: Self.resizeDebounce)
                    guard !Task.isCancelled else { return }
                }
                reported = true
                if model.chartSize != size { model.chartSize = size }
            }
    }
}

private extension View {
    func reportsChartSize(to model: ScanModel) -> some View { modifier(ChartSizeReporter(model: model)) }
}

private extension View {
    /// The mouse's back button (button 3) goes up a level, as in Finder.
    func goesUpOnMouseBack(model: ScanModel) -> some View { modifier(MouseBackGoesUp(model: model)) }
}

/// Watches the mouse's back button while the window's content is on screen. Only clicks in this
/// window count, and none while a sheet (the Trash confirmation, the folder picker) is up.
private struct MouseBackGoesUp: ViewModifier {
    let model: ScanModel
    @State private var window = WindowReference()
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .background(WindowReader(reference: window))
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [window, model] event in
                    // Local monitors run on the main thread.
                    let handled = MainActor.assumeIsolated {
                        guard event.buttonNumber == 3, let own = window.window, event.window === own,
                              own.attachedSheet == nil, model.breadcrumb.count > 1
                        else { return false }
                        model.goUp()
                        return true
                    }
                    return handled ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

/// The window a view is in, once it is in one.
@MainActor
private final class WindowReference {
    weak var window: NSWindow?
}

private struct WindowReader: NSViewRepresentable {
    let reference: WindowReference

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.reference = reference
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var reference: WindowReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reference?.window = window
        }
    }
}

private struct OnboardingView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(.quaternary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Serve l'accesso completo al disco")
                        .font(.title3.weight(.semibold))
                    Text("Per vedere tutto lo spazio, MacSpace deve poter leggere anche le cartelle di sistema e la Libreria. Puoi analizzare anche senza: le cartelle non leggibili saranno segnate.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Label("Privacy e sicurezza › Accesso completo al disco › MacSpace", systemImage: "gearshape")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            HStack {
                Spacer()
                Button("Continua senza", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Apri Impostazioni di Sistema") { FullDiskAccess.openSettings() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 500)
    }
}

/// The path row's trailing side: the scan's state and, in the treemap (which has no center to show
/// them in), the current folder's total and, at the root of a finished startup-disk scan, the
/// disk's used space: "<totale> · <N file…> · Disco: <usato> occupati".
///
/// The scan's state: while scanning, an estimated progress bar against the disk's used space (a
/// spinner for a chosen folder, whose total is unknown) and "Analisi in corso… <file> · <byte>";
/// once done, at the root only, "<N> file" (it describes the whole scan, not a subfolder); after a
/// cancel, "Analisi interrotta · <N> file" at every level, since everything shown is partial. The
/// unreadable folders follow the count. Reads the progress itself, so the content view is not
/// re-evaluated on every progress update.
struct PathRowFacts: View {
    let model: ScanModel
    let showsTotal: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let progressWidth: CGFloat = 120

    private enum State {
        case scanning(ScanProgress)
        case cancelled(ScanSummary)
        case finished(ScanSummary)
    }

    var body: some View {
        let atRoot = model.breadcrumb.count == 1
        let state = state(atRoot: atRoot)
        // While a scan runs at the root, its bytes are the folder's total: no second figure.
        let total = showsTotal && !(model.isScanning && atRoot) ? model.breadcrumb.last?.size : nil
        let disk = showsTotal ? model.diskAtRoot : nil
        HStack(spacing: 4) {
            if let total {
                Text(verbatim: Formatters.bytes(total))
                    .fontWeight(.semibold)
                    .foregroundStyle(FusionPalette.primaryText(scheme))
                    .help(disk.map { Text(verbatim: $0.explanation(scanned: total)) } ?? Text(verbatim: ""))
                    .accessibilityLabel(Text(verbatim: disk.map {
                        Formatters.bytes(total) + ". " + $0.explanation(scanned: total)
                    } ?? Formatters.bytes(total)))
            }
            if let state {
                if total != nil { separator }
                status(state)
            }
            if let disk, let total {
                separator
                Text(verbatim: disk.line)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
                    .help(Text(verbatim: disk.explanation(scanned: total)))
                    // Spoken with the total.
                    .accessibilityHidden(true)
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }

    private func state(atRoot: Bool) -> State? {
        switch model.phase {
        case .idle: nil
        case let .scanning(progress): .scanning(progress)
        case let .done(summary) where summary.wasCancelled: .cancelled(summary)
        case let .done(summary): atRoot ? .finished(summary) : nil
        }
    }

    private var separator: some View {
        Text(verbatim: "·")
            .foregroundStyle(FusionPalette.secondaryText(scheme))
            .accessibilityHidden(true)
    }

    /// One VoiceOver element, with the words the toolbar status had.
    @ViewBuilder
    private func status(_ state: State) -> some View {
        Group {
            switch state {
            case let .scanning(progress):
                HStack(spacing: 8) {
                    // The estimate needs the disk's used space; a chosen folder's total is unknown.
                    if let disk = model.disk, disk.used > 0 {
                        let fraction = disk.progress(bytesSeen: progress.bytesSeen)
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .frame(width: Self.progressWidth)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: fraction)
                            .accessibilityLabel(Text("Avanzamento stimato"))
                            .accessibilityValue(Text("circa \(Int((fraction * 100).rounded()))%"))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    ZStack(alignment: .leading) {
                        // The widest line it is likely to reach, hidden: the width holds while the
                        // numbers grow, so the row never shifts.
                        Self.line(files: 8_888_888, bytes: Formatters.bytes(888_880_000_000)).hidden()
                        CountingText(UInt64(progress.filesSeen)) {
                            Self.line(files: Int($0), bytes: Formatters.bytes(progress.bytesSeen))
                        }
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: progress.filesSeen)
                    }
                }
            case let .cancelled(summary):
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle")
                    Text(verbatim: Self.withUnreadable(
                        String(localized: "Analisi interrotta · \(Formatters.count(summary.files)) file"), summary))
                }
            case let .finished(summary):
                Text(verbatim: Self.withUnreadable(String(localized: "\(Formatters.count(summary.files)) file"), summary))
            }
        }
        .foregroundStyle(FusionPalette.secondaryText(scheme))
        .accessibilityElement(children: .combine)
    }

    /// "Analisi in corso… <files> file · <bytes>".
    private static func line(files: Int, bytes: String) -> Text {
        Text("Analisi in corso… \(Formatters.count(files)) file · \(bytes)")
    }

    /// `line`, then " · N cartelle non leggibili" when the scan could not read some folders, so the
    /// count never reads as the whole disk.
    private static func withUnreadable(_ line: String, _ summary: ScanSummary) -> String {
        guard summary.unreadable > 0 else { return line }
        // Two strings rather than a catalog plural: the count is formatted like the file count.
        let folders = summary.unreadable == 1
            ? String(localized: "1 cartella non leggibile")
            : String(localized: "\(Formatters.count(summary.unreadable)) cartelle non leggibili")
        return line + " · " + folders
    }
}
