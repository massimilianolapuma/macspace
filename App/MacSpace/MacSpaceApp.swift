import SwiftUI

@main
struct MacSpaceApp: App {
    /// One for the whole app: every window's scans judge against the same apps index, built once.
    @State private var safety = SafetyEnvironmentProvider()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(safety)
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // The View menu's show/hide inspector item and its ⌃⌘I shortcut.
            InspectorCommands()
            GoCommands()
        }
    }
}

/// "Vai › Cartella superiore" (⌘↑), as in Finder; it acts on the key window's scan.
struct GoCommands: Commands {
    @FocusedValue(\.scanModel) private var model

    var body: some Commands {
        CommandMenu("Vai") {
            Button("Cartella superiore") { model?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled((model?.breadcrumb.count ?? 0) < 2)
        }
    }
}

extension FocusedValues {
    /// The key window's scan, for the menu bar's commands.
    @Entry var scanModel: ScanModel?
}
