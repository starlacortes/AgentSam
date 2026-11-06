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
    @State private var draftTeam = Team(name: TeamTemplateCatalog.all[0].name, emoji: "🔎")
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
                Button(String(localized: "Skip setup")) {
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
        // Sheet content doesn't inherit the environment on macOS 27, so re-inject the model.
        .sheet(item: $editingAgent) { agent in
            AgentEditSheet(
                agent: agent,
                isExisting: draftTeam.agents.contains(where: { $0.id == agent.id }),
                onHire: { updated in upsertAgent(updated) },
                onFire: { fired in draftTeam.agents.removeAll { $0.id == fired.id } }
            )
            .frame(minWidth: 560, minHeight: 620)
            .environment(model)
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
            .environment(model)
        }
    }

    @ViewBuilder private var heading: some View {
        switch step {
        case 1:
            GuidedSetupHeading(step: 1, kicker: String(localized: "Bring your own keys"), title: String(localized: "Connect your models."), description: String(localized: "AgentSam runs on your API keys—no subscriptions or markup. Keys stay in this Mac's Keychain."))
        case 2:
            GuidedSetupHeading(step: 2, kicker: String(localized: "Start with a squad"), title: String(localized: "Who do you need?"), description: String(localized: "Choose a curated team with working chemistry. You can tune every agent before the first mission."))
        case 3:
            GuidedSetupHeading(step: 3, kicker: String(localized: "Meet & greet"), title: String(localized: "Meet the crew."), description: String(localized: "Rename agents, adjust their prompts, or swap the provider and model behind each role."))
        default:
            GuidedSetupHeading(step: 4, kicker: String(localized: "Put them to work"), title: String(localized: "Your first mission."), description: String(localized: "Describe the outcome. The coordinator will create a plan and every handoff will be visible live."))
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
                        SecureField(model.apiKey(for: provider).isEmpty ? String(format: String(localized: "Paste API key for %@"), provider.name) : String(localized: "Key saved — paste to replace"), text: $keyText)
                            .textFieldStyle(.plain)
                            .font(.callout.monospaced())
                            .padding(11)
                            .background(AgentSamTheme.background)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(AgentSamTheme.strongLine))
                        Button(model.apiKey(for: provider).isEmpty ? String(localized: "Save key") : String(localized: "Replace")) { saveKey() }
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
                                Text(String(localized: "Test connection"))
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
                editingProvider = ProviderConfig(id: "custom-\(UUID().uuidString.prefix(6).lowercased())", name: String(localized: "OpenAI-compatible endpoint"), kind: .openAICompatible, baseURL: "https://", models: [], defaultModel: nil)
            } label: {
                Label(String(localized: "Add a custom provider"), systemImage: "plus.circle")
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
            Button(String(localized: "Build from scratch")) {
                draftTeam = Team(name: String(localized: "New Team"), emoji: "🛡️", agents: [])
                step = 3
            }
            .buttonStyle(AgentSamGhostButtonStyle())
        }
    }

    private var crewStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField(String(localized: "Team name"), text: $draftTeam.name)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .padding(9)
                    .background(AgentSamTheme.deep)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Button(String(localized: "Hire agent")) { showAgentPicker = true }.buttonStyle(AgentSamGhostButtonStyle())
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
                    Text(String(format: String(localized: "%lld agents · %@"), draftTeam.agents.count, draftTeam.coordinator?.name ?? String(localized: "No coordinator")))
                        .font(.caption).foregroundStyle(AgentSamTheme.muted)
                }
            }
            MissionObjectiveEditor(objective: $objective)
            Text(String(localized: "Every step runs in the open. Stop anytime; you only pay your own API meter."))
                .font(.caption)
                .foregroundStyle(AgentSamTheme.dim)
        }
    }

    private var footer: some View {
        HStack {
            if step > 1 {
                Button(String(localized: "Back")) { withAnimation { step -= 1 } }.buttonStyle(AgentSamGhostButtonStyle())
            }
            Spacer()
            if step < 4 {
                VStack(alignment: .trailing, spacing: 4) {
                    Button(String(localized: "Continue")) { advance() }
                        .buttonStyle(AgentSamPrimaryButtonStyle())
                        .disabled(step == 1 && !hasConfiguredProvider)
                    if step == 1 && !hasConfiguredProvider {
                        Text(String(localized: "Save at least one provider key to continue.")).font(.caption2).foregroundStyle(AgentSamTheme.dim)
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
                        Text(String(localized: "Launch mission"))
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
            validationMessage = String(localized: "Add a coordinator and worker, use unique agent names, and choose a provider/model for every agent.")
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
        model.providers.first(where: { $0.id == agent.providerID })?.name ?? String(localized: "Choose a provider")
    }
}
