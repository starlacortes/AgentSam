import Foundation

/// A procedure Ada watches for and runs with specialist subagents.
///
/// Skills replace user-facing teams. People talk to Ada; Ada decides when a request matches a
/// skill, and the server assembles the specialists behind the scenes and runs them through the
/// ordinary mission engine (plan → parallel subagents → verify → report). Teams still exist as the
/// execution unit on disk, but nobody has to create, pick, or edit one.
public struct Skill: Codable, Identifiable, Hashable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// Ships with AgentSam.
        case builtIn
        /// Converted from a team someone built before skills existed. Runs that team as saved.
        case migratedTeam
        /// Saved by Ada with `skill_save`, usually because the user asked her to remember a procedure.
        case ada
    }

    /// A short slug, such as `research`. Ada refers to skills by this ID.
    public var id: String
    public var name: String
    /// The signals Ada looks out for: the kinds of requests this skill is for.
    public var whenToUse: String
    /// The dedicated procedure, step by step. Given to the coordinating agent of every run.
    public var procedure: [String]
    /// Roster names (see `AgentProfile.rosterTemplates`) of the specialists to bring in. Empty for a
    /// migrated team, which runs with the agents it was saved with.
    public var specialists: [String]
    /// The team the skill runs as. Stable, so mission history links back to it.
    public var teamID: UUID
    public var origin: Origin
    public var enabled: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String, whenToUse: String, procedure: [String] = [], specialists: [String] = [], teamID: UUID = UUID(), origin: Origin, enabled: Bool = true, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.whenToUse = whenToUse
        self.procedure = procedure
        self.specialists = specialists
        self.teamID = teamID
        self.origin = origin
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Turns a name into an ID: lowercase letters, digits, and single hyphens.
    public static func slug(_ text: String) -> String {
        let lowered = text.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        var result = ""
        for character in lowered {
            if (character.isLetter || character.isNumber) && character.isASCII {
                result.append(character)
            } else if !result.isEmpty && result.last != "-" {
                result.append("-")
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return String(result.prefix(48))
    }

    /// The procedure as numbered lines, for prompts.
    public var procedureText: String {
        procedure.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }
}

// MARK: - Built-in skills

extension Skill {
    /// The skills every AgentSam server has. They take over from the old team templates, with the
    /// same specialists, so anything a template team could do Ada can still do without one.
    public static let builtIns: [Skill] = [
        Skill(
            id: "research", name: "Research",
            whenToUse: "The user wants facts found, compared, or checked across sources: market or product research, “what's new in…”, background on a topic, or a defensible brief with citations.",
            procedure: [
                "Turn the question into two to four concrete sub-questions.",
                "Scout researches them with web and connected sources, recording a source for every claim.",
                "Quill writes a concise brief that leads with the answer, then the evidence, with sources inline.",
                "Judge checks every claim against its source and flags anything unsupported or out of date.",
            ],
            specialists: ["Scout", "Quill", "Judge"],
            teamID: UUID(uuidString: "5C111A00-0000-4000-8000-000000000001")!, origin: .builtIn
        ),
        Skill(
            id: "content", name: "Content writing",
            whenToUse: "The user wants polished writing or creative assets: emails, launch copy, posts, landing-page text, headlines, or on-brand variations to choose from.",
            procedure: [
                "Pin down the audience, the goal, the tone, and any brand rules in the request or workspace files.",
                "Quill drafts the copy, with two or three variants for headlines and subject lines.",
                "Iris proposes layout or visual direction when the piece is visual (a page, a post, an email).",
                "Anchor edits for clarity, consistency, and length, and keeps the final versions in one file.",
            ],
            specialists: ["Quill", "Iris", "Anchor"],
            teamID: UUID(uuidString: "5C111A00-0000-4000-8000-000000000002")!, origin: .builtIn
        ),
        Skill(
            id: "data-analysis", name: "Data analysis",
            whenToUse: "The user shares or points to data (a CSV, a table, numbers in a file, a connected account) and wants it analyzed: trends, comparisons, outliers, “why did X change”.",
            procedure: [
                "Load the data and describe its shape, gaps, and anything that looks wrong before analyzing.",
                "Plot runs the analysis, showing the numbers behind each claim.",
                "Bolt writes and runs any code needed to compute or chart the results, and saves it with the outputs.",
                "Judge re-checks the key figures and challenges conclusions the data does not support.",
            ],
            specialists: ["Plot", "Bolt", "Judge"],
            teamID: UUID(uuidString: "5C111A00-0000-4000-8000-000000000003")!, origin: .builtIn
        ),
        Skill(
            id: "briefing", name: "News briefing",
            whenToUse: "The user wants a digest of what happened on a topic, ranked by importance, often on a schedule (“every morning”, “weekly roundup”).",
            procedure: [
                "Scout scans recent sources on each topic and keeps only items from the requested time window.",
                "Rank the items by how much they matter to the user, and drop duplicates and fluff.",
                "Anchor writes a tight briefing: one line per item, why it matters, and a source link.",
                "Judge checks dates and claims so nothing stale or unsupported gets through.",
            ],
            specialists: ["Scout", "Anchor", "Judge"],
            teamID: UUID(uuidString: "5C111A00-0000-4000-8000-000000000004")!, origin: .builtIn
        ),
        Skill(
            id: "idea-review", name: "Idea pressure-test",
            whenToUse: "The user wants a business, product, or project idea evaluated: market size, competitors, risks, a go or no-go, or a one-pager.",
            procedure: [
                "Restate the idea, the target customer, and the assumptions it depends on.",
                "Scout researches the market, competitors, and comparable attempts.",
                "Plot sizes the opportunity with stated assumptions and simple numbers.",
                "Quill writes a candid one-pager: the strongest case, the biggest holes, and what to test first.",
            ],
            specialists: ["Scout", "Plot", "Quill"],
            teamID: UUID(uuidString: "5C111A00-0000-4000-8000-000000000005")!, origin: .builtIn
        ),
        Skill(
            id: "deep-reading", name: "Deep reading",
            whenToUse: "The user wants long material read carefully and summarized honestly: a paper, a contract, a report, a thesis, or a long set of files.",
            procedure: [
                "Read the whole source before summarizing; note its structure and main claims.",
                "Quill writes a faithful summary that separates what the source says from interpretation.",
                "Judge flags weak, unsupported, or contradictory claims and anything the summary missed.",
            ],
            specialists: ["Quill", "Judge"],
            teamID: UUID(uuidString: "5C111A00-0000-4000-8000-000000000006")!, origin: .builtIn
        ),
    ]

    /// Team names and lineups that came from the old templates or the starter team. A saved team that
    /// still matches one exactly is covered by a built-in skill, so migration does not duplicate it.
    static let stockLineups: [(names: Set<String>, agents: [String])] = [
        (["Starter Crew", "Equipo inicial"], ["Ada", "Scout", "Quill", "Judge"]),
        (["Research Crew"], ["Ada", "Scout", "Quill", "Judge"]),
        (["Content Studio"], ["Ada", "Quill", "Iris", "Anchor"]),
        (["Data Lab"], ["Ada", "Plot", "Bolt", "Judge"]),
        (["News Desk"], ["Ada", "Scout", "Anchor", "Judge"]),
        (["Startup Foundry"], ["Ada", "Scout", "Plot", "Quill"]),
        (["Reading Room"], ["Ada", "Quill", "Judge"]),
    ]

    /// True when the team is an unmodified starter or template team.
    static func isStock(_ team: Team) -> Bool {
        guard stockLineups.contains(where: { $0.names.contains(team.name) && $0.agents == team.agents.map(\.name) }) else { return false }
        return team.agents.allSatisfy { agent in
            guard let key = rosterKey(agent.name) else { return false }
            let prompts = ["en", "es"].map { CoreL10n.t("roster.\(key).prompt", lang: $0) } + [CoreL10n.t("roster.\(key).prompt")]
            return prompts.contains(agent.systemPrompt)
        }
    }

    private static func rosterKey(_ name: String) -> String? {
        let key = name.lowercased()
        return ["ada", "scout", "quill", "plot", "judge", "iris", "bolt", "anchor"].contains(key) ? key : nil
    }
}

// MARK: - Store

/// Built-in skills plus the custom ones saved in `skills.json`.
public actor SkillStore {
    private struct StoreFile: Codable {
        var skills: [Skill]
        /// Team IDs already looked at by the one-time team migration, so a team deleted from the
        /// skill list is not migrated back on the next start.
        var migratedTeamIDs: [UUID]
    }

    public static let maxCustomSkills = 40
    private let url: URL?
    private var file: StoreFile

    public init(root: URL?) {
        self.url = root?.appendingPathComponent("skills.json")
        if let url, let data = try? Data(contentsOf: url), let decoded = try? Self.decoder.decode(StoreFile.self, from: data) {
            self.file = decoded
        } else {
            self.file = StoreFile(skills: [], migratedTeamIDs: [])
        }
    }

    /// Every skill, built-ins first.
    public func all() -> [Skill] {
        Skill.builtIns + file.skills.sorted { $0.createdAt < $1.createdAt }
    }

    public func enabled() -> [Skill] { all().filter(\.enabled) }

    public func skill(id: String) -> Skill? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all().first(where: { $0.id == key }) ?? all().first(where: { $0.name.lowercased() == key })
    }

    /// Every team a skill runs as, so callers can tell skill teams from anything else on disk.
    public func teamIDs() -> Set<UUID> { Set(all().map(\.teamID)) }

    /// Saves a custom skill, keeping its team and creation date when it already exists.
    @discardableResult
    public func save(_ skill: Skill) throws -> Skill {
        guard !Skill.builtIns.contains(where: { $0.id == skill.id }) else {
            throw SkillError.invalid("“\(skill.id)” is a built-in skill and cannot be changed. Save a new skill with a different name.")
        }
        var skill = skill
        skill.updatedAt = Date()
        if let index = file.skills.firstIndex(where: { $0.id == skill.id }) {
            skill.createdAt = file.skills[index].createdAt
            skill.teamID = file.skills[index].teamID
            file.skills[index] = skill
        } else {
            guard file.skills.count < Self.maxCustomSkills else { throw SkillError.invalid("There are already \(Self.maxCustomSkills) custom skills. Turn one off or update an existing one instead.") }
            file.skills.append(skill)
        }
        persist()
        return skill
    }

    /// Converts saved teams into skills, once per team. Ada's solo team, teams that already back a
    /// skill, and unmodified starter or template teams (covered by built-in skills) are skipped.
    /// Team files are never changed or deleted.
    @discardableResult
    public func migrate(teams: [Team], skipping skipped: Set<UUID> = []) -> [Skill] {
        let handled = Set(file.migratedTeamIDs).union(teamIDs()).union(skipped)
        var created: [Skill] = []
        var changed = false
        for team in teams where !handled.contains(team.id) {
            file.migratedTeamIDs.append(team.id)
            changed = true
            guard !Skill.isStock(team), !team.workers.isEmpty else { continue }
            var id = Skill.slug(team.name)
            if id.isEmpty { id = "team" }
            let base = id
            var suffix = 2
            while all().contains(where: { $0.id == id }) {
                id = "\(base)-\(suffix)"
                suffix += 1
            }
            let specialists = team.agents.filter { $0.role != .coordinator }.map { "\($0.name) (\($0.title))" }.joined(separator: ", ")
            let goal = team.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            let skill = Skill(
                id: id,
                name: team.name,
                whenToUse: goal.isEmpty ? "Work that fits this specialist group: \(specialists)." : "\(goal) Specialists: \(specialists).",
                teamID: team.id,
                origin: .migratedTeam,
                createdAt: team.createdAt
            )
            file.skills.append(skill)
            created.append(skill)
        }
        if changed { persist() }
        return created
    }

    private func persist() {
        guard let url, let data = try? Self.encoder.encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum SkillError: Error, LocalizedError, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): reason
        }
    }
}

