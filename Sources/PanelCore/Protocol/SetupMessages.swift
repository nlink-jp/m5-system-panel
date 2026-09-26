import Foundation

// Setup-session messages of protocol v1 (§5.2). Plaintext lines inside the setup
// Wi-Fi; the peer is always the Wi-Fi router over a pinned connection (§5.1).

/// `SETUP 1 <device ID>`, panel → companion.
public struct SetupGreeting: Equatable, Sendable {
    public let version: Int
    public let deviceID: String

    public init(version: Int = 1, deviceID: String) {
        self.version = version
        self.deviceID = deviceID
    }

    public var line: String { "SETUP \(version) \(deviceID)" }

    public static func parse(_ line: String) -> SetupGreeting? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == 3, tokens[0] == "SETUP",
              let version = Wire.parseUInt(tokens[1]).flatMap({ Int(exactly: $0) }),
              DeviceID.isValid(tokens[2]) else { return nil }
        return SetupGreeting(version: version, deviceID: String(tokens[2]))
    }
}

/// One scanned network: `NET <rssi> <auth> <B64(ssid)>`, panel → companion.
public struct ScannedNetwork: Equatable, Sendable {
    public enum Security: String, Sendable, CaseIterable {
        case open, wpa2, wpa3, wpa2wpa3, other
    }
    public static let maxLines = 20

    public let rssi: Int
    public let security: Security
    /// 1–32 bytes, not necessarily UTF-8.
    public let ssid: [UInt8]

    public init(rssi: Int, security: Security, ssid: [UInt8]) {
        self.rssi = rssi
        self.security = security
        self.ssid = ssid
    }

    public var line: String { "NET \(rssi) \(security.rawValue) \(StrictBase64.encode(ssid))" }

    public static func parse(_ line: String) -> ScannedNetwork? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == 4, tokens[0] == "NET",
              let rssi = SetupWire.parseRSSI(tokens[1]),
              let security = Security(rawValue: String(tokens[2])),
              let ssid = StrictBase64.decode(tokens[3]), SetupWire.ssidBytes.contains(ssid.count)
        else { return nil }
        return ScannedNetwork(rssi: rssi, security: security, ssid: ssid)
    }
}

/// `JOIN <B64(ssid)> <B64(password)|->`, companion → panel.
public struct JoinRequest: Equatable, Sendable {
    public let ssid: [UInt8]
    /// nil for a network without authentication.
    public let password: [UInt8]?

    public init(ssid: [UInt8], password: [UInt8]?) {
        self.ssid = ssid
        self.password = password
    }

    /// nil when the SSID or password length is outside §5.2's limits.
    public var line: String? {
        guard SetupWire.ssidBytes.contains(ssid.count),
              password.map({ SetupWire.passwordBytes.contains($0.count) }) ?? true else { return nil }
        return "JOIN \(StrictBase64.encode(ssid)) \(password.map { StrictBase64.encode($0) } ?? "-")"
    }

    public static func parse(_ line: String) -> JoinRequest? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == 3, tokens[0] == "JOIN",
              let ssid = StrictBase64.decode(tokens[1]), SetupWire.ssidBytes.contains(ssid.count)
        else { return nil }
        if tokens[2] == "-" { return JoinRequest(ssid: ssid, password: nil) }
        guard let password = StrictBase64.decode(tokens[2]), SetupWire.passwordBytes.contains(password.count)
        else { return nil }
        return JoinRequest(ssid: ssid, password: password)
    }
}

/// `KEY <B64(K)>`, panel → companion.
public struct KeyDelivery: Equatable, Sendable {
    public let key: [UInt8]

    public init(key: [UInt8]) { self.key = key }

    public var line: String { "KEY \(StrictBase64.encode(key))" }

    public static func parse(_ line: String) -> KeyDelivery? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: false)
        guard tokens.count == 2, tokens[0] == "KEY",
              let key = StrictBase64.decode(tokens[1]), key.count == SessionKeys.keyBytes else { return nil }
        return KeyDelivery(key: key)
    }
}

/// The single-word setup lines.
public enum SetupWord: String, Sendable {
    case list = "LIST", end = "END", stored = "STORED", done = "DONE"
}

enum SetupWire {
    static let ssidBytes = 1...32
    static let passwordBytes = 1...63

    /// `-?[0-9]{1,3}`, no leading zeros, never `-0`.
    static func parseRSSI(_ text: Substring) -> Int? {
        let negative = text.hasPrefix("-")
        let digits = negative ? text.dropFirst() : text
        guard (1...3).contains(digits.utf8.count), let magnitude = Wire.parseUInt(digits) else { return nil }
        if negative && magnitude == 0 { return nil }
        return negative ? -Int(magnitude) : Int(magnitude)
    }
}
