import Foundation
import Observation
import AgentSamCore

struct ServerInfo: Decodable, Sendable, Equatable {
    var name: String
    var teams: Int
    var missions: Int
    var runningMissions: [UUID]
}

struct MissionDetailPayload: Decodable, Sendable {
    var mission: Mission
    var events: [RunEvent]
    var deliverables: [String]
    var running: Bool
}

struct ProviderStatus: Decodable, Sendable {
    var provider: ProviderConfig
    var hasKey: Bool
}

struct MissionStartBody: Encodable {
    var teamID: UUID?
    var workflowID: String?
    var objective: String?
    var language: String?

    init(teamID: UUID? = nil, workflowID: String? = nil, objective: String? = nil, language: String? = nil) {
        self.teamID = teamID
        self.workflowID = workflowID
        self.objective = objective
        self.language = language
    }
}

struct ServerErrorPayload: Decodable {
    var reason: String
}

struct KeyBody: Encodable {
    var key: String
}

struct TeamInput: Encodable {
    var name: String
    var emoji: String
    var goal: String
    var agents: [AgentProfile]
}

struct ProviderTestResult: Decodable {
    var ok: Bool
    var message: String
}

@Observable
final class ServerSession {
    static let shared = ServerSession()

    private let keychain = KeychainKeyRing(service: "local.agentsam.server")

    var baseURL: String {
        get {
            if let override = ProcessInfo.processInfo.environment["AGENTSAM_SERVER_URL"], !override.isEmpty {
                return override
            }
            return UserDefaults.standard.string(forKey: "agentsam.server.url") ?? ""
        }
        set { UserDefaults.standard.set(newValue, forKey: "agentsam.server.url") }
    }

    var token: String {
        get {
            if let override = ProcessInfo.processInfo.environment["AGENTSAM_SERVER_TOKEN"], !override.isEmpty {
                return override
            }
            return keychain.get("server.token") ?? ""
        }
        set { try? keychain.set(newValue, for: "server.token") }
    }

