import SwiftUI
import AgentSamCore

struct AgentSamSectionHeading: View {
    let title: String
    let systemImage: String
    var trailing: String?

    init(_ title: String, systemImage: String, trailing: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 7) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(AgentSamTheme.muted)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption2.monospacedDigit()).foregroundStyle(AgentSamTheme.dim)
            }
        }
    }
}

struct AgentSamTaskList: View {
    let tasks: [AgentSamTaskPresentation]
    let team: Team?

    var body: some View {
        if tasks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard").font(.title3).foregroundStyle(AgentSamTheme.dim)
                Text("The coordinator’s task plan will appear here.")
                    .font(.caption)
                    .foregroundStyle(AgentSamTheme.muted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            VStack(spacing: 7) {
                ForEach(tasks) { task in
                    HStack(alignment: .top, spacing: 9) {
                        if let agent = team?.agent(named: task.agentName) {
                            AgentSamAvatar(name: agent.name, role: agent.role, size: 28)
                        } else {
                            Image(systemName: "person.circle").frame(width: 28).foregroundStyle(AgentSamTheme.dim)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.goal)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(AgentSamTheme.secondaryInk)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(task.agentName) · \(task.deliverable)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(AgentSamTheme.dim)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        AgentSamChip(task.state.label, tint: tint(for: task.state))
                    }
                    .padding(9)
                    .background(task.state == .working ? AgentSamTheme.emerald.opacity(0.055) : AgentSamTheme.raised.opacity(0.55))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(task.state == .working ? AgentSamTheme.emerald.opacity(0.22) : AgentSamTheme.line))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func tint(for state: AgentSamTaskState) -> Color {
        switch state {
        case .queued: AgentSamTheme.muted
        case .working: AgentSamTheme.emeraldLight
        case .done: AgentSamTheme.goldLight
        case .failed: AgentSamTheme.danger
        }
    }
}

struct AgentSamChatterList: View {
    let items: [AgentSamChatterItem]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        row(item).id(item.id)
                    }
                    if items.isEmpty {
                        Text("Agent handoffs and mission notices will appear here.")
                            .font(.caption)
                            .foregroundStyle(AgentSamTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                }
                .padding(12)
            }
            .onChange(of: items.count) { _, _ in
                if let last = items.last {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func row(_ item: AgentSamChatterItem) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            if !item.system {
                AgentSamAvatar(name: item.agentName ?? "A", role: item.role ?? .worker, size: 26)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !item.system {
                    Text(item.agentName ?? "Agent")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .textCase(.uppercase)
                        .foregroundStyle(AgentSamTheme.dim)
                }
                Text(item.text)
                    .font(.caption)
                    .foregroundStyle(item.failed ? AgentSamTheme.danger : AgentSamTheme.secondaryInk)
                    .textSelection(.enabled)
                    .padding(.horizontal, item.system ? 12 : 10)
                    .padding(.vertical, item.system ? 6 : 8)
                    .background(item.system ? AgentSamTheme.raised.opacity(0.6) : AgentSamTheme.raised)
                    .overlay(RoundedRectangle(cornerRadius: item.system ? 12 : 10).strokeBorder(item.failed ? AgentSamTheme.danger.opacity(0.3) : AgentSamTheme.line))
                    .clipShape(RoundedRectangle(cornerRadius: item.system ? 12 : 10))
            }
            if item.system { Spacer() }
        }
        .frame(maxWidth: .infinity, alignment: item.system ? .center : .leading)
    }
}

struct AgentSamEventRow: View {
    let event: RunEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let agent = event.agentName {
                        Text(agent).font(.caption.weight(.semibold)).foregroundStyle(AgentSamTheme.ink)
                    }
                    Text(label).font(.caption).foregroundStyle(AgentSamTheme.muted)
                    Spacer(minLength: 0)
                    Text(event.timestamp, style: .time).font(.caption2).foregroundStyle(AgentSamTheme.dim)
                }
                if let text = event.text, !text.isEmpty {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(event.kind == .error ? AgentSamTheme.danger : AgentSamTheme.secondaryInk)
                        .lineLimit(event.kind == .agentMessage ? 12 : event.kind == .report ? 24 : 8)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var label: String {
        switch event.kind {
        case .missionStart: "Mission started"
        case .phase: "Phase — \(event.text ?? "")"
        case .plan: "Task plan"
        case .taskStarted: "Task started"
        case .agentMessage: "Agent reply"
        case .toolCall: "Tool call"
        case .taskDone: "Task done"
        case .deliverable: "Deliverable — \(event.deliverableName ?? "")"
        case .verifyFinding: "Verification finding"
        case .verifyVerdict: "Verdict — \(event.text ?? "")"
        case .report: "Final report"
        case .cost: "Cost"
        case .notice: "Notice"
        case .missionEnd: "Mission ended"
        case .error: "Error"
        }
    }

    private var symbol: String {
        switch event.kind {
        case .missionStart: "rocket"
        case .phase: "arrow.triangle.branch"
        case .plan: "map"
        case .taskStarted: "clipboard"
        case .agentMessage: "bubble.left"
        case .toolCall: "wrench.and.screwdriver"
        case .taskDone: "checkmark.circle"
        case .deliverable: "doc.text"
        case .verifyFinding: "exclamationmark.bubble"
        case .verifyVerdict: "scalemass"
        case .report: "doc.richtext"
        case .cost: "dollarsign.circle"
        case .notice: "info.circle"
        case .missionEnd: "flag.checkered"
        case .error: "xmark.octagon"
        }
    }

    private var tint: Color {
        switch event.kind {
        case .error: return AgentSamTheme.danger
        case .verifyFinding:
            if event.text?.hasPrefix("FAIL") == true { return AgentSamTheme.danger }
            if event.text?.hasPrefix("CONCERN") == true { return AgentSamTheme.goldLight }
            return AgentSamTheme.emerald
        case .missionEnd, .taskDone: return AgentSamTheme.emerald
        case .deliverable: return AgentSamTheme.teal
        case .verifyVerdict: return AgentSamTheme.goldLight
        default: return AgentSamTheme.muted
        }
    }
}

#Preview("Task list") {
    AgentSamTaskList(
        tasks: [
            AgentSamTaskPresentation(number: 1, agentName: "Scout", goal: "Gather recent sources on solid-state batteries", deliverable: "sources.md", state: .done),
            AgentSamTaskPresentation(number: 2, agentName: "Quill", goal: "Write the one-page brief", deliverable: "brief.md", state: .working),
            AgentSamTaskPresentation(number: 3, agentName: "Judge", goal: "Check claims against sources", deliverable: "review.md", state: .queued),
            AgentSamTaskPresentation(number: 4, agentName: "Scout", goal: "Fetch a missing citation", deliverable: "sources.md", state: .failed)
        ],
        team: .starterTeam()
    )
    .padding()
    .frame(width: 420)
    .background(AgentSamBackground())
    .preferredColorScheme(.dark)
}

#Preview("Task list – empty") {
    AgentSamTaskList(tasks: [], team: nil)
        .padding()
        .frame(width: 420)
        .background(AgentSamBackground())
        .preferredColorScheme(.dark)
}

