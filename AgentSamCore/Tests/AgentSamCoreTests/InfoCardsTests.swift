import XCTest
@testable import AgentSamCore

final class InfoCardsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-cards-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func args(_ json: String) -> [String: JSONValue] {
        AgentTools.arguments(of: APIToolCall(id: "c", function: .init(name: InfoCardTools.toolName, arguments: json)))
    }

    private func card(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> InfoCard {
        switch InfoCardTools.card(from: args(json)) {
        case .success(let card): return card
        case .failure(let error):
            XCTFail(error.message, file: file, line: line)
            throw error
        }
    }

    private func rejected(_ json: String) -> String? {
        if case .failure(let error) = InfoCardTools.card(from: args(json)) { return error.message }
        return nil
    }

    func testEveryTemplateBuildsFromItsFields() throws {
        let stats = try card(#"{"template":"stats","title":"November","items":[{"label":"Revenue","value":"$4,210","detail":"+12% vs Oct","tone":"good"},{"label":"Orders","number":38,"tone":"shiny"}]}"#)
        XCTAssertEqual(stats.items.map(\.value), ["$4,210", "38"])
        XCTAssertEqual(stats.items.map(\.tone), ["good", nil], "unknown tones are dropped")

        let comparison = try card(#"{"template":"comparison","columns":["Basic","Pro"],"rows":[{"label":"Price","values":["$10","$25"]},{"label":"Seats","values":[1,5]}],"highlight":1}"#)
        XCTAssertEqual(comparison.columns, ["Basic", "Pro"])
        XCTAssertEqual(comparison.rows[1].values, ["1", "5"])
        XCTAssertEqual(comparison.highlight, 1)

        let ranking = try card(#"{"template":"ranking","unit":"visits","items":[{"label":"Home","value":"1,200"},{"label":"Pricing","value":"800"}]}"#)
        XCTAssertEqual(ranking.items.map(\.number), [1200, 800], "values that are numbers draw bars")
        let mixed = try card(#"{"template":"ranking","items":[{"label":"A","number":3},{"label":"B","value":"fast"}]}"#)
        XCTAssertEqual(mixed.items.map(\.number), [nil, nil], "no bars unless every entry has a number")

        let chart = try card(#"{"template":"chart","chart":"line","items":[{"label":"Mon","number":3},{"label":"Tue","value":"5"}]}"#)
        XCTAssertEqual(chart.chart, "line")
        XCTAssertEqual(chart.items.map(\.number), [3, 5])
        XCTAssertEqual(try card(#"{"template":"chart","chart":"pie","items":[{"label":"a","number":1},{"label":"b","number":2}]}"#).chart, "bar")

        let steps = try card(#"{"template":"steps","items":[{"label":"Plan","state":"done"},{"label":"Build","state":"current"},{"label":"Ship","state":"later"}]}"#)
        XCTAssertEqual(steps.items.map(\.state), ["done", "current", "todo"])

        let timeline = try card(#"{"template":"timeline","items":[{"when":"Mon 3 Dec","label":"Kick-off"}]}"#)
        XCTAssertEqual(timeline.items.first?.when, "Mon 3 Dec")

        let summary = try card(#"{"template":"summary","items":[{"label":"Domain","value":"example.com"},{"label":"Renews","value":"12 Jan"}]}"#)
        XCTAssertEqual(summary.items.count, 2)

        let callout = try card(#"{"template":"callout","tone":"warning","text":"The card expires\n tomorrow."}"#)
        XCTAssertEqual(callout.tone, "warning")
        XCTAssertEqual(callout.text, "The card expires tomorrow.", "text is one plain line")
        XCTAssertEqual(try card(#"{"template":"callout","tone":"loud","text":"x"}"#).tone, "info")
    }

    func testBadCardsSayWhatToFix() {
        XCTAssertTrue(rejected(#"{"template":"pie"}"#)?.contains("Pick a template") == true)
        XCTAssertTrue(rejected(#"{"template":"stats","items":[]}"#)?.contains("at least 1") == true)
        XCTAssertTrue(rejected(#"{"template":"stats","items":[{"label":"No value"}]}"#)?.contains("needs a value") == true)
        let seven = (0..<7).map { #"{"label":"s\#($0)","value":"1"}"# }.joined(separator: ",")
        XCTAssertTrue(rejected(#"{"template":"stats","items":[\#(seven)]}"#)?.contains("at most 6") == true)
        XCTAssertTrue(rejected(#"{"template":"comparison","columns":["Only"],"rows":[{"label":"x","values":["1"]}]}"#)?.contains("2 to 4 columns") == true)
        XCTAssertTrue(rejected(#"{"template":"comparison","columns":["A","B"],"rows":[{"label":"x","values":["1"]}]}"#)?.contains("exactly 2 values") == true)
        XCTAssertTrue(rejected(#"{"template":"chart","items":[{"label":"a","number":1},{"label":"b","value":"n/a"}]}"#)?.contains("needs a number") == true)
        XCTAssertTrue(rejected(#"{"template":"timeline","items":[{"label":"no date"}]}"#) != nil)
        XCTAssertTrue(rejected(#"{"template":"callout"}"#)?.contains("needs text") == true)
        XCTAssertTrue(rejected(#"{"template":"callout"}"#)?.hasPrefix("No card was shown.") == true)
    }

    func testTextIsClippedAndStaysPlain() throws {
        let long = String(repeating: "x", count: 300)
        let built = try card(#"{"template":"summary","title":"\#(long)","items":[{"label":"<b>Bold</b>","value":"\#(long)"}]}"#)
        XCTAssertEqual(built.title?.count, 80)
        XCTAssertTrue(built.title?.hasSuffix("…") == true)
        XCTAssertEqual(built.items[0].value?.count, 40)
        // Kept as text; the app never renders it as markup.
        XCTAssertEqual(built.items[0].label, "<b>Bold</b>")
    }

    func testCardsRoundTripAndOlderMessagesDecodeWithout() throws {
        let message = ConversationMessage(role: .assistant, text: "Here you go.", cards: [try card(#"{"template":"stats","items":[{"label":"A","value":"1"}]}"#)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ConversationMessage.self, from: try encoder.encode(message))
        XCTAssertEqual(decoded.cards, message.cards)

        let old = #"{"id":"\#(UUID().uuidString)","role":"assistant","text":"hi","createdAt":"2026-01-01T00:00:00Z","status":"complete","missionIDs":[],"teamIDs":[],"activity":[]}"#
        XCTAssertTrue(try decoder.decode(ConversationMessage.self, from: Data(old.utf8)).cards.isEmpty)
        // A template this build does not know still decodes; the app skips it.
        let future = #"{"template":"map","items":[{"label":"x"}]}"#
        XCTAssertEqual(try decoder.decode(InfoCard.self, from: Data(future.utf8)).template, "map")
    }

    func testOfferedOnlyInChatRepliesAndNeverToSpecialists() {
        let without = OfferedTools.direct(connectorTools: [], hasLinkedMissions: false, hasExtendedAccess: false)
        XCTAssertNil(without.family(of: InfoCardTools.toolName))
        let with = OfferedTools.direct(connectorTools: [], hasLinkedMissions: false, hasExtendedAccess: false, cards: true)
        XCTAssertEqual(with.family(of: InfoCardTools.toolName), .card)
        // Held until Ada has used a tool in the reply, so questions and refusals don't grow cards.
        XCTAssertEqual(with.visibility(of: InfoCardTools.toolName), .held)
        XCTAssertFalse(with.definitions.contains { $0.function.name == InfoCardTools.toolName })
        XCTAssertTrue(with.revealing(.card).definitions.last?.function.name == InfoCardTools.toolName, "last, so the tools before it stay the same")
        let open = OfferedTools.direct(connectorTools: [], hasLinkedMissions: false, hasExtendedAccess: false, cards: true, cardsOpen: true)
        XCTAssertEqual(open.visibility(of: InfoCardTools.toolName), .sent)
        let shown = ConversationMessage(role: .assistant, text: "x", cards: [InfoCard(template: "callout", text: "x")])
        XCTAssertTrue(ConversationEngine.cardsInUse(history: [shown]))
        XCTAssertFalse(ConversationEngine.cardsInUse(history: [ConversationMessage(role: .assistant, text: "x")]))
        XCTAssertNotNil(ToolCatalog.spec(InfoCardTools.toolName))
        XCTAssertFalse(HelperTools.allows(name: InfoCardTools.toolName, family: .card, groups: Set(HelperTools.Group.allCases)))
    }

    func testAdaShowsACardThatStaysOnHerReply() async throws {
        let provider = ProviderConfig(id: "test", name: "Test", kind: .openAICompatible, baseURL: "http://localhost/v1", models: ["stub"], defaultModel: "stub")
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let offeredNames = LockedCardStrings()
        let results = LockedCardStrings()
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, routing: false, completion: { _, _, _, system, messages, tools in
            guard let tools else { return LLMReply(message: .assistant("Done."), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            offeredNames.append(tools.map(\.function.name).joined(separator: ","))
            if messages.last?.role == "tool" {
                results.append(contentsOf: messages.filter { $0.role == "tool" }.compactMap(\.content))
                return LLMReply(message: .assistant("Revenue is up 12% this month."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            let good = #"{"template":"stats","title":"This month","items":[{"label":"Revenue","value":"$4,210","detail":"+12%","tone":"good"}]}"#
            let bad = #"{"template":"comparison","columns":["A"]}"#
            return LLMReply(message: APIMessage(role: "assistant", tool_calls: [
                APIToolCall(id: "c1", function: .init(name: "show_card", arguments: good)),
                APIToolCall(id: "c2", function: .init(name: "show_card", arguments: bad)),
                APIToolCall(id: "c3", function: .init(name: "show_card", arguments: good)),
                APIToolCall(id: "c4", function: .init(name: "show_card", arguments: good)),
            ]), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "How is revenue?", launchedBy: "Owner", language: "en")
        var finished: Conversation?
        for _ in 0..<150 {
            if let current = try await conversations.get(id: conversation.id, ownerID: "owner"), current.messages.last?.status != .running { finished = current; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let reply = try XCTUnwrap(finished?.messages.last)
        XCTAssertEqual(reply.status, .complete)
        XCTAssertEqual(reply.text, "Revenue is up 12% this month.")
        // The second call is invalid (nothing shown, still counts), the fourth is over the limit of 3.
        XCTAssertEqual(reply.cards.count, 2)
        XCTAssertEqual(reply.cards.first?.title, "This month")
        XCTAssertEqual(offeredNames.values.first?.contains("show_card"), false, "held on the first call")
        XCTAssertEqual(offeredNames.values.dropFirst().first?.contains("show_card"), true, "sent once a tool ran")
        XCTAssertTrue(results.values.contains { $0.contains("is shown below your reply text") })
        XCTAssertTrue(results.values.contains { $0.hasPrefix("No card was shown.") })
        XCTAssertTrue(results.values.contains { $0.contains("Card limit reached") })
        XCTAssertEqual(reply.toolLog.first, "show_card stats “This month” (1 item) → ok")
        await engine.shutdown()
    }
}

final class LockedCardStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: String) { lock.lock(); stored.append(value); lock.unlock() }
    func append(contentsOf values: [String]) { lock.lock(); stored.append(contentsOf: values); lock.unlock() }
}
