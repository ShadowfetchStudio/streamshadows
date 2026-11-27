import Foundation
import Security

public final class KeychainStore: Sendable {
    private let service: String

    public init(service: String = "com.shadowfetch.streamshadows") {
        self.service = service
    }

    @discardableResult
    public func saveStreamKey(_ key: String, for platform: StreamingPlatform) -> OSStatus {
        let account = "stream_key_\(platform.rawValue)"
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            return deleteStreamKey(for: platform)
        }

        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            return SecItemAdd(newItem as CFDictionary, nil)
        }
        return status
    }

    public func loadStreamKey(for platform: StreamingPlatform) -> String {
        let account = "stream_key_\(platform.rawValue)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    @discardableResult
    public func deleteStreamKey(for platform: StreamingPlatform) -> OSStatus {
        let account = "stream_key_\(platform.rawValue)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
