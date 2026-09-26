import Foundation

/// The companion's side of a setup session (protocol v1 §5.2), as a pure state
/// machine: lines and user choices go in, actions come out. The caller owns the
/// connection, the Keychain and the UI; this type owns the order of things.
///
/// Key handling: the key is stored as *provisional* when `KEY` arrives, and only
/// committed — replacing the previous registration — when `DONE` arrives. Any
/// other ending discards the provisional key and keeps the previous registration.
public struct SetupExchange: Sendable {
    public enum Phase: Equatable, Sendable {
        case awaitingGreeting
        /// The panel answered; the menu may offer "Start setup".
        case ready(deviceID: String)
        case listing(deviceID: String, networks: [ScannedNetwork])
        case listed(deviceID: String, networks: [ScannedNetwork])
        case awaitingKey(deviceID: String)
        case awaitingDone(deviceID: String)
        case finished(deviceID: String)
        case failed(Failure)
    }

    public enum Failure: Equatable, Sendable {
        /// `SETUP` with a version other than 1.
        case firmwareMismatch(version: Int)
        /// A malformed or unexpected line; the connection is closed.
        case protocolViolation
        /// The connection ended before `DONE`.
        case incomplete
        /// No line from the panel for the idle limit.
        case timedOut
        /// The Keychain refused the key. Before STORED nothing reaches the panel's
        /// NVS; after DONE the panel holds a key this Mac does not (redo setup).
        case storageFailed
    }

    public enum Action: Equatable, Sendable {
        case send(String)
        case storeProvisionalKey(deviceID: String, key: [UInt8])
        case commitProvisionalKey(deviceID: String)
        case discardProvisionalKey
        case close
    }

    public static let idleLimit: Duration = .seconds(60)

    public private(set) var phase: Phase = .awaitingGreeting
    private var holdsProvisionalKey = false

    public init() {}

    /// A line from the panel.
    public mutating func receive(_ line: String) -> [Action] {
        switch phase {
        case .awaitingGreeting:
            guard let greeting = SetupGreeting.parse(line) else { return fail(.protocolViolation) }
            guard greeting.version == 1 else { return fail(.firmwareMismatch(version: greeting.version)) }
            phase = .ready(deviceID: greeting.deviceID)
            return []
        case .listing(let id, let networks):
            if line == SetupWord.end.rawValue {
                phase = .listed(deviceID: id, networks: networks)
                return []
            }
            guard let network = ScannedNetwork.parse(line), networks.count < ScannedNetwork.maxLines
            else { return fail(.protocolViolation) }
            phase = .listing(deviceID: id, networks: networks + [network])
            return []
        case .awaitingKey(let id):
            guard let delivery = KeyDelivery.parse(line) else { return fail(.protocolViolation) }
            holdsProvisionalKey = true
            phase = .awaitingDone(deviceID: id)
            // Store first: the caller calls storageFailed() instead of sending STORED if it fails.
            return [.storeProvisionalKey(deviceID: id, key: delivery.key), .send(SetupWord.stored.rawValue)]
        case .awaitingDone(let id):
            guard line == SetupWord.done.rawValue else { return fail(.protocolViolation) }
            holdsProvisionalKey = false
            phase = .finished(deviceID: id)
            return [.commitProvisionalKey(deviceID: id), .close]
        case .ready, .listed, .finished, .failed:
            // The panel speaks only when asked (or to finish); anything else is a violation.
            return fail(.protocolViolation)
        }
    }

    /// The user asked for the network list.
    public mutating func requestList() -> [Action] {
        guard case .ready(let id) = phase else { return [] }
        phase = .listing(deviceID: id, networks: [])
        return [.send(SetupWord.list.rawValue)]
    }

    /// The user chose a network (from the list or typed) and its password.
    public mutating func join(ssid: [UInt8], password: [UInt8]?) -> [Action] {
        let id: String
        switch phase {
        case .ready(let deviceID), .listed(let deviceID, _): id = deviceID
        default: return []
        }
        guard let line = JoinRequest(ssid: ssid, password: password).line else { return [] }
        phase = .awaitingKey(deviceID: id)
        return [.send(line)]
    }

    /// The connection ended (either side).
    public mutating func connectionClosed() -> [Action] {
        switch phase {
        case .finished, .failed:
            return []
        default:
            return fail(.incomplete, close: false)
        }
    }

    /// The caller could not store the provisional key, or could not commit it.
    /// Before STORED: close without sending it, so the panel saves nothing.
    public mutating func storageFailed() -> [Action] {
        switch phase {
        case .finished, .failed:
            phase = .failed(.storageFailed)
            return []
        default:
            return fail(.storageFailed)
        }
    }

    /// No line from the panel for `idleLimit` while one was expected.
    public mutating func idleTimeout() -> [Action] {
        switch phase {
        case .listing, .awaitingKey, .awaitingDone: return fail(.timedOut)
        default: return []
        }
    }

    private mutating func fail(_ failure: Failure, close: Bool = true) -> [Action] {
        var actions: [Action] = []
        if holdsProvisionalKey {
            actions.append(.discardProvisionalKey)
            holdsProvisionalKey = false
        }
        if close { actions.append(.close) }
        phase = .failed(failure)
        return actions
    }
}
