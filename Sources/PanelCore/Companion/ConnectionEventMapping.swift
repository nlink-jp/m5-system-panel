import Foundation

/// How an NWConnection's report becomes a `ConnectionSupervisor.ConnectionEvent`.
///
/// Kept here, free of Network.framework, so the one decision that ADR-0001 3b
/// measured — denial arrives as `.waiting(.dns(-65570))` with reason
/// `notAvailable` on macOS 27, not as TN3179's `.localNetworkDenied` — is tested.
public enum ConnectionEventMapping {
    /// `kDNSServiceErr_PolicyDenied`.
    public static let policyDeniedDNSError: Int32 = -65570

    /// - Parameters:
    ///   - dnsErrorCode: the code when the waiting error is `.dns`, else nil.
    ///   - unsatisfiedIsLocalNetworkDenied: the path's reason is `.localNetworkDenied`.
    public static func isPolicyDenied(dnsErrorCode: Int32?, unsatisfiedIsLocalNetworkDenied: Bool) -> Bool {
        dnsErrorCode == policyDeniedDNSError || unsatisfiedIsLocalNetworkDenied
    }
}
