import Foundation
import Security

public protocol RefreshTokenVault: Sendable {
    func read() throws -> String?
    func write(_ token: String) throws
    func clear() throws
}
/// Device-only, unlocked Keychain entry. Access tokens remain in memory and are never persisted.
public struct KeychainRefreshTokenVault: RefreshTokenVault {
    private let service: String
    private let account: String
    public init(service: String, account: String = "adult-refresh") { self.service = service; self.account = account }
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service, kSecAttrAccount as String: account,
        kSecAttrSynchronizable as String: false] }
    public func read() throws -> String? {
        var query = query; query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw ClientError.sessionNeeded }
        return token
    }
    public func write(_ token: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw ClientError.sessionNeeded }
        } else if status != errSecSuccess { throw ClientError.sessionNeeded }
    }
    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ClientError.sessionNeeded }
    }
}
