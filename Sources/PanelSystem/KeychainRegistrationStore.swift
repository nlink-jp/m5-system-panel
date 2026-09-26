import Foundation
import PanelCore
import Security

/// Registrations in the file-based login keychain (generic passwords).
///
/// The file-based keychain is the SecItem default on macOS without
/// `kSecUseDataProtectionKeychain`. It is never synchronised: iCloud Keychain
/// exists only in the data protection keychain, whose access groups need a
/// provisioning profile this Developer ID app does not have (TN3137). That is
/// what keeps the key on this Mac (protocol v1 §5.2).
///
/// Not unit-tested: a test would write to the user's login keychain. The rules
/// are MemoryRegistrationStore's and are tested there; this type only stores.
public struct KeychainRegistrationStore: RegistrationStore {
    private let service: String

    public init(service: String = "jp.nlink.m5-system-panel") { self.service = service }

    private enum Account: String { case active, pending }

    public func active() throws -> Registration? {
        try read(.active).flatMap(Registration.init(data:))
    }

    public func savePending(_ registration: Registration) throws {
        try write(.pending, registration.data)
    }

    public func commitPending() throws {
        guard let data = try read(.pending) else { throw RegistrationStoreError.noPending }
        try write(.active, data)
        try delete(.pending)
    }

    public func discardPending() throws { try delete(.pending) }

    public func removeAll() throws {
        try delete(.pending)
        try delete(.active)
    }

    // MARK: SecItem

    private func query(_ account: Account) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account.rawValue]
    }

    private func read(_ account: Account) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    private func write(_ account: Account, _ data: Data) throws {
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "m5-system-panel (\(account.rawValue))"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func delete(_ account: Account) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
