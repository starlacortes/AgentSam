import SwiftUI
import AuthenticationServices
import AgentSamCore

struct TeamsTab: View {
    @Environment(ServerSession.self) private var session
    @State private var editingTeam: Team?
    @State private var missionTeam: Team?
    @State private var deletingTeam: Team?
    @State private var liveMission: LiveMission?
    @State private var showNewTeam = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 14)], spacing: 14) {
                    ForEach(session.teams) { team in
                        IOTeamCard(team: team) {
                            editingTeam = team
                        } onLaunch: {
                            missionTeam = team
                        }
                        .contextMenu {
                            Button(String(localized: "Edit roster")) { editingTeam = team }
                            Button(String(localized: "Delete team"), role: .destructive) { deletingTeam = team }
                        }
                    }
                }
                .padding(16)
                if session.teams.isEmpty {
                    ContentUnavailableView(String(localized: "No teams yet"), systemImage: "person.3", description: Text(String(localized: "Hire a template or build your own roster.")))
                }
                if let error = session.lastError {
                    Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(AgentSamTheme.danger).padding()
                }
            }
            .background(AgentSamBackground())
            .navigationTitle(String(localized: "Teams"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewTeam = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .refreshable { await session.refreshAll() }
            .task { await session.refreshAll() }
            .sheet(isPresented: $showNewTeam) { IOTeamEditView(team: nil).environment(session) }
            .sheet(item: $editingTeam) { team in IOTeamEditView(team: team).environment(session) }
            .sheet(item: $missionTeam) { team in NewMissionSheet(liveBinding: $liveMission, presetTeam: team).environment(session) }
            .navigationDestination(item: $liveMission) { live in MissionLiveView(live: live).onDisappear { live.stop() } }
            .confirmationDialog(String(format: String(localized: "Delete %@? Existing missions will be kept."), deletingTeam?.name ?? String(localized: "this team")), isPresented: Binding(get: { deletingTeam != nil }, set: { if !$0 { deletingTeam = nil } })) {
                Button(String(localized: "Delete Team"), role: .destructive) {
                    if let deletingTeam { Task { await session.deleteTeam(deletingTeam) } }
                    deletingTeam = nil
                }
                Button(String(localized: "Cancel"), role: .cancel) { deletingTeam = nil }
            }
        }
    }
}

private struct IOTeamCard: View {
    let team: Team
    let onEdit: () -> Void
    let onLaunch: () -> Void
    var onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(team.emoji).font(.largeTitle)
                Spacer()
                AgentSamChip(String(localized: "\(team.agents.count) AGENTS"), tint: AgentSamTheme.emeraldLight)
            }
            Text(team.name).font(AgentSamTheme.displayFont(21)).foregroundStyle(AgentSamTheme.ink)
            Text(team.goal.isEmpty ? String(localized: "No standing goal") : team.goal).font(.callout).foregroundStyle(AgentSamTheme.muted).lineLimit(2)
            AgentSamAvatarStack(agents: team.agents, size: 36)
            HStack {
                Button(String(localized: "Edit roster"), action: onEdit).buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(AgentSamTheme.emeraldLight)
                Spacer()
                Button(String(localized: "Launch"), action: onLaunch).buttonStyle(AgentSamPrimaryButtonStyle()).disabled(team.agents.isEmpty)
            }
        }
        .agentSamPanel()
    }
}