// MARK: - Running a skill

public enum SkillTeams {
    /// The team a skill runs as. Ada coordinates, with the skill's procedure added to her prompt; the
    /// specialists come from the shared roster. A specialist whose provider has no key uses Ada's
    /// provider and model instead, so a skill always runs on what the server can actually call.
    /// A migrated skill runs its saved team unchanged. Returns nil when there is nothing to run.
    public static func team(for skill: Skill, coordinator: AgentProfile, providers: [ProviderConfig], hasKey: (ProviderConfig) -> Bool, saved: Team?) -> Team? {
        if skill.specialists.isEmpty {
            guard var team = saved, !team.workers.isEmpty else { return nil }
            if !skill.procedure.isEmpty, let index = team.agents.firstIndex(where: { $0.role == .coordinator }) {
                team.agents[index].systemPrompt += procedureBlock(skill)
            }
            return team
        }
        var lead = coordinator
        lead.id = UUID()
        lead.systemPrompt += procedureBlock(skill)
        var agents = [lead]
        var seen = Set<String>()
        for name in skill.specialists {
            guard let template = AgentProfile.rosterTemplates.first(where: { $0.name.lowercased() == name.lowercased() && $0.role != .coordinator }),
                  seen.insert(template.name).inserted else { continue }
            if template.role == .verifier && agents.contains(where: { $0.role == .verifier }) { continue }
            var agent = template
            agent.id = UUID()
            if let provider = providers.first(where: { $0.id == template.providerID }), hasKey(provider) {
                if !provider.models.contains(agent.model) { agent.model = provider.defaultModel ?? provider.models.first ?? coordinator.model }
            } else {
                agent.providerID = coordinator.providerID
                agent.model = coordinator.model
            }
            agents.append(agent)
        }
        guard agents.contains(where: { $0.role == .worker }) else { return nil }
        return Team(
            id: skill.teamID,
            name: skill.name,
            emoji: "🧩",
            goal: skill.whenToUse,
            agents: agents,
            toolScope: .readOnly,
            createdAt: skill.createdAt
        )
    }

