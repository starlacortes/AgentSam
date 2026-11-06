import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Connector identity & configuration

public enum ConnectorID: String, Codable, CaseIterable, Hashable, Sendable {
    case gmail
    case googleads
    case cloudflare

    public var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .googleads: "Google Ads"
        case .cloudflare: "Cloudflare"
        }
    }

    public var detail: String {
        switch self {
        case .gmail: "Search, read, draft, and optionally send email through your Gmail account."
        case .googleads: "Run read-only GAQL queries against your Google Ads accounts."
        case .cloudflare: "Inspect Cloudflare zones and DNS, with optional write access."
        }
    }

    /// KeyRing accounts that hold credentials for this connector. Removing all of them fully disconnects it.
    public var credentialAccounts: [String] {
        switch self {
        case .cloudflare: [CloudflareConnector.tokenAccount]
        case .gmail: [GoogleTokenProvider.refreshAccount(for: self), GoogleTokenProvider.cacheAccount(for: self)]
        case .googleads: [
            GoogleTokenProvider.refreshAccount(for: self),
            GoogleTokenProvider.cacheAccount(for: self),
            GoogleAdsConnector.developerTokenAccount,
            GoogleAdsConnector.customerIdAccount,
        ]
        }
    }
}

public struct ConnectorPermissions: Codable, Hashable, Sendable {
    /// Gmail: allow the gmail_send tool.
    public var sendEmail: Bool
    /// Gmail: allow the gmail_draft tool.
    public var createDraft: Bool
    /// Cloudflare: allow DNS create/update/delete and cache purge tools.
    public var dnsWrite: Bool

    public init(sendEmail: Bool = false, createDraft: Bool = false, dnsWrite: Bool = false) {
        self.sendEmail = sendEmail
        self.createDraft = createDraft
        self.dnsWrite = dnsWrite
    }
}

public struct ConnectorConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: ConnectorID
    public var enabled: Bool
    public var permissions: ConnectorPermissions

    public init(id: ConnectorID, enabled: Bool = true, permissions: ConnectorPermissions = ConnectorPermissions()) {
        self.id = id
        self.enabled = enabled
        self.permissions = permissions
    }

    public static func defaults() -> [ConnectorConfig] {
        ConnectorID.allCases.map { ConnectorConfig(id: $0) }
    }
}

// MARK: - Errors & HTTP plumbing

public struct ConnectorError: Error, LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum ConnectorHTTP {
    public static func request(
        _ session: URLSession,
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        jsonBody: [String: Any]? = nil,
        formBody: [String: String]? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        if let formBody {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var components = URLComponents()
            components.queryItems = formBody.map { URLQueryItem(name: $0.key, value: $0.value) }
            request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ConnectorError("HTTP \(status): \(snippet(data))")
        }
        return data
    }

    public static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConnectorError("Unexpected response format.")
        }
        return object
    }

    public static func url(_ base: String, _ path: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents(string: base + path)
        if !query.isEmpty { components?.queryItems = query }
        return components?.url
    }

    static func snippet(_ data: Data, limit: Int = 300) -> String {
        let text = String(data: data.prefix(2048), encoding: .utf8) ?? ""
        return String(text.replacingOccurrences(of: "\n", with: " ").prefix(limit))
    }
}

// MARK: - Tool provider protocol

public protocol ConnectorToolProvider: Sendable {
    var id: ConnectorID { get }

    /// True when the connector has the credentials it needs to make calls.
    func isConfigured(keyRing: KeyRing) -> Bool

    /// Tools available under the given permissions (the connector must already be configured).
    func toolDefs(permissions: ConnectorPermissions) -> [APIToolDef]

    func run(_ name: String, args: [String: JSONValue], permissions: ConnectorPermissions, runtime: ConnectorRuntime) async -> ToolOutcome

    func test(runtime: ConnectorRuntime) async -> (ok: Bool, message: String)
}

public extension ConnectorToolProvider {
    func owns(_ toolName: String) -> Bool {
        toolName.hasPrefix(id.rawValue + "_")
    }
}

public struct ConnectorRuntime: Sendable {
    public let keyRing: KeyRing
    public let session: URLSession
    public let google: GoogleOAuth

    public init(keyRing: KeyRing, session: URLSession, google: GoogleOAuth) {
        self.keyRing = keyRing
        self.session = session
        self.google = google
    }

