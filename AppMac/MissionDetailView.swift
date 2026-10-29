import SwiftUI
import AgentSamCore

private enum MissionRailTab: String, CaseIterable, Identifiable {
    case plan = "Plan"
    case chatter = "Chatter"
    case files = "Files"
    case activity = "Activity"
    var id: String { rawValue }
}

struct MissionDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: MissionLiveState

    @State private var railTab: MissionRailTab = .plan
    @State private var selectedAgent: AgentProfile?
    @State private var confirmDelete = false

    private var team: Team? { model.teams.first(where: { $0.id == state.mission?.teamID }) }
    private var presentation: AgentSamMissionPresentation {
        AgentSamMissionPresentation(team: team, mission: state.mission, events: state.events)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(AgentSamTheme.line)
            HSplitView {
                MissionStageView(presentation: presentation) { selectedAgent = $0 }
                    .padding(16)
                    .frame(minWidth: 520, idealWidth: 650)
                    .overlay(alignment: .bottom) { completionBanner }
                rightRail
                    .frame(minWidth: 330, idealWidth: 370, maxWidth: 430)
            }
        }
        .background(AgentSamBackground())
        .sheet(item: $selectedAgent) { agent in
            AgentMissionDetail(agent: agent, task: presentation.agents.first(where: { $0.agent.id == agent.id })?.task)
                .frame(minWidth: 440, minHeight: 320)
        }
        .confirmationDialog("Delete this mission and its local workspace?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Mission", role: .destructive) {
                Task {
                    if let mission = state.mission { await model.deleteMission(mission.id) }
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 14) {
                Circle()
                    .fill(AgentSamTheme.color(for: state.mission?.status ?? .queued))
                    .frame(width: 9, height: 9)
                    .shadow(color: AgentSamTheme.emerald.opacity(state.mission?.status == .running ? 0.7 : 0), radius: 7)
                VStack(alignment: .leading, spacing: 5) {
                    Text(state.mission?.objective ?? "Mission")
                        .font(AgentSamTheme.displayFont(19))
                        .foregroundStyle(AgentSamTheme.ink)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        if let mission = state.mission {
                            AgentSamStatusChip(status: mission.status)
                            Text(mission.teamName).font(.caption).foregroundStyle(AgentSamTheme.muted)
                        }
                    }
                }
                Spacer()
                if let mission = state.mission {
                    Metric(value: "\(mission.totalInputTokens + mission.totalOutputTokens)", label: "TOKENS")
                    Metric(value: mission.totalCostUSD < 0.01 && mission.totalCostUSD > 0 ? String(format: "$%.4f", mission.totalCostUSD) : String(format: "$%.2f", mission.totalCostUSD), label: "COST")
                }
                if let mission = state.mission, mission.status == .running {
                    Button(role: .destructive) { Task { await model.stopMission(mission.id) } } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(AgentSamGhostButtonStyle())
                }
                if state.mission?.status != .running && state.mission != nil {
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                        .buttonStyle(AgentSamGhostButtonStyle())
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(AgentSamGhostButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close mission")
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            if let mission = state.mission {
                ScrollView(.horizontal, showsIndicators: false) {
                    AgentSamPhasePipeline(phase: mission.phase, status: mission.status)
                        .padding(.horizontal, 18)
                }
                .padding(.bottom, 11)
            }
        }
        .background(AgentSamTheme.panel)
    }

    private var rightRail: some View {
        VStack(spacing: 0) {
            Picker("Mission detail", selection: $railTab) {
                ForEach(MissionRailTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider().overlay(AgentSamTheme.line)
            Group {
                switch railTab {
                case .plan:
                    ScrollView {
                        AgentSamTaskList(tasks: presentation.tasks, team: team).padding(12)
                    }
                case .chatter:
                    AgentSamChatterList(items: presentation.chatter)
                case .files:
                    deliverablesPane
                case .activity:
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 3) {
                                ForEach(state.events) { event in
                                    AgentSamEventRow(event: event).id(event.seq)
                                    Divider().overlay(AgentSamTheme.line)
                                }
                            }
                            .padding(12)
                        }
                        .onChange(of: state.events.count) { _, _ in
                            if railTab == .activity, let last = state.events.last { proxy.scrollTo(last.seq, anchor: .bottom) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AgentSamTheme.deep)
    }

    private var deliverablesPane: some View {
        VStack(spacing: 0) {
            if state.deliverables.isEmpty {
                ContentUnavailableView("No files yet", systemImage: "doc.text.magnifyingglass", description: Text("Files your agents produce will appear here."))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(state.deliverables, id: \.self) { name in
                            Button {
                                state.selectedDeliverable = name
                            } label: {
                                Label(name, systemImage: name == "final-report.md" ? "flag.checkered" : "doc.text")
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                            }
                            .buttonStyle(AgentSamGhostButtonStyle())
                            .foregroundStyle(name == state.selectedDeliverable ? AgentSamTheme.emerald : AgentSamTheme.muted)
                        }
                    }
                    .padding(10)
                }
                Divider().overlay(AgentSamTheme.line)
                if let selected = state.selectedDeliverable {
                    DeliverablePreview(name: selected) { await state.content(for: selected, store: model.store) }
                } else {
                    ContentUnavailableView("Select a file", systemImage: "doc.text")
                }
            }
        }
    }

    @ViewBuilder private var completionBanner: some View {
        if let mission = state.mission, mission.status == .completed {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(AgentSamTheme.goldLight)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mission complete").font(.headline).foregroundStyle(AgentSamTheme.ink)
                    Text("\(state.deliverables.count) files delivered · \(mission.totalInputTokens + mission.totalOutputTokens) tokens")
                        .font(.caption).foregroundStyle(AgentSamTheme.muted)
                }
                Spacer()
                if state.deliverables.contains("final-report.md") {
                    Button("Read report") {
                        state.selectedDeliverable = "final-report.md"
                        railTab = .files
                    }
                    .buttonStyle(AgentSamPrimaryButtonStyle())
                }
            }
            .padding(14)
            .background(AgentSamTheme.panel)
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(AgentSamTheme.gold.opacity(0.45)))
            .clipShape(RoundedRectangle(cornerRadius: 13))
            .padding(28)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct Metric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value).font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(AgentSamTheme.ink)
            Text(label).font(.system(size: 8, design: .monospaced)).tracking(1).foregroundStyle(AgentSamTheme.dim)
        }
    }
}

private struct AgentMissionDetail: View {
    let agent: AgentProfile
    let task: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                AgentSamAvatar(name: agent.name, role: agent.role, size: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name).font(AgentSamTheme.displayFont(24)).foregroundStyle(AgentSamTheme.ink)
                    Text(agent.title).foregroundStyle(AgentSamTheme.muted)
                    AgentSamRoleBadge(role: agent.role)
                }
            }
            LabeledContent("Model") { Text(agent.model).monospaced() }
            if let task { LabeledContent("Current assignment") { Text(task).multilineTextAlignment(.trailing) } }
            Text("PERSONA").agentSamKicker()
            Text(agent.systemPrompt).font(.callout).foregroundStyle(AgentSamTheme.secondaryInk).textSelection(.enabled)
            Spacer()
        }
        .padding(24)
        .background(AgentSamBackground())
    }
}

struct DeliverablePreview: View {
    let name: String
    let load: () async -> String?
    @State private var text: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(name).font(.subheadline.monospaced().weight(.semibold)).foregroundStyle(AgentSamTheme.emeraldLight)
                if let text {
                    if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                        Text(attributed).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(text).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 100)
                }
            }
            .padding(14)
        }
        .task(id: name) { text = await load() }
    }
}
