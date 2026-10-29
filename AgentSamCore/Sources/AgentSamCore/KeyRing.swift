import Foundation

#if canImport(Security)
import Security
#endif

public protocol KeyRing: Sendable {
    func get(_ account: String) -> String?
    func set(_ value: String, for account: String) throws
    func remove(_ account: String)
}

public enum KeyRingError: Error, LocalizedError {
    case keychainFailure(OSStatus)
    case keyNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .keychainFailure(let status):
            "Keychain error (\(status))."
        case .keyNotFound(let account):
            "No API key saved for \(account)."
        }
    }
}

public struct KeychainKeyRing: KeyRing {
    public let service: String

    public init(service: String = "local.agentsam.apikeys") {
        self.service = service
    }

    public func get(_ account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, for account: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        remove(account)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = Data(trimmed.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyRingError.keychainFailure(status) }
    }

    public func remove(_ account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct FileKeyRing: KeyRing {
    public let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    private func loadAll() -> [String: String] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveAll(_ keys: [String: String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(keys) {
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }

    public func get(_ account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return loadAll()[account]
    }

    public func set(_ value: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var all = loadAll()
        all[account] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        saveAll(all)
    }

    public func remove(_ account: String) {
        lock.lock()
        defer { lock.unlock() }
        var all = loadAll()
        all[account] = nil
        saveAll(all)
    }
}

public struct EnvKeyRing: KeyRing {
    public init() {}

    public func get(_ account: String) -> String? {
        let envName = "AGENTSAM_KEY_\(account.replacingOccurrences(of: ".", with: "_").uppercased())"
        return ProcessInfo.processInfo.environment[envName]
    }

    public func set(_ value: String, for account: String) throws {}
    public func remove(_ account: String) {}
}
