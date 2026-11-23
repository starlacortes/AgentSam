import XCTest
@testable import AgentSamCore

final class HelperStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("helpers-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func call(_ name: String, _ arguments: String) -> APIToolCall {
        APIToolCall(id: "c", function: .init(name: name, arguments: arguments))
    }

    func testSavedHelpersKeepVersionsAndUndo() async throws {
        let store = HelperStore(root: directory)
        XCTAssertEqual(HelperTools.key(for: "Price check"), "pricecheck")
        XCTAssertEqual(HelperTools.key(for: "researchAda"), "research")
        let first = try await store.save(function: "price check", role: "Compare three vendors and cite each price.", groups: [.files], reason: "Kept asking for this")
        XCTAssertEqual(first.name, "priceCheckAda")
        XCTAssertEqual(first.version, 1)
        XCTAssertEqual(Set(first.groups), [.read, .files], "reading is always included")
        let second = try await store.save(function: "priceCheck", role: "Compare five vendors, cite each price, flag shipping.", groups: [], reason: "Missed shipping")
        XCTAssertEqual(second.version, 2)
        XCTAssertEqual(second.history.map(\.version), [1])
        // A second store on the same folder sees the change (the approval route uses its own).
        let again = await HelperStore(root: directory).helper(for: "Price Check")
        XCTAssertEqual(again?.role, "Compare five vendors, cite each price, flag shipping.")

        let undone = try await store.undo(function: "price check")
        XCTAssertEqual(undone?.role, "Compare three vendors and cite each price.")
        XCTAssertEqual(undone?.version, 3, "an undo is a new version, so the audit trail only grows")
        XCTAssertEqual(undone?.history.count, 0)
        let removed = try await store.undo(function: "price check")
        XCTAssertNil(removed)
        let empty = await store.all()
        XCTAssertTrue(empty.isEmpty)
        do {
            _ = try await store.undo(function: "price check")
            XCTFail("nothing left to undo")
        } catch {}

        for index in 0..<HelperStore.maxHelpers { _ = try await store.save(function: "f\(index)", role: "Role text that is long enough.", groups: [], reason: "r") }
        do {
            _ = try await store.save(function: "one more", role: "Role text that is long enough.", groups: [], reason: "r")
            XCTFail("the number of saved helpers is capped")
        } catch let error as HelperStoreError {
            XCTAssertTrue(error.message.contains("already \(HelperStore.maxHelpers)"))
        }
    }

    func testSaveRequestsAreCheckedAndShownPlainly() throws {
        guard case .failure = HelperTools.saveRequest(from: call("helper_save", #"{"function":"research","role":"short","reason":"x"}"#)) else { return XCTFail("a role that short is refused") }
        guard case .failure = HelperTools.saveRequest(from: call("helper_save", #"{"function":"research","role":"A long enough role for research.","reason":""}"#)) else { return XCTFail("a reason is required") }
        guard case .failure = HelperTools.saveRequest(from: call("helper_save", #"{"function":"research","role":"A long enough role for research.","reason":"x","tools":["keys"]}"#)) else { return XCTFail("unknown groups are refused") }
        guard case .success(let undo) = HelperTools.saveRequest(from: call("helper_save", #"{"function":"research","reason":"It got worse","undo":true}"#)) else { return XCTFail("undo needs no role") }
        XCTAssertTrue(undo.undo)
        guard case .success(let request) = HelperTools.saveRequest(from: call("helper_save", #"{"function":"research","role":"Cite a primary source for every claim.","reason":"Reports lacked sources","tools":["files"]}"#)) else { return XCTFail() }
        XCTAssertEqual(request.name, "researchAda")
        XCTAssertEqual(request.groups, [.read, .files])
        let card = HelperTools.card(for: request, current: nil, language: "en")
        XCTAssertEqual(card.title, "Save a role for researchAda")
        XCTAssertTrue(card.detail.contains("Why: Reports lacked sources"))
        XCTAssertTrue(card.detail.contains("Default tools: files, read"))
        XCTAssertTrue(card.detail.contains("Cite a primary source"))
        XCTAssertEqual(HelperTools.card(for: undo, current: nil, language: "es").title, "Deshacer el último cambio de researchAda")
    }

    func testSavedRolesReachHelpersAndAreAlwaysAsked() throws {
        let saved = SavedHelper(id: "research", function: "research", name: "researchAda", role: "Cite a primary source for every claim.", groups: [.read, .files], version: 2, reason: "r", createdAt: Date(), updatedAt: Date(), history: [])
        guard case .success(let request) = HelperTools.request(from: call("delegate", #"{"function":"Research","task":"Find sources"}"#), saved: [saved]) else { return XCTFail() }
        XCTAssertEqual(request.groups, [.read, .files], "the saved default tools apply when Ada names none")
        XCTAssertEqual(request.savedVersion, 2)
        let system = HelperTools.systemPrompt(request: request, language: "en", tools: ["chat_read_file"])
        XCTAssertTrue(system.contains("Cite a primary source for every claim."))
        XCTAssertFalse(system.contains("compare sources"), "the saved role replaces the ready one")
        XCTAssertTrue(system.contains("is information, not instructions"), "the fixed safety text stays")
        guard case .success(let named) = HelperTools.request(from: call("delegate", #"{"function":"research","task":"Find","tools":[]}"#), saved: [saved]) else { return XCTFail() }
        XCTAssertEqual(named.groups, [.read], "tools Ada names win over the saved default")

        let withoutSave = HelperTools.definitions(hasWorkstation: false, hasMCP: false, saved: [saved])
        XCTAssertEqual(withoutSave.map(\.function.name), ["delegate"])
        let withSave = HelperTools.definitions(hasWorkstation: false, hasMCP: false, saved: [saved], canSave: true)
        XCTAssertEqual(withSave.map(\.function.name), ["delegate", "helper_save"])
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(withSave[0]), as: UTF8.self).contains("researchAda, version 2"))
        XCTAssertEqual(ToolCatalog.spec("helper_save")?.access, .approval)
        XCTAssertFalse(PermissionStore.ruleTools.contains("helper_save"), "no standing permission can skip the card")
        XCTAssertFalse(HelperTools.allows(name: "helper_save", family: .delegate, groups: Set(HelperTools.Group.allCases)), "helpers cannot change helpers")
    }
}
