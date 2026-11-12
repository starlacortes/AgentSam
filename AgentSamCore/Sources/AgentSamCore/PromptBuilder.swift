import Foundation

/// Renders versioned mission prompts and supplies their typed context values.
public struct PromptBuilder: Sendable {
    public let store: PromptStore

    public init(store: PromptStore) {
        self.store = store
    }

    private func language(for mission: Mission?) -> String {
        mission.map { CoreL10n.language(for: $0) } ?? "en"
    }

    private func t(_ key: String, mission: Mission?) -> String {
        CoreL10n.t(key, lang: language(for: mission))
    }

    private func contextBlock(for mission: Mission) -> String {
        guard let context = mission.inputContext?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty else {
            return ""
        }
        let source = mission.sourceName ?? t("prompt.externalSource", mission: mission)
        return String(format: t("prompt.context", mission: mission), source, context)
    }

    private func objective(for mission: Mission) -> String {
        mission.objective + contextBlock(for: mission)
    }

    private func localized(_ text: String, mission: Mission?) -> String {
        guard let mission, language(for: mission) == "es" else { return text }
        return text.replacingOccurrences(of: "MISSION OBJECTIVE", with: t("prompt.plan.objective", mission: mission))
            + t("prompt.language", mission: mission)
    }

    public func houseRules(for mission: Mission? = nil, canFinish: Bool = true) -> String {
        let rules = store.render("house_rules")
        guard canFinish else {
            return rules.replacingOccurrences(of: CoreL10n.t("prompt.finishRule", lang: "en"), with: "")
        }
        return localized(rules, mission: mission)
    }

    public func coordinatorSystem(agent: AgentProfile, team: Team, mission: Mission? = nil) -> String {
        let roster = team.agents.map { member in
            "- \(member.name) (\(member.title)): \(member.systemPrompt.prefix(220))"
        }.joined(separator: "\n")
        let roleLine = team.coordinator == nil
            ? "You are \(agent.name), acting as the Coordinator of a small agent team named \(team.name) (this team has no designated coordinator)."
            : "You are \(agent.name), the Coordinator of a small agent team named \(team.name)."
        let rendered = store.render("coordinator_system", context: [
            "role_line": roleLine,
            "coordinator_prompt": agent.systemPrompt,
            "roster": roster,
            "house_rules": houseRules(canFinish: false),
        ])
        return localized(rendered, mission: mission)
    }

    public func planPrompt(mission: Mission, team: Team, maxTasks: Int) -> String {
        let roster = team.workers.map { "- \($0.name) (\($0.title))" }.joined(separator: "\n")
        return localized(store.render("plan", context: [
            "mission_objective": objective(for: mission),
            "roster": roster,
            "max_tasks": String(maxTasks),
        ]), mission: mission)
    }

    public func replanPrompt(mission: Mission, previous: String) -> String {
        localized(store.render("replan", context: [
            "mission_objective": objective(for: mission),
            "previous_reply": String(previous.prefix(2_000)),
        ]), mission: mission)
    }

    public func invalidPlanFeedback(reason: String) -> String {
        store.render("plan_invalid_feedback", context: ["reason": reason])
    }

    public func workerSystem(agent: AgentProfile, team: Team, mission: Mission, externalTools: [String] = []) -> String {
        let rendered = store.render("worker_system", context: [
            "agent_name": agent.name,
            "agent_title": agent.title,
            "agent_prompt": agent.systemPrompt,
            "team_name": team.name,
            "mission_objective": objective(for: mission),
            "house_rules": houseRules(),
        ])
        let connectors = externalTools.isEmpty ? "" : String(
            format: t("prompt.worker.connectors", mission: mission),
            externalTools.joined(separator: ", ")
        )
        return localized(rendered + connectors, mission: mission)
    }

    public func workPrompt(task: TaskPlanItem, mission: Mission) -> String {
        localized(store.render("work", context: [
            "task_id": String(task.id),
            "task_goal": task.goal,
            "task_deliverable": task.deliverable,
        ]), mission: mission)
    }

    public func verifierSystem(agent: AgentProfile, mission: Mission) -> String {
        localized(store.render("verifier_system", context: [
            "agent_name": agent.name,
            "agent_title": agent.title,
            "agent_prompt": agent.systemPrompt,
            "mission_objective": objective(for: mission),
        ]), mission: mission)
    }

    public func verifyPrompt(deliverables: [String], mission: Mission? = nil) -> String {
        localized(store.render("verify", context: [
            "deliverables": deliverables.map { "- \($0)" }.joined(separator: "\n"),
        ]), mission: mission)
    }

    public func reportPrompt(mission: Mission, handoffs: [String], verification: VerificationReport? = nil) -> String {
        var rendered = store.render("report", context: [
            "mission_objective": objective(for: mission),
            "handoffs": handoffs.map { "— \($0)" }.joined(separator: "\n"),
        ])
        if let verification {
            rendered += "\n\n\(t("prompt.report.findings", mission: mission))\n"
                + verification.markdown(language: language(for: mission))
                + "\n\n\(t("prompt.report.correct", mission: mission))"
        }
        return localized(rendered, mission: mission)
    }
}
