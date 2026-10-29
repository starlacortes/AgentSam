import SwiftUI
import AgentSamCore

struct IOGuidedSetupView: View {
    @Environment(ServerSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var step = 1
    @State private var selectedProviderID = ""
    @State private var keyText = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var selectedTemplate = TeamTemplateCatalog.all[0]
    @State private var draftTeam = Team(name: "Research Crew", emoji: "🔎")
    @State private var objective = ""
    @State private var editingAgent: AgentProfile?
    @State private var editingProvider: ProviderConfig?
    @State private var showAgentPicker = false
    @State private var launching = false
    @State private var validationMessage: String?
    @State private var liveMission: LiveMission?

    private var providers: [ProviderConfig] { session.providers.map(\.provider) }
    private var completionKey: String { "agentsam.onboarding.completed.\(session.baseURL)" }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    HStack {
                        AgentSamBrand(compact: true)
                        Spacer()
                        Button("Skip") { finishSetup() }.foregroundStyle(AgentSamTheme.muted)
                    }
                    HStack(spacing: 7) {
                        ForEach(1...4, id: \.self) { number in
                            Capsule()
                                .fill(number <= step ? AgentSamTheme.emerald : AgentSamTheme.strongLine)
                                .frame(height: 4)
                        }
                    }
                }
                .padding(16)
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        heading
                        content
                    }
                    .padding(18)
                }
                Divider().overlay(AgentSamTheme.line)
                footer
            }
            .background(AgentSamBackground())
            .navigationBarHidden(true)
            .navigationDestination(item: $liveMission) { live in
                MissionLiveView(live: live).onDisappear { live.stop() }
            }
            .onAppear {
                selectedProviderID = providers.first?.id ?? ""
                draftTeam = selectedTemplate.makeTeam(providers: providers)
            }
            .sheet(item: $editingAgent) { agent in
                IOAgentEditView(agent: agent, isExisting: draftTeam.agents.contains(where: { $0.id == agent.id })) { updated in
                    if let index = draftTeam.agents.firstIndex(where: { $0.id == updated.id }) { draftTeam.agents[index] = updated } else { draftTeam.agents.append(updated) }
                } onFire: { fired in
                    draftTeam.agents.removeAll { $0.id == fired.id }
                }
            }
            .sheet(isPresented: $showAgentPicker) {
                IORosterPicker { agent in
                    var agent = agent
                    agent.id = UUID()
                    let provider = providers.first(where: { $0.id == agent.providerID }) ?? providers.first
                    agent.providerID = provider?.id ?? ""
                    agent.model = provider?.defaultModel ?? provider?.models.first ?? ""
                    showAgentPicker = false
                    editingAgent = agent
                }
            }
            .sheet(item: $editingProvider) { provider in IOProviderEditView(provider: provider) }
        }
    }

    @ViewBuilder private var heading: some View {
        switch step {
        case 1: GuidedSetupHeading(step: 1, kicker: "Server-side keys", title: "Connect your models.", description: "Keys are saved only on your AgentSam server and used for headless missions. Test the connection before continuing.")
        case 2: GuidedSetupHeading(step: 2, kicker: "Start with a squad", title: "Who do you need?", description: "Choose a curated team. You can tune every agent before the first mission.")
        case 3: GuidedSetupHeading(step: 3, kicker: "Meet & greet", title: "Meet the crew.", description: "Rename agents, adjust prompts, or swap the provider and model behind each role.")
        default: GuidedSetupHeading(step: 4, kicker: "Put them to work", title: "Your first mission.", description: "Describe the outcome and watch every real handoff live.")
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1: providerStep
        case 2: squadStep
        case 3: crewStep
        default: missionStep
        }
    }

    private var providerStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(providers) { provider in
                ProviderSelectionCard(provider: provider, selected: selectedProviderID == provider.id, configured: session.providers.first(where: { $0.provider.id == provider.id })?.hasKey ?? false) {
                    selectedProviderID = provider.id
                    keyText = ""
                    testResult = nil
                }
            }
            if let provider = selectedProvider {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField(hasKey(provider) ? "Key saved — paste to replace" : "Paste API key for \(provider.name)", text: $keyText)
                        .textFieldStyle(.plain)
                        .textInputAutocapitalization(.never)
                        .padding(11)
                        .background(AgentSamTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    HStack {
                        Button("Save key") { saveKey() }.buttonStyle(AgentSamGhostButtonStyle()).disabled(keyText.isEmpty)
                        Button {
                            testing = true
                            Task {
                                if !keyText.isEmpty {
                                    let saved = await session.saveKey(keyText, for: provider)
                                    if saved { keyText = "" }
                                }
                                if let result = await session.testConnection(to: provider) { testResult = result.message }
                                testing = false
                            }
                        } label: {
                            HStack {
                                if testing { ProgressView() } else { Image(systemName: "bolt") }
                                Text("Test connection")
                            }
                        }
                        .buttonStyle(AgentSamGhostButtonStyle())
                        .disabled(testing || (!hasKey(provider) && keyText.isEmpty))
                    }
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(AgentSamTheme.muted).textSelection(.enabled) }
                }
                .agentSamPanel()
            }
            Button("Add custom provider") {
                editingProvider = ProviderConfig(id: "custom-\(UUID().uuidString.prefix(6).lowercased())", name: "OpenAI-compatible endpoint", kind: .openAICompatible, baseURL: "https://", models: [], defaultModel: nil)
            }
            .buttonStyle(AgentSamGhostButtonStyle())
            if !hasConfiguredProvider {
                Text("Save at least one provider key to continue.")
                    .font(.caption)
                    .foregroundStyle(AgentSamTheme.dim)
            }
        }
    }

    private var squadStep: some View {
        VStack(spacing: 12) {
            ForEach(TeamTemplateCatalog.all) { template in
                SquadSelectionCard(template: template, agents: template.agents(providers: providers), selected: selectedTemplate.id == template.id) {
                    selectedTemplate = template
                    draftTeam = template.makeTeam(providers: providers)
                }
            }
            Button("Build from scratch") {
                draftTeam = Team(name: "New Team", emoji: "🛡️")
                step = 3
            }
            .buttonStyle(AgentSamGhostButtonStyle())
        }
    }

    private var crewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Team name", text: $draftTeam.name)
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .padding(11)
                .background(AgentSamTheme.raised)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                ForEach(draftTeam.agents) { agent in
                    PersonaCard(agent: agent, providerName: providerName(agent)) { editingAgent = agent }
                }
            }
            Button("Hire agent") { showAgentPicker = true }.buttonStyle(AgentSamGhostButtonStyle())
            if let validationMessage { Label(validationMessage, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AgentSamTheme.goldLight) }
        }
    }

    private var missionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                AgentSamAvatarStack(agents: draftTeam.agents, size: 36)
                VStack(alignment: .leading) {
                    Text(draftTeam.name).font(.headline).foregroundStyle(AgentSamTheme.ink)
                    Text("\(draftTeam.agents.count) agents · \(draftTeam.coordinator?.name ?? "No coordinator")").font(.caption).foregroundStyle(AgentSamTheme.muted)
                }
            }
            MissionObjectiveEditor(objective: $objective)
        }
    }

    private var footer: some View {
        HStack {
            if step > 1 { Button("Back") { step -= 1 }.buttonStyle(AgentSamGhostButtonStyle()) }
            Button("Done") { finishSetup() }.buttonStyle(.plain).foregroundStyle(AgentSamTheme.muted).padding(.leading, 8)
            Spacer()
            if step < 4 {
                Button("Continue") { advance() }.buttonStyle(AgentSamPrimaryButtonStyle()).disabled(step == 1 && !hasConfiguredProvider)
            } else {
                Button {
                    launching = true
                    Task {
                        guard let saved = await session.saveTeam(draftTeam),
                              let mission = await session.startMission(team: saved, objective: objective) else {
                            launching = false
                            return
                        }
                        UserDefaults.standard.set(true, forKey: completionKey)
                        let live = LiveMission(missionID: mission.id)
                        live.start()
                        liveMission = live
                        launching = false
                    }
                } label: {
                    HStack {
                        if launching { ProgressView() }
                        Text("Launch mission")
                    }
                }
                .buttonStyle(AgentSamPrimaryButtonStyle())
                .disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || launching || !teamIsValid)
            }
        }
        .padding(16)
    }

    private var selectedProvider: ProviderConfig? { providers.first(where: { $0.id == selectedProviderID }) }
    private var hasConfiguredProvider: Bool { session.providers.contains(where: \.hasKey) }
    private var teamIsValid: Bool {
        !draftTeam.name.trimmingCharacters(in: .whitespaces).isEmpty && draftTeam.coordinator != nil && !draftTeam.workers.isEmpty &&
        Set(draftTeam.agents.map { $0.name.lowercased() }).count == draftTeam.agents.count &&
        draftTeam.agents.allSatisfy { !$0.providerID.isEmpty && !$0.model.isEmpty }
    }

    private func hasKey(_ provider: ProviderConfig) -> Bool {
        session.providers.first(where: { $0.provider.id == provider.id })?.hasKey ?? false
    }

    private func saveKey() {
        guard let provider = selectedProvider, !keyText.isEmpty else { return }
        let key = keyText
        keyText = ""
        Task { _ = await session.saveKey(key, for: provider) }
    }

    private func advance() {
        validationMessage = nil
        if step == 2 { draftTeam = selectedTemplate.makeTeam(providers: providers) }
        if step == 3 && !teamIsValid {
            validationMessage = "Add a coordinator and worker, use unique names, and choose every provider/model."
            return
        }
        step += 1
    }

    private func providerName(_ agent: AgentProfile) -> String {
        providers.first(where: { $0.id == agent.providerID })?.name ?? "Choose provider"
    }

    private func finishSetup() {
        UserDefaults.standard.set(true, forKey: completionKey)
        dismiss()
    }
}
