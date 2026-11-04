import XCTest
@testable import AgentSamCore

final class StructuredOutputTests: XCTestCase {
    // MARK: - Helpers

    private func makeTeam(workerNames: [String]) -> Team {
        let agents = workerNames.map { name in
            AgentProfile(
                name: name,
                emoji: "",
                title: "Worker",
                role: .worker,
                systemPrompt: "",
                providerID: "anthropic",
                model: "claude-sonnet-4-5"
            )
        }
        return Team(name: "Test Team", agents: agents)
    }

    private func planCall(arguments: String) -> APIToolCall {
        APIToolCall(id: "call_1", function: .init(name: "submit_plan", arguments: arguments))
    }

    private func reviewCall(arguments: String) -> APIToolCall {
        APIToolCall(id: "call_1", function: .init(name: "submit_review", arguments: arguments))
    }

    // MARK: - Plan decoding and validation

    func testPlanDecodesAndValidates() throws {
        let json = #"{"tasks":[{"agent":"Quill","goal":"Write a memo","deliverable":"memo.md"},{"agent":"Scout","goal":"Gather facts","deliverable":"facts.md"}]}"#
        let submission: StructuredOutput.PlanSubmission = try XCTUnwrap(StructuredOutput.decode(from: planCall(arguments: json)))
        let tasks = try StructuredOutput.plan(from: submission, team: makeTeam(workerNames: ["Quill", "Scout"]), maxTasks: 8).get()
        XCTAssertEqual(tasks.map(\.agentName), ["Quill", "Scout"])
        XCTAssertEqual(tasks.map(\.deliverable), ["memo.md", "facts.md"])
        XCTAssertEqual(tasks.map(\.id), [1, 2])
    }

    func testPlanResolvesFuzzyAgentNames() throws {
        let json = #"{"tasks":[{"agent":"quill (staff writer)","goal":"Write","deliverable":"memo.md"}]}"#
        let submission: StructuredOutput.PlanSubmission = try XCTUnwrap(StructuredOutput.decode(from: planCall(arguments: json)))
        let tasks = try StructuredOutput.plan(from: submission, team: makeTeam(workerNames: ["Quill"]), maxTasks: 8).get()
        XCTAssertEqual(tasks.first?.agentName, "Quill")
    }

    func testPlanSanitizesDeliverableNames() throws {
        let json = #"{"tasks":[{"agent":"Quill","goal":"Write","deliverable":"Research Notes"}]}"#
        let submission: StructuredOutput.PlanSubmission = try XCTUnwrap(StructuredOutput.decode(from: planCall(arguments: json)))
        let tasks = try StructuredOutput.plan(from: submission, team: makeTeam(workerNames: ["Quill"]), maxTasks: 8).get()
        XCTAssertEqual(tasks.first?.deliverable, "research-notes.md")
    }

    func testPlanCapsAtMaxTasks() throws {
        let json = #"{"tasks":[{"agent":"Quill","goal":"A","deliverable":"alpha.md"},{"agent":"Scout","goal":"B","deliverable":"beta.md"}]}"#
        let submission: StructuredOutput.PlanSubmission = try XCTUnwrap(StructuredOutput.decode(from: planCall(arguments: json)))
        let tasks = try StructuredOutput.plan(from: submission, team: makeTeam(workerNames: ["Quill", "Scout"]), maxTasks: 1).get()
        XCTAssertEqual(tasks.count, 1)
    }

    func testPlanRejectsUnreadableArguments() {
        XCTAssertNil(StructuredOutput.decode(from: planCall(arguments: "not json")) as StructuredOutput.PlanSubmission?)
    }

    func testPlanRejectsEmptyTaskList() {
        let submission = StructuredOutput.PlanSubmission(tasks: [])
        let outcome = StructuredOutput.plan(from: submission, team: makeTeam(workerNames: ["Quill"]), maxTasks: 8)
        assertFailure(outcome, contains: "no tasks")
    }

    func testPlanRejectsMissingGoal() {
        let submission = StructuredOutput.PlanSubmission(tasks: [
            .init(agent: "Quill", goal: nil, deliverable: "memo.md")
        ])
        let outcome = StructuredOutput.plan(from: submission, team: makeTeam(workerNames: ["Quill"]), maxTasks: 8)
        assertFailure(outcome, contains: "task 1")
    }

    func testPlanRejectsUnknownAgent() {
        let submission = StructuredOutput.PlanSubmission(tasks: [
            .init(agent: "Stranger", goal: "Write", deliverable: "memo.md")
        ])
        let outcome = StructuredOutput.plan(from: submission, team: makeTeam(workerNames: ["Quill"]), maxTasks: 8)
        assertFailure(outcome, contains: "Stranger")
    }

    func testPlanRejectsDuplicateAgentAssignment() {
        let submission = StructuredOutput.PlanSubmission(tasks: [
            .init(agent: "Quill", goal: "A", deliverable: "alpha.md"),
            .init(agent: "Quill", goal: "B", deliverable: "beta.md"),
        ])
        let outcome = StructuredOutput.plan(from: submission, team: makeTeam(workerNames: ["Quill"]), maxTasks: 8)
        assertFailure(outcome, contains: "more than one task")
    }

