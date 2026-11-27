import XCTest
@testable import AgentSamCore

final class ChoiceCardsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-choices-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func args(_ json: String) -> [String: JSONValue] {
        AgentTools.arguments(of: APIToolCall(id: "c", function: .init(name: ChoiceCardTools.toolName, arguments: json)))
    }

    private func card(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> ChoiceCard {
        switch ChoiceCardTools.card(from: args(json)) {
        case .success(let card): return card
        case .failure(let error):
            XCTFail(error.message, file: file, line: line)
            throw error
        }
    }

    private func rejected(_ json: String) -> String? {
        if case .failure(let error) = ChoiceCardTools.card(from: args(json)) { return error.message }
        return nil
    }

    static let trip = #"""
    {"title":"Team offsite","questions":[
      {"id":"where","question":"Where should it be?","options":[{"label":"Lisbon","detail":"Sunny, two hours away"},{"label":"Online"},"Madrid"]},
      {"id":"hotel","question":"Which hotel area?","options":["Old town","By the beach"],"show_if":{"question":"where","any_of":["lisbon","Madrid"]}},
      {"question":"What matters most?","options":["Team building","Planning","Rest"],"multiple":true,"other":true}
    ]}
    """#

    func testBuildsQuestionsOptionsAndBranches() throws {
        let built = try card(Self.trip)
        XCTAssertEqual(built.title, "Team offsite")
        XCTAssertEqual(built.state, .pending)
        XCTAssertEqual(built.questions.map(\.id), ["where", "hotel", "q3"])
        XCTAssertEqual(built.questions[0].options.map(\.label), ["Lisbon", "Online", "Madrid"], "options may be plain strings")
        XCTAssertEqual(built.questions[0].options[0].detail, "Sunny, two hours away")
        XCTAssertEqual(built.questions[1].showIf, ChoiceCard.Condition(question: "where", anyOf: ["Lisbon", "Madrid"]), "labels are matched without case")
        XCTAssertTrue(built.questions[2].multiple)
        XCTAssertTrue(built.questions[2].other)
        // The branch shows only after one of its answers.
        XCTAssertEqual(built.visibleQuestions(picked: [:]).map(\.id), ["where", "q3"])
        XCTAssertEqual(built.visibleQuestions(picked: ["where": ["Online"]]).map(\.id), ["where", "q3"])
        XCTAssertEqual(built.visibleQuestions(picked: ["where": ["Lisbon"]]).map(\.id), ["where", "hotel", "q3"])

        // One question at the top level is a one-question card; show_if may name a question by number.
        let single = try card(#"{"question":"Which plan?","options":["Basic","Pro"]}"#)
        XCTAssertEqual(single.questions.count, 1)
        let numbered = try card(#"{"questions":[{"question":"A?","options":["x","y"]},{"question":"B?","options":["1","2"],"show_if":{"question":"1","any_of":["y"]}}]}"#)
        XCTAssertEqual(numbered.questions[1].showIf?.question, "q1")
        // Duplicate options are dropped, and a detail that only repeats the label too.
        let duplicate = try card(#"{"question":"Pick","options":[{"label":"Red","detail":"red"},"red","Blue"]}"#)
        XCTAssertEqual(duplicate.questions[0].options, [ChoiceCard.Option(label: "Red"), ChoiceCard.Option(label: "Blue")])
    }

    func testBadCardsSayWhatToFix() {
        XCTAssertTrue(rejected(#"{}"#)?.contains("Give 1 to 5 questions") == true)
        XCTAssertTrue(rejected(#"{"question":"Open?","options":["only one"]}"#)?.contains("ask in plain text") == true)
        let seven = (0..<7).map { "\"o\($0)\"" }.joined(separator: ",")
        XCTAssertTrue(rejected(#"{"question":"Pick","options":[\#(seven)]}"#)?.contains("at most 6 options") == true)
        let six = (0..<6).map { _ in #"{"question":"Q","options":["a","b"]}"# }.joined(separator: ",")
        XCTAssertTrue(rejected(#"{"questions":[\#(six)]}"#)?.contains("at most 5 questions") == true)
        XCTAssertTrue(rejected(#"{"questions":[{"question":"A","options":["x","y"]},{"question":"B","options":["1","2"],"show_if":{"question":"later","any_of":["x"]}}]}"#)?.contains("earlier question") == true)
        XCTAssertTrue(rejected(#"{"questions":[{"question":"A","options":["x","y"]},{"question":"B","options":["1","2"],"show_if":{"question":"q1","any_of":["z"]}}]}"#)?.contains("option labels of question q1") == true)
        XCTAssertTrue(rejected(#"{}"#)?.hasPrefix("No choice card was shown.") == true)
    }

    func testAnswersAreCheckedAgainstTheCard() throws {
        let built = try card(Self.trip)
        func answer(_ picks: [ChoiceReply.Pick]) -> Result<ChoiceAnswer, ChoiceCardTools.CardError> {
            ChoiceCardTools.answer(built, reply: ChoiceReply(cardID: built.id, answers: picks))
        }
        guard case .success(let full) = answer([
            .init(question: "where", picked: [0]),
            .init(question: "hotel", picked: [1]),
            .init(question: "q3", picked: [2, 0, 9], other: "  good  food "),
        ]) else { return XCTFail("a full answer is taken") }
        XCTAssertEqual(full.items.map(\.picked), [["Lisbon"], ["By the beach"], ["Rest", "Team building"]], "unknown option numbers are dropped")
        XCTAssertEqual(full.items[2].other, "good food")
        XCTAssertFalse(full.inWords)
        XCTAssertEqual(full.text(title: built.title, language: "en"), """
        My answers to “Team offsite”:
        - Where should it be? → Lisbon
        - Which hotel area? → By the beach
        - What matters most? → Rest, Team building, good food
        """)
        XCTAssertTrue(full.text(title: built.title, language: "es").hasPrefix("Mis respuestas a «Team offsite»:"))

        // A branch that does not show is left out, even when the app sent it.
        guard case .success(let online) = answer([.init(question: "where", picked: [1]), .init(question: "hotel", picked: [0]), .init(question: "q3", picked: [1])]) else { return XCTFail() }
        XCTAssertEqual(online.items.map(\.questionID), ["where", "q3"])
        // Every question that shows needs an answer.
        guard case .failure(let missing) = answer([.init(question: "where", picked: [0]), .init(question: "q3", picked: [1])]) else { return XCTFail() }
        XCTAssertTrue(missing.message.contains("Which hotel area?"))
        // One pick keeps one option; their own words take its place where the question allows it.
        guard case .success(let one) = answer([.init(question: "where", picked: [2, 0], other: "Paris"), .init(question: "hotel", picked: [0]), .init(question: "q3", picked: [], other: "Food")]) else { return XCTFail() }
        XCTAssertEqual(one.items[0].picked, ["Madrid"])
        XCTAssertNil(one.items[0].other, "the first question takes no own answer")
        XCTAssertEqual(one.items[2].value(language: "en"), "Food")
    }

    func testWordsThatNameAnOptionAnswerAOneQuestionCard() throws {
        let built = try card(#"{"question":"Which day?","options":["Monday","Tuesday","Friday afternoon"]}"#)
        XCTAssertEqual(ChoiceCardTools.match("Tuesday please", card: built)?.items.first?.picked, ["Tuesday"])
        XCTAssertEqual(ChoiceCardTools.match("the second one", card: built)?.items.first?.picked, ["Tuesday"])
        XCTAssertEqual(ChoiceCardTools.match("La última", card: built)?.items.first?.picked, ["Friday afternoon"])
        XCTAssertEqual(ChoiceCardTools.match("friday afternoon works", card: built)?.inWords, true)
        XCTAssertNil(ChoiceCardTools.match("Monday or Tuesday, not sure", card: built), "two picks on a one-pick question is not clear")
        XCTAssertNil(ChoiceCardTools.match("Actually, let's talk about the two budgets we have for this year first", card: built))
        XCTAssertNil(ChoiceCardTools.match("Tuesday", card: try card(Self.trip)), "only one-question cards")
    }

    func testCardIsReadAloudWithItsOptions() throws {
        let one = try card(#"{"question":"Which day works","options":["Monday","Tuesday","Friday"],"other":true}"#)
        XCTAssertEqual(ChoiceCardTools.spokenText(one, language: "en"), "Which day works. Monday, Tuesday, or Friday. Or tell me something else.\nJust say your answer, or tap it on screen.")
        let trip = ChoiceCardTools.spokenText(try card(Self.trip), language: "es")
        XCTAssertTrue(trip.hasPrefix("Primero: Where should it be?"), trip)
        XCTAssertTrue(trip.contains("Lisbon, Online o Madrid."))
        XCTAssertTrue(trip.contains("Después: What matters most? Puedes elegir varias:"))
        XCTAssertTrue(trip.contains("te preguntaré algo más"), "a branch is mentioned, not read")
    }

    func testCardsRoundTripAndOlderMessagesDecodeWithout() throws {
        var built = try card(Self.trip)
        built.state = .answered
        built.answer = ChoiceAnswer(cardID: built.id, items: [.init(questionID: "where", question: "Where?", picked: ["Lisbon"])])
        let message = ConversationMessage(role: .assistant, text: "A few questions.", choice: built)
        let reply = ConversationMessage(role: .user, text: "My answers", choiceReply: built.answer)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ConversationMessage.self, from: try encoder.encode(message)).choice, built)
        XCTAssertEqual(try decoder.decode(ConversationMessage.self, from: try encoder.encode(reply)).choiceReply, built.answer)
        let old = #"{"id":"\#(UUID().uuidString)","role":"assistant","text":"hi","createdAt":"2026-01-01T00:00:00Z","status":"complete","missionIDs":[],"teamIDs":[],"activity":[]}"#
        XCTAssertNil(try decoder.decode(ConversationMessage.self, from: Data(old.utf8)).choice)
        // A state a newer build adds never takes answers here.
        let future = #"{"id":"\#(UUID().uuidString)","questions":[],"state":"expired"}"#
        XCTAssertEqual(try decoder.decode(ChoiceCard.self, from: Data(future.utf8)).state, .closed)
    }

    func testSentFromTheStartInChatRepliesAndNeverToSpecialists() {
        let without = OfferedTools.direct(connectorTools: [], hasLinkedMissions: false, hasExtendedAccess: false)
        XCTAssertNil(without.family(of: ChoiceCardTools.toolName))
        let with = OfferedTools.direct(connectorTools: [], hasLinkedMissions: false, hasExtendedAccess: false, cards: true, choices: true)
        XCTAssertEqual(with.family(of: ChoiceCardTools.toolName), .choice)
        XCTAssertEqual(with.visibility(of: ChoiceCardTools.toolName), .sent, "a choice comes before the work, so it is never held")
        // It sits just before the held show_card, so revealing cards keeps every tool before it in place.
        XCTAssertEqual(with.definitions.last?.function.name, ChoiceCardTools.toolName)
        XCTAssertEqual(Array(with.revealing(.card).definitions.map(\.function.name).suffix(2)), [ChoiceCardTools.toolName, InfoCardTools.toolName])
        XCTAssertNotNil(ToolCatalog.spec(ChoiceCardTools.toolName))
        XCTAssertFalse(HelperTools.allows(name: ChoiceCardTools.toolName, family: .choice, groups: Set(HelperTools.Group.allCases)))
    }

    private func engine(asking json: String, calls: LockedCardStrings) async throws -> (ConversationEngine, ConversationStore) {
        let provider = ProviderConfig(id: "test", name: "Test", kind: .openAICompatible, baseURL: "http://localhost/v1", models: ["stub"], defaultModel: "stub")
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let memory = WorkspaceMemoryStore(root: directory)
        let engine = ConversationEngine(store: store, conversations: conversations, memory: memory, keyRing: keys, routing: false, completion: { _, _, _, system, messages, tools in
            guard tools != nil else { return LLMReply(message: .assistant("Done."), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Summarize only durable") { return LLMReply(message: .assistant("## Notes"), inputTokens: 0, outputTokens: 0, model: "stub") }
            let last = messages.last?.content ?? ""
            calls.append(last)
            if messages.last?.role == "tool" { return LLMReply(message: .assistant("Going ahead."), inputTokens: 0, outputTokens: 0, model: "stub") }
            if (last.contains("My answers") && !last.contains("again")) || last.contains("Tuesday") {
                return LLMReply(message: .assistant("Booked for your pick."), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: APIMessage(role: "assistant", content: "", tool_calls: [
                APIToolCall(id: "c1", function: .init(name: "ask_choice", arguments: json)),
                APIToolCall(id: "c2", function: .init(name: "ask_choice", arguments: json)),
            ]), inputTokens: 0, outputTokens: 0, model: "stub")
        })
        return (engine, conversations)
    }

    private func settled(_ conversations: ConversationStore, _ id: UUID) async throws -> Conversation {
        for _ in 0..<150 {
            if let current = try await conversations.get(id: id, ownerID: "owner"), current.messages.last?.status != .running { return current }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw ConversationError.persistence("The reply did not finish.")
    }

    func testAdaAsksTheReplyEndsAndTheAnswersComeBack() async throws {
        let calls = LockedCardStrings()
        let (engine, conversations) = try await engine(asking: Self.trip, calls: calls)
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Plan our offsite", launchedBy: "Owner", language: "en")
        let asked = try await settled(conversations, conversation.id)
        let reply = try XCTUnwrap(asked.messages.last)
        XCTAssertEqual(reply.status, .complete)
        XCTAssertEqual(calls.values.count, 1, "the reply ends with the card: no model call after it")
        let shown = try XCTUnwrap(reply.choice)
        XCTAssertEqual(shown.state, .pending)
        XCTAssertEqual(reply.text, "Where should it be?", "without a lead-in, the first question is the text")
        XCTAssertTrue(reply.speech?.contains("Lisbon, Online, or Madrid.") == true, "read aloud with the options")
        XCTAssertTrue(reply.quickReplies.isEmpty)
        XCTAssertTrue(reply.toolLog.first?.hasPrefix("ask_choice “Team offsite” Q1 Where should it be? [Lisbon | Online | Madrid]") == true, reply.toolLog.joined(separator: "\n"))
        XCTAssertTrue(reply.toolLog.dropFirst().first?.contains("already shown") == true, "one card per reply")

        // Missing an answer: refused, nothing sent.
        do {
            _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "", launchedBy: "Owner", language: "en", choice: ChoiceReply(cardID: shown.id, answers: [.init(question: "where", picked: [0])]))
            XCTFail("an incomplete answer is refused")
        } catch ConversationError.choice(let reason) {
            XCTAssertTrue(reason.contains("Which hotel area?"))
        }

        let picks = ChoiceReply(cardID: shown.id, answers: [.init(question: "where", picked: [0]), .init(question: "hotel", picked: [0]), .init(question: "q3", picked: [1])])
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "", launchedBy: "Owner", language: "en", choice: picks)
        let answered = try await settled(conversations, conversation.id)
        let user = try XCTUnwrap(answered.messages.dropLast().last)
        XCTAssertEqual(user.role, .user)
        XCTAssertEqual(user.choiceReply?.items.map(\.picked), [["Lisbon"], ["Old town"], ["Planning"]])
        XCTAssertTrue(user.text.hasPrefix("My answers to “Team offsite”:"))
        XCTAssertEqual(answered.messages.first(where: { $0.id == reply.id })?.choice?.state, .answered)
        XCTAssertEqual(answered.messages.last?.text, "Booked for your pick.")
        XCTAssertTrue(calls.values.last?.contains("- Which hotel area? → Old town") == true, "Ada reads the answers as words")

        // The card takes one answer.
        do {
            _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "", launchedBy: "Owner", language: "en", choice: picks)
            XCTFail("a second answer is refused")
        } catch ConversationError.choice(let reason) {
            XCTAssertTrue(reason.contains("already answered"))
        }
        await engine.shutdown()
    }

    func testWordsInsteadOfTapsCloseTheCard() async throws {
        let calls = LockedCardStrings()
        let (engine, conversations) = try await engine(asking: #"{"question":"Which day?","options":["Monday","Tuesday"]}"#, calls: calls)
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Book the cleaning", launchedBy: "Owner", language: "en")
        let first = try await settled(conversations, conversation.id)
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Tuesday", launchedBy: "Owner", language: "en", spoken: true)
        let done = try await settled(conversations, conversation.id)
        let card = try XCTUnwrap(done.messages.first(where: { $0.id == first.messages.last?.id })?.choice)
        XCTAssertEqual(card.state, .answered)
        XCTAssertEqual(card.answer?.inWords, true)
        XCTAssertEqual(card.answer?.items.first?.picked, ["Tuesday"])
        XCTAssertEqual(done.messages.dropLast().last?.text, "Tuesday", "their words are sent as they are")
        await engine.shutdown()
    }

    func testNoSecondCardRightAfterAnswers() async throws {
        let calls = LockedCardStrings()
        let (engine, conversations) = try await engine(asking: #"{"title":"again","question":"Which day?","options":["Monday","Tuesday"]}"#, calls: calls)
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Book it", launchedBy: "Owner", language: "en")
        let asked = try await settled(conversations, conversation.id)
        let card = try XCTUnwrap(asked.messages.last?.choice)
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "", launchedBy: "Owner", language: "en", choice: ChoiceReply(cardID: card.id, answers: [.init(question: "q1", picked: [0])]))
        let done = try await settled(conversations, conversation.id)
        let reply = try XCTUnwrap(done.messages.last)
        XCTAssertNil(reply.choice, "a card right after answers is refused")
        XCTAssertEqual(reply.text, "Going ahead.")
        XCTAssertTrue(reply.toolLog.first?.contains("just answered your choice card") == true, reply.toolLog.joined(separator: "\n"))
        await engine.shutdown()
    }
}
