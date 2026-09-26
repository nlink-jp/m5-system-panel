import Foundation

/// The companion's end of one run-session connection (protocol v1 §4.1–4.4).
///
/// Pure apart from the random `Nc`, which is passed in. The caller moves lines
/// between this and the socket and closes the connection on any `.close` outcome.
public struct CompanionSession: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// `HELLO` accepted: send these lines (`AUTH` and the first frame) now.
        case send([String])
        /// A verified acknowledgement. `first` is true for the first one: only then
        /// does the companion know the panel holds the key (show "Connected").
        case acknowledged(Acknowledgement, first: Bool)
        case close(Reason)
    }

    public enum Reason: Equatable, Sendable {
        /// `HELLO` with another version: the panel's firmware does not match.
        case firmwareMismatch(version: Int)
        /// `HELLO` from a panel with another device ID.
        case wrongPanel
        /// Malformed line, failed verification, counter mismatch: a candidate
        /// that failed verification (§2, §4.1 item 7).
        case verificationFailed
    }

    private enum State: Sendable {
        case awaitingHello
        case established(sealer: FrameSealer, opener: FrameOpener, confirmed: Bool)
        case closed
    }

    private let key: [UInt8]
    private let deviceID: String
    private let companionNonce: [UInt8]
    private var state: State = .awaitingHello

    public init(key: [UInt8], deviceID: String, companionNonce: [UInt8]) {
        self.key = key
        self.deviceID = deviceID
        self.companionNonce = companionNonce
    }

    /// Whether frames may be sent (after `HELLO`, until closed).
    public var isEstablished: Bool {
        if case .established = state { return true }
        return false
    }

    /// A line from the panel. `firstReadings` is sealed as frame 0 when the line is `HELLO`.
    public mutating func receive(_ line: String, firstReadings: Readings) -> Outcome {
        switch state {
        case .closed:
            return .close(.verificationFailed)
        case .awaitingHello:
            guard let hello = Hello.parse(line) else { return close(.verificationFailed) }
            guard hello.version == 1 else { return close(.firmwareMismatch(version: hello.version)) }
            guard hello.deviceID == deviceID else { return close(.wrongPanel) }
            guard let keys = try? SessionKeys(
                key: key, deviceID: deviceID, panelNonce: hello.panelNonce, companionNonce: companionNonce)
            else { return close(.verificationFailed) }
            var sealer = FrameSealer(key: keys.c2p)
            guard let first = try? sealer.seal(firstReadings.encoded()) else { return close(.verificationFailed) }
            state = .established(sealer: sealer, opener: FrameOpener(key: keys.p2c), confirmed: false)
            return .send([Auth(companionNonce: companionNonce).line, first])
        case .established(let sealer, var opener, let confirmed):
            guard let plaintext = try? opener.open(line), let ack = Acknowledgement.parse(plaintext)
            else { return close(.verificationFailed) }
            state = .established(sealer: sealer, opener: opener, confirmed: true)
            return .acknowledged(ack, first: !confirmed)
        }
    }

    /// The next readings frame, or nil when the session cannot send (not yet
    /// established, closed, or the counter is exhausted — close then).
    public mutating func seal(_ readings: Readings) -> String? {
        guard case .established(var sealer, let opener, let confirmed) = state,
              let line = try? sealer.seal(readings.encoded()) else { return nil }
        state = .established(sealer: sealer, opener: opener, confirmed: confirmed)
        return line
    }

    private mutating func close(_ reason: Reason) -> Outcome {
        state = .closed
        return .close(reason)
    }
}