struct SettingsTab: View {
    @Environment(ServerSession.self) private var session
    @State private var url = ""
    @State private var token = ""
    @State private var keyDrafts: [String: String] = [:]
    @State private var testResults: [String: String] = [:]
    @State private var testingProvider: String?
    @State private var testingMaloon = false
    @State private var maloonResult: IntegrationTestResult?
    @State private var message: String?
    @State private var editingProvider: ProviderConfig?
    @State private var showGuidedSetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Server")) {
                    TextField(String(localized: "Server URL"), text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(String(localized: "Access token"), text: $token).textInputAutocapitalization(.never)
                    Button(String(localized: "Reconnect")) {
                        Task {
                            let ok = await session.connect(url: url, token: token)
                            message = ok ? String(localized: "Connected.") : (session.lastError ?? String(localized: "Connection failed."))
                        }
                    }
                    .disabled(url.isEmpty || token.isEmpty)
                    if let info = session.info {
                        LabeledContent(String(localized: "Status")) { Text(String(format: String(localized: "Connected · %lld teams · %lld missions"), info.teams, info.missions)).font(.caption) }
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(session.lastError == nil ? AgentSamTheme.emerald : AgentSamTheme.danger) }
                }
                if let integration = session.integrations.first(where: { $0.id == "maloon" && $0.isConfigured }) {
                    Section {
                        LabeledContent(String(localized: "Source")) { Text(String(format: String(localized: "Indigo · %lld owner workflows"), integration.workflows.count)) }
                        Button {
                            testingMaloon = true
                            Task {
                                maloonResult = await session.testMaloonIntegration()
                                testingMaloon = false
                            }
                        } label: {
                            HStack {
                                if testingMaloon { ProgressView() } else { Image(systemName: "bolt") }
                                Text(String(localized: "Test Indigo connection"))
                            }
                        }
                        .disabled(testingMaloon)
                        if let maloonResult {
                            Text(maloonResult.message)
                                .font(.caption)
                                .foregroundStyle(maloonResult.ok ? AgentSamTheme.emerald : AgentSamTheme.danger)
                                .textSelection(.enabled)
                        }
                    } header: {
                        Text(String(localized: "Maloon"))
                    } footer: {
                        Text(String(localized: "Workflows fetch read-only business snapshots. AgentSam never sends messages or changes Indigo records."))
                    }
                }
                Section {
                    ForEach(session.providers, id: \.provider.id) { status in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(status.provider.name).font(.callout.weight(.semibold))
                                Spacer()
                                Image(systemName: status.hasKey ? "checkmark.seal.fill" : "exclamationmark.triangle")
                                    .foregroundStyle(status.hasKey ? AgentSamTheme.emerald : AgentSamTheme.goldLight)
                                Button(String(localized: "Edit")) { editingProvider = status.provider }.font(.caption)
                            }
                            HStack {
                                SecureField(status.hasKey ? "Saved — paste to replace" : "Paste API key", text: binding(for: status.provider.id))
                                    .textInputAutocapitalization(.never)
                                Button(String(localized: "Save")) {
                                    Task {
                                        if await session.saveKey(keyDrafts[status.provider.id] ?? "", for: status.provider) {
                                            keyDrafts[status.provider.id] = ""
                                            message = "Key saved on server."
                                        }
                                    }
                                }
                                .disabled((keyDrafts[status.provider.id] ?? "").isEmpty)
                            }
                            Button {
                                testingProvider = status.provider.id
                                Task {
                                    if (keyDrafts[status.provider.id] ?? "").isEmpty == false {
                                        _ = await session.saveKey(keyDrafts[status.provider.id] ?? "", for: status.provider)
                                        keyDrafts[status.provider.id] = ""
                                    }
                                    if let result = await session.testConnection(to: status.provider) {
                                        testResults[status.provider.id] = result.message
                                    }
                                    testingProvider = nil
                                }
                            } label: {
                                HStack {
                                    if testingProvider == status.provider.id { ProgressView() } else { Image(systemName: "bolt") }
                                    Text(String(localized: "Test connection"))
                                }
                            }
                            .disabled(testingProvider != nil || (!status.hasKey && (keyDrafts[status.provider.id] ?? "").isEmpty))
                            if let result = testResults[status.provider.id] {
                                Text(result).font(.caption).foregroundStyle(AgentSamTheme.muted).textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button(String(localized: "Add custom provider")) {
                        editingProvider = ProviderConfig(id: "custom-\(UUID().uuidString.prefix(6).lowercased())", name: String(localized: "OpenAI-compatible endpoint"), kind: .openAICompatible, baseURL: "https://", models: [], defaultModel: nil)
                    }
                } header: {
                    Text(String(localized: "Provider API keys (server-side)"))
                } footer: {
                    Text(String(localized: "Keys are stored only on your server and used when missions run there."))
                }
                Section {
                    ForEach(session.connectors) { status in
                        IOConnectorRow(status: status)
                    }
                    if session.connectors.isEmpty {
                        Text(String(localized: "Refresh to load connector status."))
                            .font(.caption)
                            .foregroundStyle(AgentSamTheme.dim)
                    }
                } header: {
                    Text(String(localized: "Connectors"))
                } footer: {
                    Text(String(localized: "Connected services give mission workers external tools. Write actions like sending email or changing DNS are opt-in per connector."))
                }
                Section(String(localized: "Workspace")) {
                    Button(String(localized: "Run guided setup")) { showGuidedSetup = true }
                    LabeledContent(String(localized: "App")) { Text(String(localized: "AgentSam for iOS")) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AgentSamBackground())
            .navigationTitle(String(localized: "Server"))
            .onAppear { url = session.baseURL; token = session.token }
            .sheet(item: $editingProvider) { provider in IOProviderEditView(provider: provider).environment(session) }
            .sheet(isPresented: $showGuidedSetup) { IOGuidedSetupView().environment(session) }
        }
    }

