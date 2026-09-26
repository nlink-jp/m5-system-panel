// Copied from util-series/net-meter bcdefee Sources/NetMeterCore/InterfaceResolver.swift — keep in step with the original.
/// What kind of interface the OS says this is.
public enum InterfaceKind: Equatable, Sendable {
    case wifi, wiredEthernet, cellular, loopback, other

    /// A link that carries traffic itself, as opposed to a tunnel riding on one.
    public var isPhysical: Bool { self == .wifi || self == .wiredEthernet }
}

/// One entry of the OS interface preference order.
public struct PathInterface: Equatable, Sendable {
    public var name: String
    public var kind: InterfaceKind

    public init(name: String, kind: InterfaceKind) {
        self.name = name
        self.kind = kind
    }
}

/// What the user asked to see.
public enum InterfaceSelection: Equatable, Sendable {
    case automatic
    case manual(String)

    /// The persisted form: an empty or missing value means automatic.
    public init(storedValue: String?) {
        if let name = storedValue, !name.isEmpty {
            self = .manual(name)
        } else {
            self = .automatic
        }
    }

    public var storedValue: String {
        switch self {
        case .automatic: return ""
        case .manual(let name): return name
        }
    }
}

/// Which interface is on display — or that there is none to show.
public enum ResolvedInterface: Equatable, Sendable {
    case present(String)
    /// A manual selection that is gone, or an automatic selection with no
    /// physical interface. Shown as "absent"; never replaced by another
    /// interface's numbers.
    case absent
}

/// - Parameters:
///   - selection: what the user asked for.
///   - pathOrder: the OS preference order. The same interface may be listed more
///     than once; only its first position matters.
///   - available: the interfaces that have counters right now.
public func resolveInterface(
    selection: InterfaceSelection,
    pathOrder: [PathInterface],
    available: Set<String>
) -> ResolvedInterface {
    switch selection {
    case .manual(let name):
        // Any interface with counters may be chosen by hand, tunnels included.
        return available.contains(name) ? .present(name) : .absent
    case .automatic:
        // A VPN tunnel sits above the physical link in this order; skipping
        // non-physical kinds is what keeps the link itself on display.
        let first = pathOrder.first { $0.kind.isPhysical && available.contains($0.name) }
        return first.map { .present($0.name) } ?? .absent
    }
}
