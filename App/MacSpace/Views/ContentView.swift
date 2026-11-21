import AppKit
import MacSpaceCore
import SwiftUI

struct ContentView: View {
    @State private var model = ScanModel()
    @State private var target: ScanTarget = .startupDisk
    @State private var chosenFolder: URL?
    @State private var choosingFolder = false
    @State private var showOnboarding = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            chartPlaceholder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            listPlaceholder
                .frame(width: 260)
                .frame(maxHeight: .infinity)
        }
        .background(FusionPalette.background(scheme))
        .toolbar { toolbar }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                chosenFolder = url
                target = .folder(url)
            }
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
                    Text("Macintosh HD").tag(ScanTarget.startupDisk)
                    if let chosenFolder {
                        Text(verbatim: Self.displayName(chosenFolder)).tag(ScanTarget.folder(chosenFolder))
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
            .disabled(model.isScanning)
        }
        ToolbarItem(placement: .status) {
            if case let .scanning(progress) = model.phase {
                Text("Analisi in corso… \(Formatters.count(progress.filesSeen)) file · \(Formatters.bytes(progress.bytesSeen))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
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

    private var targetName: String {
        switch target {
        case .startupDisk: String(localized: "Macintosh HD")
        case let .folder(url): Self.displayName(url)
        }
    }

    private static func displayName(_ url: URL) -> String {
        FileManager.default.displayName(atPath: url.path(percentEncoded: false))
    }

    // Placeholders until the sunburst and the biggest list exist (Task 8).

    private var chartPlaceholder: some View {
        VStack(spacing: 4) {
            if let current = model.breadcrumb.last {
                Text(verbatim: Formatters.bytes(current.size))
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(FusionPalette.primaryText(scheme))
                Text(verbatim: current.name)
                    .foregroundStyle(FusionPalette.secondaryText(scheme))
            }
        }
    }

    private var listPlaceholder: some View {
        List(model.biggest) { row in
            HStack {
                Text(verbatim: row.name).lineLimit(1)
                Spacer()
                Text(verbatim: Formatters.bytes(row.size))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
    }
}

private struct OnboardingView: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Serve l'accesso completo al disco")
                    .font(.title2.weight(.semibold))
            } icon: {
                Image(systemName: "lock.shield")
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            Text("Per vedere tutto lo spazio, MacSpace deve poter leggere anche le cartelle di sistema e la Libreria. Puoi analizzare anche senza: le cartelle non leggibili saranno segnate.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Continua senza", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Apri Impostazioni di Sistema") { FullDiskAccess.openSettings() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}

/// Number and size formatting for the UI: Italian locale; sizes as Finder shows them
/// (allocated bytes, `.file` count style).
enum Formatters {
    private static let locale = Locale(identifier: "it_IT")

    static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .file).locale(locale))
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }
}
