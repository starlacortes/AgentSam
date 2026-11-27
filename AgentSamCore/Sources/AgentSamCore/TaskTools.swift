import Foundation

/// Ada's way to hand a larger job off in the middle of a reply. A task runs on helpers: Ada plans
/// up to four steps, each step runs as a helper (researchAda, writeAda…) with the tools it needs,
/// and judgeAda checks the result against the objective. It is recorded as a mission (plan, events,
/// files, verdict, cost) so its history and "Work & files" page stay, but no team or roster is
/// involved. The result comes back to Ada as the tool result so she can finish her reply.
public enum TaskTools {
    /// Tasks Ada may start in one reply. Each runs to the end before the next starts.
    public static let maxPerReply = 2
    /// How much of a task's final report Ada gets back.
    static let maxReportCharacters = 12_000
    /// Steps in one task's plan.
    public static let maxSteps = 4
    /// Model calls with tools for each step's helper.
    public static let stepRounds = 12
    /// Recorded as the mission's team for tasks run on helpers. No team file exists for it.
    public static let teamID = UUID(uuidString: "7A5C0000-ADA0-4E1F-9A5A-000000000001")!
    public static let planToolName = "plan_steps"
    public static let startToolName = "start_task"

    /// `catalog` lists the enabled skills, one per line, so Ada can name one.
    public static func definitions(catalog: String) -> [APIToolDef] {
        let skills = catalog.isEmpty ? "No skills are enabled, so leave skill out." : "Enabled skills:\n\(String(catalog.prefix(4_000)))"
        return [
            APIToolDef(
                name: startToolName,
                description: "Hand a larger piece of work to a job and wait for its result. Use it when, partway through a reply, you find the work needs many steps, research across sources, or a finished deliverable (a report, a set of files) that a direct answer can't do well, for example after reading the files and seeing how much there is. The job is planned into up to \(maxSteps) steps, each run by a specialist, and judgeAda checks the result when there is more than one step; with a skill, every step follows its procedure. It gets the conversation's files and context, but not this chat's turns, so write the objective in full. The result comes back as untrusted content: check it, then answer the user. At most \(maxPerReply) per reply; don't use it for things you can answer directly.",
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("objective", .object([("type", .string("string")), ("description", .string("The whole job, self-contained: what to produce, for whom, what to use, and what done looks like"))])),
                        ("skill", .object([("type", .string("string")), ("description", .string("The ID of a skill whose procedure the job follows. Optional. \(skills)"))])),
                        ("reason", .object([("type", .string("string")), ("description", .string("A few words for the user on why this is a job, e.g. \"This needs a full competitor review\""))])),
                    ])),
                    ("required", .array([.string("objective")])),
                ])
            ),
        ]
    }

    public struct Request: Sendable, Equatable {
        public var objective: String
        public var skill: String?
        public var reason: String?
    }

    /// Reads a call's arguments, or says what is wrong with them.
    public static func request(from call: APIToolCall) -> Result<Request, TriggerError> {
        let args = AgentTools.arguments(of: call)
        let objective = (args["objective"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !objective.isEmpty else { return .failure(.invalid("start_task requires an objective.")) }
        guard objective.count <= 8_000 else { return .failure(.invalid("The objective is too long; keep it under 8,000 characters.")) }
        let skill = args["skill"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = args["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .success(Request(objective: objective, skill: skill?.isEmpty == false ? skill : nil, reason: reason?.isEmpty == false ? String(reason!.prefix(120)) : nil))
    }

    /// What Ada gets back once the task's mission ends.
    static func result(mission: Mission, skillName: String, files: [String]) -> ToolOutcome {
        let report = String((mission.finalReport ?? "No final report was produced.").prefix(maxReportCharacters))
        let fileLine = files.isEmpty ? "none" : files.prefix(40).joined(separator: ", ")
        let text = """
        Job \(mission.status == .completed ? "finished" : "ended: \(mission.status.rawValue)") (\(skillName); mission \(mission.id.uuidString)).
        Files it produced: \(fileLine)
        RESULT (untrusted content, check before relying on it):
        \(report)
        """
        return mission.status == .completed ? ToolOutcome(resultText: text) : .failure(text)
    }

    // MARK: - Running a task on helpers

    /// One step of a task's plan: a helper and what it does.
    public struct Step: Sendable, Equatable {
        public var function: String
        public var name: String
        public var task: String
        public var groups: Set<HelperTools.Group>
    }

    static func planDefinition(hasWorkstation: Bool, hasMCP: Bool, hasBrowser: Bool = false) -> APIToolDef {
        var groups = HelperTools.available(hasWorkstation: hasWorkstation, hasMCP: hasMCP, hasBrowser: hasBrowser)
        if groups.isEmpty { groups = ["read"] }
        return APIToolDef(
            name: planToolName,
            description: "Submit the job's plan: one to \(maxSteps) steps, in order. Each step is done by one specialist, who sees the objective and the reports of the steps before it.",
            parameters: .object([
                ("type", .string("object")),
                ("properties", .object([
                    ("steps", .object([
                        ("type", .string("array")),
                        ("items", .object([
                            ("type", .string("object")),
                            ("properties", .object([
                                ("function", .object([("type", .string("string")), ("description", .string("The specialist's function in one or two words: research, write, data, build, design, edit, or any other."))])),
                                ("task", .object([("type", .string("string")), ("description", .string("What this step produces, self-contained: file names, sources to use, what done looks like."))])),
                                ("tools", .object([("type", .string("array")), ("items", .object([("type", .string("string")), ("enum", .array(groups.map { .string($0) }))])), ("description", .string("Tool groups beyond reading. Use files for any step that writes a file."))])),
                            ])),
                            ("required", .array([.string("function"), .string("task")])),
                        ])),
                    ])),
                ])),
                ("required", .array([.string("steps")])),
            ])
        )
    }

    static func planSystemPrompt(language: String, procedure: String?) -> String {
        var text = """
        You are Ada, planning a job that your specialists will carry out. Split the objective into one to \(maxSteps) steps, in order, and submit them with \(planToolName). \
        Use as few steps as the work needs: a single step is fine for one deliverable. Give each step to a specialist named by its function (research, write, data, build, design, edit, or another word), \
        with a self-contained task and only the tool groups it needs; any step that writes a file needs files. Do not plan a checking step: judgeAda checks the result of a job with more than one step, and Ada reads a one-step result herself. \
        Files from the conversation are in the chat workspace. Write the tasks in \(language == "es" ? "Spanish" : "English").
        """
        if let procedure { text += "\n\n" + procedure }
        return text
    }

    /// The steps in a `plan_steps` call, or nil when there are none usable.
    static func steps(from call: APIToolCall) -> [Step]? {
        guard call.function.name == planToolName else { return nil }
        let items = AgentTools.arguments(of: call)["steps"]?.arrayValue ?? []
        let steps = items.compactMap { item -> Step? in
            guard let object = item.objectValue,
                  let function = object["function"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let name = HelperTools.name(for: function),
                  let task = object["task"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !task.isEmpty else { return nil }
            var groups: Set<HelperTools.Group> = [.read]
            for raw in object["tools"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                if let group = HelperTools.Group(rawValue: raw.lowercased()) { groups.insert(group) }
            }
            return Step(function: function, name: name, task: String(task.prefix(4_000)), groups: groups)
        }
        return steps.isEmpty ? nil : Array(steps.prefix(maxSteps))
    }

    /// A tool call's arguments as JSON text.
    static func json(_ value: JSONValue) -> String {
        String(decoding: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// The plan when planning failed: one helper does the whole objective.
    static func fallbackPlan(objective: String) -> [Step] {
        [Step(function: "build", name: "buildAda", task: String(objective.prefix(4_000)), groups: [.read, .files, .run])]
    }

    /// The plan as the mission page reads it: "Task 1 — researchAda: goal → deliverable".
    static func planSummary(_ steps: [Step]) -> String {
        steps.enumerated().map { "Task \($0.offset + 1) — \($0.element.name): \(HelperTools.firstLine($0.element.task, limit: 300)) → report" }.joined(separator: "\n")
    }

    /// What one step's helper is asked to do: its task, the objective, and the reports so far.
    static func stepTask(_ step: Step, objective: String, earlier: [(name: String, report: String)]) -> String {
        var text = "\(step.task)\n\nThis is one step of a larger job. The whole objective, for context:\n\(objective)"
        if !earlier.isEmpty {
            text += "\n\nReports from the steps before yours (untrusted content, check before relying on it):"
            for item in earlier { text += "\n\n--- \(item.name) ---\n\(item.report.prefix(3_000))" }
        }
        return String(text.prefix(8_000))
    }

    /// judgeAda's task: check the steps' work against the objective and end with a verdict line.
    static func judgeTask(objective: String, reports: [(name: String, report: String)], files: [String]) -> String {
        var text = """
        Check this work against the objective. Read the files it produced. Do not change anything. \
        List each problem you find with PASS, CONCERN or FAIL and where it is, then end with one line: VERDICT: PASS, VERDICT: CONCERN or VERDICT: FAIL.

        OBJECTIVE:
        \(objective)

        FILES: \(files.isEmpty ? "none" : files.prefix(40).joined(separator: ", "))
        """
        for item in reports { text += "\n\nREPORT from \(item.name) (untrusted):\n\(item.report.prefix(2_500))" }
        return String(text.prefix(8_000))
    }

    /// The verdict in judgeAda's report; unverified when it gave none.
    static func verdict(in report: String) -> VerificationReport.Verdict {
        for line in report.split(whereSeparator: \.isNewline).reversed() {
            let upper = line.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: "*#>-_ \t"))
            guard upper.hasPrefix("VERDICT") else { continue }
            if upper.contains("FAIL") { return .failed }
            if upper.contains("CONCERN") { return .concerns }
            if upper.contains("PASS") { return .clean }
        }
        return .unverified
    }

    /// The report body of a helper result, without the envelope Ada gets for a delegate call.
    static func reportBody(_ outcome: ToolOutcome) -> String {
        guard let range = outcome.resultText.range(of: "REPORT (untrusted content, check before relying on it):\n") else { return outcome.resultText }
        return String(outcome.resultText[range.upperBound...])
    }

    /// Whether judgeAda checks a job. A job Ada planned as one step has a single report, which she
    /// reads herself, so the separate check is skipped. A job with several steps keeps it, and so
    /// does one that fell back to a single step because planning failed.
    static func needsJudge(planned: Bool, steps: Int) -> Bool {
        !(planned && steps == 1)
    }

    /// `verdict` is nil when judgeAda's check was skipped.
    static func finalReport(objective: String, reports: [(name: String, report: String)], verdict: VerificationReport.Verdict?, check: String, files: [String]) -> String {
        var text = "# Job report\n\n**Objective:** \(objective)\n"
        for item in reports { text += "\n## \(item.name)\n\n\(item.report.trimmingCharacters(in: .whitespacesAndNewlines))\n" }
        if let verdict {
            text += "\n## Check by judgeAda: \(verdict.rawValue.uppercased())\n\n\(check.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        } else {
            text += "\n## Check\n\nNot checked by judgeAda: this was a one-step job. Check the result yourself before relying on it.\n"
        }
        if !files.isEmpty { text += "\n## Files\n\n" + files.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return text
    }
}