    static func procedureBlock(_ skill: Skill) -> String {
        "\n\nSKILL: \(skill.name)\nFollow this procedure, adapting it to the objective:\n\(skill.procedureText)"
    }

    /// The skill catalog as Ada sees it in her routing prompt: one "use when" line per skill. The
    /// procedure is not included; it goes to the coordinating agent when the skill runs. Kept out of
    /// the per-message conversation context so the prompt prefix stays stable.
    public static func catalog(_ skills: [Skill]) -> String {
        skills.map { skill in
            let line = skill.whenToUse.components(separatedBy: .newlines).joined(separator: " ")
            return "- \(skill.id) (\(skill.name)): use when \(lowerFirst(line))"
        }.joined(separator: "\n")
    }

    /// "The user wants…" reads as "use when the user wants…"; an acronym such as "PDF" is left alone.
    static func lowerFirst(_ text: String) -> String {
        let characters = Array(text)
        guard let first = characters.first, first.isUppercase else { return text }
        if characters.count > 1, characters[1].isUppercase { return text }
        return first.lowercased() + String(characters.dropFirst())
    }
}

// MARK: - Ada's skill tools

public enum SkillTools {
    public static let names: Set<String> = ["skill_save"]

    public static func owns(_ name: String) -> Bool { names.contains(name) }

