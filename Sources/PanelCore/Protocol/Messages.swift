import Foundation

// Run-session messages of protocol v1 (§4.1, §4.4). Parsers accept exactly the
// defined form — field order fixed, no missing or repeated fields, no leading
// zeros — and return nil for anything else. Receivers check form only, never
// relations between values (§4.4).

/// `HELLO 1 <device ID> <B64(Np)>`, panel → companion.
public struct Hello: Equatable, Sendable {
    public let version: Int
    public let deviceID: String
    public let panelNonce: [UInt8]

    public init(version: Int = 1, deviceID: String, panelNonce: [UInt8]) {
        self.version = version
        self.deviceID = deviceID
        self.panelNonce = panelNonce
    }

    public var line: String { "HELLO \(version) \(deviceID) \(StrictBase64.encode(panelNonce))" }

    /// Parses any version, so the companion can tell "wrong firmware" from garbage.
    public static func parse(_ line: String) -> Hello? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == 4, tokens[0] == "HELLO",
              let version = Wire.parseUInt(tokens[1]).flatMap({ Int(exactly: $0) }),
              DeviceID.isValid(tokens[2]),
              let nonce = StrictBase64.decode(tokens[3]), nonce.count == SessionKeys.nonceBytes
        else { return nil }
        return Hello(version: version, deviceID: String(tokens[2]), panelNonce: nonce)
    }
}

/// `AUTH <B64(Nc)>`, companion → panel.
public struct Auth: Equatable, Sendable {
    public let companionNonce: [UInt8]

    public init(companionNonce: [UInt8]) { self.companionNonce = companionNonce }

    public var line: String { "AUTH \(StrictBase64.encode(companionNonce))" }

    public static func parse(_ line: String) -> Auth? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == 2, tokens[0] == "AUTH",
              let nonce = StrictBase64.decode(tokens[1]), nonce.count == SessionKeys.nonceBytes
        else { return nil }
        return Auth(companionNonce: nonce)
    }
}

/// The readings frame (the `M` plaintext), companion → panel.
public struct Readings: Equatable, Sendable {
    public static let maxCores = 64

    public var seq: UInt64
    /// Overall CPU usage in tenths of a percent, 0...1000.
    public var cpuTenths: Int
    /// Per-core usage in logical CPU order, 0...100 each. No P/E type: which
    /// logical CPU is which kind is not documented (RFP amendment A4).
    public var cores: [Int]
    /// GPU usage in tenths of a percent, or nil when unavailable.
    public var gpuTenths: Int?
    public var memoryUsed: UInt64
    public var memoryTotal: UInt64
    public var memoryApp: UInt64
    public var memoryWired: UInt64
    public var memoryCompressed: UInt64
    public var swapUsed: UInt64
    /// 0 normal, 1 warning, 2 critical.
    public var pressure: Int
    /// BSD name of the primary interface, or nil when there is none.
    public var interface: String?
    public var rxBytesPerSecond: UInt64
    public var txBytesPerSecond: UInt64

    public init(
        seq: UInt64, cpuTenths: Int, cores: [Int], gpuTenths: Int?,
        memoryUsed: UInt64, memoryTotal: UInt64, memoryApp: UInt64, memoryWired: UInt64,
        memoryCompressed: UInt64, swapUsed: UInt64, pressure: Int, interface: String?,
        rxBytesPerSecond: UInt64, txBytesPerSecond: UInt64
    ) {
        self.seq = seq
        self.cpuTenths = cpuTenths
        self.cores = cores
        self.gpuTenths = gpuTenths
        self.memoryUsed = memoryUsed
        self.memoryTotal = memoryTotal
        self.memoryApp = memoryApp
        self.memoryWired = memoryWired
        self.memoryCompressed = memoryCompressed
        self.swapUsed = swapUsed
        self.pressure = pressure
        self.interface = interface
        self.rxBytesPerSecond = rxBytesPerSecond
        self.txBytesPerSecond = txBytesPerSecond
    }

    /// The plaintext, or `.malformed` when a value is outside its defined range —
    /// the sender refuses to produce a frame the receiver would reject.
    public func encoded() throws(ProtocolError) -> String {
        guard (1...Self.maxCores).contains(cores.count),
              cores.allSatisfy({ (0...100).contains($0) }),
              (0...1000).contains(cpuTenths), gpuTenths.map({ (0...1000).contains($0) }) ?? true,
              (0...2).contains(pressure), interface.map(Wire.isInterfaceName) ?? true,
              [seq, memoryUsed, memoryTotal, memoryApp, memoryWired, memoryCompressed, swapUsed,
               rxBytesPerSecond, txBytesPerSecond].allSatisfy({ $0 <= Wire.maxInteger })
        else { throw .malformed }
        let coreList = cores.map(String.init).joined(separator: ",")
        let text = "M seq=\(seq) cpu=\(Wire.tenths(cpuTenths)) cores=\(coreList)"
            + " gpu=\(gpuTenths.map(Wire.tenths) ?? "-") mem=\(memoryUsed)/\(memoryTotal)"
            + " app=\(memoryApp) wired=\(memoryWired) comp=\(memoryCompressed) swap=\(swapUsed)"
            + " press=\(pressure) if=\(interface ?? "-") rx=\(rxBytesPerSecond) tx=\(txBytesPerSecond)"
        guard text.utf8.count <= Frame.maxPlaintextBytes else { throw .plaintextTooLong }
        return text
    }

