import XCTest
@testable import AgentSamCore

final class L10nTests: XCTestCase {
    func testExplicitLanguageLookup() {
        XCTAssertEqual(CoreL10n.t("role.coordinator", lang: "en"), "Coordination")
        XCTAssertEqual(CoreL10n.t("role.coordinator", lang: "es"), "Coordinación")
        XCTAssertEqual(CoreL10n.t("phase.working", lang: "es"), "Agentes trabajando")
    }

    func testMissionLanguageResolution() {
        let team = Team.starterTeam()
        let spanish = Mission(teamID: team.id, teamName: team.name, objective: "Prueba", outputLanguage: "es")
        let english = Mission(teamID: team.id, teamName: team.name, objective: "Test")
        XCTAssertEqual(CoreL10n.language(for: spanish), "es")
        XCTAssertEqual(CoreL10n.language(for: english), "en")
    }

    func testSpanishMissionGetsSpanishPrompts() {
        let team = Team.starterTeam()
        let mission = Mission(teamID: team.id, teamName: team.name, objective: "Investiga los paneles solares", outputLanguage: "es")
        let builder = PromptBuilder(store: PromptStore(builtins: PromptStore.builtins))
        let plan = builder.planPrompt(mission: mission, team: team, maxTasks: team.workers.count)
        XCTAssertTrue(plan.contains("OBJETIVO DE LA MISIÓN"), "plan should be in Spanish: \(plan)")
        XCTAssertTrue(plan.contains("submit_plan"), "structured tool names must stay unchanged")

        let worker = team.workers[0]
        let system = builder.workerSystem(agent: worker, team: team, mission: mission)
        XCTAssertTrue(system.contains("IDIOMA DE TRABAJO"), "worker system should carry the Spanish language instruction")

        let coordinator = builder.coordinatorSystem(agent: team.coordinator ?? team.agents[0], team: team, mission: mission)
        XCTAssertTrue(coordinator.contains("IDIOMA DE TRABAJO"))
    }

    func testEnglishMissionKeepsEnglishPrompts() {
        let team = Team.starterTeam()
        let mission = Mission(teamID: team.id, teamName: team.name, objective: "Research solar panels")
        let builder = PromptBuilder(store: PromptStore(builtins: PromptStore.builtins))
        let plan = builder.planPrompt(mission: mission, team: team, maxTasks: team.workers.count)
        XCTAssertTrue(plan.contains("MISSION OBJECTIVE"))
        XCTAssertFalse(plan.contains("IDIOMA DE TRABAJO"))
    }

    func testVerificationMarkdownLanguage() {
        var report = VerificationReport(verdict: .clean, findings: [])
        XCTAssertTrue(report.markdown(language: "es").contains("Informe de verificación"))
        XCTAssertTrue(report.markdown(language: "es").contains("Veredicto:"))
        XCTAssertTrue(report.markdown(language: "en").contains("Verification report"))
        report.findings.append(VerificationReport.Finding(level: .pass, check: "x", detail: "y"))
        XCTAssertTrue(report.markdown(language: "es").contains("PASS"))
    }
}
