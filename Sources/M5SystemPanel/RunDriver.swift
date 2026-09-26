import Foundation
import Network
import PanelCore
import PanelSystem
import Security

/// Carries ConnectionSupervisor's decisions out to Network.framework and brings
/// the OS's reports back in. All decisions are the supervisor's (ADR-0001
/// decision 1); this type only moves events and lines. Main actor throughout:
/// every callback is delivered on the main queue.
@MainActor
final class RunDriver {
    private let registration: Registration
    private let collector: MetricsCollector
    private let onStatus: (ConnectionSupervisor.Status) -> Void
    private var supervisor: ConnectionSupervisor
    private var browser: NWBrowser?
    private var endpoints: [String: NWEndpoint] = [:]
    private var connections: [Int: NWConnection] = [:]
    private var buffers: [Int: LineBuffer] = [:]
    private var seqs: [Int: UInt64] = [:]
    private var currentID: Int?
    private var latest: Readings?
    private var timer: Timer?
    private let started = ContinuousClock.now

    init(registration: Registration, collector: MetricsCollector,
         onStatus: @escaping (ConnectionSupervisor.Status) -> Void) {
        self.registration = registration
        self.collector = collector
        self.onStatus = onStatus
        supervisor = ConnectionSupervisor(key: registration.key, deviceID: registration.deviceID)
    }

    func start() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: PanelService.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.resultsChanged(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        browser?.cancel()
        browser = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private var now: Double {
        let elapsed = ContinuousClock.now - started
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>) {
        var candidates: [(endpoint: String, deviceID: String?)] = []
        var map: [String: NWEndpoint] = [:]
        for result in results {
            let key = "\(result.endpoint)"
            map[key] = result.endpoint
            var id: String?
            if case .bonjour(let txt) = result.metadata { id = txt["id"] }
            candidates.append((key, id))
        }
        endpoints = map
        supervisor.candidatesChanged(candidates.sorted { $0.endpoint < $1.endpoint })
    }

    private func readings(for id: Int?) -> Readings? {
        guard var readings = latest else { return nil }
        readings.seq = id.flatMap { seqs[$0] } ?? 0
        return readings
    }

    private func tick() {
        // Sample every second whether or not a session exists: CPU usage is a delta.
        latest = collector.collect(seq: 0, now: now)
        guard let readings = readings(for: currentID) else { return }
        apply(supervisor.tick(now: now, readings: readings))
    }

    private func apply(_ actions: [ConnectionSupervisor.Action]) {
        for action in actions {
            switch action {
            case .connect(let id, let endpointKey):
                guard let endpoint = endpoints[endpointKey] else { continue }
                open(id: id, to: endpoint)
            case .cancel(let id):
                close(id)
            case .send(let id, let line):
                connections[id]?.send(content: Data((line + "\n").utf8), completion: .idempotent)
                if line.hasPrefix("F ") { seqs[id, default: 0] += 1 }
            case .status(let status):
                onStatus(status)
            }
        }
    }

    private func open(id: Int, to endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        connections[id] = connection
        buffers[id] = LineBuffer()
        seqs[id] = 0
        currentID = id
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state, id: id, connection: connection) }
        }
        connection.start(queue: .main)
        receive(id: id, connection: connection)
    }

    private func close(_ id: Int) {
        connections.removeValue(forKey: id)?.cancel()
        buffers[id] = nil
        seqs[id] = nil
        if currentID == id { currentID = nil }
    }

    private func stateChanged(_ state: NWConnection.State, id: Int, connection: NWConnection) {
        let event: ConnectionSupervisor.ConnectionEvent
        switch state {
        case .preparing: event = .preparing
        case .waiting(let error):
            var code: Int32?
            if case .dns(let dnsError) = error { code = dnsError }
            let denied = connection.currentPath?.unsatisfiedReason == .localNetworkDenied
            event = .waiting(isPolicyDenied: ConnectionEventMapping.isPolicyDenied(
                dnsErrorCode: code, unsatisfiedIsLocalNetworkDenied: denied))
        case .ready: event = .ready
        case .failed: event = .failed
        case .cancelled: event = .cancelled
        case .setup: return
        @unknown default: return
        }
        apply(supervisor.connectionEvent(event, connection: id, now: now))
        if case .failed = state { close(id) }
    }

    private func receive(id: Int, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.connections[id] === connection else { return }
                if let data, !data.isEmpty { self.received(data, id: id) }
                if complete || error != nil {
                    self.apply(self.supervisor.connectionEvent(.failed, connection: id, now: self.now))
                    self.close(id)
                } else {
                    self.receive(id: id, connection: connection)
                }
            }
        }
    }

    private func received(_ data: Data, id: Int) {
        guard var buffer = buffers[id] else { return }
        let lines: [String]
        do {
            lines = try buffer.append(data)
        } catch {
            apply([.cancel(connection: id)])
            apply(supervisor.connectionEvent(.failed, connection: id, now: now))
            return
        }
        buffers[id] = buffer
        for line in lines {
            guard connections[id] != nil, let readings = readings(for: id) else { return }
            apply(supervisor.lineReceived(line, connection: id, now: now, nonce: Self.nonce(), readings: readings))
        }
    }

    static func nonce() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: SessionKeys.nonceBytes)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return bytes
    }
}
