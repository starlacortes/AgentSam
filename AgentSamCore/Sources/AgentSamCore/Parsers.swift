import Foundation

public enum PlanParser {
    public static func parse(_ text: String) -> [TaskPlanItem] {
        var items: [TaskPlanItem] = []
        var current: [String: String] = [:]
        var order: Int = 0

        func flush() {
            guard let agent = current["Agent"], !agent.isEmpty,
                  let goal = current["Goal"], !goal.isEmpty else {
                current = [:]
                return
            }
            order += 1
            let deliverable = sanitizedFilename(current["Deliverable"]) ?? "task-\(order).md"
            items.append(TaskPlanItem(
                id: order,
                agentName: agent,
                goal: goal,
                deliverable: deliverable
            ))
            current = [:]
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("TASK") {
                flush()
                continue
            }
            if let key = keyPrefix(in: line, of: ["Agent", "Goal", "Deliverable"]) {
                current[key] = value(after: line)
            }
        }
        flush()
        return items
    }

    private static func keyPrefix(in line: String, of keys: [String]) -> String? {
        for key in keys {
            if line.hasPrefix(key + ":") || line.hasPrefix(key + " :") {
                return key
            }
        }
        return nil
    }

    private static func value(after line: String) -> String {
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
    }

    public static func sanitizedFilename(_ name: String?) -> String? {
        guard var name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        name = name.replacingOccurrences(of: " ", with: "-").lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        name = name.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        if !name.hasSuffix(".md") { name += ".md" }
        return name.count > 4 ? name : nil
    }

    public static func fallbackPlan(mission: Mission, team: Team) -> [TaskPlanItem] {
        let workers = team.workers.isEmpty ? team.agents : team.workers
        return workers.enumerated().map { index, agent in
            TaskPlanItem(
                id: index + 1,
                agentName: agent.name,
                goal: "Contribute your part toward the mission objective: \(mission.objective)",
                deliverable: "\(AgentTools.normalized(agent.name).replacingOccurrences(of: " ", with: "-").lowercased())-notes.md"
            )
        }
    }
}

public enum VerifierParser {
    public static func parse(_ text: String) -> (findings: [VerificationReport.Finding], verdict: VerificationReport.Verdict) {
        var findings: [VerificationReport.Finding] = []
        var verdict: VerificationReport.Verdict?

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let raw = prefixAfter(line, "VERDICT:") {
                let value = raw.trimmingCharacters(in: .whitespaces).uppercased()
                if value.hasPrefix("CLEAN") { verdict = .clean }
                else if value.hasPrefix("CONCERN") { verdict = .concerns }
                else if value.hasPrefix("FAIL") { verdict = .failed }
                continue
            }
            guard line.hasPrefix("-") else { continue }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let level: VerificationReport.Level
            let rest: String
            if body.uppercased().hasPrefix("PASS") {
                level = .pass
                rest = String(body.dropFirst(4))
            } else if body.uppercased().hasPrefix("CONCERN") {
                level = .concern
                rest = String(body.dropFirst(7))
            } else if body.uppercased().hasPrefix("FAIL") {
                level = .fail
                rest = String(body.dropFirst(4))
            } else {
                continue
            }
            let detail = rest.trimmingCharacters(in: CharacterSet(charactersIn: " —-:"))
            findings.append(VerificationReport.Finding(level: level, check: "review", detail: detail.isEmpty ? "no detail" : detail))
        }

        let resolvedVerdict = verdict ?? {
            if let worst = findings.map(\.level).max() {
                switch worst {
                case .pass: return VerificationReport.Verdict.clean
                case .concern: return VerificationReport.Verdict.concerns
                case .fail: return VerificationReport.Verdict.failed
                }
            }
            return VerificationReport.Verdict.unverified
        }()
        return (findings, resolvedVerdict)
    }

    private static func prefixAfter(_ line: String, _ prefix: String) -> String? {
        guard line.uppercased().hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }
}
