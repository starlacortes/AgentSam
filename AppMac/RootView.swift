import SwiftUI
import AgentSamCore

enum NavSection: Hashable {
    case missions
    case teams
    case templates
    case settings
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var section: NavSection = .missions
    @State private var showNewMission = false
    @State private var selectedTeam: Team?
    @State private var showGuidedSetup = false
    @AppStorage("agentsam.onboarding.completed") private var onboardingCompleted = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section {
                    AgentSamBrand()
                        .padding(.vertical, 8)
                        .listRowBackground(Color.clear)
                }
                Section("Workspace") {
                    Label("Missions", systemImage: "flag.checkered.2.crossed").tag(NavSection.missions)
                    Label("Teams", systemImage: "person.3").tag(NavSection.teams)
                    Label("Team Templates", systemImage: "square.grid.2x2").tag(NavSection.templates)
                }
                Section("Configuration") {
                    Label("Settings", systemImage: "gearshape").tag(NavSection.settings)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(AgentSamTheme.deep)
            .navigationSplitViewColumnWidth(220)
            .safeAreaInset(edge: .bottom) {
                Label("Local workspace", systemImage: "externaldrive")
                    .font(.caption2)
                    .foregroundStyle(AgentSamTheme.dim)
                    .help(model.dataDirPath)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } detail: {
            Group {
                switch section {
                case .missions: MissionsView(showNewMission: $showNewMission)
                case .teams: TeamsView(showNewMission: $showNewMission, selectedTeam: $selectedTeam)
                case .templates: TemplatesView()
                case .settings: SettingsView(onRunSetup: { showGuidedSetup = true })
                }
            }
            .background(AgentSamTheme.background)
        }
        .navigationTitle("AgentSam")
        .tint(AgentSamTheme.emerald)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showNewMission = true
                } label: {
                    Label("New Mission", systemImage: "plus.circle.fill")
                }
                .buttonStyle(AgentSamPrimaryButtonStyle())
                .disabled(model.teams.filter { !$0.agents.isEmpty }.isEmpty)
                .keyboardShortcut("n")
                .help(model.teams.filter { !$0.agents.isEmpty }.isEmpty ? "Create a team before launching a mission" : "Create a new mission (⌘N)")
            }
        }
        .sheet(isPresented: $showNewMission) {
            NewMissionSheet(presetTeam: nil).frame(minWidth: 600, minHeight: 520)
        }
        .sheet(item: $selectedTeam) { team in
            NewMissionSheet(presetTeam: team).frame(minWidth: 600, minHeight: 520)
        }
        .sheet(isPresented: $showGuidedSetup) {
            GuidedSetupView()
        }
        .task(id: section) { await model.reload() }
        .onChange(of: model.isBootstrapped) { _, ready in
            if ready && !onboardingCompleted { showGuidedSetup = true }
        }
        .onAppear {
            if model.isBootstrapped && !onboardingCompleted { showGuidedSetup = true }
        }
    }
}

struct NewMissionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let presetTeam: Team?

    @State private var teamID: UUID?
    @State private var objective = ""
    @State private var launching = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("NEW MISSION").agentSamKicker()
                    Text("Put your team to work").font(AgentSamTheme.displayFont(24)).foregroundStyle(AgentSamTheme.ink)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(AgentSamGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close")
            }
            .padding(20)
            Divider().overlay(AgentSamTheme.line)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TEAM").agentSamKicker()
                        Picker("Team", selection: $teamID) {
                            ForEach(model.teams.filter { !$0.agents.isEmpty }) { team in
                                Text("\(team.emoji) \(team.name)").tag(Optional(team.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(AgentSamTheme.raised)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    if let team = selectedTeam {
                        HStack(spacing: 14) {
                            AgentSamAvatarStack(agents: team.agents, size: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(team.name).font(.headline).foregroundStyle(AgentSamTheme.ink)
                                Text("\(team.agents.count) agents · Coordinated by \(team.coordinator?.name ?? "unassigned")")
                                    .font(.caption).foregroundStyle(AgentSamTheme.muted)
                            }
                            Spacer()
                        }
                        .agentSamPanel()
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text("OBJECTIVE").agentSamKicker()
                        MissionObjectiveEditor(objective: $objective)
                    }
                }
                .padding(22)
            }
            Divider().overlay(AgentSamTheme.line)
            HStack {
                Text("Watch every handoff live. Stop anytime.")
                    .font(.caption).foregroundStyle(AgentSamTheme.dim)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(AgentSamGhostButtonStyle())
                Button {
                    launching = true
                    Task {
                        if let team = selectedTeam { await model.launchMission(team: team, objective: objective) }
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
                .keyboardShortcut(.return)
                .disabled(selectedTeam == nil || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || launching)
            }
            .padding(18)
        }
        .background(AgentSamBackground())
        .onAppear {
            if teamID == nil { teamID = presetTeam?.id ?? model.teams.first(where: { !$0.agents.isEmpty })?.id }
        }
    }

    private var selectedTeam: Team? { model.teams.first(where: { $0.id == teamID }) }
}