    /// The specialists a saved skill may use: the shared roster, without Ada herself.
    static var specialistNames: [String] {
        AgentProfile.rosterTemplates.filter { $0.role != .coordinator }.map(\.name)
    }

    public static var definitions: [APIToolDef] {
        [
            APIToolDef(
                name: "skill_save",
                description: """
                Save or update one of your own skills: a procedure you will follow, with specialists, whenever a \
                matching request comes in. Use it when the user asks you to remember how to handle a kind of \
                request ("whenever I ask for X, do it this way"), or asks to change or turn off a skill you saved. \
                Built-in skills cannot be changed. The skill is used from the next message on.
                """,
                parameters: .object([
                    ("type", .string("object")),
                    ("properties", .object([
                        ("name", .object([("type", .string("string")), ("description", .string("Short name, e.g. Weekly ads report. The ID is derived from it."))])),
                        ("when_to_use", .object([("type", .string("string")), ("description", .string("The requests this skill is for, in one or two sentences."))])),
                        ("procedure", .object([("type", .string("array")), ("items", .object([("type", .string("string"))])), ("description", .string("Two to eight concrete steps, in order."))])),
                        ("specialists", .object([
                            ("type", .string("array")),
                            ("items", .object([("type", .string("string")), ("enum", .array(specialistNames.map { .string($0) }))])),
                            ("description", .string("One to four specialists to bring in. At least one must not be Judge (the verifier).")),
                        ])),
                        ("enabled", .object([("type", .string("boolean")), ("description", .string("false turns the skill off. Defaults to true."))])),
                    ])),
                    ("required", .array([.string("name"), .string("when_to_use"), .string("procedure"), .string("specialists")])),
                ])
            ),
        ]
    }

    public static func run(call: APIToolCall, skills: SkillStore) async -> ToolOutcome {
        let args = AgentTools.arguments(of: call)
        guard call.function.name == "skill_save" else { return ToolOutcome(resultText: "Unknown skill tool.", succeeded: false) }
        let name = (args["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let whenToUse = (args["when_to_use"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let procedure = (args["procedure"]?.arrayValue ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let requested = (args["specialists"]?.arrayValue ?? []).compactMap(\.stringValue)
        let specialists = specialistNames.filter { name in requested.contains(where: { $0.lowercased() == name.lowercased() }) }
        let id = Skill.slug(name)
        guard !id.isEmpty, name.count <= 80 else { return ToolOutcome(resultText: "skill_save needs a name of at most 80 characters.", succeeded: false) }
        guard !whenToUse.isEmpty, whenToUse.count <= 600 else { return ToolOutcome(resultText: "skill_save needs when_to_use, at most 600 characters.", succeeded: false) }
        guard (1...8).contains(procedure.count), procedure.allSatisfy({ $0.count <= 400 }) else { return ToolOutcome(resultText: "skill_save needs one to eight procedure steps of at most 400 characters each.", succeeded: false) }
        guard (1...4).contains(specialists.count), specialists.contains(where: { $0 != "Judge" }) else {
            return ToolOutcome(resultText: "skill_save needs one to four specialists from: \(specialistNames.joined(separator: ", ")), and at least one that is not Judge.", succeeded: false)
        }
        let skill = Skill(id: id, name: name, whenToUse: whenToUse, procedure: procedure, specialists: specialists, origin: .ada, enabled: args["enabled"]?.boolValue ?? true)
        do {
            let saved = try await skills.save(skill)
            return ToolOutcome(resultText: "Saved skill \(saved.id) (\(saved.enabled ? "on" : "off")). It is used from the next message on.")
        } catch {
            return ToolOutcome(resultText: error.localizedDescription, succeeded: false)
        }
    }
}
