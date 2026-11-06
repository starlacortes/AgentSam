import SwiftUI
import Observation
import Foundation
import Darwin
import AgentSamCore

@Observable
final class MissionLiveState {
    let missionID: UUID
    var mission: Mission?
    var events: [RunEvent] = []
    var deliverables: [String] = []
    var deliverableContents: [String: String] = [:]
    var selectedDeliverable: String?
    private var observeTask: Task<Void, Never>?

    init(missionID: UUID) {
        self.missionID = missionID
    }

    func start(store: MissionStore) {
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            guard let self else { return }
            self.mission = await store.mission(id: self.missionID)
            self.events = await store.events(missionID: self.missionID, afterSeq: 0)
            self.deliverables = await store.deliverables(missionID: self.missionID)
            if let first = self.deliverables.first { self.selectedDeliverable = first }

            let stream = await store.subscribe(missionID: self.missionID)
            for await event in stream {
                guard !Task.isCancelled else { break }
                if !self.events.contains(where: { $0.seq == event.seq }) {
                    self.events.append(event)
                    self.events.sort { $0.seq < $1.seq }
                }
                switch event.kind {
                case .phase, .taskStarted, .taskDone, .cost, .deliverable, .verifyVerdict, .missionEnd:
                    self.mission = await store.mission(id: self.missionID)
                default:
                    break
                }
                if event.kind == .deliverable || event.kind == .missionEnd {
                    self.deliverables = await store.deliverables(missionID: self.missionID)
                    if self.selectedDeliverable == nil {
                        self.selectedDeliverable = self.deliverables.first
                    }
                }
                if event.kind == .missionEnd {
                    self.deliverableContents = [:]
                }
            }
        }
    }

    func stopObserving() {
        observeTask?.cancel()
        observeTask = nil
    }

    func content(for deliverable: String, store: MissionStore) async -> String? {
        if let cached = deliverableContents[deliverable] { return cached }
        guard let text = await store.deliverable(missionID: missionID, name: deliverable) else { return nil }
        deliverableContents[deliverable] = text
        return text
    }
}

@MainActor
@Observable
final class AppModel {
    let store: MissionStore
    let engine: MissionEngine
    let keyRing: KeychainKeyRing
    let client = LLMClient()
    let connectorHub: ConnectorHub

    var teams: [Team] = []
    var providers: [ProviderConfig] = []
    var missions: [Mission] = []
    var connectorStatuses: [ConnectorStatus] = []
    var liveState: MissionLiveState?
    var dataDirPath: String = ""
    var isBootstrapped = false

    var notice: String?

    init() {
        let raw = ProcessInfo.processInfo.environment["AGENTSAM_DATA"]
        let url: URL
        if let raw, !raw.isEmpty {
            url = URL(fileURLWithPath: raw)
        } else {
            url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AgentSam", isDirectory: true)
        }
        store = MissionStore(root: url)
        keyRing = KeychainKeyRing()
        let google = GoogleOAuth(
            clientID: ProcessInfo.processInfo.environment["AGENTSAM_GOOGLE_CLIENT_ID"] ?? "",
            clientSecret: ProcessInfo.processInfo.environment["AGENTSAM_GOOGLE_CLIENT_SECRET"] ?? ""
        )
        connectorHub = ConnectorHub(store: store, keyRing: keyRing, google: google)
        engine = MissionEngine(store: store, keyRing: keyRing, connectors: connectorHub)
        dataDirPath = url.path
        Task { await bootstrap() }
    }

    func bootstrap() async {
        let url = URL(fileURLWithPath: dataDirPath)
        let providersURL = url.appendingPathComponent("providers.json")
        if !FileManager.default.fileExists(atPath: providersURL.path) {
            await store.saveProviders(ProviderConfig.builtin)
        }
        let connectorsURL = url.appendingPathComponent("connectors.json")
        if !FileManager.default.fileExists(atPath: connectorsURL.path) {
            await store.saveConnectorConfigs(ConnectorConfig.defaults())
        }
        if await store.loadTeams().isEmpty {
            await store.saveTeam(Team.starterTeam())
        }
        await reload()
        isBootstrapped = true
    }

    func reload() async {
        teams = await store.loadTeams()
        providers = await store.loadProviders()
        missions = await store.listMissions(limit: 200)
        await refreshConnectorStatuses()
    }

    func saveProviders(_ list: [ProviderConfig]) async {
        providers = list
        await store.saveProviders(list)
    }

    func saveTeam(_ team: Team) async {
        var team = team
        team.updatedAt = Date()
        await store.saveTeam(team)
        await reload()
    }

