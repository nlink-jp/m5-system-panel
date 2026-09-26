import Foundation
import SystemConfiguration

/// The Wi-Fi interface and the IPv4 router it received, read without any
/// privilege from the dynamic store (measured: spikes/README.md "Phase 1
/// checks"). Protocol v1 §5.1 opens a setup session only to this address, over
/// a connection pinned to this interface.
public enum WiFiRouter {
    public struct Route: Equatable, Sendable {
        public let interface: String  // BSD name, e.g. en1
        public let router: String     // dotted IPv4
    }

    /// nil when there is no Wi-Fi interface or it has no IPv4 router.
    public static func current() -> Route? {
        guard let store = SCDynamicStoreCreate(nil, "m5-system-panel" as CFString, nil, nil) else { return nil }
        let wifi = Set((SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [])
            .filter { SCNetworkInterfaceGetInterfaceType($0) as String? == kSCNetworkInterfaceTypeIEEE80211 as String }
            .compactMap { SCNetworkInterfaceGetBSDName($0) as String? })
        let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] ?? []
        for key in keys {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let name = value["InterfaceName"] as? String, wifi.contains(name),
                  let router = value["Router"] as? String else { continue }
            return Route(interface: name, router: router)
        }
        return nil
    }
}
