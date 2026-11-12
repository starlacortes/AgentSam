import XCTest
@testable import AgentSamCore

/// Locks in the behavior of the legacy text parsers, which remain the
/// fallback when a model ignores the structured submission tools.
final class ParsersTests: XCTestCase {
    // MARK: - PlanParser

    func testPlanParserParsesTaskBlocks() {
        let text = """
        Here is the plan:

        TASK 1
        Agent: Quill
        Goal: Write a memo
        Deliverable: memo.md

        TASK 2
        Agent: Scout
        Goal: Gather facts
        Deliverable: research notes
        """
        let plan = PlanParser.parse(text)
        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan[0].agentName, "Quill")
        XCTAssertEqual(plan[0].deliverable, "memo.md")
        // Deliverables are sanitized even in the fallback path.
        XCTAssertEqual(plan[1].deliverable, "research-notes.md")
        XCTAssertEqual(plan.map(\.id), [1, 2])
    }

    func testPlanParserSkipsIncompleteTasks() {
        let text = """
        TASK 1
        Agent: Quill
        Goal:

        TASK 2
        Goal: no agent here
        """
        XCTAssertTrue(PlanParser.parse(text).isEmpty)
    }

    func testPlanParserDefaultsMissingDeliverable() {
        let text = """
        TASK 1
        Agent: Quill
        Goal: Write something
        """
        let plan = PlanParser.parse(text)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan[0].deliverable, "task-1.md")
    }

    func testPlanParserIgnoresGarbage() {
        XCTAssertTrue(PlanParser.parse("Just some prose, no task blocks.").isEmpty)
    }

    func testSanitizedFilenameNeutralizesTraversal() {
        XCTAssertEqual(PlanParser.sanitizedFilename("../evil.md"), "..-evil.md")
        XCTAssertNil(PlanParser.sanitizedFilename("a.md"))
        XCTAssertEqual(PlanParser.sanitizedFilename("Notes"), "notes.md")
    }

    // MARK: - VerifierParser

    func testVerifierParserParsesFindingsAndVerdict() {
        let text = """
        - PASS — accuracy: numbers check out
        - CONCERN — sources: some links are dead
        VERDICT: CONCERNS
        """
        let (findings, verdict) = VerifierParser.parse(text)
        XCTAssertEqual(findings.map(\.level), [.pass, .concern])
        XCTAssertEqual(findings.first?.detail, "accuracy: numbers check out")
        XCTAssertEqual(verdict, .concerns)
    }

    func testVerifierParserInfersVerdictFromFindings() {
        let (findings, verdict) = VerifierParser.parse("- FAIL — coverage: half the brief untouched")
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(verdict, .failed)
    }

    func testVerifierParserIgnoresGarbage() {
        let (findings, verdict) = VerifierParser.parse("I looked at everything and it all seemed fine.")
        XCTAssertTrue(findings.isEmpty)
        XCTAssertEqual(verdict, .unverified)
    }
}
