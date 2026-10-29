import SwiftUI
import AgentSamCore

func iosStatusColor(_ status: MissionStatus) -> Color { AgentSamTheme.color(for: status) }
func iosRoleColor(_ role: AgentProfile.Role) -> Color { AgentSamTheme.color(for: role) }

private enum IOMissionTab: String, CaseIterable, Identifiable {
    case plan = "Plan"
    case chatter = "Chatter"
    case files = "Files"
    case activity = "Activity"
    var id: String { rawValue }
}

struct MissionLiveView: View {
    @Environment(ServerSession.self) private var session
    let live: LiveMission
    @State private var showDeliverable: FileItem?
    @State private var selectedAgent: AgentProfile?
    @State private var tab: IOMissionTab = .plan

    private var team: Team? { session.teams.first(where: { $0.id == live.mission?.teamID }) }
    private var presentation: AgentSamMissionPresentation {
        AgentSamMissionPresentation(team: team, mission: live.mission, events: live.events)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            MissionStageView(presentation: presentation) { selectedAgent = $0 }
                .frame(height: 300)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            if live.mission?.status == .completed, live.deliverables.contains("final-report.md") {
                Button {
                    showDeliverable = FileItem(name: "final-report.md")
                } label: {
                    Label("Mission complete · Read final report", systemImage: "checkmark.seal.fill")
                        .font(.callout.weight(.semibold))
                }
                .buttonStyle(AgentSamPrimaryButtonStyle())
                .padding(.bottom, 10)
            }
            Picker("Mission detail", selection: $tab) {
                ForEach(IOMissionTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            content
        }
        .background(AgentSamBackground())
        .navigationTitle("Live Mission")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if live.mission?.status == .running {
                ToolbarItem(placement: .primaryAction) {
                    Button("Stop", role: .destructive) { Task { await session.stopMission(id: live.missionID) } }
                }
            }
        }
        .task { live.start() }
        .onDisappear { live.stop() }
        .sheet(item: $showDeliverable) { item in DeliverableSheet(live: live, name: item.name) }
        .sheet(item: $selectedAgent) { agent in IOAgentMissionDetail(agent: agent, task: presentation.agents.first(where: { $0.agent.id == agent.id })?.task) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(live.mission?.objective ?? "Loading mission…")
                .font(.headline)
                .foregroundStyle(AgentSamTheme.ink)
                .lineLimit(3)
            HStack(spacing: 8) {
                if let mission = live.mission {
                    AgentSamStatusChip(status: mission.status)
                    Text(mission.phase.label).font(.caption).foregroundStyle(AgentSamTheme.muted)
                    Spacer()
                    AgentSamMoneyText(amount: mission.totalCostUSD).font(.caption).foregroundStyle(AgentSamTheme.secondaryInk)
                    Text("\(mission.totalInputTokens + mission.totalOutputTokens) tok").font(.caption2.monospacedDigit()).foregroundStyle(AgentSamTheme.dim)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .plan:
            ScrollView { AgentSamTaskList(tasks: presentation.tasks, team: team).padding(12) }
        case .chatter:
            AgentSamChatterList(items: presentation.chatter)
        case .files:
            if live.deliverables.isEmpty {
                ContentUnavailableView("No files yet", systemImage: "doc.text.magnifyingglass", description: Text("Agent deliverables will appear here."))
            } else {
                List(live.deliverables, id: \.self) { name in
                    Button { showDeliverable = FileItem(name: name) } label: {
                        Label(name, systemImage: name == "final-report.md" ? "flag.checkered" : "doc.text")
                            .font(.callout.monospaced())
                            .foregroundStyle(name == "final-report.md" ? AgentSamTheme.goldLight : AgentSamTheme.secondaryInk)
                    }
                    .listRowBackground(AgentSamTheme.panel)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        case .activity:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(live.events) { event in
                            AgentSamEventRow(event: event).id(event.seq)
                            Divider().overlay(AgentSamTheme.line)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: live.events.count) { _, _ in
                    if tab == .activity, let last = live.events.last { proxy.scrollTo(last.seq, anchor: .bottom) }
                }
            }
        }
    }
}

private struct IOAgentMissionDetail: View {
    let agent: AgentProfile
    let task: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    HStack {
                        AgentSamAvatar(name: agent.name, role: agent.role, size: 62)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(agent.name).font(AgentSamTheme.displayFont(24)).foregroundStyle(AgentSamTheme.ink)
                            Text(agent.title).foregroundStyle(AgentSamTheme.muted)
                            AgentSamRoleBadge(role: agent.role)
                        }
                    }
                    LabeledContent("Model") { Text(agent.model).monospaced() }
                    if let task {
                        Text("CURRENT ASSIGNMENT").agentSamKicker()
                        Text(task).font(.callout).foregroundStyle(AgentSamTheme.secondaryInk)
                    }
                    Text("PERSONA").agentSamKicker()
                    Text(agent.systemPrompt).font(.callout).foregroundStyle(AgentSamTheme.secondaryInk).textSelection(.enabled)
                }
                .padding(20)
            }
            .background(AgentSamBackground())
            .navigationTitle("Agent")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct DeliverableSheet: View {
    let live: LiveMission
    let name: String
    @Environment(\.dismiss) private var dismiss
    @State private var text: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let text {
                        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                            Text(attributed).font(.footnote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(text).font(.footnote.monospaced()).textSelection(.enabled)
                        }
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding()
            }
            .background(AgentSamBackground())
            .foregroundStyle(AgentSamTheme.secondaryInk)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task(id: name) { text = await live.content(for: name) }
        }
    }
}

struct FileItem: Identifiable {
    let name: String
    var id: String { name }
}
