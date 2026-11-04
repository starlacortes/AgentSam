import Foundation

/// Renders the prompt templates for each mission phase. Template text comes
/// from a `PromptStore` (builtin seeds, overridable at runtime); this type
/// only builds the typed context values each template interpolates.
public struct PromptBuilder: Sendable {
    public let store: PromptStore

    public init(store: PromptStore) {
        self.store = store
    }

    public func houseRules() -> String {
        store.render("house_rules")
    }

    public func coordinatorSystem(agent: AgentProfile, team: Team) -> String {
        let roster = team.agents.map { a in
            "- \(a.name) (\(a.title)): \(a.systemPrompt.prefix(220))"
        }.joined(separator: "\n")
        let roleLine = team.coordinator == nil
            ? "You are \(agent.name), acting as the Coordinator of a small agent team named \(team.name) (this team has no designated coordinator)."
            : "You are \(agent.name), the Coordinator of a small agent team named \(team.name)."
        return store.render("coordinator_system", context: [
            "role_line": roleLine,
            "coordinator_prompt": agent.systemPrompt,
            "roster": roster,
            "house_rules": houseRules(),
        ])
    }

    public func planPrompt(mission: Mission, team: Team, maxTasks: Int) -> String {
        let roster = team.workers.map { "- \($0.name) (\($0.title))" }.joined(separator: "\n")
        return store.render("plan", context: [
            "mission_objective": mission.objective,
            "roster": roster,
            "max_tasks": String(maxTasks),
        ])
    }

    public func replanPrompt(mission: Mission, previous: String) -> String {
        store.render("replan", context: [
            "mission_objective": mission.objective,
            "previous_reply": String(previous.prefix(2_000)),
        ])
    }

    /// Tool-result feedback for a `submit_plan` call the engine rejected.
    public func invalidPlanFeedback(reason: String) -> String {
        store.render("plan_invalid_feedback", context: ["reason": reason])
    }

    public func workerSystem(agent: AgentProfile, team: Team, mission: Mission) -> String {
        store.render("worker_system", context: [
            "agent_name": agent.name,
            "agent_title": agent.title,
            "agent_prompt": agent.systemPrompt,
            "team_name": team.name,
            "mission_objective": mission.objective,
            "house_rules": houseRules(),
        ])
    }

    public func workPrompt(task: TaskPlanItem, mission: Mission) -> String {
        store.render("work", context: [
            "task_id": String(task.id),
            "task_goal": task.goal,
            "task_deliverable": task.deliverable,
        ])
    }

    public func verifierSystem(agent: AgentProfile, mission: Mission) -> String {
        store.render("verifier_system", context: [
            "agent_name": agent.name,
            "agent_title": agent.title,
            "agent_prompt": agent.systemPrompt,
            "mission_objective": mission.objective,
        ])
    }

    public func verifyPrompt(deliverables: [String]) -> String {
        store.render("verify", context: [
            "deliverables": deliverables.map { "- \($0)" }.joined(separator: "\n"),
        ])
    }

    public func reportPrompt(mission: Mission, handoffs: [String]) -> String {
        store.render("report", context: [
            "mission_objective": mission.objective,
            "handoffs": handoffs.map { "— \($0)" }.joined(separator: "\n"),
        ])
    }
}
