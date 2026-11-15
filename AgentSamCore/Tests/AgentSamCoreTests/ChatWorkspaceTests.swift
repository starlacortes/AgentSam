import XCTest
@testable import AgentSamCore

final class ChatWorkspaceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-chat-workspace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func call(_ name: String, _ arguments: String) -> APIToolCall {
        APIToolCall(id: UUID().uuidString, function: .init(name: name, arguments: arguments))
    }

    func testWriteListReadRoundTripAndJail() async throws {
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()

        let write = await ChatWorkspaceTools.run(
            call: call("chat_write_file", #"{"path":"site/index.html","content":"<h1>Jelly</h1>"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertEqual(write.wroteFiles, ["site/index.html"])

        let list = await ChatWorkspaceTools.run(
            call: call("chat_list_files", "{}"),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertEqual(list.resultText, "site/index.html")

        let read = await ChatWorkspaceTools.run(
            call: call("chat_read_file", #"{"path":"site/index.html"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(read.resultText.contains("Jelly"))

        // Path jail: escapes are refused and don't resolve outside the workspace.
        let escape = await ChatWorkspaceTools.run(
            call: call("chat_write_file", #"{"path":"../../keys.json","content":"stolen"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(escape.resultText.contains("Invalid path"))
        let escaped = await workspace.read(conversationID: conversationID, name: "../secrets.txt")
        XCTAssertNil(escaped)

        // Files are isolated per conversation.
        let other = await ChatWorkspaceTools.run(
            call: call("chat_read_file", #"{"path":"site/index.html"}"#),
            workspace: workspace,
            conversationID: UUID()
        )
        XCTAssertTrue(other.resultText.contains("not found"))
    }

    func testReadRefusesNonTextExtensions() async throws {
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        _ = await workspace.write(conversationID: conversationID, name: "notes.md", content: "hi")
        // Sneak a binary-ish file straight onto disk; .pem isn't a readable extension.
        let target = workspace.directory(conversationID).appendingPathComponent("key.pem")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("PRIVATE".utf8).write(to: target)
        let readable = await workspace.read(conversationID: conversationID, name: "notes.md")
        XCTAssertNotNil(readable)
        let blocked = await workspace.read(conversationID: conversationID, name: "key.pem")
        XCTAssertNil(blocked)
    }

    func testRunProgramExecutesJavaScript() async throws {
        try XCTSkipIf(Shell.which("node") == nil, "node is not installed")
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        let outcome = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"js","source":"console.log(6 * 7)"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(outcome.resultText.contains("42"), outcome.resultText)
    }

    func testRunProgramCompilesAndRunsC() async throws {
        try XCTSkipIf(Shell.which("gcc") == nil, "gcc is not installed")
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        let source = """
        #include <stdio.h>
        int main(void) { printf("hello from c\n"); return 0; }
        """
        let outcome = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"c","source":"\#(escapeForJSON(source))"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(outcome.resultText.contains("hello from c"), outcome.resultText)
    }

    func testRunProgramRunsPython() async throws {
        try XCTSkipIf(Shell.which("python3") == nil, "python3 is not installed")
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        let outcome = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"python","source":"print(sum(range(10)))"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(outcome.resultText.contains("45"), outcome.resultText)
    }

    func testRunProgramRejectsUnsupportedLanguageAndBadFilenames() async throws {
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        let language = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"cobol","source":"x"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(language.resultText.contains("Unsupported language"))

        let escape = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"js","source":"1","filename":"../evil.js"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(escape.resultText.contains("Invalid filename"))
    }

    func testRunProgramLeavesNoSandboxBehind() async throws {
        try XCTSkipIf(Shell.which("node") == nil, "node is not installed")
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        _ = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"js","source":"console.log(1)"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        let leftovers = try FileManager.default.contentsOfDirectory(at: workspace.directory(conversationID), includingPropertiesForKeys: nil)
        XCTAssertEqual(leftovers, [])
    }

    func testRunProgramTimesOutOnInfiniteLoop() async throws {
        try XCTSkipIf(Shell.which("python3") == nil, "python3 is not installed")
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        let started = Date()
        let outcome = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"python","source":"while True: pass"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(outcome.resultText.contains("Timed out"), outcome.resultText)
        XCTAssertLessThan(Date().timeIntervalSince(started), 40)
    }

    func testStdinIsPiped() async throws {
        try XCTSkipIf(Shell.which("python3") == nil, "python3 is not installed")
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        let outcome = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"python","source":"print(input().upper())","stdin":"jelly bean"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(outcome.resultText.contains("JELLY BEAN"), outcome.resultText)
    }
}

/// Locates an executable in PATH, so tests can skip when a toolchain isn't installed.
enum Shell {
    static func which(_ program: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        for candidate in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(candidate)).appendingPathComponent(program)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url.path }
        }
        return nil
    }
}

/// Minimal JSON string escaping for building tool arguments in tests.
func escapeForJSON(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
}
