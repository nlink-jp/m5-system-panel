// Copied from util-series/net-meter bcdefee Sources/NetMeterSystem/PathOrderMonitor.swift — keep in step with the original.
import Foundation
import PanelCore
import Network

/// The OS interface preference order, kept current by `NWPathMonitor`.
///
/// The list is passed on as the OS gives it — the same interface may appear more
/// than once, and a VPN tunnel appears with kind `.other`. Making sense of it is
/// `resolveInterface`'s job, not this type's.
public final class PathOrderMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "jp.nlink.m5-system-panel.path")
    private let lock = NSLock()
    private var order: [PathInterface] = []
    private var hasDelivered = false

    public init() {}

    /// The most recent order; empty until the first update arrives.
    public var current: [PathInterface] {
        lock.lock()
        defer { lock.unlock() }
        return order
    }

    /// - Parameter onChange: called on a private queue, once soon after `start`
    ///   and again whenever the order changes. Hop to the main actor before
    ///   touching UI.
    public func start(onChange: @escaping @Sendable ([PathInterface]) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let order = path.availableInterfaces.map {
                PathInterface(name: $0.name, kind: Self.kind(of: $0.type))
            }
            guard let self else { return }
            self.lock.lock()
            // The first update is always passed on, even an empty one: offline,
            // "no interfaces" is the news.
            let changed = order != self.order || !self.hasDelivered
            self.order = order
            self.hasDelivered = true
            self.lock.unlock()
            if changed { onChange(order) }
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }

    static func kind(of type: NWInterface.InterfaceType) -> InterfaceKind {
        switch type {
        case .wifi: return .wifi
        case .wiredEthernet: return .wiredEthernet
        case .cellular: return .cellular
        case .loopback: return .loopback
        case .other: return .other
        @unknown default: return .other
        }
    }
}
