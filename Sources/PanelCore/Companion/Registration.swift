import Foundation

/// The paired panel: its device ID and the key shared at setup.
public struct Registration: Equatable, Sendable {
    public let deviceID: String
    public let key: [UInt8]

    public init?(deviceID: String, key: [UInt8]) {
        guard DeviceID.isValid(deviceID), key.count == SessionKeys.keyBytes else { return nil }
        self.deviceID = deviceID
        self.key = key
    }

    /// Stored form: 4 ASCII bytes of the ID, then the 32 key bytes.
    public var data: Data { Data(Array(deviceID.utf8) + key) }

    public init?(data: Data) {
        let bytes = Array(data)
        guard bytes.count == 4 + SessionKeys.keyBytes,
              let id = String(bytes: bytes[0..<4], encoding: .ascii) else { return nil }
        self.init(deviceID: id, key: Array(bytes[4...]))
    }
}

/// Where registrations are kept (the Keychain in the app, memory in tests).
///
/// Protocol v1 §5.2: the key from `KEY` is saved as *pending*; `DONE` makes it
/// the active registration, replacing the previous one; any other ending
/// discards the pending one and leaves the active one alone.
public protocol RegistrationStore: Sendable {
    func active() throws -> Registration?
    func savePending(_ registration: Registration) throws
    /// Pending becomes active (the previous active one is replaced).
    func commitPending() throws
    func discardPending() throws
    /// "Unregister panel": both entries go.
    func removeAll() throws
}

public enum RegistrationStoreError: Error, Equatable, Sendable {
    case noPending
}

/// In-memory store for tests and for running without a bundle.
public final class MemoryRegistrationStore: RegistrationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var activeEntry: Registration?
    private var pendingEntry: Registration?

    public init(active: Registration? = nil) { activeEntry = active }

    public func active() throws -> Registration? { lock.withLock { activeEntry } }

    public func savePending(_ registration: Registration) throws { lock.withLock { pendingEntry = registration } }

    public func commitPending() throws {
        try lock.withLock {
            guard let pending = pendingEntry else { throw RegistrationStoreError.noPending }
            activeEntry = pending
            pendingEntry = nil
        }
    }

    public func discardPending() throws { lock.withLock { pendingEntry = nil } }

    public func removeAll() throws {
        lock.withLock {
            activeEntry = nil
            pendingEntry = nil
        }
    }

    /// For tests.
    public var pending: Registration? { lock.withLock { pendingEntry } }
}
