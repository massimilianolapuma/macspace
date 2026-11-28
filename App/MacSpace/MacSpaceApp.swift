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
            ScanCommands()
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

/// "Archivio › Analisi completa": the key window's target scanned again in full, its snapshot
/// (if one is shown) staying on screen until the scan ends.
struct ScanCommands: Commands {
    @FocusedValue(\.fullScan) private var fullScan

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Analisi completa") { fullScan?() }
                .disabled(fullScan == nil)
        }
    }
}

/// A full scan of one window's target, published by the key window while it can start one (see
/// `GoUpAction`); the installed apps are indexed again, as for "Analizza".
struct FullScanAction: Equatable {
    let model: ScanModel
    let safety: SafetyEnvironmentProvider
    let target: ScanTarget

    @MainActor func callAsFunction() {
        safety.rebuildApps()
        model.fullScan(target)
    }

    static func == (lhs: FullScanAction, rhs: FullScanAction) -> Bool {
        lhs.model === rhs.model && lhs.safety === rhs.safety && lhs.target == rhs.target
    }
}

extension FocusedValues {
    /// The key window's way up a level; nil while it has none.
    @Entry var goUp: GoUpAction?
    /// The key window's full scan; nil while it cannot start one.
    @Entry var fullScan: FullScanAction?
}
