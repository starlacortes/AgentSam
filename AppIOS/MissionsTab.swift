import SwiftUI
import AgentSamCore

private enum IOMissionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case completed = "Completed"
    case attention = "Attention"
    var id: String { rawValue }
}

struct MissionsTab: View {
    @Environment(ServerSession.self) private var session
    @State private var liveMission: LiveMission?
    @State private var showNewMission = false
    @State private var search = ""
    @State private var filter: IOMissionFilter = .all

    var body: some View {
        NavigationStack {
            Group {
                if session.missions.isEmpty { emptyState } else { missionList }
            }
            .background(AgentSamBackground())
            .navigationTitle("Missions")
            .searchable(text: $search, prompt: "Search missions")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(IOMissionFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    Button { showNewMission = true } label: { Image(systemName: "plus.circle.fill") }
                        .disabled(session.teams.filter { !$0.agents.isEmpty }.isEmpty)
                }
            }
            .refreshable { await session.refreshAll() }
            .sheet(isPresented: $showNewMission) { NewMissionSheet(liveBinding: $liveMission) }
            .navigationDestination(item: $liveMission) { live in MissionLiveView(live: live).onDisappear { live.stop() } }
            .task { await session.refreshAll() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "flag.checkered.2.crossed").font(.system(size: 44)).foregroundStyle(AgentSamTheme.emerald)
            Text("No missions yet").font(AgentSamTheme.displayFont(24)).foregroundStyle(AgentSamTheme.ink)
            Text("Launch one from a team, then watch your agents work in real time.").font(.callout).foregroundStyle(AgentSamTheme.muted).multilineTextAlignment(.center)
            Button("Launch first mission") { showNewMission = true }.buttonStyle(AgentSamPrimaryButtonStyle()).disabled(session.teams.filter { !$0.agents.isEmpty }.isEmpty)
            if let error = session.lastError {
                Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(AgentSamTheme.danger)
                Button("Retry") { Task { await session.refreshAll() } }.buttonStyle(AgentSamGhostButtonStyle())
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missionList: some View {
        List {
            if let error = session.lastError {
                Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(AgentSamTheme.danger).listRowBackground(Color.clear)
            }
            if filteredMissions.isEmpty {
                ContentUnavailableView("No matching missions", systemImage: "magnifyingglass").listRowBackground(Color.clear)
            }
            ForEach(filteredMissions) { mission in
                Button {
                    let live = LiveMission(missionID: mission.id)
                    liveMission = live
                } label: {
                    MissionListRow(mission: mission)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var filteredMissions: [Mission] {
        session.missions.filter { mission in
            let matchesSearch = search.isEmpty || mission.objective.localizedCaseInsensitiveContains(search) || mission.teamName.localizedCaseInsensitiveContains(search)
            switch filter {
            case .all: return matchesSearch
            case .running: return matchesSearch && (mission.status == .running || mission.status == .queued)
            case .completed: return matchesSearch && mission.status == .completed
            case .attention: return matchesSearch && (mission.status == .failed || mission.status == .stopped)
            }
        }.sorted { $0.createdAt > $1.createdAt }
    }
}

struct MissionListRow: View {
    let mission: Mission

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(AgentSamTheme.color(for: mission.status).opacity(0.14))
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: iconName).foregroundStyle(AgentSamTheme.color(for: mission.status)))
            VStack(alignment: .leading, spacing: 5) {
                Text(mission.objective).font(.subheadline.weight(.semibold)).lineLimit(2).foregroundStyle(AgentSamTheme.ink)
                HStack(spacing: 6) {
                    Text(mission.teamName)
                    Text("·")
                    Text(mission.createdAt, format: .relative(presentation: .named))
                }
                .font(.caption).foregroundStyle(AgentSamTheme.muted)
                AgentSamStatusChip(status: mission.status)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                AgentSamMoneyText(amount: mission.totalCostUSD).font(.caption).foregroundStyle(AgentSamTheme.secondaryInk)
                Text("\(mission.totalInputTokens + mission.totalOutputTokens) tok").font(.caption2).foregroundStyle(AgentSamTheme.dim)
            }
        }
        .padding(12)
        .background(mission.status == .running ? AgentSamTheme.emerald.opacity(0.06) : AgentSamTheme.panel)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(mission.status == .running ? AgentSamTheme.emerald.opacity(0.25) : AgentSamTheme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var iconName: String {
        switch mission.status {
        case .completed: "checkmark"
        case .failed: "xmark"
        case .stopped: "stop.fill"
        case .running: "dot.radiowaves.left.and.right"
        case .queued: "clock"
        }
    }
}

struct NewMissionSheet: View {
    @Environment(ServerSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Binding var liveBinding: LiveMission?
    var presetTeam: Team?
    @State private var teamID: UUID?
    @State private var objective = ""
    @State private var launching = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Team", selection: $teamID) {
                        ForEach(session.teams.filter { !$0.agents.isEmpty }) { team in Text("\(team.emoji) \(team.name)").tag(Optional(team.id)) }
                    }
                    .pickerStyle(.menu)
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AgentSamTheme.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    if let team = selectedTeam {
                        HStack {
                            AgentSamAvatarStack(agents: team.agents, size: 38)
                            VStack(alignment: .leading) {
                                Text(team.name).font(.headline).foregroundStyle(AgentSamTheme.ink)
                                Text("\(team.agents.count) agents · \(team.coordinator?.name ?? "No coordinator")").font(.caption).foregroundStyle(AgentSamTheme.muted)
                            }
                        }
                        .agentSamPanel()
                    }
                    Text("OBJECTIVE").agentSamKicker()
                    MissionObjectiveEditor(objective: $objective)
                    if let error = session.lastError { Text(error).font(.caption).foregroundStyle(AgentSamTheme.danger) }
                }
                .padding(18)
            }
            .background(AgentSamBackground())
            .navigationTitle("New Mission")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        launching = true
                        Task {
                            if let team = selectedTeam, let mission = await session.startMission(team: team, objective: objective) {
                                let live = LiveMission(missionID: mission.id)
                                live.start()
                                liveBinding = live
                                dismiss()
                            }
                            launching = false
                        }
                    } label: {
                        if launching { ProgressView() } else { Text("Launch") }
                    }
                    .disabled(selectedTeam == nil || objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || launching)
                }
            }
            .onAppear { if teamID == nil { teamID = presetTeam?.id ?? session.teams.first(where: { !$0.agents.isEmpty })?.id } }
        }
    }

    private var selectedTeam: Team? { session.teams.first(where: { $0.id == teamID }) }
}
