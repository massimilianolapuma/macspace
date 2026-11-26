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
    /// Shared by every window (`MacSpaceApp`); starts itself once, on the first window.
    @Environment(SafetyEnvironmentProvider.self) private var safety
    @AppStorage(ColorMode.storageKey) private var colorMode: ColorMode = .deletable
    @AppStorage(ChartKind.storageKey) private var chart: ChartKind = .sunburst
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    BreadcrumbView(model: model)
                    if chart == .treemap {
                        folderTotal
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .opacity(model.breadcrumb.isEmpty ? 0 : 1)
                Group {
                    switch chart {
                    case .sunburst: SunburstView(model: model, colorMode: colorMode)
                    case .treemap: TreemapView(model: model, colorMode: colorMode)
                    }
                }
                .reportsChartSize(to: model)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
                ChartLegend(model: model, mode: colorMode)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            SidebarView(model: model, colorMode: colorMode)
                .frame(width: 300)
                .frame(maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(FusionPalette.background(scheme))
        .background {
            // ⌘↑ goes up a level, as in Finder.
            Button { model.goUp() } label: { EmptyView() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(model.breadcrumb.count < 2)
                .opacity(0)
                .accessibilityHidden(true)
        }
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
        ToolbarItem(placement: .status) {
            status
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
    }

    /// Scans `target`; the installed apps are indexed again meanwhile (apps installed or removed
    /// since launch), keeping the previous index until the new one lands.
    private func startScan() {
        safety.rebuildApps()
        model.start(target)
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

    /// Scan state and file count (and the folders it could not read); the byte total lives only
    /// in the chart's center.
    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case let .scanning(progress):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                CountingText(UInt64(progress.filesSeen)) { Text("Analisi in corso… \(Formatters.count(Int($0))) file") }
                    .monospacedDigit()
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: progress.filesSeen)
                    .lineLimit(1)
                    .frame(minWidth: 190, alignment: .leading)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        case let .done(summary) where summary.wasCancelled:
            HStack(spacing: 6) {
                Image(systemName: "pause.circle")
                Text(verbatim: Self.withUnreadable(
                    String(localized: "Analisi interrotta · \(Formatters.count(summary.files)) file"), summary))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        case let .done(summary):
            Text(verbatim: Self.withUnreadable(String(localized: "\(Formatters.count(summary.files)) file"), summary))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
        case .idle:
            EmptyView()
        }
    }

    /// The current folder's size (and the disk's capacity at its root): the treemap has no
    /// center to show it in, as the sunburst does.
    private var folderTotal: some View {
        HStack(spacing: 4) {
            Text(verbatim: Formatters.bytes(model.breadcrumb.last?.size ?? 0))
                .fontWeight(.semibold)
                .foregroundStyle(FusionPalette.primaryText(scheme))
            if model.center == FileTree.root, let capacity = model.capacity {
                Text("di \(Formatters.bytes(capacity))")
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
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
