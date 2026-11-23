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

    func testVerificationMarkdownLanguage() {
        var report = VerificationReport(verdict: .clean, findings: [])
        XCTAssertTrue(report.markdown(language: "es").contains("Informe de verificación"))
        XCTAssertTrue(report.markdown(language: "es").contains("Veredicto:"))
        XCTAssertTrue(report.markdown(language: "en").contains("Verification report"))
        report.findings.append(VerificationReport.Finding(level: .pass, check: "x", detail: "y"))
        XCTAssertTrue(report.markdown(language: "es").contains("PASS"))
    }
}
