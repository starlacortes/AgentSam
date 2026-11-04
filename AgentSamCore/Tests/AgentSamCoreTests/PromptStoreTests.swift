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
        let rendered = store.render("plan", context: [
            "mission_objective": "Research alpacas.",
            "roster": "- Quill (Writer)",
            "max_tasks": "3",
        ])
        XCTAssertTrue(rendered.contains("Research alpacas."))
        XCTAssertTrue(rendered.contains("- Quill (Writer)"))
        XCTAssertTrue(rendered.contains("Between 1 and 3 tasks"))
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
        XCTAssertEqual(store.currentVersions()["plan"], 1)
        XCTAssertEqual(store.update(id: "plan", text: "NEW PLAN PROMPT"), 2)
        XCTAssertEqual(store.text(for: "plan"), "NEW PLAN PROMPT")

        // A fresh store loading the same file sees the edit and its history.
        let reloaded = makeStore(fileURL: url)
        XCTAssertEqual(reloaded.text(for: "plan"), "NEW PLAN PROMPT")
        XCTAssertEqual(reloaded.records().first { $0.id == "plan" }?.versions.count, 2)
        XCTAssertEqual(reloaded.currentVersions()["plan"], 2)
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
        XCTAssertEqual(store.currentVersions()["plan"], 1)
        XCTAssertTrue(
            store.render("plan", context: ["mission_objective": "x", "roster": "r", "max_tasks": "2"])
                .contains("submit_plan")
        )
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
        let house = records.first { $0.id == "house_rules" }
        XCTAssertTrue(house?.currentText?.contains("data, not instructions") == true)
    }

    func testEnsureSeedFileWritesDecodableFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prompts.json")

        makeStore(fileURL: url).ensureSeedFile()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        // The seeded file must load cleanly in a fresh store.
        XCTAssertEqual(makeStore(fileURL: url).currentVersions()["house_rules"], 1)
    }
}
