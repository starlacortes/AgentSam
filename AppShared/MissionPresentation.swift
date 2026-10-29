import Foundation
import AgentSamCore

enum AgentSamTaskState: String, Hashable {
    case queued
    case working
    case done
    case failed

    var label: String { rawValue }
}

struct AgentSamTaskPresentation: Identifiable, Hashable {
    let number: Int
    let agentName: String
    let goal: String
    let deliverable: String
    var state: AgentSamTaskState
    var id: String { "\(number)-\(agentName)-\(goal)" }
}

enum AgentSamAgentState: Hashable {
    case idle
    case working
    case done
    case failed
}

struct AgentSamAgentPresentation: Identifiable, Hashable {
    let agent: AgentProfile
    var state: AgentSamAgentState
    var task: String?
    var id: UUID { agent.id }
}

struct AgentSamChatterItem: Identifiable, Hashable {
    let seq: Int
    let agentName: String?
    let role: AgentProfile.Role?
    let text: String
    let timestamp: Date
    let system: Bool
    let failed: Bool
    var id: Int { seq }
}

struct AgentSamMissionPresentation {
    let team: Team?
    let mission: Mission?
    let events: [RunEvent]
    let tasks: [AgentSamTaskPresentation]
    let agents: [AgentSamAgentPresentation]
    let chatter: [AgentSamChatterItem]

    init(team: Team?, mission: Mission?, events: [RunEvent]) {
        self.team = team
        self.mission = mission
        self.events = events.sorted { $0.seq < $1.seq }
        self.tasks = Self.makeTasks(team: team, mission: mission, events: self.events)
        self.agents = Self.makeAgents(team: team, mission: mission, tasks: tasks, events: self.events)
        self.chatter = Self.makeChatter(team: team, events: self.events)
    }

    private static func makeTasks(team: Team?, mission: Mission?, events: [RunEvent]) -> [AgentSamTaskPresentation] {
        guard let plan = events.last(where: { $0.kind == .plan })?.text else { return [] }
        var result: [AgentSamTaskPresentation] = []
        for line in plan.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Task ") else { continue }
            let afterTask = trimmed.index(trimmed.startIndex, offsetBy: 5)
            guard let numberEnd = trimmed[afterTask...].firstIndex(of: " "),
                  let number = Int(trimmed[afterTask..<numberEnd]) else { continue }
            let remainder = trimmed[trimmed.index(after: numberEnd)...].trimmingCharacters(in: .whitespaces)
            let parts = remainder.components(separatedBy: " — ")
            guard parts.count >= 2 else { continue }
            let assignment = parts.dropFirst().joined(separator: " — ")
            guard let colon = assignment.firstIndex(of: ":") else { continue }
            let agentName = String(assignment[..<colon]).trimmingCharacters(in: .whitespaces)
            let output = assignment[assignment.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let outputParts = output.components(separatedBy: " → ")
            let goal = outputParts.dropLast().joined(separator: " → ").trimmingCharacters(in: .whitespaces)
            let deliverable = outputParts.last?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !goal.isEmpty else { continue }

            let agentID = team?.agent(named: agentName)?.id
            let started = events.filter {
                $0.kind == .taskStarted && $0.text == goal && ($0.agentID == agentID || $0.agentName == agentName)
            }
            let firstStart = started.first?.seq ?? .max
            let done = events.contains {
                $0.kind == .taskDone && $0.seq >= firstStart && ($0.agentID == agentID || $0.agentName == agentName)
            }
            let failed = events.contains {
                $0.kind == .error && $0.seq >= firstStart && ($0.agentID == agentID || $0.agentName == agentName)
            }
            let state: AgentSamTaskState = failed ? .failed : done ? .done : !started.isEmpty ? .working : .queued
            result.append(AgentSamTaskPresentation(number: number, agentName: agentName, goal: goal, deliverable: deliverable, state: state))
        }
        if mission?.status == .completed {
            return result.map { item in
                var item = item
                if item.state != .failed { item.state = .done }
                return item
            }
        }
        return result
    }

    private static func makeAgents(
        team: Team?,
        mission: Mission?,
        tasks: [AgentSamTaskPresentation],
        events: [RunEvent]
    ) -> [AgentSamAgentPresentation] {
        guard let team else { return [] }
        return team.agents.map { agent in
            let assigned = tasks.filter { $0.agentName == agent.name }
            let state: AgentSamAgentState
            if assigned.contains(where: { $0.state == .failed }) {
                state = .failed
            } else if assigned.contains(where: { $0.state == .working }) {
                state = .working
            } else if !assigned.isEmpty && assigned.allSatisfy({ $0.state == .done }) {
                state = .done
            } else if let mission, mission.status == .running {
                switch (agent.role, mission.phase) {
                case (.coordinator, .planning), (.coordinator, .reporting), (.verifier, .verifying):
                    state = .working
                case (.verifier, .reporting):
                    state = .done
                default:
                    state = .idle
                }
            } else if mission?.phase == .done && (agent.role == .coordinator || agent.role == .verifier) {
                state = mission?.status == .failed ? .failed : .done
            } else {
                state = .idle
            }
            let task = assigned.first(where: { $0.state == .working })?.goal ?? assigned.first?.goal
            return AgentSamAgentPresentation(agent: agent, state: state, task: task)
        }
    }

    private static func makeChatter(team: Team?, events: [RunEvent]) -> [AgentSamChatterItem] {
        events.compactMap { event in
            let system: Bool
            switch event.kind {
            case .missionStart, .missionEnd, .notice, .error:
                system = true
            case .agentMessage, .taskDone, .verifyVerdict:
                system = false
            default:
                return nil
            }
            guard let text = event.text, !text.isEmpty else { return nil }
            let role = team?.agents.first(where: { $0.id == event.agentID || $0.name == event.agentName })?.role
            return AgentSamChatterItem(
                seq: event.seq,
                agentName: event.agentName,
                role: role,
                text: text,
                timestamp: event.timestamp,
                system: system,
                failed: event.kind == .error
            )
        }
    }
}
