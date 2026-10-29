import Foundation

public enum PromptBuilder {
    public static let houseRules = """
    House rules for every AgentSam agent:
    - Keep chat replies short; put substantial work in files.
    - Write deliverables in clean markdown. Stay inside the mission workspace; never invent files that were not provided.
    - When you finish your task, call the finish tool with a one-paragraph summary.
    - Be concrete: no filler, no restating the brief at length.
    """

    public static func coordinatorSystem(team: Team) -> String {
        let roster = team.agents.map { agent in
            "- \(agent.name) (\(agent.title)): \(agent.systemPrompt.prefix(220))"
        }.joined(separator: "\n")
        return """
        You are \(team.coordinator?.name ?? "the Coordinator") of a small agent team named \(team.name).
        \(team.coordinator?.systemPrompt ?? "You coordinate the team toward the mission objective.")

        Your team:
        \(roster)

        \(houseRules)
        """
    }

    public static func planPrompt(mission: Mission, team: Team) -> String {
        let roster = team.workers.map { "- \($0.name) (\($0.title))" }.joined(separator: "\n")
        return """
        MISSION OBJECTIVE
        \(mission.objective)

        Available workers:
        \(roster)

        Produce a task plan for the workers. Requirements:
        - Between 1 and \(team.workers.count) tasks. One task per worker at most. Only assign tasks to listed workers.
        - Each task must be independently completable and produce exactly one deliverable markdown file.
        - Deliverable filenames must be short, lowercase, hyphenated, and end in .md.

        Output your plan in EXACTLY this format and nothing else:

        TASK 1
        Agent: <worker name>
        Goal: <one sentence>
        Deliverable: <filename.md>

        TASK 2
        Agent: <worker name>
        Goal: <one sentence>
        Deliverable: <filename.md>

        Print the plan and stop. No extra commentary.
        """
    }

    public static func replanPrompt(mission: Mission, previous: String) -> String {
        """
        Your previous reply was not a parseable task plan. It must contain only TASK blocks in the required format.
        MISSION OBJECTIVE
        \(mission.objective)

        Your previous reply was:
        \(previous.prefix(2_000))

        Output the corrected plan now in the exact TASK/Agent/Goal/Deliverable format. Print the plan and stop.
        """
    }

    public static func workerSystem(agent: AgentProfile, team: Team, mission: Mission) -> String {
        """
        You are \(agent.name), \(agent.title) on team \(team.name).
        \(agent.systemPrompt)

        MISSION OBJECTIVE (for context, your task follows separately):
        \(mission.objective)

        \(houseRules)
        """
    }

    public static func workPrompt(task: TaskPlanItem, mission: Mission) -> String {
        """
        YOUR TASK (Task #\(task.id))
        Goal: \(task.goal)
        Deliverable: write your main output to \(task.deliverable)

        Produce the deliverable now. Write the file with the write_file tool, then call finish with a short summary of what you produced and any important caveats.
        """
    }

    public static func verifierSystem(agent: AgentProfile, mission: Mission) -> String {
        """
        You are \(agent.name), \(agent.title) for mission review.
        \(agent.systemPrompt)

        MISSION OBJECTIVE
        \(mission.objective)

        You have read_file and list_dir tools only. You never edit files.
        Inspect the deliverables in the workspace and judge whether they accomplish the objective.

        Respond ONLY with findings, one per line, in EXACTLY this format:
        - PASS — <area>: <one sentence>
        - CONCERN — <area>: <one sentence>
        - FAIL — <area>: <one sentence>
        Use at most 8 lines. Then a final line:
        VERDICT: CLEAN
        or
        VERDICT: CONCERNS
        or
        VERDICT: FAILED
        """
    }

    public static func verifyPrompt(deliverables: [String]) -> String {
        """
        Deliverables in the workspace:
        \(deliverables.map { "- \($0)" }.joined(separator: "\n"))

        Read each deliverable, compare it against the mission objective, and report your findings now in the required format.
        """
    }

    public static func reportPrompt(mission: Mission, handoffs: [String]) -> String {
        """
        The workers finished. Merge their handoffs into the final mission report.

        MISSION OBJECTIVE
        \(mission.objective)

        WORKER HANDOFFS
        \(handoffs.map { "— \($0)" }.joined(separator: "\n"))

        Write the final mission report as clean markdown (200–800 words):
        - A title and one-paragraph executive summary
        - What was produced, referencing each deliverable file by name
        - Key findings / content highlights
        - Caveats or open items

        The report replaces everything else in your reply. Print the report markdown and stop.
        """
    }
}