    private func binding(for providerID: String) -> Binding<String> {
        Binding(get: { keyDrafts[providerID] ?? "" }, set: { keyDrafts[providerID] = $0 })
    }
}

struct IOProviderEditView: View {
    @Environment(ServerSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let provider: ProviderConfig
    @State private var name = ""
    @State private var kind: ProviderConfig.Kind = .openAICompatible
    @State private var baseURL = ""
    @State private var models = ""
    @State private var defaultModel = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField(String(localized: "Display name"), text: $name)
                Picker(String(localized: "Kind"), selection: $kind) {
                    Text(String(localized: "OpenAI-compatible")).tag(ProviderConfig.Kind.openAICompatible)
                    Text(String(localized: "Anthropic")).tag(ProviderConfig.Kind.anthropic)
                }
                TextField(String(localized: "Base URL"), text: $baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(String(localized: "Comma-separated model IDs"), text: $models).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(String(localized: "Default model ID"), text: $defaultModel).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .scrollContentBackground(.hidden)
            .background(AgentSamBackground())
            .navigationTitle(String(localized: "Configure Provider"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        saving = true
                        let modelList = models.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        let resolvedDefault = defaultModel.trimmingCharacters(in: .whitespaces)
                        let updated = ProviderConfig(id: provider.id, name: name.trimmingCharacters(in: .whitespaces), kind: kind, baseURL: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")), models: modelList, defaultModel: resolvedDefault.isEmpty ? modelList.first : resolvedDefault)
                        Task {
                            if await session.saveProvider(updated) { dismiss() }
                            saving = false
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || URL(string: baseURL)?.host == nil || saving)
                }
            }
            .onAppear {
                name = provider.name
                kind = provider.kind
                baseURL = provider.baseURL
                models = provider.models.joined(separator: ", ")
                defaultModel = provider.defaultModel ?? ""
            }
        }
    }
}

struct IOConnectorRow: View {
    @Environment(ServerSession.self) private var session
    let status: ConnectorStatus

    @State private var cloudflareToken = ""
    @State private var adsDeveloperToken = ""
    @State private var adsCustomerId = ""
    @State private var message: String?
    @State private var working = false

    private var isGoogle: Bool { status.id == .gmail || status.id == .googleads }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(status.name).font(.callout.weight(.semibold))
                Spacer()
                Image(systemName: status.configured ? "checkmark.seal.fill" : "link")
                    .foregroundStyle(status.configured ? AgentSamTheme.emerald : AgentSamTheme.goldLight)
            }
            Toggle(String(localized: "Enabled in missions"), isOn: enabledBinding)
                .disabled(!status.configured)

            switch status.id {
            case .gmail:
                Toggle(String(localized: "Allow creating drafts"), isOn: permissionBinding(\.createDraft))
                Toggle(String(localized: "Allow sending email"), isOn: permissionBinding(\.sendEmail))
            case .cloudflare:
                Toggle(String(localized: "Allow DNS writes and cache purge"), isOn: permissionBinding(\.dnsWrite))
            case .googleads:
                EmptyView()
            }

