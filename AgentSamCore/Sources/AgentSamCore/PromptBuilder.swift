import Foundation

public enum PromptBuilder {
    /// Looks up a prompt fragment in the mission's working language.
    private static func t(_ key: String, mission: Mission) -> String {
        CoreL10n.t(key, lang: CoreL10n.language(for: mission))
    }

    private static func contextBlock(for mission: Mission) -> String {
        guard let context = mission.inputContext?.trimmingCharacters(in: .whitespacesAndNewlines), !context.isEmpty else {
            return ""
        }
        let source = mission.sourceName ?? t("prompt.externalSource", mission: mission)
        return String(format: t("prompt.context", mission: mission), source, context)
    }

    /// Instructs agents to work in Spanish for Spanish-language missions.
    private static func languageBlock(for mission: Mission) -> String {
        guard CoreL10n.language(for: mission) == "es" else { return "" }
        return t("prompt.language", mission: mission)
    }

    private static func houseRules(for mission: Mission) -> String {
        t("prompt.houseRules", mission: mission)
    }

    public static func coordinatorSystem(team: Team, mission: Mission) -> String {
        let lang = CoreL10n.language(for: mission)
        let name = team.coordinator?.name ?? CoreL10n.t("prompt.coordinatorFallback", lang: lang)
        let systemPrompt = team.coordinator?.systemPrompt ?? CoreL10n.t("prompt.coordinatorFallbackRole", lang: lang)
        let roster = team.agents.map { agent in
            String(format: CoreL10n.t("prompt.rosterLine", lang: lang), agent.name, agent.title, String(agent.systemPrompt.prefix(220)))
        }.joined(separator: "\n")
        return String(
            format: CoreL10n.t("prompt.coordinatorSystem", lang: lang),
            name, team.name, systemPrompt, roster,
            houseRules(for: mission), languageBlock(for: mission)
        )
    }

    public static func planPrompt(mission: Mission, team: Team) -> String {
        let roster = team.workers.map { String(format: t("prompt.rosterLineShort", mission: mission), $0.name, $0.title) }.joined(separator: "\n")
        return """
        \(t("prompt.plan.objective", mission: mission))
        \(mission.objective)\(contextBlock(for: mission))
        
        \(t("prompt.plan.workers", mission: mission))
        \(roster)
        
        \(String(format: t("prompt.plan.requirements", mission: mission), Int64(team.workers.count)))
        
        \(t("prompt.plan.format", mission: mission))
        """
    }

    public static func replanPrompt(mission: Mission, previous: String) -> String {
        """
        \(t("prompt.replan.intro", mission: mission))
        \(t("prompt.plan.objective", mission: mission))
        \(mission.objective)\(contextBlock(for: mission))
        
        \(t("prompt.replan.previous", mission: mission))
        \(previous.prefix(2_000))

        \(t("prompt.replan.correct", mission: mission))
        """
    }

    public static func workerSystem(agent: AgentProfile, team: Team, mission: Mission, externalTools: [String] = []) -> String {
        let connectorNote: String
        if externalTools.isEmpty {
            connectorNote = ""
        } else {
            connectorNote = String(format: t("prompt.worker.connectors", mission: mission), externalTools.joined(separator: ", "))
        }
        return """
        \(String(format: t("prompt.worker.identity", mission: mission), agent.name, agent.title, team.name))
        \(agent.systemPrompt)
        
        \(t("prompt.worker.missionHeader", mission: mission))
        \(mission.objective)\(contextBlock(for: mission))
        
        \(houseRules(for: mission))\(languageBlock(for: mission))\(connectorNote)
        """
    }

    public static func workPrompt(task: TaskPlanItem, mission: Mission) -> String {
        """
        \(String(format: t("prompt.work.header", mission: mission), Int64(task.id)))
        \(String(format: t("prompt.work.goal", mission: mission), task.goal))
        \(String(format: t("prompt.work.deliverable", mission: mission), task.deliverable))
        
        \(t("prompt.work.produce", mission: mission))
        """
    }

    public static func verifierSystem(agent: AgentProfile, mission: Mission) -> String {
        """
        \(String(format: t("prompt.verifier.identity", mission: mission), agent.name, agent.title))
        \(agent.systemPrompt)
        
        \(t("prompt.plan.objective", mission: mission))
        \(mission.objective)\(contextBlock(for: mission))
        
        \(t("prompt.verifier.readonly", mission: mission))
        
        \(t("prompt.verifier.format", mission: mission))
        \(languageBlock(for: mission))
        """
    }

    public static func verifyPrompt(deliverables: [String], mission: Mission) -> String {
        """
        \(t("prompt.verify.deliverables", mission: mission))
        \(deliverables.map { "- \($0)" }.joined(separator: "\n"))
        
        \(t("prompt.verify.instruction", mission: mission))
        """
    }

    public static func reportPrompt(mission: Mission, handoffs: [String], verification: VerificationReport) -> String {
        """
        \(t("prompt.report.intro", mission: mission))
        
        \(t("prompt.plan.objective", mission: mission))
        \(mission.objective)\(contextBlock(for: mission))
        
        \(t("prompt.report.handoffs", mission: mission))
        \(handoffs.map { "— \($0)" }.joined(separator: "\n"))
        
        \(t("prompt.report.findings", mission: mission))
        \(verification.markdown(language: CoreL10n.language(for: mission)))
        
        \(t("prompt.report.correct", mission: mission))
        
        \(t("prompt.report.format", mission: mission))
        
        \(t("prompt.report.stop", mission: mission))
        """
    }
}
