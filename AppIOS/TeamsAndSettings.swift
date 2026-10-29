import SwiftUI
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
                            Button("Edit roster") { editingTeam = team }
                            Button("Delete team", role: .destructive) { deletingTeam = team }
                        }
                    }
                }
                .padding(16)
                if session.teams.isEmpty {
                    ContentUnavailableView("No teams yet", systemImage: "person.3", description: Text("Hire a template or build your own roster."))
                }
                if let error = session.lastError {
                    Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(AgentSamTheme.danger).padding()
                }
            }
            .background(AgentSamBackground())
            .navigationTitle("Teams")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showNewTeam = true } label: { Image(systemName: "plus.circle.fill") }
                }
            }
            .refreshable { await session.refreshAll() }
            .task { await session.refreshAll() }
            .sheet(isPresented: $showNewTeam) { IOTeamEditView(team: nil) }
            .sheet(item: $editingTeam) { team in IOTeamEditView(team: team) }
            .sheet(item: $missionTeam) { team in NewMissionSheet(liveBinding: $liveMission, presetTeam: team) }
            .navigationDestination(item: $liveMission) { live in MissionLiveView(live: live).onDisappear { live.stop() } }
            .confirmationDialog("Delete \(deletingTeam?.name ?? "this team")? Existing missions will be kept.", isPresented: Binding(get: { deletingTeam != nil }, set: { if !$0 { deletingTeam = nil } })) {
                Button("Delete Team", role: .destructive) {
                    if let deletingTeam { Task { await session.deleteTeam(deletingTeam) } }
                    deletingTeam = nil
                }
                Button("Cancel", role: .cancel) { deletingTeam = nil }
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
                AgentSamChip("\(team.agents.count) AGENTS", tint: AgentSamTheme.emeraldLight)
            }
            Text(team.name).font(AgentSamTheme.displayFont(21)).foregroundStyle(AgentSamTheme.ink)
            Text(team.goal.isEmpty ? "No standing goal" : team.goal).font(.callout).foregroundStyle(AgentSamTheme.muted).lineLimit(2)
            AgentSamAvatarStack(agents: team.agents, size: 36)
            HStack {
                Button("Edit roster", action: onEdit).buttonStyle(.plain).font(.caption.weight(.semibold)).foregroundStyle(AgentSamTheme.emeraldLight)
                Spacer()
                Button("Launch", action: onLaunch).buttonStyle(AgentSamPrimaryButtonStyle()).disabled(team.agents.isEmpty)
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
    @State private var message: String?
    @State private var editingProvider: ProviderConfig?
    @State private var showGuidedSetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("Server URL", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Access token", text: $token).textInputAutocapitalization(.never)
                    Button("Reconnect") {
                        Task {
                            let ok = await session.connect(url: url, token: token)
                            message = ok ? "Connected." : (session.lastError ?? "Connection failed.")
                        }
                    }
                    .disabled(url.isEmpty || token.isEmpty)
                    if let info = session.info {
                        LabeledContent("Status") { Text("Connected · \(info.teams) teams · \(info.missions) missions").font(.caption) }
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(session.lastError == nil ? AgentSamTheme.emerald : AgentSamTheme.danger) }
                }
                Section {
                    ForEach(session.providers, id: \.provider.id) { status in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(status.provider.name).font(.callout.weight(.semibold))
                                Spacer()
                                Image(systemName: status.hasKey ? "checkmark.seal.fill" : "exclamationmark.triangle")
                                    .foregroundStyle(status.hasKey ? AgentSamTheme.emerald : AgentSamTheme.goldLight)
                                Button("Edit") { editingProvider = status.provider }.font(.caption)
                            }
                            HStack {
                                SecureField(status.hasKey ? "Saved — paste to replace" : "Paste API key", text: binding(for: status.provider.id))
                                    .textInputAutocapitalization(.never)
                                Button("Save") {
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
                                    Text("Test connection")
                                }
                            }
                            .disabled(testingProvider != nil || (!status.hasKey && (keyDrafts[status.provider.id] ?? "").isEmpty))
                            if let result = testResults[status.provider.id] {
                                Text(result).font(.caption).foregroundStyle(AgentSamTheme.muted).textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button("Add custom provider") {
                        editingProvider = ProviderConfig(id: "custom-\(UUID().uuidString.prefix(6).lowercased())", name: "OpenAI-compatible endpoint", kind: .openAICompatible, baseURL: "https://", models: [], defaultModel: nil)
                    }
                } header: {
                    Text("Provider API keys (server-side)")
                } footer: {
                    Text("Keys are stored only on your server and used when missions run there.")
                }
                Section("Workspace") {
                    Button("Run guided setup") { showGuidedSetup = true }
                    LabeledContent("App") { Text("AgentSam for iOS") }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AgentSamBackground())
            .navigationTitle("Server")
            .onAppear { url = session.baseURL; token = session.token }
            .sheet(item: $editingProvider) { provider in IOProviderEditView(provider: provider) }
            .sheet(isPresented: $showGuidedSetup) { IOGuidedSetupView() }
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
                TextField("Display name", text: $name)
                Picker("Kind", selection: $kind) {
                    Text("OpenAI-compatible").tag(ProviderConfig.Kind.openAICompatible)
                    Text("Anthropic").tag(ProviderConfig.Kind.anthropic)
                }
                TextField("Base URL", text: $baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Comma-separated model IDs", text: $models).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Default model ID", text: $defaultModel).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            .scrollContentBackground(.hidden)
            .background(AgentSamBackground())
            .navigationTitle("Configure Provider")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
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
