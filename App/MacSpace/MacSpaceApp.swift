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
    @FocusedValue(\.goUp) private var goUp

    var body: some Commands {
        CommandMenu("Vai") {
            Button("Cartella superiore") { goUp?() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(goUp == nil)
        }
    }
}

/// Going up a level in one window's scan, published by the key window only while it can: below the
/// root, and with no sheet up. A value, so the menu's enabled state follows it without depending on
/// Observation inside `Commands`.
struct GoUpAction: Equatable {
    let model: ScanModel

    @MainActor func callAsFunction() { model.goUp() }

    static func == (lhs: GoUpAction, rhs: GoUpAction) -> Bool { lhs.model === rhs.model }
}

extension FocusedValues {
    /// The key window's way up a level; nil while it has none.
    @Entry var goUp: GoUpAction?
}
