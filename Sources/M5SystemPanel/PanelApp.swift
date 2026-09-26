import AppKit
import PanelCore
import SwiftUI

/// The menu bar item and its menu. Scaffold only: the status line is fixed until
/// discovery and the connection exist (RFP §2, "Companion menu").
struct PanelApp: App {
    private let version = displayVersion(
        bundleShortVersion: Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
    )

    var body: some Scene {
        MenuBarExtra("m5-system-panel", systemImage: "gauge.with.dots.needle.33percent") {
            Text("Not set up")
            Divider()
            Text("m5-system-panel \(version)")
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .menuBarExtraStyle(.menu)
    }
}