    public static func parse(_ text: String) -> Readings? {
        guard let fields = Wire.fields(
            text, kind: "M",
            names: ["seq", "cpu", "cores", "gpu", "mem", "app", "wired", "comp", "swap", "press", "if", "rx", "tx"])
        else { return nil }
        guard let seq = Wire.parseUInt(fields[0]),
              let cpu = Wire.parseTenths(fields[1]),
              let cores = parseCores(fields[2]),
              let gpu: Int? = fields[3] == "-" ? .some(nil) : Wire.parseTenths(fields[3]).map { .some($0) },
              let memory = parseMemory(fields[4]),
              let app = Wire.parseUInt(fields[5]), let wired = Wire.parseUInt(fields[6]),
              let comp = Wire.parseUInt(fields[7]), let swap = Wire.parseUInt(fields[8]),
              let press = Wire.parseUInt(fields[9]), press <= 2,
              fields[10] == "-" || Wire.isInterfaceName(fields[10]),
              let rx = Wire.parseUInt(fields[11]), let tx = Wire.parseUInt(fields[12])
        else { return nil }
        return Readings(
            seq: seq, cpuTenths: cpu, cores: cores, gpuTenths: gpu,
            memoryUsed: memory.used, memoryTotal: memory.total, memoryApp: app, memoryWired: wired,
            memoryCompressed: comp, swapUsed: swap, pressure: Int(press),
            interface: fields[10] == "-" ? nil : String(fields[10]),
            rxBytesPerSecond: rx, txBytesPerSecond: tx)
    }

    private static func parseCores(_ text: Substring) -> [Int]? {
        let items = text.split(separator: ",", omittingEmptySubsequences: false)
        guard (1...maxCores).contains(items.count) else { return nil }
        var cores: [Int] = []
        for item in items {
            guard let value = Wire.parseUInt(item), value <= 100 else { return nil }
            cores.append(Int(value))
        }
        return cores
    }

    private static func parseMemory(_ text: Substring) -> (used: UInt64, total: UInt64)? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let used = Wire.parseUInt(parts[0]), let total = Wire.parseUInt(parts[1])
        else { return nil }
        return (used, total)
    }
}

/// The acknowledgement frame, panel → companion.
public struct Acknowledgement: Equatable, Sendable {
    /// The last measurement `seq` received in this session, nil before the first.
    public var seq: UInt64?
    /// Milliseconds since the panel booted.
    public var uptimeMilliseconds: UInt64

    public init(seq: UInt64?, uptimeMilliseconds: UInt64) {
        self.seq = seq
        self.uptimeMilliseconds = uptimeMilliseconds
    }

    public func encoded() throws(ProtocolError) -> String {
        guard (seq ?? 0) <= Wire.maxInteger, uptimeMilliseconds <= Wire.maxInteger else { throw .malformed }
        return "A seq=\(seq.map(String.init) ?? "-") up=\(uptimeMilliseconds)"
    }

    public static func parse(_ text: String) -> Acknowledgement? {
        guard let fields = Wire.fields(text, kind: "A", names: ["seq", "up"]),
              let up = Wire.parseUInt(fields[1]) else { return nil }
        if fields[0] == "-" { return Acknowledgement(seq: nil, uptimeMilliseconds: up) }
        guard let seq = Wire.parseUInt(fields[0]) else { return nil }
        return Acknowledgement(seq: seq, uptimeMilliseconds: up)
    }
}

/// Token-level rules shared by the messages.
enum Wire {
    /// 2^63 − 1: the largest `<n>`.
    static let maxInteger = UInt64(Int64.max)

    /// Splits `<kind> name=value …` with the names in exactly this order and
    /// returns the values, or nil.
    static func fields(_ text: String, kind: String, names: [String]) -> [Substring]? {
        let tokens = text.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == names.count + 1, tokens[0] == kind else { return nil }
        var values: [Substring] = []
        for (token, name) in zip(tokens.dropFirst(), names) {
            guard token.hasPrefix(name + "=") else { return nil }
            let value = token.dropFirst(name.count + 1)
            guard !value.isEmpty else { return nil }
            values.append(value)
        }
        return values
    }

    /// `<n>`: decimal, no sign, no leading zeros, at most 2^63 − 1.
    static func parseUInt(_ text: Substring) -> UInt64? {
        guard !text.isEmpty, text.utf8.count <= 19,
              text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              text == "0" || text.first != "0",
              let value = UInt64(text), value <= maxInteger
        else { return nil }
        return value
    }

    /// `<pct1>` as tenths: 1–3 integer digits without leading zeros, one decimal
    /// digit, at most 100.0.
    static func parseTenths(_ text: Substring) -> Int? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...3).contains(parts[0].utf8.count), parts[1].utf8.count == 1,
              let whole = parseUInt(parts[0]), let tenth = parseUInt(parts[1])
        else { return nil }
        let value = Int(whole) * 10 + Int(tenth)
        return value <= 1000 ? value : nil
    }

    static func tenths(_ value: Int) -> String { "\(value / 10).\(value % 10)" }

    /// `[A-Za-z0-9]{1,15}`.
    static func isInterfaceName(_ text: some StringProtocol) -> Bool {
        (1...15).contains(text.utf8.count) && text.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0)
        }
    }
}
