import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Connector identity & configuration

public enum ConnectorID: String, Codable, CaseIterable, Hashable, Sendable {
    case gmail
    case googleads
    case cloudflare
    case github
    case web

    public var displayName: String {
        switch self {
        case .gmail: "Gmail"
        case .googleads: "Google Ads"
        case .cloudflare: "Cloudflare"
        case .github: "GitHub"
        case .web: "Web"
        }
    }

    public var detail: String {
        switch self {
        case .gmail: "Search, read, draft, and optionally send email through your Gmail account."
        case .googleads: "Run read-only GAQL queries against your Google Ads accounts, with optional campaign pause/enable."
        case .cloudflare: "Inspect Cloudflare zones and DNS, with optional write access."
        case .github: "Read repositories, code, issues, and pull requests on GitHub, with optional write access to a branch."
        case .web: "Read public web pages, and search the web with a Brave Search key."
        }
    }

    /// KeyRing accounts that hold credentials for this connector. Removing all of them fully disconnects it.
    public var credentialAccounts: [String] {
        switch self {
        case .cloudflare: [CloudflareConnector.tokenAccount]
        case .github: [GitHubConnector.tokenAccount]
        case .web: [WebConnector.braveKeyAccount]
        case .gmail: [GoogleTokenProvider.refreshAccount(for: self), GoogleTokenProvider.cacheAccount(for: self)]
        case .googleads: [
            GoogleTokenProvider.refreshAccount(for: self),
            GoogleTokenProvider.cacheAccount(for: self),
            GoogleTokenProvider.serviceAccountAccount(for: self),
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
    /// GitHub: allow committing files to a non-default branch and commenting on issues/PRs.
    public var githubWrite: Bool
    /// Google Ads: allow pausing and enabling campaigns.
    public var adsWrite: Bool

    public init(sendEmail: Bool = false, createDraft: Bool = false, dnsWrite: Bool = false, githubWrite: Bool = false, adsWrite: Bool = false) {
        self.sendEmail = sendEmail
        self.createDraft = createDraft
        self.dnsWrite = dnsWrite
        self.githubWrite = githubWrite
        self.adsWrite = adsWrite
    }

    /// Every write allowed. Only meaningful as a scope: it is always intersected with the
    /// connector's own toggles, so this means "whatever the user switched on in Connections".
    public static let all = ConnectorPermissions(sendEmail: true, createDraft: true, dnsWrite: true, githubWrite: true, adsWrite: true)

    /// A permission is granted only when both sides allow it.
    public func intersected(with other: ConnectorPermissions) -> ConnectorPermissions {
        ConnectorPermissions(
            sendEmail: sendEmail && other.sendEmail,
            createDraft: createDraft && other.createDraft,
            dnsWrite: dnsWrite && other.dnsWrite,
            githubWrite: githubWrite && other.githubWrite,
            adsWrite: adsWrite && other.adsWrite
        )
    }

    // Hand-written so configs saved before newer permissions existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sendEmail = try c.decodeIfPresent(Bool.self, forKey: .sendEmail) ?? false
        createDraft = try c.decodeIfPresent(Bool.self, forKey: .createDraft) ?? false
        dnsWrite = try c.decodeIfPresent(Bool.self, forKey: .dnsWrite) ?? false
        githubWrite = try c.decodeIfPresent(Bool.self, forKey: .githubWrite) ?? false
        adsWrite = try c.decodeIfPresent(Bool.self, forKey: .adsWrite) ?? false
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
            throw ConnectorError("HTTP \(status): \(googleErrorSummary(data) ?? snippet(data))")
        }
        return data
    }

    /// Google APIs nest the useful part (e.g. Google Ads `requestError: PAGE_SIZE_NOT_SUPPORTED`)
    /// deep in `error.details[].errors[]`, past where a raw snippet gets cut off. Pull it out.
    static func googleErrorSummary(_ data: Data) -> String? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        var parts: [String] = []
        if let status = error["status"] as? String { parts.append(status) }
        for detail in error["details"] as? [[String: Any]] ?? [] {
            for item in detail["errors"] as? [[String: Any]] ?? [] {
                let code = (item["errorCode"] as? [String: Any])?.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                let message = item["message"] as? String
                parts.append([code, message].compactMap { $0 }.joined(separator: " — "))
            }
        }
        if parts.count <= 1, let message = error["message"] as? String { parts.append(message) }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
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
    public typealias WriteApproval = @Sendable (APIToolCall) async -> String

    public let store: MissionStore
    public let keyRing: KeyRing
    public let session: URLSession
    public let google: GoogleOAuth

    public static let providers: [any ConnectorToolProvider] = [
        CloudflareConnector(),
        GitHubConnector(),
        GmailConnector(),
        GoogleAdsConnector(),
        WebConnector(),
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

    public static let readOnlyToolNames: Set<String> = [
        "gmail_search", "gmail_read",
        "googleads_accounts", "googleads_campaigns", "googleads_query",
        "cloudflare_zones", "cloudflare_dns_list",
        "github_repos", "github_read", "github_search", "github_issues", "github_issue",
        "web_fetch", "web_search",
    ]

    public func toolDefs(scope: ToolScope? = nil, readOnly: Bool = false) async -> [APIToolDef] {
        var defs: [APIToolDef] = []
        for provider in Self.providers {
            let config = await config(for: provider.id)
            guard config.enabled, provider.isConfigured(keyRing: keyRing) else { continue }
            if let scope, !scope.connectorIDs.contains(provider.id) { continue }
            let permissions = scope.map { config.permissions.intersected(with: $0.permissions) } ?? config.permissions
            if let web = provider as? WebConnector {
                defs += web.toolDefs(keyRing: keyRing).filter { !readOnly || Self.readOnlyToolNames.contains($0.function.name) }
            } else {
                defs += provider.toolDefs(permissions: permissions).filter { !readOnly || Self.readOnlyToolNames.contains($0.function.name) }
            }
        }
        return defs
    }

    public func run(call: APIToolCall, scope: ToolScope? = nil, readOnly: Bool = false, approval: WriteApproval? = nil, approved: Bool = false) async -> ToolOutcome {
        guard let provider = Self.providers.first(where: { $0.owns(call.function.name) }) else {
            return .failure("Unknown tool: \(call.function.name).")
        }
        guard !readOnly || Self.readOnlyToolNames.contains(call.function.name) else {
            return .failure("Ada only has read-only connector access in this conversation.")
        }
        if let scope, !scope.connectorIDs.contains(provider.id) {
            return .failure("This team does not have access to \(provider.id.displayName).")
        }
        let config = await config(for: provider.id)
        guard config.enabled else {
            return .failure("The \(provider.id.displayName) connector is disabled. Enable it in Connections.")
        }
        guard provider.isConfigured(keyRing: keyRing) else {
            return .failure("The \(provider.id.displayName) connector is not connected. Connect it in Connections.")
        }
        let permissions = scope.map { config.permissions.intersected(with: $0.permissions) } ?? config.permissions
        if !readOnly && !Self.readOnlyToolNames.contains(call.function.name) && !approved {
            guard let approval else { return .failure("Connector writes require an explicit user approval.") }
            let decision = await approval(call)
            guard decision.hasPrefix("approved:") else { return .failure(decision) }
        }
        let args = AgentTools.arguments(of: call)
        return await provider.run(call.function.name, args: args, permissions: permissions, runtime: runtime)
    }

    // MARK: Status & tests

    public func status(for id: ConnectorID) async -> ConnectorStatus {
        let config = await config(for: id)
        return ConnectorStatus(
            id: id,
            name: id.displayName,
            detail: id.detail,
            enabled: config.enabled,
            // For the web connector, "configured" means web search has a key; fetching always works.
            configured: id == .web ? WebConnector.hasSearchKey(keyRing) : (provider(for: id)?.isConfigured(keyRing: keyRing) ?? false),
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