    var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty }

    var info: ServerInfo?
    var teams: [Team] = []
    var missions: [Mission] = []
    var providers: [ProviderStatus] = []
    var integrations: [IntegrationStatus] = []
    var connectors: [ConnectorStatus] = []
    var lastError: String?
    var refreshing = false

    var maloonWorkflows: [MissionWorkflow] {
        integrations.first(where: { $0.id == "maloon" && $0.isConfigured })?.workflows ?? []
    }

    func connect(url rawURL: String, token rawToken: String) async -> Bool {
        var url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "https://" + url
        }
        while url.hasSuffix("/") { url = String(url.dropLast()) }
        let previousURL = baseURL
        let previousToken = token
        baseURL = url
        token = rawToken
        await refreshAll()
        if lastError != nil {
            baseURL = previousURL
            token = previousToken
            if previousURL.isEmpty { info = nil }
            return false
        }
        return true
    }

    func refreshAll() async {
        refreshing = true
        defer { refreshing = false }
        do {
            async let infoTask = get("api/info", as: ServerInfo.self)
            async let teamsTask = get("api/teams", as: [Team].self)
            async let missionsTask = get("api/missions?limit=100", as: [Mission].self)
            async let providersTask = get("api/providers", as: [ProviderStatus].self)
            async let integrationsTask = get("api/integrations", as: [IntegrationStatus].self)
            async let connectorsTask = get("api/connectors", as: [ConnectorStatus].self)
            info = try await infoTask
            teams = try await teamsTask
            missions = try await missionsTask
            providers = try await providersTask
            integrations = try await integrationsTask
            connectors = try await connectorsTask
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshMissions() async {
        do {
            missions = try await get("api/missions?limit=100", as: [Mission].self)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func startMission(team: Team, objective: String) async -> Mission? {
        await startMission(MissionStartBody(teamID: team.id, objective: objective, language: Self.preferredLanguage()))
    }

    func startMission(workflow: MissionWorkflow, notes: String) async -> Mission? {
        await startMission(MissionStartBody(workflowID: workflow.id, objective: notes, language: Self.preferredLanguage()))
    }

    /// The device language tag ("es" | "en") sent to the server so missions run in the user's language.
    static func preferredLanguage() -> String {
        let first = Locale.preferredLanguages.first?.lowercased() ?? ""
        return first.hasPrefix("es") ? "es" : "en"
    }

    private func startMission(_ input: MissionStartBody) async -> Mission? {
        do {
            let body = try JSONEncoder.iso.encode(input)
            let (data, response) = try await request("api/missions", method: "POST", body: body)
            guard (200..<300).contains(response.statusCode) else {
                let reason = try? JSONDecoder.iso.decode(ServerErrorPayload.self, from: data).reason
                lastError = reason ?? String(format: NSLocalizedString("Server rejected the mission (%lld).", comment: ""), response.statusCode)
                return nil
            }
            let mission = try JSONDecoder.iso.decode(Mission.self, from: data)
            await refreshMissions()
            return mission
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func saveTeam(_ team: Team) async -> Team? {
        do {
            let input = TeamInput(name: team.name, emoji: team.emoji, goal: team.goal, agents: team.agents)
            let body = try JSONEncoder.iso.encode(input)
            let exists = teams.contains(where: { $0.id == team.id })
            let path = exists ? "api/teams/\(team.id.uuidString)" : "api/teams"
            let (data, response) = try await request(path, method: exists ? "PUT" : "POST", body: body)
            guard (200..<300).contains(response.statusCode) else {
                lastError = String(format: NSLocalizedString("Server rejected the team (%lld).", comment: ""), response.statusCode)
                return nil
            }
            let saved = try JSONDecoder.iso.decode(Team.self, from: data)
            await refreshAll()
            return saved
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func deleteTeam(_ team: Team) async -> Bool {
        do {
            let (_, response) = try await request("api/teams/\(team.id.uuidString)", method: "DELETE")
            guard (200..<300).contains(response.statusCode) else {
                lastError = String(format: NSLocalizedString("Server rejected the delete (%lld).", comment: ""), response.statusCode)
                return false
            }
            await refreshAll()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func saveProvider(_ provider: ProviderConfig) async -> Bool {
        do {
            let body = try JSONEncoder.iso.encode(provider)
            let (_, response) = try await request("api/providers", method: "POST", body: body)
            guard (200..<300).contains(response.statusCode) else {
                lastError = String(format: NSLocalizedString("Server rejected the provider (%lld).", comment: ""), response.statusCode)
                return false
            }
            await refreshAll()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func testConnection(to provider: ProviderConfig) async -> ProviderTestResult? {
        do {
            let (data, response) = try await request("api/providers/\(provider.id)/test", method: "POST")
            guard (200..<300).contains(response.statusCode) else {
                lastError = String(format: NSLocalizedString("Server rejected the connection test (%lld).", comment: ""), response.statusCode)
                return nil
            }
            return try JSONDecoder.iso.decode(ProviderTestResult.self, from: data)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func testMaloonIntegration() async -> IntegrationTestResult? {
        do {
            let (data, response) = try await request("api/integrations/maloon/test", method: "POST")
            guard (200..<300).contains(response.statusCode) else {
                let reason = try? JSONDecoder.iso.decode(ServerErrorPayload.self, from: data).reason
                lastError = reason ?? String(format: NSLocalizedString("Maloon connection test failed (%lld).", comment: ""), response.statusCode)
                return nil
            }
            return try JSONDecoder.iso.decode(IntegrationTestResult.self, from: data)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func detail(id: UUID) async throws -> MissionDetailPayload {
        try await get("api/missions/\(id.uuidString)", as: MissionDetailPayload.self)
    }

    func stopMission(id: UUID) async {
        _ = try? await request("api/missions/\(id.uuidString)/stop", method: "POST")
    }

    func deleteMission(id: UUID) async {
        _ = try? await request("api/missions/\(id.uuidString)", method: "DELETE")
        await refreshMissions()
    }

    func deliverable(id: UUID, name: String) async throws -> String {
        let (data, _) = try await request("api/missions/\(id.uuidString)/deliverables/\(name)")
        return String(data: data, encoding: .utf8) ?? ""
    }

    func saveKey(_ key: String, for provider: ProviderConfig) async -> Bool {
        do {
            let body = try JSONEncoder.iso.encode(KeyBody(key: key))
            let (_, response) = try await request("api/providers/\(provider.id)/key", method: "POST", body: body)
            guard (200..<300).contains(response.statusCode) else {
                lastError = String(format: NSLocalizedString("Server rejected the key (%lld).", comment: ""), response.statusCode)
                return false
            }
            await refreshAll()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: Connectors

    func refreshConnectors() async {
        do {
            connectors = try await get("api/connectors", as: [ConnectorStatus].self)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateConnector(_ id: ConnectorID, enabled: Bool? = nil, permissions: ConnectorPermissions? = nil) async -> Bool {
        struct PatchBody: Encodable {
            var enabled: Bool?
            var permissions: ConnectorPermissions?
        }
        do {
            let body = try JSONEncoder.iso.encode(PatchBody(enabled: enabled, permissions: permissions))
            let (data, response) = try await request("api/connectors/\(id.rawValue)", method: "PATCH", body: body)
            guard (200..<300).contains(response.statusCode) else {
                let reason = try? JSONDecoder.iso.decode(ServerErrorPayload.self, from: data).reason
                lastError = reason ?? String(format: NSLocalizedString("Server rejected the connector change (%lld).", comment: ""), response.statusCode)
                return false
            }
            await refreshConnectors()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func disconnectConnector(_ id: ConnectorID) async -> Bool {
        do {
            let (_, response) = try await request("api/connectors/\(id.rawValue)/disconnect", method: "POST")
            guard (200..<300).contains(response.statusCode) else {
                lastError = String(format: NSLocalizedString("Server rejected the disconnect (%lld).", comment: ""), response.statusCode)
                return false
            }
            await refreshConnectors()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func testConnector(_ id: ConnectorID) async -> (ok: Bool, message: String)? {
        do {
            let (data, response) = try await request("api/connectors/\(id.rawValue)/test", method: "POST")
            guard (200..<300).contains(response.statusCode) else {
                let reason = try? JSONDecoder.iso.decode(ServerErrorPayload.self, from: data).reason
                return (false, reason ?? String(format: NSLocalizedString("Connector test failed (%lld).", comment: ""), response.statusCode))
            }
            let result = try JSONDecoder.iso.decode(IntegrationTestResult.self, from: data)
            return (result.ok, result.message)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func setCloudflareToken(_ token: String) async -> (ok: Bool, message: String) {
        do {
            let body = try JSONEncoder.iso.encode(KeyBody(key: token))
            let (data, response) = try await request("api/connectors/cloudflare/token", method: "POST", body: body)
            guard (200..<300).contains(response.statusCode) else {
                let reason = try? JSONDecoder.iso.decode(ServerErrorPayload.self, from: data).reason
                return (false, reason ?? String(format: NSLocalizedString("Server rejected the token (%lld).", comment: ""), response.statusCode))
            }
            await refreshConnectors()
            return (true, NSLocalizedString("Cloudflare token verified and stored.", comment: ""))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func setGoogleAdsCredentials(developerToken: String, customerId: String) async -> (ok: Bool, message: String) {
        struct Body: Encodable {
            var developerToken: String?
            var customerId: String?
        }
        do {
            let body = try JSONEncoder.iso.encode(Body(
                developerToken: developerToken.isEmpty ? nil : developerToken,
                customerId: customerId.isEmpty ? nil : customerId
            ))
            let (data, response) = try await request("api/connectors/googleads/credentials", method: "POST", body: body)
            guard (200..<300).contains(response.statusCode) else {
                let reason = try? JSONDecoder.iso.decode(ServerErrorPayload.self, from: data).reason
                return (false, reason ?? String(format: NSLocalizedString("Server rejected the credentials (%lld).", comment: ""), response.statusCode))
            }
            await refreshConnectors()
            return (true, NSLocalizedString("Google Ads credentials stored.", comment: ""))
        } catch {
            return (false, error.localizedDescription)
        }
    }

    func googleAuthorizeURL(_ id: ConnectorID) async -> String? {
        struct Body: Encodable {
            var clientKind: String
        }
        do {
            let body = try JSONEncoder.iso.encode(Body(clientKind: "app"))
            let (data, response) = try await request("api/connectors/\(id.rawValue)/authorize", method: "POST", body: body)
            guard (200..<300).contains(response.statusCode) else {
                let reason = try? JSONDecoder.iso.decode(ServerErrorPayload.self, from: data).reason
                lastError = reason ?? String(format: NSLocalizedString("Could not start Google authorization (%lld).", comment: ""), response.statusCode)
                return nil
            }
            let result = try JSONDecoder.iso.decode(OAuthStartResult.self, from: data)
            return result.url
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    enum AgentSamServerError: LocalizedError {
        case badURL
        case badResponse

        var errorDescription: String? {
            switch self {
            case .badURL: NSLocalizedString("The server URL is not valid.", comment: "")
            case .badResponse: NSLocalizedString("Unexpected server response — check the token and that the server is running.", comment: "")
            }
        }
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: "\(baseURL)/\(path)") else { throw AgentSamServerError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.preferredLanguage() == "es" ? "es" : "en", forHTTPHeaderField: "Accept-Language")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentSamServerError.badResponse }
        if http.statusCode == 401 {
            throw AgentSamServerError.badResponse
        }
        return (data, http)
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let (data, response) = try await request(path)
        guard (200..<300).contains(response.statusCode) else {
            throw AgentSamServerError.badResponse
        }
        return try JSONDecoder.iso.decode(T.self, from: data)
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension LiveMission: Hashable {
    static func == (lhs: LiveMission, rhs: LiveMission) -> Bool {
        lhs.missionID == rhs.missionID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(missionID)
    }
}

@Observable
final class LiveMission {
    let missionID: UUID
    var mission: Mission?
    var events: [RunEvent] = []
    var deliverables: [String] = []
    var deliverableText: [String: String] = [:]
    var selectedDeliverable: String?
    var connected = false
    var pollTask: Task<Void, Never>?

    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var started = false
    private let session = ServerSession.shared

    init(missionID: UUID) {
        self.missionID = missionID
    }

    func start() {
        guard !started else { return }
        started = true
        Task { await loadDetail() }
        openSocket()
        startPolling()
    }

    func stop() {
        started = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        receiveTask?.cancel()
        receiveTask = nil
        pollTask?.cancel()
        pollTask = nil
        connected = false
    }

    private func loadDetail() async {
        guard let detail = try? await session.detail(id: missionID) else { return }
        events = detail.events.sorted { $0.seq < $1.seq }
        mission = detail.mission
        deliverables = detail.deliverables
        if selectedDeliverable == nil { selectedDeliverable = deliverables.first }
    }

    private func openSocket() {
        guard let url = URL(string: session.baseURL.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://") + "/api/missions/\(missionID.uuidString)/live") else {
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        connected = true
        receiveTask = Task {
            while !Task.isCancelled {
                guard let message = try? await socket.receive() else { break }
                switch message {
                case .string(let text): handle(text)
                default: break
                }
            }
            connected = false
        }
    }

    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { break }
                let status = mission?.status ?? .running
                if status == .running || status == .queued {
                    await loadDetail()
                } else {
                    break
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONDecoder.iso.decode(RunEvent.self, from: data),
              !events.contains(where: { $0.seq == event.seq }) else { return }
        events.append(event)
        events.sort { $0.seq < $1.seq }
        switch event.kind {
        case .phase, .taskStarted, .taskDone, .cost, .deliverable, .verifyVerdict, .missionEnd:
            Task { await loadDetail() }
        default:
            break
        }
    }

    func content(for name: String) async -> String? {
        if let cached = deliverableText[name] { return cached }
        guard let text = try? await session.deliverable(id: missionID, name: name) else { return nil }
        deliverableText[name] = text
        return text
    }
}
