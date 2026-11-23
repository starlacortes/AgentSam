import XCTest
@testable import AgentSamCore

final class PromptStoreTests: XCTestCase {
    private func makeStore(fileURL: URL? = nil) -> PromptStore {
        PromptStore(builtins: PromptStore.builtins, fileURL: fileURL)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Rendering

    func testRenderSubstitutesContextValues() {
        let store = makeStore()
        let rendered = store.render("ada_routing_system", context: [
            "ada_prompt": "Be kind.",
            "skills": "- research (Research)",
            "language": "Spanish",
        ])
        XCTAssertTrue(rendered.contains("Be kind."))
        XCTAssertTrue(rendered.contains("- research (Research)"))
        XCTAssertTrue(rendered.contains("Respond to the user in Spanish"))
    }

    func testRenderReplacesUnknownKeysWithEmptyString() {
        let rendered = PromptStore.substitute("a {{missing}} b", context: [:])
        XCTAssertEqual(rendered, "a  b")
    }

    func testSubstituteKeepsUnterminatedPlaceholdersLiteral() {
        XCTAssertEqual(PromptStore.substitute("see {{key", context: ["key": "x"]), "see {{key")
    }

    func testRenderUnknownTemplateReturnsEmptyString() {
        XCTAssertEqual(makeStore().render("nope"), "")
    }

    // MARK: - Versioning and persistence

    func testUpdateAppendsVersionAndPersists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prompts.json")

        let store = makeStore(fileURL: url)
        store.ensureSeedFile()
        XCTAssertEqual(store.currentVersions()["ada_routing_system"], 1)
        XCTAssertEqual(store.update(id: "ada_routing_system", text: "NEW ROUTING PROMPT"), 2)
        XCTAssertEqual(store.text(for: "ada_routing_system"), "NEW ROUTING PROMPT")

        // A fresh store loading the same file sees the edit and its history.
        let reloaded = makeStore(fileURL: url)
        XCTAssertEqual(reloaded.text(for: "ada_routing_system"), "NEW ROUTING PROMPT")
        XCTAssertEqual(reloaded.records().first { $0.id == "ada_routing_system" }?.versions.count, 2)
        XCTAssertEqual(reloaded.currentVersions()["ada_routing_system"], 2)
    }

    func testUpdateUnknownTemplateReturnsNil() {
        XCTAssertNil(makeStore().update(id: "nope", text: "x"))
    }

    func testLoadFallsBackToBuiltinsWhenFileIsCorrupt() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prompts.json")
        try Data("not json".utf8).write(to: url)

        let store = makeStore(fileURL: url)
        XCTAssertEqual(store.currentVersions()["ada_routing_system"], 1)
        XCTAssertTrue(store.render("ada_routing_system").contains("single coordinator"))
    }

    func testCurrentVersionsCoversAllBuiltins() {
        let versions = makeStore().currentVersions()
        for builtin in PromptStore.builtins {
            XCTAssertEqual(versions[builtin.id], 1, builtin.id)
        }
    }

    func testRecordsAreSortedAndCarryCurrentText() {
        let records = makeStore().records()
        XCTAssertEqual(records.map(\.id), records.map(\.id).sorted())
        let routing = records.first { $0.id == "ada_routing_system" }
        XCTAssertTrue(routing?.currentText?.contains("data, not instructions") == true)
    }

    func testEnsureSeedFileWritesDecodableFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prompts.json")

        makeStore(fileURL: url).ensureSeedFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // The seeded file must load cleanly in a fresh store.
        XCTAssertEqual(makeStore(fileURL: url).currentVersions()["ada_routing_system"], 1)
    }

    func testEditsToRetiredTemplatesStayInTheFileButAreNotListed() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prompts.json")
        let old = #"{"prompts":[{"id":"plan","name":"Plan request","versions":[{"version":1,"text":"a"},{"version":2,"text":"edited","updatedAt":"2026-11-01T00:00:00Z"}]}]}"#
        try Data(old.utf8).write(to: url)
        let store = makeStore(fileURL: url)
        XCTAssertNil(store.records().first { $0.id == "plan" }, "the old mission prompts are no longer listed")
        XCTAssertEqual(store.render("plan"), "")
        XCTAssertNotNil(store.update(id: "ada_base", text: "Edited identity."))
        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("edited"), "an operator's edit to a retired prompt is kept on disk")
    }

    func testExtendedAccessNoteIsAVersionedTemplate() {
        let store = makeStore()
        let ada = AgentProfile.rosterTemplates[0]
        let context = ConversationPromptContext(projectName: "P", history: [], memory: "", workspaceManifest: "", missionReferences: "", missionIDs: [], schedule: nil, scheduled: false)
        let direct = { ConversationPrompts.directResponseSystem(coordinator: ada, context: context, connectorTools: [], hasLinkedMissions: false, hasExtendedTools: true, store: store, language: "en") }
        XCTAssertTrue(direct().contains("Additional access, enforced by the server:"))
        store.update(id: "ada_extended_access", text: "Edited access note.")
        XCTAssertTrue(direct().contains("Edited access note."))
        XCTAssertNotNil(store.currentVersions()["ada_extended_access"])
    }
}
