import Foundation
import Security

/// Passwords and key passphrases, kept in the login Keychain under Clavra's service name.
enum Keychain {
    private static let service = "com.naqara.clavra"

    static func password(for host: Server.ID) -> String? { get("\(host.uuidString)/password") }
    static func passphrase(for host: Server.ID) -> String? { get("\(host.uuidString)/passphrase") }
    static func setPassword(_ value: String?, for host: Server.ID) { set(value, "\(host.uuidString)/password") }
    static func setPassphrase(_ value: String?, for host: Server.ID) { set(value, "\(host.uuidString)/passphrase") }

    static func forget(_ host: Server.ID) {
        set(nil, "\(host.uuidString)/password")
        set(nil, "\(host.uuidString)/passphrase")
    }

    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    private static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Saves the value, or removes the item when it's nil or empty.
    private static func set(_ value: String?, _ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData] = Data(value.utf8)
        q[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(q as CFDictionary, nil)
    }
}
