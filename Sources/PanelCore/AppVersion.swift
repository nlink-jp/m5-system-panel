import Foundation

/// The version string shown to the user.
///
/// A menu bar app has no `--version`, so the menu is the only place a user can
/// read which build they are running. The value is shown verbatim — the `v`
/// prefix and any `-dirty` / `-N-g<sha>` suffix stay, because a bug report is
/// only useful when it names the exact build.
///
/// - Parameter bundleShortVersion: `CFBundleShortVersionString`, which
///   `make build-app` fills in from `git describe`. It is nil outside a bundle
///   (`swift run`), and that reads as "dev".
public func displayVersion(bundleShortVersion: String?) -> String {
    guard let version = bundleShortVersion, !version.isEmpty else { return "dev" }
    return version
}
