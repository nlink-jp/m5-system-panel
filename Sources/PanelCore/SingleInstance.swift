import Foundation

/// Startup single-instance guard decision.
///
/// macOS can start a second copy of the app while one is already running:
/// LaunchServices resolves the bundle identifier among *all* registered copies
/// (dev build in `dist/`, a release-verification extraction, `/Applications`)
/// and may pick a different copy than the running one. Two copies would stack
/// two menu bar items and open two connections to the panel.
/// `LSMultipleInstancesProhibited` in Info.plist is the LaunchServices-level
/// guard; this decision covers the launch paths LS does not see (direct binary
/// exec, `open -n`).
public enum SingleInstanceDecision: Equatable, Sendable {
    /// No other instance — continue launching.
    case proceed
    /// Another instance already owns the menu bar item; log and exit.
    case exitDuplicate(message: String)
}

/// - Parameters:
///   - bundleID: `Bundle.main.bundleIdentifier` — nil for the bare dev
///     binary, which cannot enumerate instances and always proceeds.
///   - ownPID: this process.
///   - instancePIDs: pids of running apps with the same bundle identifier;
///     may or may not include `ownPID`.
public func singleInstanceDecision(
    bundleID: String?,
    ownPID: Int32,
    instancePIDs: [Int32]
) -> SingleInstanceDecision {
    guard bundleID != nil else { return .proceed }
    let others = instancePIDs.filter { $0 != ownPID }
    guard !others.isEmpty else { return .proceed }
    let pids = others.map(String.init).joined(separator: ", ")
    return .exitDuplicate(
        message: "m5-system-panel: another instance is already running (pid \(pids)) — exiting"
    )
}
