import SwiftUI
import AgentSamCore

struct GuidedSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("agentsam.onboarding.completed") private var onboardingCompleted = false

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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                AgentSamBrand()
                Spacer()
                Button("Skip setup") {
                    onboardingCompleted = true
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(AgentSamTheme.muted)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            Divider().overlay(AgentSamTheme.line)
            HStack(spacing: 0) {
                GuidedSetupRail(step: step)
                Divider().overlay(AgentSamTheme.line)
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            heading
                            content
                        }
                        .padding(30)
                    }
                    Divider().overlay(AgentSamTheme.line)
                    footer
                }
            }
        }
        .frame(minWidth: 900, minHeight: 630)
        .background(AgentSamBackground())
        .onAppear {
            selectedProviderID = model.providers.first?.id ?? ""
            draftTeam = selectedTemplate.makeTeam(providers: model.providers)
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditSheet(
                agent: agent,
                isExisting: draftTeam.agents.contains(where: { $0.id == agent.id }),
                onHire: { updated in upsertAgent(updated) },
                onFire: { fired in draftTeam.agents.removeAll { $0.id == fired.id } }
            )
            .frame(minWidth: 560, minHeight: 620)
        }
        .sheet(isPresented: $showAgentPicker) {
            TemplateRosterPicker { agent in
                var agent = agent
                agent.id = UUID()
                let provider = model.providers.first(where: { $0.id == agent.providerID }) ?? model.providers.first
                agent.providerID = provider?.id ?? ""
                agent.model = provider?.defaultModel ?? provider?.models.first ?? ""
                showAgentPicker = false
                editingAgent = agent
            }
            .frame(minWidth: 440, minHeight: 400)
        }
        .sheet(item: $editingProvider) { provider in
            ProviderEditSheet(provider: provider) { saved in
                Task {
                    var providers = model.providers
                    if let index = providers.firstIndex(where: { $0.id == saved.id }) {
                        providers[index] = saved
                    } else {
                        providers.append(saved)
                    }
                    await model.saveProviders(providers)
                    selectedProviderID = saved.id
                }
            }
            .frame(minWidth: 520, minHeight: 480)
        }
    }

    @ViewBuilder private var heading: some View {
        switch step {
        case 1:
            GuidedSetupHeading(step: 1, kicker: "Bring your own keys", title: "Connect your models.", description: "AgentSam runs on your API keys—no subscriptions or markup. Keys stay in this Mac’s Keychain.")
        case 2:
            GuidedSetupHeading(step: 2, kicker: "Start with a squad", title: "Who do you need?", description: "Choose a curated team with working chemistry. You can tune every agent before the first mission.")
        case 3:
            GuidedSetupHeading(step: 3, kicker: "Meet & greet", title: "Meet the crew.", description: "Rename agents, adjust their prompts, or swap the provider and model behind each role.")
        default:
            GuidedSetupHeading(step: 4, kicker: "Put them to work", title: "Your first mission.", description: "Describe the outcome. The coordinator will create a plan and every handoff will be visible live.")
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
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(model.providers) { provider in
                    ProviderSelectionCard(
                        provider: provider,
                        selected: selectedProviderID == provider.id,
                        configured: !model.apiKey(for: provider).isEmpty
                    ) {
                        selectedProviderID = provider.id
                        testResult = nil
                        keyText = ""
                    }
                }
            }
            if let provider = selectedProvider {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SecureField(model.apiKey(for: provider).isEmpty ? "Paste API key for \(provider.name)" : "Key saved — paste to replace", text: $keyText)
                            .textFieldStyle(.plain)
                            .font(.callout.monospaced())
                            .padding(11)
                            .background(AgentSamTheme.background)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AgentSamTheme.strongLine))
                        Button(model.apiKey(for: provider).isEmpty ? "Save key" : "Replace") { saveKey() }
                            .buttonStyle(AgentSamGhostButtonStyle())
                            .disabled(keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    HStack(spacing: 12) {
                        Button {
                            saveKey()
                            testing = true
                            testResult = nil
                            Task {
                                testResult = await model.testConnection(to: provider)
                                testing = false
                            }
                        } label: {
                            HStack {
                                if testing { ProgressView().controlSize(.small) } else { Image(systemName: "bolt") }
                                Text("Test connection")
                            }
                        }
                        .buttonStyle(AgentSamGhostButtonStyle())
                        .disabled(testing || (model.apiKey(for: provider).isEmpty && keyText.isEmpty))
                        if let testResult {
                            Text(testResult).font(.caption).foregroundStyle(AgentSamTheme.muted).textSelection(.enabled)
                        }
                    }
                }
                .agentSamPanel()
            }
            Button {
                editingProvider = ProviderConfig(id: "custom-\(UUID().uuidString.prefix(6).lowercased())", name: "OpenAI-compatible endpoint", kind: .openAICompatible, baseURL: "https://", models: [], defaultModel: nil)
            } label: {
                Label("Add a custom provider", systemImage: "plus.circle")
            }
            .buttonStyle(AgentSamGhostButtonStyle())
        }
    }

    private var squadStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 13)], spacing: 13) {
                ForEach(TeamTemplateCatalog.all) { template in
                    SquadSelectionCard(template: template, agents: template.agents(providers: model.providers), selected: selectedTemplate.id == template.id) {
                        selectedTemplate = template
                        draftTeam = template.makeTeam(providers: model.providers)
                    }
                }
            }
            Button("Build from scratch") {
                draftTeam = Team(name: "New Team", emoji: "🛡️", agents: [])
                step = 3
            }
            .buttonStyle(AgentSamGhostButtonStyle())
        }
    }

    private var crewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Team name", text: $draftTeam.name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .padding(9)
                    .background(AgentSamTheme.deep)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button("Hire agent") { showAgentPicker = true }.buttonStyle(AgentSamGhostButtonStyle())
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 13)], spacing: 13) {
                ForEach(draftTeam.agents) { agent in
                    PersonaCard(agent: agent, providerName: providerName(agent)) { editingAgent = agent }
                }
            }
            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(AgentSamTheme.goldLight)
            }
        }
    }

    private var missionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                AgentSamAvatarStack(agents: draftTeam.agents, size: 36)
                VStack(alignment: .leading) {
                    Text(draftTeam.name).font(.headline).foregroundStyle(AgentSamTheme.ink)
                    Text("\(draftTeam.agents.count) agents · \(draftTeam.coordinator?.name ?? "No coordinator")")
                        .font(.caption).foregroundStyle(AgentSamTheme.muted)
                }
            }
            MissionObjectiveEditor(objective: $objective)
            Text("Every step runs in the open. Stop anytime; you only pay your own API meter.")
                .font(.caption)
                .foregroundStyle(AgentSamTheme.dim)
        }
    }

    private var footer: some View {
        HStack {
            if step > 1 {
                Button("Back") { withAnimation { step -= 1 } }.buttonStyle(AgentSamGhostButtonStyle())
            }
            Spacer()
            if step < 4 {
                VStack(alignment: .trailing, spacing: 4) {
                    Button("Continue") { advance() }
                        .buttonStyle(AgentSamPrimaryButtonStyle())
                        .disabled(step == 1 && !hasConfiguredProvider)
                    if step == 1 && !hasConfiguredProvider {
                        Text("Save at least one provider key to continue.").font(.caption2).foregroundStyle(AgentSamTheme.dim)
                    }
                }
            } else {
                Button {
                    launching = true
                    Task {
                        await model.saveTeam(draftTeam)
                        await model.launchMission(team: draftTeam, objective: objective)
                        onboardingCompleted = true
                        launching = false
                        dismiss()
                    }
                } label: {
                    HStack {
                        if launching { ProgressView().controlSize(.small) }
                        Text("Launch mission")
                    }
                }
                .buttonStyle(AgentSamPrimaryButtonStyle())
                .disabled(objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || launching || !teamIsValid)
                .keyboardShortcut(.return)
            }
        }
        .padding(18)
    }

    private var selectedProvider: ProviderConfig? {
        model.providers.first(where: { $0.id == selectedProviderID })
    }

    private var hasConfiguredProvider: Bool {
        model.providers.contains { !model.apiKey(for: $0).isEmpty }
    }

    private var teamIsValid: Bool {
        !draftTeam.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        draftTeam.coordinator != nil &&
        !draftTeam.workers.isEmpty &&
        Set(draftTeam.agents.map { $0.name.lowercased() }).count == draftTeam.agents.count &&
        draftTeam.agents.allSatisfy { !$0.providerID.isEmpty && !$0.model.isEmpty }
    }

    private func advance() {
        validationMessage = nil
        if step == 2 { draftTeam = selectedTemplate.makeTeam(providers: model.providers) }
        if step == 3 && !teamIsValid {
            validationMessage = "Add a coordinator and worker, use unique agent names, and choose a provider/model for every agent."
            return
        }
        withAnimation { step += 1 }
    }

    private func saveKey() {
        guard let provider = selectedProvider, !keyText.isEmpty else { return }
        model.setAPIKey(keyText.trimmingCharacters(in: .whitespacesAndNewlines), for: provider)
        keyText = ""
    }

    private func upsertAgent(_ agent: AgentProfile) {
        if let index = draftTeam.agents.firstIndex(where: { $0.id == agent.id }) {
            draftTeam.agents[index] = agent
        } else {
            draftTeam.agents.append(agent)
        }
    }

    private func providerName(_ agent: AgentProfile) -> String {
        model.providers.first(where: { $0.id == agent.providerID })?.name ?? "Choose a provider"
    }
}
