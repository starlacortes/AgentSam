import SwiftUI
import AgentSamCore

private enum MissionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case running = "Running"
    case completed = "Completed"
    case attention = "Attention"
    var id: String { rawValue }
}

struct MissionsView: View {
    @Environment(AppModel.self) private var model
    @Binding var showNewMission: Bool
    @State private var search = ""
    @State private var filter: MissionFilter = .all

    var body: some View {
        Group {
            if model.missions.isEmpty {
                emptyState
            } else {
                missionList
            }
        }
        .background(AgentSamBackground())
        .navigationTitle("Missions")
        .searchable(text: $search, prompt: "Search objectives or teams")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Filter", selection: $filter) {
                    ForEach(MissionFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
        .overlay(alignment: .bottomTrailing) { launchButton }
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            Image(systemName: "flag.checkered.2.crossed")
                .font(.system(size: 44))
                .foregroundStyle(AgentSamTheme.emerald)
            Text("No missions yet").font(AgentSamTheme.displayFont(24)).foregroundStyle(AgentSamTheme.ink)
            Text("Hire a team, give it an objective, and watch every handoff live.")
                .font(.callout).foregroundStyle(AgentSamTheme.muted)
            Button("Launch first mission") { showNewMission = true }
                .buttonStyle(AgentSamPrimaryButtonStyle())
                .disabled(model.teams.filter { !$0.agents.isEmpty }.isEmpty)
            if model.teams.filter({ !$0.agents.isEmpty }).isEmpty {
                Text("Create a team from Templates first.").font(.caption).foregroundStyle(AgentSamTheme.dim)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var launchButton: some View {
        Button { showNewMission = true } label: { Label("New Mission", systemImage: "plus") }
            .buttonStyle(AgentSamPrimaryButtonStyle())
            .padding()
            .disabled(model.teams.filter { !$0.agents.isEmpty }.isEmpty)
    }

    private var missionList: some View {
        List {
            if filteredMissions.isEmpty {
                ContentUnavailableView("No matching missions", systemImage: "magnifyingglass", description: Text("Try another search or status filter."))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredMissions) { mission in
                    Button { model.open(mission.id) } label: { MissionRow(mission: mission) }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 5, leading: 14, bottom: 5, trailing: 14))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .sheet(item: liveStateBinding) { live in
            MissionDetailView(state: live).frame(minWidth: 1_020, minHeight: 680)
        }
        .refreshable { await model.reload() }
    }

    private var filteredMissions: [Mission] {
        model.missions.filter { mission in
            let matchesSearch = search.isEmpty || mission.objective.localizedCaseInsensitiveContains(search) || mission.teamName.localizedCaseInsensitiveContains(search)
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .running: matchesFilter = mission.status == .running || mission.status == .queued
            case .completed: matchesFilter = mission.status == .completed
            case .attention: matchesFilter = mission.status == .failed || mission.status == .stopped
            }
            return matchesSearch && matchesFilter
        }.sorted { $0.createdAt > $1.createdAt }
    }

    private var liveStateBinding: Binding<MissionLiveState?> {
        Binding(
            get: { model.liveState },
            set: { newValue in
                if newValue == nil { model.liveState?.stopObserving() }
                model.liveState = newValue
            }
        )
    }
}

extension MissionLiveState: Identifiable {
    var id: UUID { missionID }
}

struct MissionRow: View {
    let mission: Mission

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(AgentSamTheme.color(for: mission.status).opacity(0.12))
                .frame(width: 42, height: 42)
                .overlay(Image(systemName: iconName).foregroundStyle(AgentSamTheme.color(for: mission.status)))
            VStack(alignment: .leading, spacing: 6) {
                Text(mission.objective)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AgentSamTheme.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    AgentSamStatusChip(status: mission.status)
                    Text(mission.teamName).font(.caption).foregroundStyle(AgentSamTheme.muted)
                    Text(mission.createdAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(AgentSamTheme.dim)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                AgentSamMoneyText(amount: mission.totalCostUSD).font(.callout).foregroundStyle(AgentSamTheme.secondaryInk)
                Text("\(mission.totalInputTokens + mission.totalOutputTokens) tokens").font(.caption2).foregroundStyle(AgentSamTheme.dim)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(AgentSamTheme.dim)
        }
        .padding(13)
        .background(mission.status == .running ? AgentSamTheme.emerald.opacity(0.055) : AgentSamTheme.panel.opacity(0.8))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(mission.status == .running ? AgentSamTheme.emerald.opacity(0.24) : AgentSamTheme.line))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .accessibilityHint("Open live mission")
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
