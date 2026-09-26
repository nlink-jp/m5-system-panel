import AppKit
import PanelCore
import SwiftUI

/// The menu bar item, its menu (RFP §2 "Companion menu") and the setup window.
struct PanelApp: App {
    @State private var model = AppModel()
    private let version = displayVersion(
        bundleShortVersion: Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
    )

    var body: some Scene {
        MenuBarExtra("m5-system-panel", systemImage: "gauge.with.dots.needle.33percent") {
            PanelMenu(model: model, version: version)
        }
        .menuBarExtraStyle(.menu)

        Window("パネルの設定", id: "setup") {
            SetupView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)  // opened from the menu only, never at launch
    }
}

private struct PanelMenu: View {
    @Bindable var model: AppModel
    let version: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        if let hint = model.hintText { Text(hint) }
        if let error = model.lastError { Text(error) }
        Divider()
        if model.setupOffered || model.registration == nil {
            Button(MenuText.startSetup) {
                openWindow(id: "setup")
                NSApp.activate()
            }
        }
        if model.registration != nil {
            Button(MenuText.unregister) {
                if confirmUnregister() { model.unregister() }
            }
        }
        Toggle(MenuText.launchAtLogin, isOn: Binding(
            get: { model.loginItem.isOn },
            set: { model.setLoginItem($0) }))
            .disabled(model.loginItem == .unavailable)
        Divider()
        Text("m5-system-panel \(version)")
        Button(MenuText.quit) { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func confirmUnregister() -> Bool {
        let alert = NSAlert()
        alert.messageText = "パネルの登録を解除しますか？"
        alert.informativeText = "この Mac に保存した鍵を消します。パネルを使うには、もう一度設定が必要です。"
        alert.addButton(withTitle: "解除")
        alert.addButton(withTitle: "キャンセル")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}
