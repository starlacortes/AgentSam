import SwiftUI
import AgentSamCore

struct IOTeamEditView: View {
    @Environment(ServerSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let team: Team?

    @State private var name = ""
    @State private var emoji = "🛡️"
    @State private var goal = ""
    @State private var roster: [AgentProfile] = []
    @State private var editingAgent: AgentProfile?
    @State private var showRoster = false
    @State private var saving = false
    @State private var showDiscardConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("TEAM IDENTITY").agentSamKicker()
                        TextField("Team name", text: $name)
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                            .padding(12)
                            .background(AgentSamTheme.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        TextField("What is this team for?", text: $goal, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(2...4)
                            .padding(12)
                            .background(AgentSamTheme.raised)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    HStack {
                        Text("ROSTER").agentSamKicker()
                        Spacer()
                        Text(validationMessage).font(.caption2).foregroundStyle(isValid ? AgentSamTheme.dim : AgentSamTheme.goldLight)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 12)], spacing: 12) {
                        ForEach(roster) { agent in
                            PersonaCard(agent: agent, providerName: providerName(agent)) { editingAgent = agent }
                        }
                        Button { showRoster = true } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "person.badge.plus").font(.title2).foregroundStyle(AgentSamTheme.emerald)
                                Text("Hire agent").font(.callout.weight(.semibold)).foregroundStyle(AgentSamTheme.secondaryInk)
                            }
                            .frame(maxWidth: .infinity, minHeight: 170)
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(AgentSamTheme.emerald.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
            .background(AgentSamBackground())
            .navigationTitle(team == nil ? "New Team" : "Edit Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { attemptClose() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        saving = true
                        Task {
                            let saved = Team(id: team?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), emoji: emoji, goal: goal, agents: roster, createdAt: team?.createdAt ?? Date(), updatedAt: Date())
                            if await session.saveTeam(saved) != nil { dismiss() }
                            saving = false
                        }
                    } label: {
                        if saving { ProgressView() } else { Text(team == nil ? "Create" : "Save") }
                    }
                    .disabled(!isValid || saving)
                }
            }
            .sheet(item: $editingAgent) { agent in
                IOAgentEditView(agent: agent, isExisting: roster.contains(where: { $0.id == agent.id })) { updated in
                    if let index = roster.firstIndex(where: { $0.id == updated.id }) { roster[index] = updated } else { roster.append(updated) }
                } onFire: { fired in
                    roster.removeAll { $0.id == fired.id }
                }
            }
            .sheet(isPresented: $showRoster) {
                IORosterPicker { agent in
                    var agent = agent
                    agent.id = UUID()
                    let provider = session.providers.first(where: { $0.provider.id == agent.providerID })?.provider ?? session.providers.first?.provider
                    agent.providerID = provider?.id ?? ""
                    agent.model = provider?.defaultModel ?? provider?.models.first ?? ""
                    showRoster = false
                    editingAgent = agent
                }
            }
            .confirmationDialog("Discard unsaved team changes?", isPresented: $showDiscardConfirmation) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .interactiveDismissDisabled(hasChanges)
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        roster.contains(where: { $0.role == .coordinator }) &&
        roster.contains(where: { $0.role == .worker }) &&
        Set(roster.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }).count == roster.count &&
        roster.allSatisfy { !$0.providerID.isEmpty && !$0.model.isEmpty }
    }

    private var validationMessage: String {
        if isValid { return "\(roster.count) ready" }
        if roster.isEmpty { return "Add a coordinator and worker" }
        if !roster.contains(where: { $0.role == .coordinator }) { return "Needs a coordinator" }
        if !roster.contains(where: { $0.role == .worker }) { return "Needs a worker" }
        if Set(roster.map { $0.name.lowercased() }).count != roster.count { return "Names must be unique" }
        return "Choose every model"
    }

    private var hasChanges: Bool {
        guard let team else { return !name.isEmpty || !goal.isEmpty || !roster.isEmpty }
        return name != team.name || goal != team.goal || roster != team.agents
    }

    private func attemptClose() {
        if hasChanges { showDiscardConfirmation = true } else { dismiss() }
    }

    private func providerName(_ agent: AgentProfile) -> String {
        session.providers.first(where: { $0.provider.id == agent.providerID })?.provider.name ?? "Choose provider"
    }
}