    func deleteTeam(_ team: Team) async {
        await store.deleteTeam(id: team.id)
        await reload()
    }

    func launchMission(team: Team, objective: String) async {
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let mission = await store.createMission(team: team, objective: objective, outputLanguage: CoreL10n.preferredLanguage())
        await engine.launch(missionID: mission.id, team: team)
        await reload()
        open(mission.id)
    }

    func open(_ missionID: UUID) {
        liveState?.stopObserving()
        let state = MissionLiveState(missionID: missionID)
        liveState = state
        state.start(store: store)
    }

    func stopMission(_ missionID: UUID) async {
        await engine.stop(missionID: missionID)
    }

    func isRunning(_ missionID: UUID) -> Bool {
        missions.first(where: { $0.id == missionID })?.status == .running
    }

    func deleteMission(_ missionID: UUID) async {
        await engine.stop(missionID: missionID)
        if liveState?.missionID == missionID {
            liveState?.stopObserving()
            liveState = nil
        }
        await store.deleteMission(id: missionID)
        await reload()
    }

    func apiKey(for provider: ProviderConfig) -> String {
        keyRing.get(provider.keyAccount) ?? ""
    }

    func setAPIKey(_ key: String, for provider: ProviderConfig) {
        try? keyRing.set(key, for: provider.keyAccount)
    }

    func removeAPIKey(for provider: ProviderConfig) {
        keyRing.remove(provider.keyAccount)
    }

    func testConnection(to provider: ProviderConfig) async -> String {
        let key = apiKey(for: provider)
        guard !key.isEmpty else { return "No API key saved for \(provider.name)." }
        let result = await client.testConnection(provider: provider, key: key)
        return result.message
    }

    // MARK: Connectors

    func connectorStatus(for id: ConnectorID) -> ConnectorStatus {
        connectorStatuses.first(where: { $0.id == id })
            ?? ConnectorStatus(
                id: id,
                name: id.displayName,
                detail: id.detail,
                enabled: true,
                configured: false,
                permissions: ConnectorPermissions(),
                oauthAvailable: connectorHub.google.isConfigured
            )
    }

    func setConnectorEnabled(_ id: ConnectorID, enabled: Bool) async {
        var config = await connectorHub.config(for: id)
        config.enabled = enabled
        await connectorHub.setConfig(config)
        await refreshConnectorStatuses()
    }

    func setConnectorPermissions(_ id: ConnectorID, permissions: ConnectorPermissions) async {
        var config = await connectorHub.config(for: id)
        config.permissions = permissions
        await connectorHub.setConfig(config)
        await refreshConnectorStatuses()
    }

    func disconnectConnector(_ id: ConnectorID) async {
        connectorHub.disconnect(id)
        await refreshConnectorStatuses()
    }

    func testConnector(_ id: ConnectorID) async -> String {
        let result = await connectorHub.test(id)
        return result.message
    }

