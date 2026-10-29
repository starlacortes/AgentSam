import SwiftUI
import AgentSamCore

struct TeamsView: View {
    @Environment(AppModel.self) private var model
    @Binding var showNewMission: Bool
    @Binding var selectedTeam: Team?

    @State private var showNewTeam = false
    @State private var editingTeam: Team?
    @State private var deletingTeam: Team?

    var body: some View {
        Group {
            if model.teams.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "person.3").font(.system(size: 44)).foregroundStyle(AgentSamTheme.emerald)
                    Text("Build your first team").font(AgentSamTheme.displayFont(24)).foregroundStyle(AgentSamTheme.ink)
                    Text("Start with a specialist roster and tune every agent to your workflow.")
                        .font(.callout).foregroundStyle(AgentSamTheme.muted)
                    Button("Create a team") { showNewTeam = true }.buttonStyle(AgentSamPrimaryButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 15)], spacing: 15) {
                        ForEach(model.teams) { team in
                            TeamCard(team: team) {
                                editingTeam = team
                            } onLaunch: {
                                selectedTeam = team
                            }
                            .contextMenu {
                                Button("Launch mission with this team…") { selectedTeam = team }
                                Button("Edit roster") { editingTeam = team }
                                Divider()
                                Button("Delete team", role: .destructive) { deletingTeam = team }
                            }
                        }
                    }
                    .padding(22)
                }
            }
        }
        .background(AgentSamBackground())
        .navigationTitle("Teams")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNewTeam = true } label: { Label("New team", systemImage: "plus.circle.fill") }
                    .buttonStyle(AgentSamGhostButtonStyle())
            }
        }
        .sheet(isPresented: $showNewTeam) {
            TeamEditSheet(team: nil).frame(minWidth: 680, minHeight: 560)
        }
        .sheet(item: $editingTeam) { team in
            TeamEditSheet(team: team).frame(minWidth: 680, minHeight: 560)
        }
        .confirmationDialog("Delete \(deletingTeam?.name ?? "this team")? Existing missions will be kept.", isPresented: Binding(get: { deletingTeam != nil }, set: { if !$0 { deletingTeam = nil } }), titleVisibility: .visible) {
            Button("Delete Team", role: .destructive) {
                if let deletingTeam { Task { await model.deleteTeam(deletingTeam) } }
                deletingTeam = nil
            }
            Button("Cancel", role: .cancel) { deletingTeam = nil }
        }
    }
}

struct TeamCard: View {
    let team: Team
    let onEdit: () -> Void
    let onLaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text(team.emoji).font(.system(size: 34))
                Spacer()
                AgentSamChip("\(team.agents.count) AGENTS", tint: AgentSamTheme.emeraldLight)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(team.name).font(AgentSamTheme.displayFont(20)).foregroundStyle(AgentSamTheme.ink)
                Text(team.goal.isEmpty ? "No standing goal" : team.goal)
                    .font(.callout).foregroundStyle(AgentSamTheme.muted).lineLimit(2)
            }
            AgentSamAvatarStack(agents: team.agents, size: 36)
            Divider().overlay(AgentSamTheme.line)
            HStack {
                Button("Edit roster", action: onEdit).buttonStyle(.plain).font(.caption.weight(.medium)).foregroundStyle(AgentSamTheme.emeraldLight)
                Spacer()
                Button("Launch", action: onLaunch).buttonStyle(AgentSamPrimaryButtonStyle()).disabled(team.agents.isEmpty)
            }
        }
        .agentSamPanel(padding: 16)
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
    }
}

