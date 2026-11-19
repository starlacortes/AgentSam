import XCTest
@testable import AgentSamCore

final class SkillsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let provider = ProviderConfig(id: "test", name: "Test", kind: .openAICompatible, baseURL: "http://localhost/v1", models: ["stub"], defaultModel: "stub")

    private func agent(_ name: String, role: AgentProfile.Role, prompt: String = "Do careful, focused work.") -> AgentProfile {
        AgentProfile(name: name, emoji: "•", title: "Specialist", role: role, systemPrompt: prompt, providerID: "test", model: "stub")
    }

    func testSlugKeepsLettersAndDigits() {
        XCTAssertEqual(Skill.slug("Weekly Ads Report"), "weekly-ads-report")
        XCTAssertEqual(Skill.slug("  Análisis de datos!! "), "analisis-de-datos")
        XCTAssertEqual(Skill.slug("***"), "")
    }

    func testBuiltInSkillsHaveUniqueIDsAndTeams() {
        XCTAssertEqual(Set(Skill.builtIns.map(\.id)).count, Skill.builtIns.count)
        XCTAssertEqual(Set(Skill.builtIns.map(\.teamID)).count, Skill.builtIns.count)
        XCTAssertFalse(Skill.builtIns.map(\.teamID).contains(ConversationEngine.soloTeamID))
    }

    func testMigrationConvertsCustomTeamsOnceAndSkipsStockSoloAndSkillTeams() async throws {
        let custom = Team(name: "Ad Ops", goal: "Watch ad spend.", agents: [agent("Ada", role: .coordinator), agent("Penny", role: .worker)])
        let starter = Team.starterTeam()
        let solo = ConversationEngine.soloTeam(coordinator: AgentProfile.rosterTemplates[0], language: "en")
        let skillTeam = Team(id: Skill.builtIns[0].teamID, name: "Research", agents: [agent("Ada", role: .coordinator), agent("Scout", role: .worker)])
        let empty = Team(name: "Just Ada", agents: [agent("Ada", role: .coordinator)])

        let skills = SkillStore(root: directory)
        let created = await skills.migrate(teams: [custom, starter, solo, skillTeam, empty], skipping: [ConversationEngine.soloTeamID])
        XCTAssertEqual(created.map(\.id), ["ad-ops"])
        XCTAssertEqual(created.first?.teamID, custom.id)
        XCTAssertEqual(created.first?.origin, .migratedTeam)
        XCTAssertTrue(created.first?.whenToUse.contains("Watch ad spend.") == true)

        // Running again, or after a reload from disk, changes nothing.
        let again = await skills.migrate(teams: [custom, starter], skipping: [])
        XCTAssertTrue(again.isEmpty)
        let reloaded = SkillStore(root: directory)
        let ids = await reloaded.all().map(\.id)
        XCTAssertEqual(ids, Skill.builtIns.map(\.id) + ["ad-ops"])
        let third = await reloaded.migrate(teams: [custom], skipping: [])
        XCTAssertTrue(third.isEmpty)
    }

    func testEditedStarterTeamIsKeptAsItsOwnSkill() async {
        var edited = Team.starterTeam()
        edited.agents[1].systemPrompt = "Only use primary sources."
        let skills = SkillStore(root: directory)
        let created = await skills.migrate(teams: [edited], skipping: [])
        XCTAssertEqual(created.count, 1)
    }

    func testMigratedNameThatClashesWithABuiltInGetsASuffix() async {
        let team = Team(name: "Research", agents: [agent("Ada", role: .coordinator), agent("Scout", role: .worker)])
        let skills = SkillStore(root: directory)
        let created = await skills.migrate(teams: [team], skipping: [])
        XCTAssertEqual(created.map(\.id), ["research-2"])
    }

    func testBuiltInSkillTeamUsesAdaAndFallsBackToHerProvider() throws {
        let ada = agent("Ada", role: .coordinator)
        let skill = try XCTUnwrap(Skill.builtIns.first { $0.id == "research" })
        let team = try XCTUnwrap(SkillTeams.team(for: skill, coordinator: ada, providers: [provider], hasKey: { _ in true }, saved: nil))
        XCTAssertEqual(team.id, skill.teamID)
        XCTAssertEqual(team.coordinator?.name, "Ada")
        XCTAssertTrue(team.coordinator?.systemPrompt.contains("SKILL: Research") == true)
        XCTAssertEqual(team.workers.map(\.name), ["Scout", "Quill"])
        XCTAssertEqual(team.verifier?.name, "Judge")
        // No Anthropic or DeepSeek provider is configured, so every specialist runs on Ada's.
        XCTAssertTrue(team.agents.allSatisfy { $0.providerID == "test" && $0.model == "stub" })
        XCTAssertEqual(team.toolScope, .readOnly)
    }

    func testMigratedSkillRunsItsSavedTeam() throws {
        let saved = Team(name: "Ad Ops", agents: [agent("Ada", role: .coordinator), agent("Penny", role: .worker)])
        let skill = Skill(id: "ad-ops", name: "Ad Ops", whenToUse: "Ads.", teamID: saved.id, origin: .migratedTeam)
        let team = SkillTeams.team(for: skill, coordinator: agent("Ada", role: .coordinator), providers: [provider], hasKey: { _ in true }, saved: saved)
        XCTAssertEqual(team, saved)
        XCTAssertNil(SkillTeams.team(for: skill, coordinator: agent("Ada", role: .coordinator), providers: [provider], hasKey: { _ in true }, saved: nil))
    }

    func testSkillSaveValidatesAndRefusesBuiltIns() async {
        let skills = SkillStore(root: directory)
        func call(_ json: String) -> APIToolCall {
            APIToolCall(id: "1", function: .init(name: "skill_save", arguments: json))
        }
        let saved = await SkillTools.run(call: call(#"{"name":"Weekly ads report","when_to_use":"Weekly Google Ads summaries.","procedure":["Pull last week's campaigns","Summarize changes"],"specialists":["Plot","Judge","Nobody"]}"#), skills: skills)
        XCTAssertTrue(saved.succeeded, saved.resultText)
        let skill = await skills.skill(id: "weekly-ads-report")
        XCTAssertEqual(skill?.specialists, ["Plot", "Judge"])
        XCTAssertEqual(skill?.origin, .ada)

        let onlyVerifier = await SkillTools.run(call: call(#"{"name":"Checks","when_to_use":"x","procedure":["a"],"specialists":["Judge"]}"#), skills: skills)
        XCTAssertFalse(onlyVerifier.succeeded)
        let builtIn = await SkillTools.run(call: call(#"{"name":"Research","when_to_use":"x","procedure":["a"],"specialists":["Scout"]}"#), skills: skills)
        XCTAssertFalse(builtIn.succeeded)
        let noSteps = await SkillTools.run(call: call(#"{"name":"Empty","when_to_use":"x","procedure":[],"specialists":["Scout"]}"#), skills: skills)
        XCTAssertFalse(noSteps.succeeded)

        // Updating keeps the skill's team, so its mission history stays linked.
        let firstTeam = skill?.teamID
        _ = await SkillTools.run(call: call(#"{"name":"Weekly ads report","when_to_use":"Weekly summaries.","procedure":["One step"],"specialists":["Plot"],"enabled":false}"#), skills: skills)
        let updated = await skills.skill(id: "weekly-ads-report")
        XCTAssertEqual(updated?.teamID, firstTeam)
        XCTAssertEqual(updated?.enabled, false)
        let enabledIDs = await skills.enabled().map(\.id)
        XCTAssertFalse(enabledIDs.contains("weekly-ads-report"))
    }

    func testUseSkillRunsTheSkillAsAMissionWithoutAnyTeamSetup() async throws {
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let research = try XCTUnwrap(Skill.builtIns.first { $0.id == "research" })
        actor Seen {
            var routing = ""
            var team: Team?
            func set(routing: String) { self.routing = routing }
            func set(team: Team) { self.team = team }
        }
        let seen = Seen()
        let root = directory!
        let missions = MissionEngine(store: store, keyRing: keys)
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, missions: missions, completion: { _, _, _, system, _, _ in
            if system.contains("Decide how to handle") {
                await seen.set(routing: system)
                return LLMReply(message: .assistant(#"{"action":"USE_SKILL","skillIDs":["research"],"rationale":"Looking into it"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("Here is what I found."), inputTokens: 0, outputTokens: 0, model: "stub")
        }, missionRunner: { team, objective, _, _, _ in
            await seen.set(team: team)
            let store = MissionStore(root: root)
            var mission = await store.createMission(team: team, objective: objective)
            mission.status = .completed
            mission.phase = .done
            mission.finalReport = "Findings"
            await store.saveMission(mission)
            return mission
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "What's new in solid-state batteries?", launchedBy: "Owner", language: "en")
        var result = try await conversations.get(id: conversation.id, ownerID: "owner")
        for _ in 0..<150 where result?.messages.last?.status == .running {
            try await Task.sleep(nanoseconds: 20_000_000)
            result = try await conversations.get(id: conversation.id, ownerID: "owner")
        }
        let last = try XCTUnwrap(result?.messages.last)
        XCTAssertEqual(last.text, "Here is what I found.")
        XCTAssertEqual(last.teamIDs, [research.teamID])
        XCTAssertEqual(last.missionIDs.count, 1)
        let routing = await seen.routing
        XCTAssertTrue(routing.contains("- research (Research): use when the user wants facts found"))
        XCTAssertFalse(routing.contains("SKILL: Research"))
        XCTAssertTrue(routing.contains("USE_SKILL"))
        XCTAssertFalse(routing.contains("PROPOSE_TEAM"))
        let team = await seen.team
        XCTAssertEqual(team?.id, research.teamID)
        XCTAssertTrue(team?.coordinator?.systemPrompt.contains("SKILL: Research") == true)
        // The skill's team is kept on disk so mission history can show who worked on it.
        let stored = await store.team(id: research.teamID)
        XCTAssertNotNil(stored)
        await engine.shutdown()
    }
}