#Preview("Chatter") {
    AgentSamChatterList(items: [
        AgentSamChatterItem(seq: 1, agentName: nil, role: nil, text: "Mission started", timestamp: .now, system: true, failed: false),
        AgentSamChatterItem(seq: 2, agentName: "Ada", role: .coordinator, text: "Scout, please gather sources. Quill, you draft once they land.", timestamp: .now, system: false, failed: false),
        AgentSamChatterItem(seq: 3, agentName: "Scout", role: .worker, text: "Found six recent sources and saved them to sources.md.", timestamp: .now, system: false, failed: false),
        AgentSamChatterItem(seq: 4, agentName: nil, role: nil, text: "Quill hit a rate limit and is retrying", timestamp: .now, system: true, failed: true)
    ])
    .frame(width: 420, height: 360)
    .background(AgentSamBackground())
    .preferredColorScheme(.dark)
}

#Preview("Chatter – empty") {
    AgentSamChatterList(items: [])
        .frame(width: 420, height: 200)
        .background(AgentSamBackground())
        .preferredColorScheme(.dark)
}

#Preview("Event rows") {
    let missionID = UUID()
    VStack(alignment: .leading, spacing: 6) {
        AgentSamEventRow(event: RunEvent(seq: 1, missionID: missionID, kind: .missionStart, text: "Summarize this quarter’s solid-state battery news"))
        AgentSamEventRow(event: RunEvent(seq: 2, missionID: missionID, kind: .toolCall, agentName: "Scout", text: "write_file sources.md"))
        AgentSamEventRow(event: RunEvent(seq: 3, missionID: missionID, kind: .deliverable, agentName: "Quill", deliverableName: "brief.md"))
        AgentSamEventRow(event: RunEvent(seq: 4, missionID: missionID, kind: .verifyFinding, agentName: "Judge", text: "CONCERN — one claim lacks a source"))
        AgentSamEventRow(event: RunEvent(seq: 5, missionID: missionID, kind: .error, agentName: "Quill", text: "Provider returned 429"))
    }
    .padding()
    .frame(width: 440)
    .background(AgentSamBackground())
    .preferredColorScheme(.dark)
}
