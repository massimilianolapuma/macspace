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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                BreadcrumbView(model: model)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .opacity(model.breadcrumb.isEmpty ? 0 : 1)
                SunburstView(model: model)
                    .padding([.horizontal, .bottom], 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            BiggestListView(model: model)
                .frame(width: 260)
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
            if model.isScanning { model.start(target) }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(dismiss: { showOnboarding = false })
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
            status
        }
        ToolbarItem(placement: .primaryAction) {
            if model.isScanning {
                Button("Interrompi", systemImage: "stop.fill") { model.cancel() }
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Analizza", systemImage: "play.fill") { model.start(target) }
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    /// Scan state and file count; the byte total lives only in the chart's center.
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
                Text("Analisi interrotta · \(Formatters.count(summary.files)) file")
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
        case let .done(summary):
            Text("\(Formatters.count(summary.files)) file")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
        case .idle:
            EmptyView()
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
