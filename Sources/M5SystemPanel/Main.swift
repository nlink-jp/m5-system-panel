import AppKit
import PanelCore

@main
@MainActor
enum Main {
    static func main() {
        // Two instances would stack two menu bar items and connect twice.
        // LSMultipleInstancesProhibited (Info.plist) stops LaunchServices
        // launches; this guard stops the rest (direct exec, `open -n`).
        let bundleID = Bundle.main.bundleIdentifier
        let instancePIDs = bundleID.map { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .map(\.processIdentifier)
        } ?? []
        if case .exitDuplicate(let message) = singleInstanceDecision(
            bundleID: bundleID,
            ownPID: ProcessInfo.processInfo.processIdentifier,
            instancePIDs: instancePIDs
        ) {
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(0)
        }

        // An accessory app through LSUIElement in Info.plist.
        PanelApp.main()
    }
}