    public func googleTokens(for id: ConnectorID) -> GoogleTokenProvider {
        GoogleTokenProvider(connectorID: id, keyRing: keyRing, oauth: google)
    }
}

// MARK: - Hub

/// Central registry used by the engine (and by the apps/server to manage connectors).
public struct ConnectorHub: Sendable {
    public let store: MissionStore
    public let keyRing: KeyRing
    public let session: URLSession
    public let google: GoogleOAuth

    public static let providers: [any ConnectorToolProvider] = [
        CloudflareConnector(),
        GmailConnector(),
        GoogleAdsConnector(),
    ]

    public init(store: MissionStore, keyRing: KeyRing, session: URLSession? = nil, google: GoogleOAuth) {
        self.store = store
        self.keyRing = keyRing
        self.google = google
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 120
            config.timeoutIntervalForResource = 300
            self.session = URLSession(configuration: config)
        }
    }

    public var runtime: ConnectorRuntime {
        ConnectorRuntime(keyRing: keyRing, session: session, google: google)
    }

    public func provider(for id: ConnectorID) -> (any ConnectorToolProvider)? {
        Self.providers.first { $0.id == id }
    }

    // MARK: Config

    public func configs() async -> [ConnectorConfig] {
        await store.loadConnectorConfigs()
    }

    public func saveConfigs(_ configs: [ConnectorConfig]) async {
        await store.saveConnectorConfigs(configs)
    }

    public func config(for id: ConnectorID) async -> ConnectorConfig {
        (await configs()).first(where: { $0.id == id }) ?? ConnectorConfig(id: id)
    }

    public func setConfig(_ config: ConnectorConfig) async {
        var configs = await configs()
        if let index = configs.firstIndex(where: { $0.id == config.id }) {
            configs[index] = config
        } else {
            configs.append(config)
        }
        await saveConfigs(configs)
    }

    // MARK: Credentials

    public func isConfigured(_ id: ConnectorID) -> Bool {
        provider(for: id)?.isConfigured(keyRing: keyRing) ?? false
    }

    public func disconnect(_ id: ConnectorID) {
        for account in id.credentialAccounts {
            keyRing.remove(account)
        }
    }

    // MARK: Tool surface

    public func owns(_ toolName: String) -> Bool {
        Self.providers.contains { $0.owns(toolName) }
    }

    public func toolDefs() async -> [APIToolDef] {
        var defs: [APIToolDef] = []
        for provider in Self.providers {
            let config = await config(for: provider.id)
            guard config.enabled, provider.isConfigured(keyRing: keyRing) else { continue }
            defs += provider.toolDefs(permissions: config.permissions)
        }
        return defs
    }

    public func run(call: APIToolCall) async -> ToolOutcome {
        guard let provider = Self.providers.first(where: { $0.owns(call.function.name) }) else {
            return ToolOutcome(resultText: "Unknown tool: \(call.function.name).")
        }
        let config = await config(for: provider.id)
        guard config.enabled else {
            return ToolOutcome(resultText: "The \(provider.id.displayName) connector is disabled. Enable it in Settings.")
        }
        guard provider.isConfigured(keyRing: keyRing) else {
            return ToolOutcome(resultText: "The \(provider.id.displayName) connector is not connected. Connect it in Settings.")
        }
        let args = AgentTools.arguments(of: call)
        return await provider.run(call.function.name, args: args, permissions: config.permissions, runtime: runtime)
    }

    // MARK: Status & tests

    public func status(for id: ConnectorID) async -> ConnectorStatus {
        let config = await config(for: id)
        return ConnectorStatus(
            id: id,
            name: id.displayName,
            detail: id.detail,
            enabled: config.enabled,
            configured: provider(for: id)?.isConfigured(keyRing: keyRing) ?? false,
            permissions: config.permissions,
            oauthAvailable: google.isConfigured
        )
    }

    public func test(_ id: ConnectorID) async -> (ok: Bool, message: String) {
        guard let provider = provider(for: id) else {
            return (false, "Unknown connector: \(id.rawValue).")
        }
        guard provider.isConfigured(keyRing: keyRing) else {
            return (false, "\(id.displayName) is not connected yet.")
        }
        return await provider.test(runtime: runtime)
    }
}
