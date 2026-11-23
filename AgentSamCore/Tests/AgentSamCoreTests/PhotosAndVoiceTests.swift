import XCTest
@testable import AgentSamCore

final class PhotosAndVoiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-photos-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0xFF, 0xD9])
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D])

    // MARK: - Photo storage

    func testMediaTypeIsSniffedFromBytes() {
        XCTAssertEqual(ConversationPhotoStore.mediaType(of: jpeg), "image/jpeg")
        XCTAssertEqual(ConversationPhotoStore.mediaType(of: png), "image/png")
        XCTAssertEqual(ConversationPhotoStore.mediaType(of: Data("GIF89a......".utf8)), "image/gif")
        XCTAssertEqual(ConversationPhotoStore.mediaType(of: Data("RIFF\u{0}\u{0}\u{0}\u{0}WEBPVP8 ".utf8)), "image/webp")
        XCTAssertNil(ConversationPhotoStore.mediaType(of: Data("<svg></svg>".utf8)))
        XCTAssertNil(ConversationPhotoStore.mediaType(of: Data()))
    }

    func testSaveLoadAndRemovePhotos() throws {
        let store = ConversationPhotoStore(root: directory)
        let conversation = UUID()
        let saved = try XCTUnwrap(store.save(conversationID: conversation, data: jpeg))
        XCTAssertEqual(saved.mediaType, "image/jpeg")
        XCTAssertEqual(saved.bytes, jpeg.count)
        XCTAssertEqual(store.attachment(conversationID: conversation, id: saved.id.uppercased()), saved)
        XCTAssertEqual(store.load(conversationID: conversation, id: saved.id)?.data, jpeg)
        XCTAssertEqual(store.image(conversationID: conversation, attachment: saved)?.data, jpeg.base64EncodedString())
        // Another conversation, a path-like id, and non-images are all refused.
        XCTAssertNil(store.attachment(conversationID: UUID(), id: saved.id))
        XCTAssertNil(store.load(conversationID: conversation, id: "../\(saved.id)"))
        XCTAssertNil(store.save(conversationID: conversation, data: Data("not an image".utf8)))
        XCTAssertNil(store.save(conversationID: conversation, data: Data(repeating: 0xFF, count: ConversationPhotoStore.maxBytes + 1)))
        store.removeAll(conversationID: conversation)
        XCTAssertNil(store.load(conversationID: conversation, id: saved.id))
    }

    func testOlderMessagesDecodeWithoutPhotosOrVoice() throws {
        let json = #"{"id":"\#(UUID().uuidString)","role":"user","text":"hi","createdAt":"2026-01-01T00:00:00Z","status":"complete"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let message = try decoder.decode(ConversationMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.photos, [])
        XCTAssertFalse(message.spoken)
    }

    // MARK: - Vision support

    func testVisionSupportKnowsTextOnlyFamilies() {
        let anthropic = ProviderConfig.builtin[0]
        let openAI = ProviderConfig.builtin[1]
        XCTAssertTrue(VisionSupport.accepts(provider: anthropic, model: "claude-sonnet-4-5"))
        XCTAssertTrue(VisionSupport.accepts(provider: openAI, model: "gpt-5.2-mini"))
        XCTAssertTrue(VisionSupport.accepts(provider: openAI, model: "google/gemini-3-pro"))
        XCTAssertFalse(VisionSupport.accepts(provider: openAI, model: "deepseek-chat"))
        XCTAssertFalse(VisionSupport.accepts(provider: openAI, model: "llama-3.3-70b-versatile"))
        XCTAssertFalse(VisionSupport.accepts(provider: openAI, model: "gpt-oss:120b"))
        XCTAssertTrue(VisionSupport.accepts(provider: openAI, model: "qwen2.5-vl-72b"))
        XCTAssertTrue(VisionSupport.accepts(provider: openAI, model: "glm-4.5v"))
        XCTAssertTrue(VisionSupport.accepts(provider: openAI, model: "meta-llama/llama-4-scout"))
    }

    // MARK: - Wire formats

    func testAnthropicPutsImagesBeforeText() throws {
        let wire = AnthropicClient.translate(messages: [.user("What is this?", images: [APIImage(mediaType: "image/jpeg", data: "AAAA")])])
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(wire[0]))
        let content = try XCTUnwrap(json.objectValue?["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0].objectValue?["type"]?.stringValue, "image")
        let source = content[0].objectValue?["source"]?.objectValue
        XCTAssertEqual(source?["type"]?.stringValue, "base64")
        XCTAssertEqual(source?["media_type"]?.stringValue, "image/jpeg")
        XCTAssertEqual(source?["data"]?.stringValue, "AAAA")
        XCTAssertEqual(content[1].objectValue?["text"]?.stringValue, "What is this?")
    }

    func testAnthropicPhotoWithoutTextHasNoEmptyTextBlock() {
        let wire = AnthropicClient.translate(messages: [.user("", images: [APIImage(mediaType: "image/png", data: "AAAA")])])
        XCTAssertEqual(wire[0].content.count, 1)
    }

    func testOpenAIUsesImageURLParts() throws {
        let message = OpenAICompatClient.WireMessage(role: "user", content: "Look", images: [APIImage(mediaType: "image/png", data: "AAAA")])
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(message))
        let parts = try XCTUnwrap(json.objectValue?["content"]?.arrayValue)
        XCTAssertEqual(parts[0].objectValue?["type"]?.stringValue, "text")
        XCTAssertEqual(parts[1].objectValue?["type"]?.stringValue, "image_url")
        XCTAssertEqual(parts[1].objectValue?["image_url"]?.objectValue?["url"]?.stringValue, "data:image/png;base64,AAAA")

        let plain = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(OpenAICompatClient.WireMessage(role: "user", content: "Hi")))
        XCTAssertEqual(plain.objectValue?["content"]?.stringValue, "Hi")
    }

    // MARK: - History

    func testChatTurnsCarryRecentImagesAndNoteOlderOnes() {
        let photo = PhotoAttachment(id: UUID().uuidString.lowercased(), mediaType: "image/jpeg", bytes: 10)
        let old = ConversationMessage(role: .user, text: "", photos: [photo])
        let recent = ConversationMessage(role: .user, text: "And this one?", photos: [photo])
        let history = [
            old,
            ConversationMessage(role: .assistant, text: "A cat."),
            recent,
            ConversationMessage(role: .assistant, text: "A dog."),
            ConversationMessage(role: .user, text: "latest"),
        ]
        let image = APIImage(mediaType: "image/jpeg", data: "AAAA")
        let turns = ConversationEngine.chatTurns(from: history, images: [recent.id: [image]])
        XCTAssertEqual(turns[0].content, "[The user attached a photo here.]")
        XCTAssertNil(turns[0].images)
        XCTAssertEqual(turns[2].content, "And this one?")
        XCTAssertEqual(turns[2].images, [image])
    }

    func testPhotoNotesForRoutingAndNonVisionModels() {
        let photo = PhotoAttachment(id: UUID().uuidString.lowercased(), mediaType: "image/jpeg", bytes: 10)
        let message = ConversationMessage(role: .user, text: "Fix this", photos: [photo, photo])
        XCTAssertTrue(ConversationEngine.textWithPhotoNote(message).contains("attached 2 photos"))
        XCTAssertEqual(ConversationEngine.directText(for: message, canSee: true, model: "m", language: "en"), "Fix this")
        XCTAssertTrue(ConversationEngine.directText(for: message, canSee: false, model: "deepseek-chat", language: "en").contains("deepseek-chat, can't look at images"))
        let stripped = ConversationEngine.withoutImages([.user("Hi", images: [APIImage(mediaType: "image/png", data: "A")])], model: "m")
        XCTAssertNil(stripped[0].images)
        XCTAssertTrue(stripped[0].content?.contains("rejected") == true)
        XCTAssertTrue(ConversationEngine.mayBeImageRejection(LLMError(message: "bad", statusCode: 400)))
        XCTAssertFalse(ConversationEngine.mayBeImageRejection(LLMError(message: "down", statusCode: 503)))
    }

    // MARK: - Engine

    private func makeEngine(model: String, completion: @escaping ConversationEngine.Completion) async throws -> (ConversationEngine, ConversationStore) {
        let provider = ProviderConfig(id: "test", name: "Test", kind: .openAICompatible, baseURL: "http://localhost/v1", models: [model], defaultModel: model)
        let store = MissionStore(root: directory)
        await store.saveProviders([provider])
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("test-key", for: provider.keyAccount)
        let conversations = ConversationStore(root: directory)
        let engine = ConversationEngine(store: store, conversations: conversations, memory: WorkspaceMemoryStore(root: directory), keyRing: keys, completion: completion)
        return (engine, conversations)
    }

    private func finished(_ conversations: ConversationStore, id: UUID) async throws -> Conversation {
        for _ in 0..<150 {
            if let conversation = try await conversations.get(id: id, ownerID: "owner"), conversation.messages.last?.status != .running { return conversation }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Conversation did not finish")
        return try await conversations.get(id: id, ownerID: "owner")!
    }

    func testDirectReplySeesAttachedPhotos() async throws {
        let (engine, conversations) = try await makeEngine(model: "stub") { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") {
                XCTAssertNil(messages.last?.images, "Routing should not pay for the images.")
                XCTAssertTrue(messages.last?.content?.contains("attached a photo") == true)
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            return LLMReply(message: .assistant("saw \(messages.last?.images?.count ?? 0)"), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        let photo = try XCTUnwrap(ConversationPhotoStore(root: directory).save(conversationID: conversation.id, data: jpeg))
        let sent = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "", launchedBy: "Owner", language: "en", photos: [photo])
        XCTAssertEqual(sent.title, "New conversation")
        let result = try await finished(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.first?.photos, [photo])
        XCTAssertEqual(result.messages.last?.text, "saw 1")
        await engine.shutdown()
    }

    func testTextOnlyModelExplainsInsteadOfSendingPhotos() async throws {
        let (engine, conversations) = try await makeEngine(model: "deepseek-chat") { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("workspace Markdown memory") { return LLMReply(message: .assistant("# Memory"), inputTokens: 0, outputTokens: 0, model: "stub") }
            XCTAssertNil(messages.last?.images)
            XCTAssertTrue(messages.last?.content?.contains("can't look at images") == true)
            return LLMReply(message: .assistant("This model can't see photos."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        let photo = try XCTUnwrap(ConversationPhotoStore(root: directory).save(conversationID: conversation.id, data: png))
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "What is this?", launchedBy: "Owner", language: "en", photos: [photo])
        let result = try await finished(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.status, .complete)
        await engine.shutdown()
    }

    func testRejectedPhotosFallBackToText() async throws {
        let (engine, conversations) = try await makeEngine(model: "stub") { _, _, _, system, messages, _ in
            if system.contains("Decide how to handle") {
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if messages.last?.images != nil { throw LLMError(message: "HTTP 400: image input not supported", statusCode: 400) }
            return LLMReply(message: .assistant("fell back"), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        let photo = try XCTUnwrap(ConversationPhotoStore(root: directory).save(conversationID: conversation.id, data: jpeg))
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Look", launchedBy: "Owner", language: "en", photos: [photo])
        let result = try await finished(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.text, "fell back")
        await engine.shutdown()
    }

    func testSpokenMessagesGetTheVoiceStyle() async throws {
        let (engine, conversations) = try await makeEngine(model: "stub") { _, _, _, system, _, _ in
            if system.contains("spoken acknowledgement") { return LLMReply(message: .assistant("On it."), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Decide how to handle") {
                XCTAssertTrue(system.contains("talking by voice"))
                return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("workspace Markdown memory") { return LLMReply(message: .assistant("# Memory"), inputTokens: 0, outputTokens: 0, model: "stub") }
            XCTAssertTrue(system.hasSuffix(ConversationPrompts.voiceStyle(language: "en")))
            return LLMReply(message: .assistant("Short answer."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Write a summary of the campaign", launchedBy: "Owner", language: "en", spoken: true)
        let result = try await finished(conversations, id: conversation.id)
        XCTAssertTrue(result.messages.first?.spoken == true)
        XCTAssertEqual(result.messages.last?.text, "Short answer.")
        await engine.shutdown()
    }

    func testQuickSpokenQuestionsSkipRouting() {
        let question = ConversationMessage(role: .user, text: "How did yesterday's campaign do?", spoken: true)
        XCTAssertTrue(ConversationEngine.isQuickSpokenQuestion(question, history: [question]))
        // Typed, work requests, long messages, and answers to Ada's question still route.
        XCTAssertFalse(ConversationEngine.isQuickSpokenQuestion(ConversationMessage(role: .user, text: "How did it do?"), history: []))
        XCTAssertFalse(ConversationEngine.isQuickSpokenQuestion(ConversationMessage(role: .user, text: "Build me a landing page", spoken: true), history: []))
        XCTAssertFalse(ConversationEngine.isQuickSpokenQuestion(ConversationMessage(role: .user, text: String(repeating: "word ", count: 30), spoken: true), history: []))
        let asked = ConversationMessage(role: .assistant, text: "Which account do you mean?")
        let answer = ConversationMessage(role: .user, text: "The main one", spoken: true)
        XCTAssertFalse(ConversationEngine.isQuickSpokenQuestion(answer, history: [asked, answer]))
    }

    func testFastPathAnswersWithoutARoutingCall() async throws {
        let (engine, conversations) = try await makeEngine(model: "stub") { _, _, _, system, _, _ in
            if system.contains("spoken acknowledgement") { return LLMReply(message: .assistant("On it."), inputTokens: 0, outputTokens: 0, model: "stub") }
            XCTAssertFalse(system.contains("Decide how to handle"), "A quick spoken question should not be routed.")
            if system.contains("workspace Markdown memory") { return LLMReply(message: .assistant("# Memory"), inputTokens: 0, outputTokens: 0, model: "stub") }
            return LLMReply(message: .assistant("It's sunny."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "What's the weather like?", launchedBy: "Owner", language: "en", spoken: true)
        let result = try await finished(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.text, "It's sunny.")
        await engine.shutdown()
    }

    func testTypedMessagesDoNotGetTheVoiceStyle() {
        let prompts = PromptStore(builtins: PromptStore.builtins)
        let ada = AgentProfile.rosterTemplates[0]
        let typed = ConversationPromptContext(projectName: "Personal", history: [], memory: "", workspaceManifest: "", missionReferences: "", missionIDs: [], schedule: nil, scheduled: false)
        var spoken = typed
        spoken.spoken = true
        XCTAssertFalse(ConversationPrompts.directResponseSystem(coordinator: ada, context: typed, connectorTools: [], hasLinkedMissions: false, store: prompts, language: "en").contains("VOICE REPLY"))
        XCTAssertTrue(ConversationPrompts.directResponseSystem(coordinator: ada, context: spoken, connectorTools: [], hasLinkedMissions: false, store: prompts, language: "en").contains("VOICE REPLY"))
        XCTAssertTrue(ConversationPrompts.consolidationSystem(coordinator: ada, context: spoken, store: prompts, language: "es").contains("natural Spanish"))
    }

    // MARK: - Prompt seeds

    func testUntouchedSeedFileFollowsNewBuiltinsButEditsWin() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("prompts.json")
        let file = """
        {"prompts":[
          {"id":"ada_direct_system","name":"Ada direct response","versions":[{"version":1,"text":"OLD SEED"}]},
          {"id":"ada_base","name":"Ada identity","versions":[{"version":1,"text":"OLD SEED"},{"version":2,"text":"EDITED","updatedAt":"2026-01-01T00:00:00Z"}]}
        ]}
        """
        try Data(file.utf8).write(to: url)
        let store = PromptStore(builtins: PromptStore.builtins, fileURL: url)
        XCTAssertNotEqual(store.text(for: "ada_direct_system"), "OLD SEED")
        XCTAssertTrue(store.text(for: "ada_direct_system")?.contains("Lead with the answer") == true)
        XCTAssertEqual(store.text(for: "ada_base"), "EDITED")
    }

    // MARK: - Spoken part and on-screen detail

    func testExtractDetailsSplitsSpokenPartFromScreenDetail() {
        let reply = "Revenue is up 12 percent. The details are on screen.\n```details\n| Month | Revenue |\n| --- | --- |\n| Oct | $10k |\n\n```js\nlet a = 1\n```\n```"
        let split = ConversationPrompts.extractDetails(reply)
        XCTAssertEqual(split.speech, "Revenue is up 12 percent. The details are on screen.")
        XCTAssertEqual(split.screen, "Revenue is up 12 percent. The details are on screen.\n\n| Month | Revenue |\n| --- | --- |\n| Oct | $10k |\n\n```js\nlet a = 1\n```")
        XCTAssertEqual(ConversationPrompts.extractDetails("Just this.").speech, nil)
        // While streaming, the spoken part is known as soon as the details line starts.
        XCTAssertEqual(ConversationPrompts.extractDetails("Short. ```details").speech, "Short.")
        XCTAssertEqual(ConversationPrompts.extractDetails("Short. ```details").screen, "Short.")
    }

    func testSpokenReplyIsOneReplyReadInFull() async throws {
        let (engine, conversations) = try await makeEngine(model: "stub") { _, _, _, system, _, _ in
            if system.contains("spoken acknowledgement") { return LLMReply(message: .assistant("On it."), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("workspace Markdown memory") { return LLMReply(message: .assistant("# Memory"), inputTokens: 0, outputTokens: 0, model: "stub") }
            return LLMReply(message: .assistant("Three campaigns are live. The details are on screen.\n```details\n- Spring\n- Summer\n- Fall"), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "Which campaigns are live?", launchedBy: "Owner", language: "en", spoken: true)
        let result = try await finished(conversations, id: conversation.id)
        let reply = try XCTUnwrap(result.messages.last)
        // The chat and the voice say the same thing: no separate spoken part, and a stray details
        // line from the model is folded into the reply.
        XCTAssertNil(reply.speech)
        XCTAssertEqual(reply.text, "Three campaigns are live. The details are on screen.\n\n- Spring\n- Summer\n- Fall")
        await engine.shutdown()
    }

    // MARK: - Spoken acknowledgement

    func testSpokenMessagesGetAQuickAcknowledgementFromASmallModel() async throws {
        let models = ModelLog()
        let (engine, conversations) = try await makeEngine(model: "stub") { _, _, profile, system, messages, _ in
            if system.contains("spoken acknowledgement") {
                await models.add(profile.model)
                XCTAssertTrue(system.contains("in Spanish"))
                XCTAssertEqual(messages.last?.content, "¿Cómo va la campaña de ayer?")
                return LLMReply(message: .assistant("\"Déjame revisar la campaña.\"\nExtra line"), inputTokens: 0, outputTokens: 0, model: "stub")
            }
            if system.contains("workspace Markdown memory") { return LLMReply(message: .assistant("# Memory"), inputTokens: 0, outputTokens: 0, model: "stub") }
            // The real answer takes a moment, so the acknowledgement lands while Ada is still working.
            try await Task.sleep(for: .milliseconds(300))
            return LLMReply(message: .assistant("Va bien."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "¿Cómo va la campaña de ayer?", launchedBy: "Owner", language: "en", spoken: true)
        let result = try await finished(conversations, id: conversation.id)
        XCTAssertEqual(result.messages.last?.acknowledgement, "Déjame revisar la campaña.")
        XCTAssertEqual(result.messages.last?.text, "Va bien.")
        let used = await models.all
        XCTAssertEqual(used.count, 1)
        await engine.shutdown()
    }

    func testTypedMessagesGetNoAcknowledgement() async throws {
        let (engine, conversations) = try await makeEngine(model: "stub") { _, _, _, system, _, _ in
            XCTAssertFalse(system.contains("spoken acknowledgement"))
            if system.contains("Decide how to handle") { return LLMReply(message: .assistant(#"{"action":"DIRECT"}"#), inputTokens: 0, outputTokens: 0, model: "stub") }
            if system.contains("workspace Markdown memory") { return LLMReply(message: .assistant("# Memory"), inputTokens: 0, outputTokens: 0, model: "stub") }
            return LLMReply(message: .assistant("Typed answer."), inputTokens: 0, outputTokens: 0, model: "stub")
        }
        let conversation = try await conversations.create(ownerID: "owner")
        _ = try await engine.send(conversationID: conversation.id, ownerID: "owner", text: "How is it going?", launchedBy: "Owner", language: "en")
        let result = try await finished(conversations, id: conversation.id)
        XCTAssertNil(result.messages.last?.acknowledgement)
        await engine.shutdown()
    }

    func testAcknowledgementUsesASmallModel() {
        let deepseek = ProviderConfig.builtin.first { $0.id == "deepseek" }!
        let anthropic = ProviderConfig.builtin.first { $0.id == "anthropic" }!
        var ada = AgentProfile.rosterTemplates[0]
        ada.providerID = "deepseek"
        ada.model = "deepseek-v4-pro"
        XCTAssertEqual(ConversationEngine.acknowledgementProfile(for: ada, providers: [deepseek, anthropic], hasKey: { _ in true }).model, "deepseek-chat")
        ada.providerID = "anthropic"
        ada.model = "claude-opus-4-5"
        XCTAssertEqual(ConversationEngine.acknowledgementProfile(for: ada, providers: [anthropic], hasKey: { _ in true }).model, "claude-haiku-4-5")
        // A provider with no small model and no other key: Ada's own model.
        let custom = ProviderConfig(id: "custom", name: "Custom", kind: .openAICompatible, baseURL: "https://example.com", models: ["big-model"])
        ada.providerID = "custom"
        ada.model = "big-model"
        XCTAssertEqual(ConversationEngine.acknowledgementProfile(for: ada, providers: [custom, anthropic], hasKey: { $0.id == "custom" }).model, "big-model")
        // "gemini" contains "mini" but isn't a small model.
        let google = ProviderConfig(id: "g", name: "G", kind: .openAICompatible, baseURL: "https://example.com", models: ["gemini-2.5-pro", "gemini-2.5-flash"])
        ada.providerID = "g"
        ada.model = "gemini-2.5-pro"
        XCTAssertEqual(ConversationEngine.acknowledgementProfile(for: ada, providers: [google], hasKey: { _ in true }).model, "gemini-2.5-flash")
    }

    func testAcknowledgementIsCleanedToOneShortLine() {
        XCTAssertEqual(ConversationEngine.cleanAcknowledgement("**On it**"), "On it.")
        XCTAssertEqual(ConversationEngine.cleanAcknowledgement("Ada: Let me check that!"), "Let me check that!")
        XCTAssertNil(ConversationEngine.cleanAcknowledgement("Want me to check?"))
        XCTAssertNil(ConversationEngine.cleanAcknowledgement(""))
        XCTAssertNil(ConversationEngine.cleanAcknowledgement(String(repeating: "word ", count: 20)))
        XCTAssertTrue(ConversationEngine.acknowledgementSystem(language: "en", avoid: "Let me check that.").contains("Don't repeat your last one (\"Let me check that.\")"))
    }

    func testVoiceStyleAsksForOneReplyReadInFull() {
        let style = ConversationPrompts.voiceStyle(language: "en")
        XCTAssertTrue(style.contains("read aloud to them in full"))
        XCTAssertTrue(style.contains("Here's what we could do:"))
        XCTAssertTrue(style.contains("don't write a ```details block"))
        XCTAssertTrue(ConversationPrompts.voiceStyle(language: "es").contains("natural Spanish"))
    }

    func testSpokenTextNamesSkippedPartsInTheReplyLanguage() {
        let english = SpeechClient.spokenText("Here it is.\n```js\nx = 1\n```\n| A | B |\n| --- | --- |\n| 1 | 2 |\nDone.", language: "en")
        XCTAssertTrue(english.contains("on screen"), english)
        XCTAssertFalse(english.contains("x = 1"), english)
        let spanish = SpeechClient.spokenText("Aquí está el resumen de la semana.\n```js\nx = 1\n```\n| A | B |\n| --- | --- |\n| 1 | 2 |\nEso es todo.", language: "es")
        XCTAssertTrue(spanish.contains("Hay un ejemplo de código en pantalla."), spanish)
        XCTAssertTrue(spanish.contains("La tabla está en pantalla."), spanish)
    }

    func testSkippedPartsFollowTheLanguageOfTheProseNotTheCode() {
        let english = SpeechClient.spokenText("Here is the fix for the build.\n```js\n// añadir la función de búsqueda para el menú y la página\n```\nThat is all.", language: "es")
        XCTAssertTrue(english.contains("Code example omitted from speech."), english)
        let spanish = SpeechClient.spokenText("Aquí está la tabla de precios.\n| Plan | Price |\n| --- | --- |\n| The basic one | $10 |", language: "en")
        XCTAssertTrue(spanish.contains("La tabla está en pantalla."), spanish)
    }

    func testAVeryLongReplyIsReadInFullPieceByPiece() {
        let reply = (1...400).map { "Point \($0) is worth a sentence of its own." }.joined(separator: " ")
        let spoken = SpeechClient.spokenText(reply)
        let pieces = SpeechClient.spokenChunks(spoken)
        XCTAssertGreaterThan(pieces.count, 20)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= SpeechClient.maxSpeechCharacters })
        XCTAssertEqual(pieces.joined(separator: " "), spoken)
        XCTAssertTrue(ConversationPrompts.voiceStyle(language: "en").contains("there is no length limit"))
    }

    func testOneClipForAWholeReplyStopsWithinTheProviderLimit() {
        let reply = String(repeating: "This is a fairly ordinary sentence about nothing. ", count: 30).trimmingCharacters(in: .whitespaces)
        XCTAssertEqual(SpeechClient.cappedSpeech(reply, tail: "The rest is on screen."), reply)
        let huge = String(repeating: "This is a fairly ordinary sentence about nothing. ", count: 120)
        let clip = SpeechClient.cappedSpeech(huge, tail: "The rest is on screen.")
        XCTAssertTrue(clip.hasSuffix("nothing. The rest is on screen."))
        XCTAssertLessThanOrEqual(clip.count, SpeechClient.maxSpeechCharacters)
    }
}

private actor ModelLog {
    private(set) var all: [String] = []
    func add(_ model: String) { all.append(model) }
}
