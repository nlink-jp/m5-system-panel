import Foundation

/// The companion's run-session supervision (ADR-0001 decision 1; protocol v1 §2,
/// §4.1) as a pure state machine. Time and randomness are injected; the caller
/// owns the NWBrowser, the NWConnections and the menu.
///
/// | Connection state      | Handling                                              |
/// |-----------------------|-------------------------------------------------------|
/// | `.preparing` 10 s     | cancel and recreate (the OS never leaves it itself)   |
/// | `.waiting`            | leave to the OS; PolicyDenied → "permission required" |
/// | `.failed`/`.cancelled`| recreate after 5 s                                    |
/// | no verified ack 5 s   | "not responding"; cancel and recreate                 |
///
/// Browse results only supply candidates; whether the panel is there is decided
/// by the connection and its acknowledgements.
public struct ConnectionSupervisor: Sendable {
    public enum Status: Equatable, Sendable {
        case searching
        case connected(deviceID: String)
        case notResponding
        case permissionRequired
        case firmwareMismatch
    }

    /// What the OS reports for a connection.
    public enum ConnectionEvent: Equatable, Sendable {
        case preparing
        /// `isPolicyDenied`: the error is `.dns(-65570)` or the path's reason is
        /// `.localNetworkDenied` (ADR-0001 3b: macOS 27 reported the former).
        case waiting(isPolicyDenied: Bool)
        case ready
        case failed
        case cancelled
    }

    public enum Action: Equatable, Sendable {
        case connect(connection: Int, endpoint: String)
        case cancel(connection: Int)
        case send(connection: Int, line: String)
        case status(Status)
    }

    public struct Timing: Sendable {
        public var preparingLimit: Double = 10
        public var ackLimit: Double = 5
        public var retryInterval: Double = 5
        public var avoidFailedFor: Double = 60
        public init() {}
    }

    private struct Current: Sendable {
        let id: Int
        let endpoint: String
        let createdAt: Double
        var preparingSince: Double?
        var readyAt: Double?
        var lastAck: Double?
        var session: CompanionSession
    }

    private let key: [UInt8]
    private let deviceID: String
    private let timing: Timing
    private var candidates: [String] = []
    private var avoidUntil: [String: Double] = [:]
    private var current: Current?
    private var nextID = 1
    private var nextCandidate = 0
    private var lastAttempt: Double?
    private var status: Status = .searching

    public init(key: [UInt8], deviceID: String, timing: Timing = Timing()) {
        self.key = key
        self.deviceID = deviceID
        self.timing = timing
    }

    public var currentStatus: Status { status }

    /// Browse results: (endpoint key, TXT `id`). Only this panel's ID is kept.
    public mutating func candidatesChanged(_ results: [(endpoint: String, deviceID: String?)]) {
        candidates = results.filter { $0.deviceID == deviceID }.map(\.endpoint)
    }

    /// Once a second: applies the time limits, sends `readings` on an established
    /// session, and starts a connection when there is none and the retry interval
    /// has passed.
    public mutating func tick(now: Double, readings: Readings) -> [Action] {
        var actions: [Action] = []
        if var c = current {
            if let since = c.preparingSince, now - since >= timing.preparingLimit {
                actions += drop(c.id, now: now, avoid: false)
            } else if let ready = c.readyAt, now - (c.lastAck ?? ready) >= timing.ackLimit {
                actions += setStatus(.notResponding)
                actions += drop(c.id, now: now, avoid: false)
            } else if let line = c.session.seal(readings) {
                current = c
                actions.append(.send(connection: c.id, line: line))
            }
        }
        if current == nil, lastAttempt.map({ now - $0 >= timing.retryInterval }) ?? true,
           let endpoint = pickCandidate(now: now) {
            let id = nextID
            nextID += 1
            lastAttempt = now
            current = Current(id: id, endpoint: endpoint, createdAt: now, preparingSince: nil,
                              readyAt: nil, lastAck: nil,
                              // Replaced with a fresh nonce when HELLO arrives (lineReceived).
                              session: CompanionSession(key: key, deviceID: deviceID, companionNonce: []))
            actions.append(.connect(connection: id, endpoint: endpoint))
        }
        return actions
    }

    public mutating func connectionEvent(_ event: ConnectionEvent, connection: Int, now: Double) -> [Action] {
        guard var c = current, c.id == connection else { return [] }
        switch event {
        case .preparing:
            if c.preparingSince == nil { c.preparingSince = now }
            current = c
            return []
        case .waiting(let denied):
            c.preparingSince = nil  // .waiting is the OS's to resolve
            current = c
            return denied ? setStatus(.permissionRequired) : []
        case .ready:
            c.preparingSince = nil
            c.readyAt = now
            current = c
            return []
        case .failed, .cancelled:
            current = nil
            if status == .connected(deviceID: deviceID) { return setStatus(.notResponding) }
            return []
        }
    }

    /// A line from the panel on `connection`. `nonce` must be 16 fresh random
    /// bytes (used when the line is HELLO); `readings` becomes frame 0.
    public mutating func lineReceived(
        _ line: String, connection: Int, now: Double, nonce: [UInt8], readings: Readings
    ) -> [Action] {
        guard var c = current, c.id == connection else { return [] }
        if !c.session.isEstablished {
            c.session = CompanionSession(key: key, deviceID: deviceID, companionNonce: nonce)
        }
        switch c.session.receive(line, firstReadings: readings) {
        case .send(let lines):
            current = c
            return lines.map { .send(connection: connection, line: $0) }
        case .acknowledged(_, _):
            c.lastAck = now
            current = c
            return setStatus(.connected(deviceID: deviceID))
        case .close(.firmwareMismatch):
            return setStatus(.firmwareMismatch) + drop(c.id, now: now, avoid: true)
        case .close(.wrongPanel), .close(.verificationFailed):
            return protocolViolation(connection: connection, now: now)
        }
    }

    /// The connection broke the protocol below the session (an over-long or
    /// non-ASCII line): a candidate that failed verification (§4.1 item 7).
    public mutating func protocolViolation(connection: Int, now: Double) -> [Action] {
        guard let c = current, c.id == connection else { return [] }
        let wasConnected = status == .connected(deviceID: deviceID)
        return (wasConnected ? setStatus(.notResponding) : []) + drop(c.id, now: now, avoid: true)
    }

    private mutating func drop(_ id: Int, now: Double, avoid: Bool) -> [Action] {
        if avoid, let endpoint = current?.endpoint { avoidUntil[endpoint] = now + timing.avoidFailedFor }
        current = nil
        return [.cancel(connection: id)]
    }

    private mutating func pickCandidate(now: Double) -> String? {
        let usable = candidates.filter { (avoidUntil[$0] ?? -.infinity) <= now }
        guard !usable.isEmpty else { return nil }
        let endpoint = usable[nextCandidate % usable.count]
        nextCandidate += 1
        return endpoint
    }

    private mutating func setStatus(_ new: Status) -> [Action] {
        guard new != status else { return [] }
        status = new
        return [.status(new)]
    }
}
