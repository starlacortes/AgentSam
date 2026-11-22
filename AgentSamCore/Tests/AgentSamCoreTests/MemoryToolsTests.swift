import XCTest
@testable import AgentSamCore

final class MemoryToolsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-memory-tools-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testPinnedFactsReachThePromptAndDeduplicate() async throws {
        let memory = WorkspaceMemoryStore(root: directory)
        try await memory.pin(ownerID: "owner", text: "  My business is in Austin  ", origin: .ada)
        try await memory.pin(ownerID: "owner", text: "my business is in austin", origin: .person)
        let state = await memory.state(ownerID: "owner")
        XCTAssertEqual(state.pinned.map(\.text), ["My business is in Austin"])
        XCTAssertTrue(state.promptText.hasPrefix("## Remembered on request\n- My business is in Austin"))
        let other = await memory.state(ownerID: "someone-else")
        XCTAssertTrue(other.pinned.isEmpty, "memory is per owner")
    }

    func testSecretsAreNeverRemembered() async {
        let memory = WorkspaceMemoryStore(root: directory)
        for secret in ["My password is hunter2", "use key sk-abcdefghijklmnopqrstuvwx", "token ghp_abcdefghijklmnopqrstuvwxyz1234"] {
            do {
                try await memory.pin(ownerID: "owner", text: secret, origin: .ada)
                XCTFail("stored a secret: \(secret)")
            } catch {
                XCTAssertEqual(error as? MemoryEditError, .secret)
            }
        }
    }

    func testDisabledMemoryRefusesAndHidesPinnedFacts() async throws {
        let memory = WorkspaceMemoryStore(root: directory)
        try await memory.pin(ownerID: "owner", text: "Prefers short replies", origin: .person)
        _ = try await memory.setEnabled(ownerID: "owner", false)
        let state = await memory.state(ownerID: "owner")
        XCTAssertEqual(state.promptText, "")
        do {
            try await memory.pin(ownerID: "owner", text: "Another fact", origin: .ada)
            XCTFail("pinned while memory was off")
        } catch {
            XCTAssertEqual(error as? MemoryEditError, .disabled)
        }
    }

    func testForgetRemovesPinnedSummaryAndPendingMentions() async throws {
        let memory = WorkspaceMemoryStore(root: directory)
        try await memory.pin(ownerID: "owner", text: "Works with Acme Corp on billing", origin: .ada)
        try await memory.pin(ownerID: "owner", text: "Prefers Spanish", origin: .person)
        let conversation = UUID()
        let user = ConversationMessage(role: .user, text: "Draft a note to acme corp")
        let assistant = ConversationMessage(role: .assistant, text: "Here is the note.")
        let job = try await memory.record(conversationID: conversation, ownerID: "owner", userMessage: user, assistantMessage: assistant)
        if let job { _ = try await memory.finishCompaction(job, markdown: "## Projects\n- Acme Corp billing migration\n- Website refresh") }
        // A second exchange stays pending (below the compaction threshold).
        _ = try await memory.record(conversationID: conversation, ownerID: "owner", userMessage: ConversationMessage(role: .user, text: "Remind me about ACME"), assistantMessage: ConversationMessage(role: .assistant, text: "Okay."))

        let result = try await memory.forget(ownerID: "owner", matching: "acme")
        XCTAssertEqual(result.pinnedRemoved, 1)
        XCTAssertEqual(result.summaryLinesRemoved, 1)
        XCTAssertEqual(result.pendingRemoved, 1)
        let state = await memory.state(ownerID: "owner")
        XCTAssertEqual(state.pinned.map(\.text), ["Prefers Spanish"])
        XCTAssertFalse(state.markdown.lowercased().contains("acme corp billing"))
        XCTAssertTrue(state.markdown.contains("Website refresh"))
        XCTAssertTrue(state.markdown.contains("## Sources"), "the source index stays")
        XCTAssertEqual(state.pendingEntries, 0)
    }

    func testToolsRememberAndForgetForTheSignedInOwner() async throws {
        let memory = WorkspaceMemoryStore(root: directory)
        let remember = APIToolCall(id: "r", function: .init(name: "memory_remember", arguments: #"{"fact":"Star's shop opens at 9"}"#))
        let saved = await MemoryTools.run(call: remember, memory: memory, ownerID: "owner")
        XCTAssertTrue(saved.succeeded, saved.resultText)
        let anonymous = await MemoryTools.run(call: remember, memory: memory, ownerID: nil)
        XCTAssertFalse(anonymous.succeeded)
        let forget = APIToolCall(id: "f", function: .init(name: "memory_forget", arguments: #"{"about":"shop"}"#))
        let forgot = await MemoryTools.run(call: forget, memory: memory, ownerID: "owner")
        XCTAssertTrue(forgot.resultText.contains("Forgot 1 remembered fact"), forgot.resultText)
        let tooShort = await MemoryTools.run(call: APIToolCall(id: "s", function: .init(name: "memory_forget", arguments: #"{"about":"a"}"#)), memory: memory, ownerID: "owner")
        XCTAssertFalse(tooShort.succeeded)
        let state = await memory.state(ownerID: "owner")
        XCTAssertTrue(state.pinned.isEmpty)
    }

    func testOlderMemoryFilesDecodeWithoutPinnedFacts() throws {
        let json = ##"{"enabled":true,"markdown":"# Workspace memory","sources":[],"compactionCount":2,"pendingEntries":0}"##
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkspaceMemory.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.compactionCount, 2)
        XCTAssertTrue(decoded.pinned.isEmpty)
    }

    func testDirectRepliesOfferTheMemoryTools() {
        let offered = OfferedTools.direct(connectorTools: [], hasLinkedMissions: false, hasExtendedAccess: false)
        XCTAssertEqual(offered.family(of: "memory_remember"), .memory)
        XCTAssertEqual(offered.family(of: "memory_forget"), .memory)
    }
}
