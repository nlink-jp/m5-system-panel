// Phase 1 check (ADR-0002 consequence): can an unprivileged process read the
// Wi-Fi interface's router address through a public API? Read-only.
// Run: swift spikes/wifi_router.swift
import Foundation
import SystemConfiguration

guard let store = SCDynamicStoreCreate(nil, "wifi_router" as CFString, nil, nil) else {
    print("SCDynamicStoreCreate failed"); exit(1)
}
// Which BSD name is Wi-Fi (not assumed to be en1).
let wifi = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? [])
    .filter { SCNetworkInterfaceGetInterfaceType($0) as String? == kSCNetworkInterfaceTypeIEEE80211 as String }
    .compactMap { SCNetworkInterfaceGetBSDName($0) as String? }
print("Wi-Fi interfaces:", wifi)

let pattern = "State:/Network/Service/[^/]+/IPv4" as CFString
let keys = SCDynamicStoreCopyKeyList(store, pattern) as? [String] ?? []
for key in keys {
    guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
          let name = value["InterfaceName"] as? String, wifi.contains(name) else { continue }
    let router = value["Router"] as? String ?? "(none)"
    print("\(name): Router key present=\(value["Router"] != nil) routerIsPrivateIPv4=\(router.hasPrefix("10.") || router.hasPrefix("192.168.") || router.hasPrefix("172."))")
}