    func setCloudflareToken(_ token: String) async -> (ok: Bool, message: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (false, "Cloudflare API token is required.") }
        let verified = await CloudflareConnector.verifyToken(trimmed, session: connectorHub.session)
        guard verified.ok else { return (false, verified.message) }
        try? keyRing.set(trimmed, for: CloudflareConnector.tokenAccount)
        await refreshConnectorStatuses()
        return (true, "Cloudflare token verified and stored.")
    }

    func setGoogleAdsCredentials(developerToken: String, customerId: String) async {
        let token = developerToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let customer = customerId.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "customers/", with: "")
        if !token.isEmpty { try? keyRing.set(token, for: GoogleAdsConnector.developerTokenAccount) }
        if !customer.isEmpty { try? keyRing.set(customer, for: GoogleAdsConnector.customerIdAccount) }
        await refreshConnectorStatuses()
    }

    /// Runs the Google OAuth flow for a connector. Returns an error message, or nil on success.
    func startGoogleOAuth(_ id: ConnectorID) async -> String? {
        guard connectorHub.google.isConfigured else {
            return "Google OAuth is not configured on this Mac. Set AGENTSAM_GOOGLE_CLIENT_ID (and optionally AGENTSAM_GOOGLE_CLIENT_SECRET) and restart AgentSam."
        }
        let config = await connectorHub.config(for: id)
        let scopes = id == .gmail
            ? GmailConnector.scopes(permissions: config.permissions)
            : [GoogleAdsConnector.oauthScope]
        do {
            let outcome = try await MacGoogleOAuth.run(google: connectorHub.google, scopes: scopes)
            let result = try await connectorHub.google.exchangeCode(code: outcome.code, redirectURI: outcome.redirectURI, codeVerifier: outcome.verifier)
            guard let refreshToken = result.refreshToken, !refreshToken.isEmpty else {
                return "Google did not return a refresh token. Reconnect and approve the consent screen."
            }
            try? keyRing.set(refreshToken, for: GoogleTokenProvider.refreshAccount(for: id))
            keyRing.remove(GoogleTokenProvider.cacheAccount(for: id))
            await refreshConnectorStatuses()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func refreshConnectorStatuses() async {
        connectorStatuses = []
        for connectorID in ConnectorID.allCases {
            connectorStatuses.append(await connectorHub.status(for: connectorID))
        }
    }
}

/// Runs the Google desktop-app OAuth flow on macOS: binds a loopback port, opens the default browser,
/// and captures the authorization code from Google's redirect.
enum MacGoogleOAuth {
    struct Outcome: Sendable {
        let code: String
        let redirectURI: String
        let verifier: String
    }

    static func run(google: GoogleOAuth, scopes: [String]) async throws -> Outcome {
        let listener = LoopbackListener()
        let port = try listener.bindAndListen()
        let redirectURI = "http://127.0.0.1:\(port)/oauth2callback"
        let (verifier, _) = GoogleOAuth.newVerifier()
        let state = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let url = google.authorizeURL(redirectURI: redirectURI, state: state, scopes: scopes, codeVerifier: verifier, prompt: "consent") else {
            listener.close()
            throw ConnectorError("Could not build the Google authorization URL.")
        }
        // MacGoogleOAuth.run is called from AppModel on the main actor, so opening the browser is safe here.
        NSWorkspace.shared.open(url)
        let code = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: listener.waitForCode())
            }
        }
        return Outcome(code: code, redirectURI: redirectURI, verifier: verifier)
    }
}

/// Minimal blocking HTTP listener on 127.0.0.1 that accepts exactly one request and extracts the OAuth code.
/// Confined to a single thread at a time: bind on the caller, then waitForCode on a background queue.
final class LoopbackListener: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private(set) var port: Int = 0

    func bindAndListen() throws -> Int {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw ConnectorError("Could not create the loopback socket.") }
        var reuse: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(sock, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(sock)
            throw ConnectorError("Could not bind the loopback socket.")
        }
        guard Darwin.listen(sock, 1) == 0 else {
            Darwin.close(sock)
            throw ConnectorError("Could not listen on the loopback socket.")
        }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.getsockname(sock, sockaddrPointer, &length)
            }
        }
        listenFD = sock
        port = Int(UInt16(bigEndian: local.sin_port))
        return port
    }

    func waitForCode() -> Result<String, Error> {
        var timeout = timeval(tv_sec: 300, tv_usec: 0)
        _ = setsockopt(listenFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else {
            close()
            return .failure(ConnectorError("Timed out waiting for the Google sign-in to complete."))
        }
        clientFD = client
        var buffer = [UInt8](repeating: 0, count: 8192)
        let received = Darwin.recv(client, &buffer, buffer.count, 0)
        guard received > 0,
              let requestText = String(bytes: buffer[0..<Int(received)], encoding: .utf8),
              let firstLine = requestText.components(separatedBy: "\r\n").first else {
            respond(title: "Sign-in failed", message: "No callback received from Google.")
            close()
            return .failure(ConnectorError("No callback received from Google."))
        }
        let path = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let code = URLComponents(string: path)?.queryItems?.first(where: { $0.name == "code" })?.value
        guard let code, !code.isEmpty else {
            respond(title: "Sign-in failed", message: "Google did not return an authorization code. Return to AgentSam and try again.")
            close()
            return .failure(ConnectorError("Google did not return an authorization code."))
        }
        respond(title: "AgentSam connected", message: "You can close this window and return to AgentSam.")
        close()
        return .success(code)
    }

    private func respond(title: String, message: String) {
        let html = """
        <!doctype html><html><head><meta charset="utf-8"><title>AgentSam</title>
        <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#0A100D;color:#F2F7F2;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}main{text-align:center;padding:32px;max-width:420px}h1{color:#4AD99E;font-size:22px;margin:0 0 10px}p{color:#93A89A;font-size:14px;line-height:1.5;margin:0}</style>
        </head><body><main><h1>\(title)</h1><p>\(message)</p></main></body></html>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        _ = response.withCString { Darwin.send(clientFD, $0, response.utf8.count, 0) }
    }

    func close() {
        if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }
}

