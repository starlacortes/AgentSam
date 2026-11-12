import Foundation

/// Structured tool-call output for the planning and verification phases.
///
/// The coordinator submits its plan through the `submit_plan` tool and the
/// verifier submits its findings through the `submit_review` tool. Both are
/// decoded from the tool call's JSON arguments, so the engine never parses
/// free-form text on the happy path. The text parsers in `Parsers.swift`
/// remain only as a fallback for models that ignore the tools.
public enum StructuredOutput {
    // MARK: - Errors

    /// Why a `submit_plan` submission was rejected; the reason is written for
    /// the coordinator, so it can be fed back through a tool result.
    public struct PlanValidationError: Error, CustomStringConvertible, Sendable {
        public let reason: String
        public init(reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    // MARK: - Wire shapes

    public struct PlanSubmission: Decodable, Sendable {
        public struct Task: Decodable, Sendable {
            public var agent: String?
            public var goal: String?
            public var deliverable: String?
        }
        public var tasks: [Task]?
    }

    public struct ReviewSubmission: Decodable, Sendable {
        public struct Finding: Decodable, Sendable {
            public var level: String?
            public var area: String?
            public var detail: String?
        }
        public var verdict: String?
        public var findings: [Finding]?
    }

    // MARK: - Decoding

    /// Decodes a tool call's JSON arguments into the given type. Returns nil
    /// when the arguments are missing or not valid JSON of the expected shape.
    public static func decode<T: Decodable>(from call: APIToolCall) -> T? {
        guard let data = call.function.arguments.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Plan validation

    /// Validates a `submit_plan` submission against the team and turns it into
    /// engine-ready tasks. On failure the error describes what the coordinator
    /// should correct, so it can be fed back through a tool result.
    public static func plan(
        from submission: PlanSubmission,
        team: Team,
        maxTasks: Int
    ) -> Result<[TaskPlanItem], PlanValidationError> {
        guard let rawTasks = submission.tasks, !rawTasks.isEmpty else {
            return .failure(PlanValidationError(reason: "the plan contained no tasks"))
        }
        var items: [TaskPlanItem] = []
        var seenAgents: Set<String> = []
        var seenDeliverables: Set<String> = []
        for (index, task) in rawTasks.prefix(max(1, maxTasks)).enumerated() {
            let agentName = task.agent?.trimmed ?? ""
            let goal = task.goal?.trimmed ?? ""
            guard !agentName.isEmpty, !goal.isEmpty else {
                return .failure(PlanValidationError(reason: "task \(index + 1) is missing an agent or a goal"))
            }
            guard let agent = team.agent(named: agentName) else {
                return .failure(PlanValidationError(reason: "task \(index + 1) names an agent not on this team: \(agentName)"))
            }
            guard seenAgents.insert(agent.name).inserted else {
                return .failure(PlanValidationError(reason: "\(agent.name) is assigned more than one task"))
            }
            guard let deliverable = PlanParser.sanitizedFilename(task.deliverable) else {
                return .failure(PlanValidationError(reason: "task \(index + 1) has an invalid deliverable filename: \(task.deliverable ?? "")"))
            }
            guard seenDeliverables.insert(deliverable).inserted else {
                return .failure(PlanValidationError(reason: "more than one task targets the deliverable \(deliverable)"))
            }
            items.append(TaskPlanItem(id: index + 1, agentName: agent.name, goal: goal, deliverable: deliverable))
        }
        return .success(items)
    }

    // MARK: - Review mapping

    /// Maps a `submit_review` submission into verification findings and a
    /// verdict. Unknown levels are skipped; when the verdict is missing it is
    /// inferred from the worst finding, matching `VerifierParser` semantics.
    public static func review(
        from submission: ReviewSubmission
    ) -> (findings: [VerificationReport.Finding], verdict: VerificationReport.Verdict) {
        let findings = (submission.findings ?? []).prefix(8).compactMap { finding -> VerificationReport.Finding? in
            guard let level = Self.level(from: finding.level) else { return nil }
            let area = finding.area?.trimmed ?? ""
            let detail = finding.detail?.trimmed ?? ""
            let text = area.isEmpty ? detail : "\(area): \(detail)"
            return VerificationReport.Finding(level: level, check: "review", detail: text.isEmpty ? "no detail" : text)
        }
        let verdict = Self.verdict(from: submission.verdict) ?? {
            switch findings.map(\.level).max() {
            case .pass: return VerificationReport.Verdict.clean
            case .concern: return VerificationReport.Verdict.concerns
            case .fail: return VerificationReport.Verdict.failed
            case nil: return VerificationReport.Verdict.unverified
            }
        }()
        return (findings, verdict)
    }

    private static func level(from raw: String?) -> VerificationReport.Level? {
        switch raw?.trimmed.lowercased() {
        case "pass": return .pass
        case "concern": return .concern
        case "fail": return .fail
        default: return nil
        }
    }

    private static func verdict(from raw: String?) -> VerificationReport.Verdict? {
        switch raw?.trimmed.lowercased() {
        case "clean": return .clean
        case "concerns": return .concerns
        case "failed": return .failed
        default: return nil
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