struct TeamEditSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let team: Team?

    @State private var name = ""
    @State private var emoji = "🛡️"
    @State private var goal = ""
    @State private var roster: [AgentProfile] = []
    @State private var editingAgent: AgentProfile?
    @State private var showAgentPicker = false
    @State private var saving = false
    @State private var showDiscardConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Team name", text: $name)
                    .textFieldStyle(.plain)
                    .font(AgentSamTheme.displayFont(23))
                    .foregroundStyle(AgentSamTheme.ink)
                Spacer()
                Button("Cancel") { attemptClose() }.buttonStyle(AgentSamGhostButtonStyle())
                Button {
                    saving = true
                    Task { await saveAndClose() }
                } label: {
                    HStack {
                        if saving { ProgressView().controlSize(.small) }
                        Text(team == nil ? "Create team" : "Save changes")
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(AgentSamPrimaryButtonStyle())
                .disabled(!isValid || saving)
            }
            .padding(18)
            Divider().overlay(AgentSamTheme.line)
            rosterGrid
            Divider().overlay(AgentSamTheme.line)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("STANDING GOAL").agentSamKicker()
                    Spacer()
                    Text(validationMessage).font(.caption2).foregroundStyle(isValid ? AgentSamTheme.dim : AgentSamTheme.goldLight)
                }
                TextField("What this team is for, e.g. ‘Research and write reports’", text: $goal)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(AgentSamTheme.deep)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AgentSamTheme.line))
            }
            .padding(16)
        }
        .background(AgentSamBackground())
        .onAppear {
            if let team {
                name = team.name
                emoji = team.emoji
                goal = team.goal
                roster = team.agents
            }
        }
        .sheet(item: $editingAgent) { agent in
            AgentEditSheet(
                agent: agent,
                isExisting: roster.contains { $0.id == agent.id },
                onHire: { updated in
                    if let index = roster.firstIndex(where: { $0.id == updated.id }) { roster[index] = updated } else { roster.append(updated) }
                },
                onFire: { fired in roster.removeAll { $0.id == fired.id } }
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
        .confirmationDialog("Discard unsaved team changes?", isPresented: $showDiscardConfirmation) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .interactiveDismissDisabled(hasChanges)
    }

    private var rosterGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 13)], spacing: 13) {
                ForEach(roster) { agent in
                    AgentCard(agent: agent, providerName: providerName(agent))
                        .onTapGesture { editingAgent = agent }
                }
                hireCard
            }
            .padding(18)
        }
    }

    private var hireCard: some View {
        Button { showAgentPicker = true } label: {
            VStack(spacing: 8) {
                Image(systemName: "person.badge.plus").font(.title2).foregroundStyle(AgentSamTheme.emerald)
                Text("Hire agent").font(.callout.weight(.semibold)).foregroundStyle(AgentSamTheme.secondaryInk)
                Text("Choose a specialist").font(.caption2).foregroundStyle(AgentSamTheme.dim)
            }
            .frame(maxWidth: .infinity, minHeight: 145)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AgentSamTheme.emerald.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
        }
        .buttonStyle(.plain)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        roster.contains(where: { $0.role == .coordinator }) &&
        roster.contains(where: { $0.role == .worker }) &&
        Set(roster.map { $0.name.trimmingCharacters(in: .whitespaces).lowercased() }).count == roster.count &&
        roster.allSatisfy { !$0.providerID.isEmpty && !$0.model.isEmpty }
    }

    private var validationMessage: String {
        if isValid { return "\(roster.count) agents ready" }
        if roster.isEmpty { return "Hire a coordinator and at least one worker." }
        if !roster.contains(where: { $0.role == .coordinator }) { return "Assign one agent to Coordination." }
        if !roster.contains(where: { $0.role == .worker }) { return "Add at least one Worker." }
        if Set(roster.map { $0.name.lowercased() }).count != roster.count { return "Agent names must be unique." }
        return "Choose a provider and model for every agent."
    }

    private var hasChanges: Bool {
        guard let team else { return !name.isEmpty || !goal.isEmpty || !roster.isEmpty }
        return name != team.name || goal != team.goal || roster != team.agents || emoji != team.emoji
    }

    private func attemptClose() {
        if hasChanges { showDiscardConfirmation = true } else { dismiss() }
    }

    private func providerName(_ agent: AgentProfile) -> String {
        model.providers.first(where: { $0.id == agent.providerID })?.name ?? "Choose provider"
    }

    private func saveAndClose() async {
        let saved = Team(
            id: team?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespaces), emoji: emoji,
            goal: goal.trimmingCharacters(in: .whitespacesAndNewlines), agents: roster,
            createdAt: team?.createdAt ?? Date(), updatedAt: Date()
        )
        await model.saveTeam(saved)
        saving = false
        dismiss()
    }
}

struct AgentCard: View {
    let agent: AgentProfile
    let providerName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AgentSamAvatar(name: agent.name, role: agent.role, size: 44)
                Spacer()
                AgentSamRoleBadge(role: agent.role)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(agent.name).font(.headline).foregroundStyle(AgentSamTheme.ink)
                Text(agent.title).font(.caption).foregroundStyle(AgentSamTheme.muted).lineLimit(1)
            }
            Divider().overlay(AgentSamTheme.line)
            Label(agent.model, systemImage: "cpu").font(.caption2.monospaced()).foregroundStyle(AgentSamTheme.secondaryInk).lineLimit(1)
            Label(providerName, systemImage: "externaldrive.connected.to.line.below").font(.caption2).foregroundStyle(AgentSamTheme.dim).lineLimit(1)
        }
        .agentSamPanel(padding: 12, tint: AgentSamTheme.color(for: agent.role))
        .contentShape(Rectangle())
        .accessibilityHint("Edit agent")
    }
}

struct TemplateRosterPicker: View {
    let onPick: (AgentProfile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hire from the roster").font(AgentSamTheme.displayFont(23)).foregroundStyle(AgentSamTheme.ink).padding(.top)
            Text("Pick a specialist, then tune the model and prompt.").font(.callout).foregroundStyle(AgentSamTheme.muted)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(AgentProfile.rosterTemplates, id: \.id) { agent in
                        Button { onPick(agent) } label: {
                            HStack(spacing: 11) {
                                AgentSamAvatar(name: agent.name, role: agent.role, size: 40)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(agent.name) — \(agent.title)").font(.callout.weight(.semibold)).foregroundStyle(AgentSamTheme.ink)
                                    Text(agent.systemPrompt).font(.caption2).foregroundStyle(AgentSamTheme.muted).lineLimit(2)
                                }
                                Spacer()
                                AgentSamRoleBadge(role: agent.role)
                            }
                            .agentSamPanel(padding: 10)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .background(AgentSamBackground())
    }
}