            switch status.id {
            case .cloudflare:
                if !status.configured {
                    HStack {
                        SecureField(String(localized: "Cloudflare API token"), text: $cloudflareToken)
                            .textInputAutocapitalization(.never)
                        Button(String(localized: "Save")) { saveCloudflareToken() }
                            .disabled(cloudflareToken.isEmpty || working)
                    }
                }
            case .googleads:
                TextField(String(localized: "Developer token"), text: $adsDeveloperToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(String(localized: "Login customer ID (optional)"), text: $adsCustomerId)
                    .keyboardType(.numberPad)
                    .autocorrectionDisabled()
                Button(String(localized: "Save credentials")) { saveAdsCredentials() }
                    .disabled((adsDeveloperToken.isEmpty && adsCustomerId.isEmpty) || working)
            case .gmail:
                EmptyView()
            }

            HStack(spacing: 14) {
                if isGoogle {
                    if !status.oauthAvailable {
                        Text(String(localized: "Server has no Google OAuth client (set AGENTSAM_GOOGLE_CLIENT_ID)."))
                            .font(.caption)
                            .foregroundStyle(AgentSamTheme.goldLight)
                    } else {
                        Button(status.configured ? String(localized: "Reconnect Google") : String(localized: "Connect Google")) { connectGoogle() }
                            .disabled(working)
                    }
                }
                if status.configured {
                    Button(String(localized: "Test")) { runTest() }
                    Button(String(localized: "Disconnect"), role: .destructive) { disconnect() }
                        .foregroundStyle(AgentSamTheme.danger)
                }
            }
            .buttonStyle(.borderless)
            .font(.callout)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AgentSamTheme.muted)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { status.enabled },
            set: { newValue in
                Task { _ = await session.updateConnector(status.id, enabled: newValue) }
            }
        )
    }

    private func permissionBinding(_ keyPath: WritableKeyPath<ConnectorPermissions, Bool>) -> Binding<Bool> {
        Binding(
            get: { status.permissions[keyPath: keyPath] },
            set: { newValue in
                var permissions = status.permissions
                permissions[keyPath: keyPath] = newValue
                Task { _ = await session.updateConnector(status.id, permissions: permissions) }
            }
        )
    }

    private func connectGoogle() {
        working = true
        message = nil
        Task {
            guard let urlString = await session.googleAuthorizeURL(status.id), let url = URL(string: urlString) else {
                message = session.lastError ?? String(localized: "Could not start Google authorization.")
                working = false
                return
            }
            startOAuthSession(url: url)
        }
    }

    private func startOAuthSession(url: URL) {
        let completion: ASWebAuthenticationSession.CompletionHandler = { _, error in
            Task { @MainActor in
                await session.refreshConnectors()
                working = false
                if error != nil {
                    message = String(localized: "Google sign-in did not complete. If you approved access, pull to refresh.")
                } else {
                    message = String(localized: "Connected with Google.")
                }
            }
        }
        let provider = OAuthContextProvider()
        if #available(iOS 17.4, *) {
            let authSession = ASWebAuthenticationSession(url: url, callback: .customScheme("agentsam-ios"), completionHandler: completion)
            authSession.presentationContextProvider = provider
            authSession.prefersEphemeralWebBrowserSession = true
            authSession.start()
        } else {
            let authSession = ASWebAuthenticationSession(url: url, callbackURLScheme: "agentsam-ios", completionHandler: completion)
            authSession.presentationContextProvider = provider
            authSession.prefersEphemeralWebBrowserSession = true
            authSession.start()
        }
    }

    private func runTest() {
        working = true
        message = nil
        Task {
            if let result = await session.testConnector(status.id) {
                message = result.message
            }
            working = false
        }
    }

    private func disconnect() {
        Task {
            _ = await session.disconnectConnector(status.id)
            message = nil
        }
    }

    private func saveCloudflareToken() {
        working = true
        message = nil
        Task {
            let result = await session.setCloudflareToken(cloudflareToken)
            message = result.message
            if result.ok { cloudflareToken = "" }
            working = false
        }
    }

    private func saveAdsCredentials() {
        working = true
        message = nil
        Task {
            let result = await session.setGoogleAdsCredentials(developerToken: adsDeveloperToken, customerId: adsCustomerId)
            message = result.message
            if result.ok {
                adsDeveloperToken = ""
                adsCustomerId = ""
            }
            working = false
        }
    }
}

private final class OAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
        return scene?.windows.first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

