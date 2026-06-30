import Foundation
import Security

enum APIKeyStore {
    private static let service = "com.adamblair.Harness"
    private static let claudeAccount = "anthropic_api_key"

    static func loadClaudeKey() -> String? {
        var query = baseQuery(account: claudeAccount)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            return nil
        }
        return key
    }

    static func saveClaudeKey(_ key: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        let data = Data(trimmedKey.utf8)
        let query = baseQuery(account: claudeAccount)
        let update: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
            return
        }

        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        "Keychain failed with status \(status)."
    }
}
