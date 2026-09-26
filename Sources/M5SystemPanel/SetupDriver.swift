import Foundation
import Network
import PanelCore
import PanelSystem

/// Finds a panel in setup mode and runs the setup session (protocol v1 §5).
///
/// §5.1: the only peer is the Wi-Fi interface's router, over a connection
/// pinned to the Wi-Fi interface. The connection that reads the `SETUP`
/// greeting is the setup session itself; "Start setup" is offered while it is
/// open. Probing happens when the Wi-Fi path changes (joining the setup Wi-Fi is
/// such a change), with a few retries — never on a standing timer.
@MainActor
final class SetupDriver {
    enum Phase: Equatable {
        case idle
        case offered(deviceID: String)
        case listing
        case choosing(networks: [ScannedNetwork])
        case joining
        case finished(deviceID: String)
        case failed(String)
    }

    private let store: RegistrationStore
    private let onPhase: (Phase) -> Void
    private let onRegistered: () -> Void
    private let pathMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
    private var wifiInterface: NWInterface?
    private var connection: NWConnection?
    private var exchange = SetupExchange()
    private var buffer = LineBuffer()
    private var retries = 0
    private var idleTimer: Timer?
    private(set) var phase: Phase = .idle {
        didSet { onPhase(phase) }
    }

    init(store: RegistrationStore, onPhase: @escaping (Phase) -> Void, onRegistered: @escaping () -> Void) {
        self.store = store
        self.onPhase = onPhase
        self.onRegistered = onRegistered
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wifiInterface = path.availableInterfaces.first { $0.type == .wifi }
                self.retries = 0
                self.probe()
            }
        }
        pathMonitor.start(queue: .main)
    }

    // MARK: user actions

    func requestList() {
        phase = .listing
        perform(exchange.requestList())
    }

    func join(ssid: [UInt8], password: [UInt8]?) {
        phase = .joining
        perform(exchange.join(ssid: ssid, password: password))
    }

    func dismissResult() {
        if case .finished = phase { phase = .idle } else if case .failed = phase { phase = .idle }
    }

    // MARK: probing

    private func probe() {
        guard connection == nil, let route = WiFiRouter.current(), let interface = wifiInterface,
              interface.name == route.interface, let port = NWEndpoint.Port(rawValue: 47110)
        else { return }
        let parameters = NWParameters.tcp
        parameters.requiredInterface = interface  // pinned to Wi-Fi (§5.1)
        let connection = NWConnection(host: NWEndpoint.Host(route.router), port: port, using: parameters)
        self.connection = connection
        exchange = SetupExchange()
        buffer = LineBuffer()
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.stateChanged(state, connection) }
        }
        connection.start(queue: .main)
        receive(connection)
        // Nothing but a panel in setup mode answers at once; give up quietly otherwise.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.connection === connection, case .awaitingGreeting = self.exchange.phase else { return }
                self.finish(connection, retry: true)
            }
        }
    }

    private func stateChanged(_ state: NWConnection.State, _ connection: NWConnection) {
        guard self.connection === connection else { return }
        switch state {
        case .failed, .cancelled: finish(connection, retry: true)
        case .waiting: finish(connection, retry: true)
        default: break
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    do {
                        for line in try self.buffer.append(data) {
                            self.perform(self.exchange.receive(line))
                            self.resetIdle()
                        }
                    } catch {
                        self.perform([.close])
                    }
                }
                if complete || error != nil {
                    self.perform(self.exchange.connectionClosed())
                    self.finish(connection, retry: true)
                } else if self.connection === connection {
                    self.receive(connection)
                }
            }
        }
    }

    private func resetIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: SetupExchange.idleLimitSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.perform(self.exchange.idleTimeout())
            }
        }
    }

    private func perform(_ actions: [SetupExchange.Action]) {
        for action in actions {
            switch action {
            case .send(let line):
                connection?.send(content: Data((line + "\n").utf8), completion: .idempotent)
            case .storeProvisionalKey(let id, let key):
                if let registration = Registration(deviceID: id, key: key) {
                    do { try store.savePending(registration) } catch { phase = .failed("鍵を保存できませんでした") }
                }
            case .commitProvisionalKey:
                do {
                    try store.commitPending()
                    onRegistered()
                } catch {
                    phase = .failed("鍵を保存できませんでした")
                }
            case .discardProvisionalKey:
                try? store.discardPending()
            case .close:
                if let connection { finish(connection, retry: false) }
            }
        }
        syncPhase()
    }

    private func syncPhase() {
        switch exchange.phase {
        case .awaitingGreeting: break
        case .ready(let id): phase = .offered(deviceID: id)
        case .listing: phase = .listing
        case .listed(_, let networks): phase = .choosing(networks: networks)
        case .awaitingKey, .awaitingDone: phase = .joining
        case .finished(let id): phase = .finished(deviceID: id)
        case .failed(let failure):
            switch failure {
            case .firmwareMismatch: phase = .failed("パネルのファームウェアが違います")
            case .protocolViolation: phase = .failed("パネルとのやり取りに失敗しました")
            case .incomplete: if case .offered = phase { phase = .idle } else { phase = .failed("設定を完了できませんでした") }
            case .timedOut: phase = .failed("パネルが応答しません")
            }
        }
    }

    private func finish(_ connection: NWConnection, retry: Bool) {
        guard self.connection === connection else { return }
        connection.cancel()
        self.connection = nil
        idleTimer?.invalidate()
        if case .offered = phase { phase = .idle }
        if retry, retries < 3 {
            retries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                MainActor.assumeIsolated { self?.probe() }
            }
        }
    }
}

extension SetupExchange {
    static var idleLimitSeconds: TimeInterval {
        let c = idleLimit.components
        return Double(c.seconds) + Double(c.attoseconds) / 1e18
    }
}
