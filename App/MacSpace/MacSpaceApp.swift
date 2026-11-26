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
        }
    }
}