struct IOAgentEditView: View {
    @Environment(ServerSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let agent: AgentProfile
    let isExisting: Bool
    let onSave: (AgentProfile) -> Void
    let onFire: (AgentProfile) -> Void

    @State private var name = ""
    @State private var emoji = "🤖"
    @State private var title = ""
    @State private var role: AgentProfile.Role = .worker
    @State private var prompt = ""
    @State private var providerID = ""
    @State private var model = ""
    @State private var temperature = 0.3

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Title", text: $title)
                    TextField("Emoji", text: $emoji)
                    Picker("Role", selection: $role) {
                        ForEach(AgentProfile.Role.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section("Engine") {
                    Picker("Provider", selection: $providerID) {
                        ForEach(session.providers, id: \.provider.id) { status in
                            Text(status.provider.name).tag(status.provider.id)
                        }
                    }
                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if let provider = selectedProvider, !provider.models.isEmpty {
                        Menu("Choose a known model") {
                            ForEach(provider.models, id: \.self) { known in Button(known) { model = known } }
                        }
                    }
                    Stepper("Temperature \(String(format: "%.1f", temperature))", value: $temperature, in: 0...1, step: 0.1)
                }
                Section("System prompt") {
                    TextEditor(text: $prompt).frame(minHeight: 180)
                    Text("Tool use, deliverables, and finish rules are appended automatically.")
                        .font(.caption).foregroundStyle(AgentSamTheme.muted)
                }
                if isExisting {
                    Section {
                        Button("Fire agent", role: .destructive) {
                            onFire(agent)
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AgentSamBackground())
            .navigationTitle(isExisting ? "Edit \(agent.name)" : "Hire Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || providerID.isEmpty || model.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                name = agent.name
                emoji = agent.emoji
                title = agent.title
                role = agent.role
                prompt = agent.systemPrompt
                providerID = session.providers.contains(where: { $0.provider.id == agent.providerID }) ? agent.providerID : session.providers.first?.provider.id ?? ""
                model = agent.model
                if model.isEmpty { model = selectedProvider?.defaultModel ?? selectedProvider?.models.first ?? "" }
                temperature = agent.temperature ?? 0.3
            }
            .onChange(of: providerID) { _, _ in
                if let provider = selectedProvider, !provider.models.contains(model) {
                    model = provider.defaultModel ?? provider.models.first ?? ""
                }
            }
        }
    }

    private var selectedProvider: ProviderConfig? {
        session.providers.first(where: { $0.provider.id == providerID })?.provider
    }

    private func save() {
        onSave(AgentProfile(
            id: agent.id, name: name.trimmingCharacters(in: .whitespaces), emoji: emoji.isEmpty ? "🤖" : String(emoji.prefix(2)),
            title: title.isEmpty ? "Specialist" : title, role: role, systemPrompt: prompt,
            providerID: providerID, model: model.trimmingCharacters(in: .whitespaces), temperature: temperature
        ))
        dismiss()
    }
}

struct IORosterPicker: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (AgentProfile) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(AgentProfile.rosterTemplates, id: \.id) { agent in
                        Button { onPick(agent) } label: {
                            HStack(spacing: 11) {
                                AgentSamAvatar(name: agent.name, role: agent.role, size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(agent.name).font(.headline).foregroundStyle(AgentSamTheme.ink)
                                    Text(agent.title).font(.caption).foregroundStyle(AgentSamTheme.muted)
                                }
                                Spacer()
                                AgentSamRoleBadge(role: agent.role)
                            }
                            .agentSamPanel(padding: 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(AgentSamBackground())
            .navigationTitle("Hire from Roster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