    func testPlanRejectsInvalidDeliverable() {
        let submission = StructuredOutput.PlanSubmission(tasks: [
            .init(agent: "Quill", goal: "Write", deliverable: "")
        ])
        let outcome = StructuredOutput.plan(from: submission, team: makeTeam(workerNames: ["Quill"]), maxTasks: 8)
        assertFailure(outcome, contains: "deliverable")
    }

    func testPlanRejectsDuplicateDeliverables() {
        let submission = StructuredOutput.PlanSubmission(tasks: [
            .init(agent: "Quill", goal: "A", deliverable: "notes.md"),
            .init(agent: "Scout", goal: "B", deliverable: "notes.md"),
        ])
        let outcome = StructuredOutput.plan(from: submission, team: makeTeam(workerNames: ["Quill", "Scout"]), maxTasks: 8)
        assertFailure(outcome, contains: "notes.md")
    }

    // MARK: - Review mapping

    func testReviewMapsVerdictAndFindings() {
        let json = #"{"verdict":"concerns","findings":[{"level":"pass","area":"accuracy","detail":"numbers check out"},{"level":"fail","area":"sources","detail":"links are dead"}]}"#
        let submission: StructuredOutput.ReviewSubmission? = StructuredOutput.decode(from: reviewCall(arguments: json))
        guard let submission else { return XCTFail("expected a decoded submission") }
        let review = StructuredOutput.review(from: submission)
        XCTAssertEqual(review.verdict, .concerns)
        XCTAssertEqual(review.findings.map(\.level), [.pass, .fail])
        XCTAssertEqual(review.findings.map(\.check), ["review", "review"])
        XCTAssertEqual(review.findings.first?.detail, "accuracy: numbers check out")
    }

    func testReviewAcceptsCleanVerdictWithNoFindings() {
        let json = #"{"verdict":"clean","findings":[]}"#
        let submission: StructuredOutput.ReviewSubmission? = StructuredOutput.decode(from: reviewCall(arguments: json))
        guard let submission else { return XCTFail("expected a decoded submission") }
        let review = StructuredOutput.review(from: submission)
        XCTAssertEqual(review.verdict, .clean)
        XCTAssertTrue(review.findings.isEmpty)
    }

    func testReviewInfersVerdictFromWorstFinding() {
        let json = #"{"findings":[{"level":"concern","detail":"minor"}]}"#
        let submission: StructuredOutput.ReviewSubmission? = StructuredOutput.decode(from: reviewCall(arguments: json))
        guard let submission else { return XCTFail("expected a decoded submission") }
        let review = StructuredOutput.review(from: submission)
        XCTAssertEqual(review.verdict, .concerns)
    }

    func testReviewSkipsUnknownLevelsAndVerdicts() {
        let json = #"{"verdict":"meh","findings":[{"level":"super","detail":"x"}]}"#
        let submission: StructuredOutput.ReviewSubmission? = StructuredOutput.decode(from: reviewCall(arguments: json))
        guard let submission else { return XCTFail("expected a decoded submission") }
        let review = StructuredOutput.review(from: submission)
        XCTAssertEqual(review.verdict, .unverified)
        XCTAssertTrue(review.findings.isEmpty)
    }

    func testReviewCapsFindingsAtEight() {
        let findings = (0..<10).map { "{\"level\":\"pass\",\"detail\":\"f\($0)\"}" }.joined(separator: ",")
        let json = #"{"verdict":"clean","findings":[\#(findings)]}"#
        let submission: StructuredOutput.ReviewSubmission? = StructuredOutput.decode(from: reviewCall(arguments: json))
        guard let submission else { return XCTFail("expected a decoded submission") }
        let review = StructuredOutput.review(from: submission)
        XCTAssertEqual(review.findings.count, 8)
    }

    // MARK: - Tool schemas

    func testSubmissionToolSchemasAreValidJSONSchemas() throws {
        let encoder = JSONEncoder()
        for tool in [AgentTools.submitPlanTool, AgentTools.submitReviewTool] {
            let decoded = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(tool))
            let params = decoded.objectValue?["function"]?.objectValue?["parameters"]
            guard let params = params?.objectValue else {
                return XCTFail("\(tool.function.name) has no parameters object")
            }
            XCTAssertEqual(params["type"]?.stringValue, "object", tool.function.name)
            XCTAssertNotNil(params["properties"]?.objectValue, tool.function.name)
            guard case .array(let required)? = params["required"] else {
                return XCTFail("\(tool.function.name) has no required array")
            }
            XCTAssertFalse(required.isEmpty, tool.function.name)
        }
    }

    // MARK: - Assertion helper

    private func assertFailure(
        _ outcome: Result<[TaskPlanItem], StructuredOutput.PlanValidationError>,
        contains expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let error) = outcome else {
            return XCTFail("Expected failure containing \"\(expected)\", got success", file: file, line: line)
        }
        XCTAssertTrue(
            error.reason.contains(expected),
            "Expected reason containing \"\(expected)\", got \"\(error.reason)\"",
            file: file,
            line: line
        )
    }
}
