// Copied from util-series/net-meter bcdefee Sources/NetMeterSystem/LoginItemService.swift — keep in step with the original.
import Foundation
import PanelCore
import ServiceManagement

/// `SMAppService` for the app itself. Gated on running from a real bundle,
/// because the service fails without one.
public struct LoginItemService: Sendable {
    public init() {}

    public var state: LoginItemState {
        guard Bundle.main.bundleIdentifier != nil else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .on
        case .requiresApproval: return .requiresApproval
        // `.notFound` is what an app that has never been registered reports. It
        // is "not yet", not "cannot": the toggle stays usable.
        case .notRegistered, .notFound: return .off
        @unknown default: return .off
        }
    }

    public func set(_ on: Bool) throws {
        guard Bundle.main.bundleIdentifier != nil else { return }
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
