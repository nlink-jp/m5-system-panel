// Phase 0 probe app (RFP §4, items 3–5). Not the product.
//
// Browses for _m5-system-panel._tcp, connects to the first panel, sends a line
// every second and logs every event the frameworks report: browser state and
// results, connection state / viability / path, each ack with its receive time,
// sleep and wake. When no ack has arrived for 5 s it opens a new connection but
// keeps the old one (un-cancelled) so that the time the old one takes to fail on
// its own is observed too; the old one is cancelled after 300 s.
//
// Launch with `open --env PHASE0_LOG=<file> dist/spike/Phase0Probe.app` — never
// the binary from Terminal, which is granted local network access automatically
// (TN3179) and would hide the prompt and the deny path.

import AppKit
import Network

let logPath = ProcessInfo.processInfo.environment["PHASE0_LOG"]
let started = ContinuousClock.now
let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

func log(_ message: String) {
    let elapsed = ContinuousClock.now - started
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    let line = "\(isoFormatter.string(from: Date())) +\(String(format: "%.3f", seconds)) \(message)\n"
    FileHandle.standardError.write(Data(line.utf8))
    guard let logPath else { return }
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
    }
}

@MainActor
final class Probe: NSObject, NSApplicationDelegate {
    private var browser: NWBrowser?
    private var connections: [Int: NWConnection] = [:]
    private var current: Int?
    private var nextID = 1
    private var lastAck: [Int: ContinuousClock.Instant] = [:]
    private var createdAt: [Int: ContinuousClock.Instant] = [:]
    private var lastAttempt: ContinuousClock.Instant?
    private var buffers: [Int: Data] = [:]
    private var sendSeq = 0
    private var endpoint: NWEndpoint?
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("launch pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundleIdentifier ?? "nil") os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Phase 0 probe")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "P0"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Phase 0 probe", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                log("workspace \(note.name.rawValue)")
            }
        }

        startBrowser()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        log("terminate")
    }

    private func startBrowser() {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_m5-system-panel._tcp", domain: nil),
            using: .tcp)
        browser.stateUpdateHandler = { state in
            log("browser state \(state)")
        }
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            for change in changes {
                switch change {
                case .added(let r): log("browser added \(r.endpoint) \(r.metadata) ifaces=\(r.interfaces.map(\.name))")
                case .removed(let r): log("browser removed \(r.endpoint)")
                case .changed(let old, let new, let flags): log("browser changed \(old.endpoint) -> \(new.endpoint) flags=\(flags.rawValue)")
                case .identical: log("browser identical")
                @unknown default: log("browser change (unknown)")
                }
            }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.endpoint = results.first?.endpoint
                if self.current == nil, let endpoint = self.endpoint {
                    self.connect(to: endpoint, reason: "first result")
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func connect(to endpoint: NWEndpoint, reason: String) {
        let id = nextID
        nextID += 1
        let connection = NWConnection(to: endpoint, using: .tcp)
        log("conn#\(id) create to \(endpoint) (\(reason))")
        connection.stateUpdateHandler = { [weak self] state in
            var extra = ""
            if case .waiting = state, let reason = connection.currentPath?.unsatisfiedReason {
                extra = " unsatisfiedReason=\(reason)"
            }
            log("conn#\(id) state \(state)\(extra)")
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.lastAck[id] = ContinuousClock.now
                    self.receive(id: id, connection: connection)
                case .failed, .cancelled:
                    self.connections[id] = nil
                    self.lastAck[id] = nil
                    if self.current == id { self.current = nil }
                default: break
                }
            }
        }
        connection.viabilityUpdateHandler = { viable in log("conn#\(id) viable \(viable)") }
        connection.betterPathUpdateHandler = { better in log("conn#\(id) betterPath \(better)") }
        connection.pathUpdateHandler = { path in
            log("conn#\(id) path \(path.status) reason=\(path.unsatisfiedReason) ifaces=\(path.availableInterfaces.map(\.name))")
        }
        connections[id] = connection
        current = id
        createdAt[id] = ContinuousClock.now
        lastAttempt = ContinuousClock.now
        connection.start(queue: .main)
    }

    private func receive(id: Int, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty {
                    var buffer = self.buffers[id, default: Data()]
                    buffer.append(data)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        self.lastAck[id] = ContinuousClock.now
                        log("conn#\(id) rx \(line)")
                    }
                    self.buffers[id] = buffer
                }
                if isComplete { log("conn#\(id) rx complete (peer closed)") }
                if let error { log("conn#\(id) rx error \(error)") }
                if !isComplete && error == nil { self.receive(id: id, connection: connection) }
            }
        }
    }

    private func tick() {
        let now = ContinuousClock.now
        for (id, connection) in connections where connection.state == .ready {
            sendSeq += 1
            let payload = Data("d \(sendSeq) conn=\(id)\n".utf8)
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error { log("conn#\(id) tx error \(error)") }
            })
        }
        // Design behaviour under test: a connection still not ready after 10 s is
        // replaced (run 1: a connection started while the permission prompt was up
        // stayed in .preparing indefinitely, even after the user allowed it).
        if let id = current, let connection = connections[id], connection.state != .ready,
           let created = createdAt[id], now - created > .seconds(10) {
            log("conn#\(id) not ready after 10 s (state \(connection.state)) — cancelling and retrying")
            connection.cancel()
            current = nil
        }
        // With no current connection, retry every 5 s against the last browse result.
        if current == nil, let endpoint,
           lastAttempt.map({ now - $0 > .seconds(5) }) ?? true {
            connect(to: endpoint, reason: "retry")
            return
        }
        // Design behaviour under test: 5 s without an ack means "not responding".
        if let id = current, let last = lastAck[id], now - last > .seconds(5) {
            log("conn#\(id) no ack for 5 s — opening a new connection, keeping this one")
            current = nil
            let old = connections[id]
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
                if let old, old.state != .cancelled {
                    log("conn#\(id) still \(old.state) after 300 s — cancelling")
                    old.cancel()
                }
            }
            if let endpoint { connect(to: endpoint, reason: "no ack") }
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let probe = Probe()
    app.delegate = probe  // weak: kept alive by withExtendedLifetime below
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(probe) { app.run() }
}
