import Foundation
import OntologyKit
import Security

enum APIKeyStore {
    private static let service = "com.adamblair.Harness"
    private static let claudeAccount = "anthropic_api_key"
    private static let xAIAccount = "xai_api_key"
    private static let firecrawlAccount = "firecrawl_api_key"

    static func loadKey(for backend: Backend) -> String? {
        guard let account = account(for: backend) else { return nil }
        return loadKey(account: account)
    }

    static func saveKey(_ key: String, for backend: Backend) throws {
        guard let account = account(for: backend) else { return }
        try saveKey(key, account: account)
    }

    static func deleteKey(for backend: Backend) throws {
        guard let account = account(for: backend) else { return }
        try deleteKey(account: account)
    }

    static func loadClaudeKey() -> String? {
        loadKey(account: claudeAccount)
    }

    static func saveClaudeKey(_ key: String) throws {
        try saveKey(key, account: claudeAccount)
    }

    static func deleteClaudeKey() throws {
        try deleteKey(account: claudeAccount)
    }

    static func loadFirecrawlKey() -> String? {
        loadKey(account: firecrawlAccount)
    }

    static func saveFirecrawlKey(_ key: String) throws {
        try saveKey(key, account: firecrawlAccount)
    }

    static func deleteFirecrawlKey() throws {
        try deleteKey(account: firecrawlAccount)
    }

    private static func loadKey(account: String) -> String? {
        var query = baseQuery(account: account)
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

    private static func saveKey(_ key: String, account: String) throws {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else { return }

        let data = Data(trimmedKey.utf8)
        let query = baseQuery(account: account)
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

    private static func deleteKey(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private static func account(for backend: Backend) -> String? {
        switch backend {
        case .codex:
            return nil
        case .grok:
            return xAIAccount
        case .claude:
            return claudeAccount
        case .hermes:
            return nil
        }
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
