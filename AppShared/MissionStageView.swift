import SwiftUI
import AgentSamCore

struct MissionStageView: View {
    let presentation: AgentSamMissionPresentation
    var onSelectAgent: ((AgentProfile) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width < 520 {
                compactStage
            } else {
                wideStage(size: geometry.size)
            }
        }
        .frame(minHeight: 310, idealHeight: 410)
        .background(
            ZStack {
                AgentSamTheme.deep
                RadialGradient(colors: [AgentSamTheme.emerald.opacity(0.055), .clear], center: .topLeading, startRadius: 10, endRadius: 420)
                RadialGradient(colors: [AgentSamTheme.gold.opacity(0.04), .clear], center: .bottomTrailing, startRadius: 10, endRadius: 360)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AgentSamTheme.line))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: presentation.agents)
    }

    private var compactStage: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 14)], spacing: 18) {
                ForEach(presentation.agents) { item in
                    AgentStageNode(item: item, compact: true) {
                        onSelectAgent?(item.agent)
                    }
                }
            }
            .padding(20)
        }
    }

    private func wideStage(size: CGSize) -> some View {
        let positions = nodePositions(size: size)
        return ZStack {
            Canvas { context, _ in
                guard let coordinator = presentation.agents.first(where: { $0.agent.role == .coordinator }),
                      let start = positions[coordinator.id] else { return }
                let workers = presentation.agents.filter { $0.agent.role == .worker }
                for worker in workers {
                    guard let end = positions[worker.id] else { continue }
                    drawLine(from: start, to: end, active: coordinator.state == .working || worker.state == .working, in: &context)
                    if let verifier = presentation.agents.first(where: { $0.agent.role == .verifier }),
                       let verifierPoint = positions[verifier.id] {
                        drawLine(from: end, to: verifierPoint, active: worker.state == .working || verifier.state == .working, in: &context)
                    }
                }
            }
            ForEach(presentation.agents) { item in
                AgentStageNode(item: item, compact: false) {
                    onSelectAgent?(item.agent)
                }
                .position(positions[item.id] ?? CGPoint(x: size.width / 2, y: size.height / 2))
            }
            if presentation.agents.isEmpty {
                ContentUnavailableView("No roster available", systemImage: "person.3", description: Text("The original team is no longer available. Mission activity remains accessible below."))
            }
        }
    }

    private func drawLine(from: CGPoint, to: CGPoint, active: Bool, in context: inout GraphicsContext) {
        var path = Path()
        path.move(to: from)
        path.addLine(to: to)
        context.stroke(
            path,
            with: .color(active ? AgentSamTheme.emerald.opacity(0.72) : AgentSamTheme.strongLine),
            style: StrokeStyle(lineWidth: active ? 2 : 1, lineCap: .round, dash: active ? [] : [4, 7])
        )
    }

    private func nodePositions(size: CGSize) -> [UUID: CGPoint] {
        var result: [UUID: CGPoint] = [:]
        let coordinator = presentation.agents.first(where: { $0.agent.role == .coordinator })
        let verifier = presentation.agents.first(where: { $0.agent.role == .verifier })
        let workers = presentation.agents.filter { $0.agent.role == .worker }
        if let coordinator { result[coordinator.id] = CGPoint(x: size.width * 0.5, y: max(65, size.height * 0.16)) }
        for (index, worker) in workers.enumerated() {
            let fraction = workers.count == 1 ? 0.5 : 0.16 + 0.68 * Double(index) / Double(max(1, workers.count - 1))
            result[worker.id] = CGPoint(x: size.width * fraction, y: size.height * 0.52)
        }
        if let verifier { result[verifier.id] = CGPoint(x: size.width * 0.5, y: min(size.height - 58, size.height * 0.85)) }
        return result
    }
}

private struct AgentStageNode: View {
    let item: AgentSamAgentPresentation
    let compact: Bool
    let action: () -> Void

    private var stateLabel: String {
        switch item.state {
        case .idle: "idle"
        case .working: "working"
        case .done: "done"
        case .failed: "attention"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                AgentSamAvatar(
                    name: item.agent.name,
                    role: item.agent.role,
                    size: compact ? 52 : 66,
                    active: item.state == .working,
                    complete: item.state == .done
                )
                Text(item.agent.name)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AgentSamTheme.ink)
                    .lineLimit(1)
                Text(stateLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(item.state == .failed ? AgentSamTheme.danger : item.state == .done ? AgentSamTheme.goldLight : item.state == .working ? AgentSamTheme.emerald : AgentSamTheme.dim)
                if let task = item.task, item.state == .working {
                    Text(task)
                        .font(.caption2)
                        .foregroundStyle(AgentSamTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: compact ? 120 : 150)
                }
            }
            .frame(width: compact ? 112 : 138)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(item.task ?? item.agent.title)
    }
}

/// A running mission where Scout has finished and Quill is mid-task.
private func previewPresentation() -> AgentSamMissionPresentation {
    let team = Team.starterTeam()
    let mission = Mission(teamID: team.id, teamName: team.name, objective: "Summarize this quarter’s solid-state battery news", status: .running, phase: .working)
    let plan = """
    Task 1 Research — Scout: Gather recent sources → sources.md
    Task 2 Draft — Quill: Write the one-page brief → brief.md
    """
    let events = [
        RunEvent(seq: 1, missionID: mission.id, kind: .plan, text: plan),
        RunEvent(seq: 2, missionID: mission.id, kind: .taskStarted, agentName: "Scout", text: "Gather recent sources"),
        RunEvent(seq: 3, missionID: mission.id, kind: .taskDone, agentName: "Scout"),
        RunEvent(seq: 4, missionID: mission.id, kind: .taskStarted, agentName: "Quill", text: "Write the one-page brief")
    ]
    return AgentSamMissionPresentation(team: team, mission: mission, events: events)
}

#Preview("Stage – wide") {
    MissionStageView(presentation: previewPresentation())
        .padding()
        .frame(width: 700)
        .background(AgentSamBackground())
        .preferredColorScheme(.dark)
}

#Preview("Stage – compact") {
    MissionStageView(presentation: previewPresentation())
        .padding()
        .frame(width: 380)
        .background(AgentSamBackground())
        .preferredColorScheme(.dark)
}
