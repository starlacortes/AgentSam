import XCTest
@testable import AgentSamCore

/// The replay set itself: that it loads, that every case asks for things that exist, and that the
/// scorer reads a first step the way the report claims. None of this calls a model.
final class PromptReplayTests: XCTestCase {
    func testTheBuiltInSetLoadsAndIsBigEnough() throws {
        let cases = try PromptReplay.builtInCases()
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "Case IDs must be unique.")
        for replay in cases {
            XCTAssertFalse(replay.about.isEmpty, replay.id)
            XCTAssertFalse(replay.message.isEmpty, replay.id)
            XCTAssertTrue(["en", "es"].contains(replay.language), replay.id)
            XCTAssertNotEqual(replay.history.last?.role, "user", "\(replay.id): history ends on Ada's turn; the new message is separate.")
        }
        // Every dimension the report adds up has at least one case behind it.
        var seen = Set<PromptReplay.Dimension>()
        for replay in cases {
            let empty = PromptReplay.score(replay, reply: .assistant(""))
            seen.formUnion(empty.map(\.dimension))
        }
        XCTAssertEqual(seen, Set(PromptReplay.Dimension.allCases))
    }

    func testEveryExpectedToolIsOfferedInItsCase() throws {
        for replay in try PromptReplay.builtInCases() {
            // What the model is sent for this case, with its history (held tools are not sent).
            let offered = Set(PromptReplay.request(for: replay).tools.map(\.function.name))
            // One of the tools Ada may call has to be on offer. A tool she must not call may be absent.
            if let any = replay.expect.callsAny {
                XCTAssertTrue(any.contains(where: offered.contains), "\(replay.id) expects one of \(any), which this setup does not send.")
            }
            for name in replay.expect.toolNames {
                XCTAssertNotNil(ToolCatalog.spec(name), "\(replay.id) names an unknown tool: \(name)")
            }
        }
    }

    func testARequestIsWhatTheServerSendsAndIsStable() throws {
        let cases = try PromptReplay.builtInCases()
        let quick = try XCTUnwrap(cases.first { $0.id == "quick-fact" })
        let request = PromptReplay.request(for: quick)
        XCTAssertTrue(request.system.contains("You are Ada"))
        XCTAssertTrue(request.tools.contains { $0.function.name == "delegate" })
        XCTAssertTrue(request.tools.contains { $0.function.name == "start_task" })
        XCTAssertEqual(request.messages.count, 1)
        let turn = try XCTUnwrap(request.messages.last?.content)
        XCTAssertTrue(turn.hasSuffix("<user_message>\nWhat's the capital of Australia?\n</user_message>"), turn)
        XCTAssertTrue(turn.contains("Person: Sam"))
        // The same case builds the same bytes twice, so two runs differ only by prompt and model.
        let again = PromptReplay.request(for: quick)
        XCTAssertEqual(request.system, again.system)
        XCTAssertEqual(request.messages, again.messages)
        XCTAssertEqual(request.tools, again.tools)
        // Cases with the same setup and language share the system prompt and tools, which is what
        // lets a provider serve them from its prompt cache.
        let rewrite = try XCTUnwrap(cases.first { $0.id == "small-task-stays-direct" })
        XCTAssertEqual(PromptReplay.request(for: rewrite).system, request.system)
        XCTAssertEqual(PromptReplay.request(for: rewrite).tools, request.tools)
        // Earlier turns ride as real messages.
        let followUp = try XCTUnwrap(cases.first { $0.id == "follow-up-from-history" })
        XCTAssertEqual(PromptReplay.request(for: followUp).messages.map(\.role), ["user", "assistant", "user"])
        let sizes = request.sizes
        XCTAssertGreaterThan(sizes.tools, 1_000)
        XCTAssertGreaterThan(sizes.system, 1_000)
        XCTAssertEqual(sizes.history, 0)
    }

    private func call(_ name: String) -> APIMessage {
        APIMessage(role: "assistant", content: nil, tool_calls: [APIToolCall(id: "1", function: .init(name: name, arguments: "{}"))])
    }

    func testScoringToolChoiceAndDelegation() {
        let replay = PromptReplay.Case(id: "t", about: "t", message: "m", expect: .init(callsAny: ["gmail_search"], callsNone: ["delegate", "start_task", "web_search"]))
        let good = PromptReplay.score(replay, reply: call("gmail_search"))
        XCTAssertEqual(good.map(\.dimension), [.tools, .delegation, .tools])
        XCTAssertTrue(good.allSatisfy(\.passed))
        let delegated = PromptReplay.score(replay, reply: call("delegate"))
        XCTAssertEqual(delegated.filter { !$0.passed }.map(\.dimension), [.tools, .delegation])
        let answered = PromptReplay.score(replay, reply: .assistant("Yes, she did."))
        XCTAssertEqual(answered.filter { !$0.passed }.map(\.dimension), [.tools])
        // Expecting a hand-off is a delegation check.
        let big = PromptReplay.Case(id: "b", about: "b", message: "m", expect: .init(callsAny: ["start_task", "delegate"]))
        XCTAssertEqual(PromptReplay.score(big, reply: call("start_task")), [.init(dimension: .delegation, passed: true, detail: "expected one of start_task, delegate; called start_task")])
        XCTAssertFalse(PromptReplay.score(big, reply: .assistant("Here is the report…"))[0].passed)
    }

    func testScoringATextAnswer() {
        let replay = PromptReplay.Case(id: "t", about: "t", message: "m", expect: .init(noTools: true, maxWords: 5, mentionsAny: ["Canberra"], mentionsNone: ["I sent"], language: "en", asksQuestion: false))
        let good = PromptReplay.score(replay, reply: .assistant("It is Canberra.\n\n```suggestions\nAnd the largest city?\n```"))
        XCTAssertEqual(good.map(\.dimension), [.tools, .length, .truth, .truth, .language, .clarify])
        XCTAssertTrue(good.allSatisfy(\.passed), "\(good)")
        let bad = PromptReplay.score(replay, reply: .assistant("I sent the letter to Sydney, which is the capital, is that what you wanted?"))
        XCTAssertEqual(bad.filter { !$0.passed }.map(\.dimension), [.length, .truth, .truth, .clarify])
        // Calling a tool when a text answer was expected fails the text checks too; only "says
        // nothing forbidden" still holds, because nothing was said.
        let called = PromptReplay.score(replay, reply: call("web_search"))
        XCTAssertEqual(called.filter(\.passed).map(\.detail), ["makes none of the forbidden claims"])
        // Without noTools, a tool call simply has no text to score yet.
        let open = PromptReplay.Case(id: "o", about: "o", message: "m", expect: .init(callsNone: ["delegate"], maxWords: 5))
        XCTAssertEqual(PromptReplay.score(open, reply: call("web_search")).map(\.dimension), [.delegation])
        // Language: Spanish expected, English given.
        let spanish = PromptReplay.Case(id: "s", about: "s", language: "es", message: "Hola", expect: .init(language: "es"))
        XCTAssertTrue(PromptReplay.score(spanish, reply: .assistant("¡Hola! Estoy muy bien, gracias. ¿En qué te ayudo?"))[0].passed)
        XCTAssertFalse(PromptReplay.score(spanish, reply: .assistant("Hello! I am doing well, thank you. What can I do for you?"))[0].passed)
    }

    func testTheReportAddsUpByDimension() {
        let outcomes = [
            PromptReplay.Outcome(caseID: "a", about: "First", toolCalls: ["gmail_search"], text: "", checks: [.init(dimension: .tools, passed: true, detail: "ok")], inputTokens: 1_000, cachedInputTokens: 0, outputTokens: 20, seconds: 1.2, error: nil),
            PromptReplay.Outcome(caseID: "b", about: "Second", toolCalls: [], text: "A long answer", checks: [.init(dimension: .length, passed: false, detail: "90 words; limit 40"), .init(dimension: .tools, passed: true, detail: "ok")], inputTokens: 1_000, cachedInputTokens: 800, outputTokens: 90, seconds: 2, error: nil),
            PromptReplay.Outcome(caseID: "c", about: "Third", toolCalls: [], text: "", checks: [], inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, seconds: 0.1, error: "HTTP 401"),
        ]
        let report = PromptReplay.report(outcomes: outcomes, model: "deepseek-v4-pro", label: "baseline")
        XCTAssertTrue(report.contains("# Ada replay report: baseline"))
        XCTAssertTrue(report.contains("Cases passed: 1 of 3 (1 model call failed)"), report)
        XCTAssertTrue(report.contains("Checks passed: 2 of 3 (67%)"), report)
        XCTAssertTrue(report.contains("2000 in (800 from cache, 40%), 110 out"), report)
        XCTAssertTrue(report.contains("| tools | 2 (100%) | 2 |"), report)
        XCTAssertTrue(report.contains("| length | 0 (0%) | 1 |"), report)
        XCTAssertTrue(report.contains("| b | FAIL | text, 3 words |"), report)
        XCTAssertTrue(report.contains("- length: 90 words; limit 40"), report)
        XCTAssertTrue(report.contains("- Model call failed: HTTP 401"), report)
        XCTAssertFalse(PromptReplay.promptFingerprint().isEmpty)
    }

    /// The live run: replays the set against a real model and writes the report. It only runs when
    /// a key is given (`ADA_REPLAY_KEY`), so the normal test run never calls a provider.
    ///
    ///     ADA_REPLAY_KEY=sk-… swift test --filter PromptReplayTests/testLiveReplay
    ///
    /// Optional: `ADA_REPLAY_MODEL` (default deepseek-v4-pro), `ADA_REPLAY_BASE_URL` (default
    /// DeepSeek's API; an Anthropic URL selects the Anthropic client), `ADA_REPLAY_LABEL`,
    /// `ADA_REPLAY_ONLY` (comma-separated case IDs) and `ADA_REPLAY_REPORT` (a file to write).
    func testLiveReplay() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let key = env["ADA_REPLAY_KEY"], !key.isEmpty else {
            throw XCTSkip("Set ADA_REPLAY_KEY to replay the set against a real model.")
        }
        let model = env["ADA_REPLAY_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "deepseek-v4-pro"
        let baseURL = env["ADA_REPLAY_BASE_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "https://api.deepseek.com/v1"
        let provider = ProviderConfig(id: "replay", name: "Replay", kind: baseURL.contains("anthropic.com") ? .anthropic : .openAICompatible, baseURL: baseURL, models: [model], defaultModel: model)
        var cases = try PromptReplay.builtInCases()
        if let only = env["ADA_REPLAY_ONLY"], !only.isEmpty {
            let ids = Set(only.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            cases = cases.filter { ids.contains($0.id) }
        }
        let outcomes = await PromptReplay.run(cases: cases, provider: provider, key: key, model: model) { outcome in
            print("replay \(outcome.caseID): \(outcome.passed ? "pass" : "FAIL")")
        }
        let report = PromptReplay.report(outcomes: outcomes, model: model, label: env["ADA_REPLAY_LABEL"] ?? "")
        print(report)
        if let path = env["ADA_REPLAY_REPORT"], !path.isEmpty {
            try Data(report.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        // A low score is a finding, not a broken build. Only a run where no call got through fails.
        XCTAssertTrue(outcomes.contains { $0.error == nil }, "No model call succeeded: \(outcomes.first?.error ?? "no cases")")
    }
}
