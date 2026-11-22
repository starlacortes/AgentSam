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
        guard canFinish else { return Self.withoutFinishRule(rules) }
        return localized(rules, mission: mission)
    }

    /// Drops the rule about calling the finish tool, for agents that have no finish tool. Matches
    /// any line that mentions the finish tool rather than the exact builtin wording, so it still
    /// works after an operator edits `house_rules` in prompts.json.
    static func withoutFinishRule(_ rules: String) -> String {
        rules.components(separatedBy: "\n")
            .filter { $0.range(of: "finish tool", options: .caseInsensitive) == nil }
            .joined(separator: "\n")
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

    public func workerSystem(agent: AgentProfile, team: Team, mission: Mission, externalTools: [String] = [], hasWorkstation: Bool = false) -> String {
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
        return localized(rendered + connectors + (hasWorkstation ? Self.workstationNote : "") + Self.webBuildNote, mission: mission)
    }

    /// Tells a mission worker how to use Ada's workstation: the route for running programs, git and
    /// pull requests when the mission sandbox and the GitHub connector cannot.
    public static let workstationNote = """


    You also have Ada's Linux workstation (workstation_status, workstation_run, workstation_start_job, workstation_job, workstation_jobs, workstation_stop_job). It is a separate machine: your mission files are not on it.
    - To use a mission file there, write it with workstation_run, for example `mkdir -p ~/work && cat > ~/work/file.js <<'ADA_EOF'` followed by the content and a final `ADA_EOF` line (one command is at most 20,000 bytes).
    - Git is set up there. Before any git work, run `cat ~/GIT.md` and follow it: it says which repositories you can reach and how credentials work. Work on a new branch, commit, push that branch, then open a pull request: with `gh pr create` if gh is installed, otherwise with the GitHub REST API (POST https://api.github.com/repos/OWNER/REPO/pulls, with title, head, base and body) using the short-lived token GIT.md describes. Never push to main.
    - workstation_run and workstation_start_job may wait for the person to approve a card; the call returns the real output once it has run. If it was denied or expired, say so and stop that step. Do not run the same command again.
    - Only report a branch, push or pull request as done when the command output shows it. Include the pull request URL in your handoff.
    """

    /// Lets the chat preview pages the team builds: one entry file with relative, sibling assets.
    public static let webBuildNote = "\n\nIf your task produces a web page or site, also write it as `index.html` (or another `.html` file) with any `.css` and `.js` beside it, referenced by relative paths such as `styles.css`. Keep everything self-contained: no build step, and only well-known CDN links if a library is essential. The user can preview these files live in chat."

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
