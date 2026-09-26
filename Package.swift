// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "m5-system-panel",
    // macOS 26 baseline. The string form is used deliberately — the Makefile reads
    // the deployment target from this line, so it is stated once.
    platforms: [.macOS("26.0")],
    targets: [
        // Pure, testable logic: the wire format, the shared constants, the state
        // machines. No AppKit, no OS calls, no clock.
        .target(
            name: "PanelCore"
        ),
        // The menu bar companion: wiring only. `resources:` stays empty on
        // purpose — SwiftPM's `Bundle.module` does not look inside an assembled
        // .app bundle.
        .executableTarget(
            name: "M5SystemPanel",
            dependencies: ["PanelCore"],
            resources: []
        ),
        .testTarget(
            name: "PanelCoreTests",
            dependencies: ["PanelCore"]
        ),
    ]
)
