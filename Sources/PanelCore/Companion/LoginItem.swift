// Copied from util-series/net-meter bcdefee Sources/NetMeterCore/LoginItem.swift — keep in step with the original.
/// Launch at login, as the system reports it. This is system state: it is read
/// from and written to the OS directly and never mirrored in the app's settings.
public enum LoginItemState: Equatable, Sendable {
    /// Not running from an app bundle (`swift run`): there is nothing to register.
    case unavailable
    case off
    case on
    /// Registered, but waiting for the user's approval in System Settings.
    case requiresApproval

    public var isOn: Bool { self == .on || self == .requiresApproval }
}
