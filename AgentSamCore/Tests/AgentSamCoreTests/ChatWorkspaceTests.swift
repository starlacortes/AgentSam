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

    private func requireSandbox() throws {
        if let reason = OSSandbox.unavailableReason { throw XCTSkip("The OS sandbox is unavailable: \(reason)") }
    }

    private func pythonString(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
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

    func testManifestRangedReadAndMissionCopy() async throws {
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        await workspace.write(conversationID: conversationID, name: "site/notes.md", content: "one\ntwo\nthree")
        let manifest = await workspace.manifest(conversationID: conversationID)
        XCTAssertEqual(manifest, ["site/notes.md — 13"])
        let read = await ChatWorkspaceTools.run(
            call: call("chat_read_file", #"{"path":"site/notes.md","start_line":2}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertEqual(read.resultText, "two\nthree")
        let destination = directory.appendingPathComponent("mission-deliverables")
        let copied = await workspace.copyFiles(conversationID: conversationID, to: destination)
        XCTAssertEqual(copied, ["site/notes.md"])
        let data = try Data(contentsOf: destination.appendingPathComponent("site/notes.md"))
        XCTAssertEqual(String(data: data, encoding: .utf8), "one\ntwo\nthree")
        XCTAssertEqual(AgentTools.listWorkspace(destination), ["site/notes.md — 13 bytes"])
    }

    func testRangedReadReportsExactNextLineWhenClipped() async throws {
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        let startLine = 7
        let text = (1...400).map { "line \($0): " + String(repeating: "x", count: 60) }.joined(separator: "\n")
        await workspace.write(conversationID: conversationID, name: "notes.md", content: text)
        let read = await ChatWorkspaceTools.run(
            call: call("chat_read_file", #"{"path":"notes.md","start_line":7}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        let prefix = String(text.prefix(AgentTools.resultClip))
        let expectedNext = startLine + prefix.filter { $0 == "\n" }.count
        XCTAssertTrue(read.resultText.hasSuffix("start_line \(expectedNext)]"), String(read.resultText.suffix(120)))
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
        try requireSandbox()
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
        try requireSandbox()
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
        try requireSandbox()
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        let outcome = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"python","source":"print(sum(range(10)))"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(outcome.resultText.contains("45"), outcome.resultText)
        XCTAssertTrue(outcome.succeeded)
    }

    func testFailuresAreReportedAsFailures() async throws {
        let workspace = ChatWorkspaceStore(root: directory)
        let missing = await ChatWorkspaceTools.run(call: call("chat_read_file", "{}"), workspace: workspace, conversationID: UUID())
        XCTAssertFalse(missing.succeeded, missing.resultText)
        let listed = await ChatWorkspaceTools.run(call: call("chat_list_files", "{}"), workspace: workspace, conversationID: UUID())
        XCTAssertTrue(listed.succeeded, listed.resultText)

        try XCTSkipIf(Shell.which("python3") == nil, "python3 is not installed")
        try requireSandbox()
        let crashed = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"python","source":"raise SystemExit(3)"}"#),
            workspace: workspace,
            conversationID: UUID()
        )
        XCTAssertFalse(crashed.succeeded, crashed.resultText)
        XCTAssertTrue(crashed.resultText.contains("exit code 3"), crashed.resultText)
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
        try requireSandbox()
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
        try requireSandbox()
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
        try requireSandbox()
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        let outcome = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"python","source":"print(input().upper())","stdin":"jelly bean"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(outcome.resultText.contains("JELLY BEAN"), outcome.resultText)
    }

    func testRunProgramCannotSeeTheDataFolder() async throws {
        try XCTSkipIf(Shell.which("python3") == nil, "python3 is not installed")
        try requireSandbox()
        // `directory` is the data root, the way the server lays it out: keys sit beside conversations.
        let secret = "sk-test-\(UUID().uuidString)"
        try Data(secret.utf8).write(to: directory.appendingPathComponent("keys.json"))
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        let keys = directory.appendingPathComponent("keys.json").resolvingSymlinksInPath().path
        let source = """
        import os
        for path in [\(pythonString(keys)), "../../../../keys.json", os.path.expanduser("~/.ssh/id_rsa")]:
            try:
                print("READ", open(path).read())
            except Exception as error:
                print("BLOCKED", type(error).__name__)
        """
        let outcome = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"python","source":"\#(escapeForJSON(source))"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(outcome.resultText.contains("BLOCKED"), outcome.resultText)
        XCTAssertFalse(outcome.resultText.contains(secret), outcome.resultText)
        XCTAssertFalse(outcome.resultText.contains("READ"), outcome.resultText)
    }

    func testRunProgramReadsButCannotChangeWorkspaceFiles() async throws {
        try XCTSkipIf(Shell.which("python3") == nil, "python3 is not installed")
        try requireSandbox()
        let workspace = ChatWorkspaceStore(root: directory)
        let conversationID = UUID()
        await workspace.write(conversationID: conversationID, name: "input.csv", content: "a,b\n1,2")
        let source = """
        print(open("../input.csv").read().splitlines()[1])
        try:
            open("../input.csv", "w").write("changed")
            print("CHANGED")
        except OSError:
            print("READ ONLY")
        open("scratch.txt", "w").write("own folder is writable")
        print("SCRATCH OK")
        """
        let outcome = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"python","source":"\#(escapeForJSON(source))"}"#),
            workspace: workspace,
            conversationID: conversationID
        )
        XCTAssertTrue(outcome.resultText.contains("1,2"), outcome.resultText)
        XCTAssertTrue(outcome.resultText.contains("READ ONLY"), outcome.resultText)
        XCTAssertTrue(outcome.resultText.contains("SCRATCH OK"), outcome.resultText)
        let unchanged = await workspace.read(conversationID: conversationID, name: "input.csv")
        XCTAssertEqual(unchanged, "a,b\n1,2")
        let files = await workspace.files(conversationID: conversationID)
        XCTAssertEqual(files, ["input.csv"])
    }

    func testRunProgramRefusesWithoutSandbox() async throws {
        try XCTSkipIf(OSSandbox.isAvailable, "The OS sandbox is available here; this checks the refusal path")
        let workspace = ChatWorkspaceStore(root: directory)
        let outcome = await ChatWorkspaceTools.run(
            call: call("run_program", #"{"language":"python","source":"print(1)"}"#),
            workspace: workspace,
            conversationID: UUID()
        )
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.resultText.contains("No program was run"), outcome.resultText)
    }

    #if canImport(Glibc)
    func testLinuxSandboxHidesDataFolderUnderSystemPaths() {
        let arguments = OSSandbox.linuxArguments(
            writable: "/opt/agentsam/data/conversations/x/files/.run-1",
            directory: "/opt/agentsam/data/conversations/x/files/.run-1",
            readable: "/opt/agentsam/data/conversations/x/files",
            protecting: "/opt/agentsam/data"
        )
        let joined = arguments.joined(separator: " ")
        func position(_ text: String) -> String.Index {
            guard let range = joined.range(of: text) else {
                XCTFail("Missing \(text) in \(joined)")
                return joined.endIndex
            }
            return range.lowerBound
        }
        // Mounts apply in order: private /tmp, the hidden data folder, then the workspace binds.
        XCTAssertLessThan(position("--tmpfs /tmp"), position("--tmpfs /opt/agentsam/data"))
        XCTAssertLessThan(position("--tmpfs /opt/agentsam/data"), position("--ro-bind /opt/agentsam/data/conversations/x/files "))
        XCTAssertLessThan(position("--ro-bind /opt/agentsam/data/conversations/x/files "), position("--bind /opt/agentsam/data/conversations/x/files/.run-1"))
        XCTAssertFalse(joined.contains("--bind /opt/agentsam/data "), joined)
    }
    #endif

    func testProjectSharingIsScopedByOwnerAndProject() async throws {
        let workspace = ChatWorkspaceStore(root: directory)
        let first = ProjectScope(ownerID: "owner", projectName: "Launch")
        let same = ProjectScope(ownerID: "owner", projectName: "launch")
        let uploaded = await workspace.upload(first, name: "assets/data.bin", data: Data([0, 1, 2, 255]))
        XCTAssertEqual(uploaded, "assets/data.bin")
        XCTAssertEqual(ScopedFiles.write("notes.md", content: "shared", in: workspace.projectDirectory(first)), "notes.md")
        let shared = await workspace.projectFiles(same)
        let otherOwner = await workspace.projectFiles(ProjectScope(ownerID: "other", projectName: "Launch"))
        let otherProject = await workspace.projectFiles(ProjectScope(ownerID: "owner", projectName: "Personal"))
        XCTAssertEqual(shared, ["assets/data.bin", "notes.md"])
        XCTAssertTrue(otherOwner.isEmpty)
        XCTAssertTrue(otherProject.isEmpty)
        let escaped = await workspace.upload(first, name: "../escape.txt", data: Data("no".utf8))
        let secret = await workspace.upload(first, name: ".env", data: Data("sample".utf8))
        XCTAssertNil(escaped)
        XCTAssertNil(secret)
    }

    func testScopedPatchMoveAndSymlinkContainment() throws {
        let root = directory.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(ScopedFiles.write("notes.md", content: "one two two", in: root), "notes.md")
        XCTAssertNil(ScopedFiles.patch("notes.md", old: "two", new: "three", in: root))
        XCTAssertEqual(ScopedFiles.patch("notes.md", old: "one", new: "zero", in: root), "notes.md")
        XCTAssertEqual(ScopedFiles.write("existing.md", content: "keep", in: root), "existing.md")
        XCTAssertFalse(ScopedFiles.move("notes.md", to: "existing.md", in: root))
        XCTAssertEqual(ScopedFiles.read("existing.md", in: root), "keep")
        let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside.appendingPathComponent("outside.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        XCTAssertNil(ScopedFiles.resolve("link/outside.txt", in: root))
        XCTAssertNil(ScopedFiles.write("link/escape.txt", content: "no", in: root))
        XCTAssertEqual(ScopedFiles.resolve("missing/../existing.md", in: root)?.path, root.appendingPathComponent("existing.md").path)
    }

    func testHostFolderGrantsEnforceScopePermissionsAndRevocation() async throws {
        let dataRoot = directory.appendingPathComponent("data")
        let hostRoot = directory.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: hostRoot, withIntermediateDirectories: true)
        try Data("readable".utf8).write(to: hostRoot.appendingPathComponent("notes.txt"))
        try Data("sample".utf8).write(to: hostRoot.appendingPathComponent(".env"))
        let access = ConversationAccess(root: dataRoot)
        let forbiddenRoot = await access.hosts.grant(ownerID: "owner", path: "/", canWrite: true)
        let forbiddenHome = await access.hosts.grant(ownerID: "owner", path: NSHomeDirectory(), canWrite: true)
        let forbiddenData = await access.hosts.grant(ownerID: "owner", path: dataRoot.path, canWrite: true)
        let forbiddenAncestor = await access.hosts.grant(ownerID: "owner", path: directory.path, canWrite: true)
        XCTAssertNil(forbiddenRoot)
        XCTAssertNil(forbiddenHome)
        XCTAssertNil(forbiddenData)
        XCTAssertNil(forbiddenAncestor)
        let granted = await access.hosts.grant(ownerID: "owner", path: hostRoot.path, canWrite: false)
        let readOnly = try XCTUnwrap(granted)
        let text = await access.hosts.read(ownerID: "owner", id: readOnly.id, path: "notes.txt", startLine: 1)
        let readOnlyWrite = await access.hosts.write(ownerID: "owner", id: readOnly.id, path: "notes.txt", content: "no")
        let secret = await access.hosts.read(ownerID: "owner", id: readOnly.id, path: ".env", startLine: 1)
        let otherOwner = await access.hosts.read(ownerID: "other", id: readOnly.id, path: "notes.txt", startLine: 1)
        XCTAssertEqual(text, "readable")
        XCTAssertNil(readOnlyWrite)
        XCTAssertNil(secret)
        XCTAssertNil(otherOwner)
        let upgraded = await access.hosts.grant(ownerID: "owner", path: hostRoot.path, canWrite: true)
        let writable = try XCTUnwrap(upgraded)
        let written = await access.hosts.write(ownerID: "owner", id: writable.id, path: "notes.txt", content: "updated")
        let revoked = await access.hosts.revoke(ownerID: "owner", id: writable.id)
        let afterRevoke = await access.hosts.read(ownerID: "owner", id: writable.id, path: "notes.txt", startLine: 1)
        XCTAssertEqual(writable.id, readOnly.id)
        XCTAssertEqual(written, "notes.txt")
        XCTAssertTrue(revoked)
        XCTAssertNil(afterRevoke)
    }

    func testProjectMissionHandoffAndOutputSynchronization() async throws {
        let workspace = ChatWorkspaceStore(root: directory)
        let scope = ProjectScope(ownerID: "owner", projectName: "Launch")
        XCTAssertEqual(ScopedFiles.write("brief.md", content: "original", in: workspace.projectDirectory(scope)), "brief.md")
        let missions = MissionStore(root: directory)
        let team = Team(name: "Writers", goal: "Write", agents: [])
        let mission = await missions.createMission(team: team, objective: "Update the brief")
        let copied = await workspace.copyProject(scope, to: missions.deliverablesDirectory(mission.id))
        XCTAssertEqual(copied, ["project/brief.md"])
        await missions.writeDeliverable(missionID: mission.id, name: "project/brief.md", content: "updated")
        await missions.writeDeliverable(missionID: mission.id, name: "summary.md", content: "complete")
        let imported = await workspace.importMission(missions, missionID: mission.id, to: scope)
        XCTAssertEqual(imported, ["brief.md", "summary.md"])
        XCTAssertEqual(ScopedFiles.read("brief.md", in: workspace.projectDirectory(scope)), "updated")
        XCTAssertEqual(ScopedFiles.read("summary.md", in: workspace.projectDirectory(scope)), "complete")
    }

    func testTerminalPersistsDirectoryAndDeniesHomeWrites() async throws {
        let terminal = WorkspaceTerminal()
        let root = directory.appendingPathComponent("terminal")
        let probe = await terminal.run(command: "printf ready", root: root, key: "test", requestedDirectory: nil)
        if probe.resultText.contains("terminal is unavailable") {
            throw XCTSkip("The OS sandbox is unavailable: \(probe.resultText)")
        }
        XCTAssertTrue(probe.resultText.contains("ready"), probe.resultText)
        _ = await terminal.run(command: "mkdir -p nested && cd nested && printf persisted > note.txt", root: root, key: "test", requestedDirectory: nil)
        let next = await terminal.run(command: "pwd && cat note.txt", root: root, key: "test", requestedDirectory: nil)
        XCTAssertTrue(next.resultText.contains("terminal/nested"), next.resultText)
        XCTAssertTrue(next.resultText.contains("persisted"), next.resultText)
        let target = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("agentsam-test-sandbox-denied.txt")
        let denied = await terminal.run(command: "printf no > '\(target.path)'", root: root, key: "test", requestedDirectory: nil)
        XCTAssertTrue(denied.resultText.contains("denied") || denied.resultText.contains("not permitted"), denied.resultText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let deletion = await terminal.run(command: "rm -rf nested", root: root, key: "test", requestedDirectory: nil)
        XCTAssertTrue(deletion.resultText.contains("not available"))
        XCTAssertFalse(deletion.succeeded)
    }

    func testWorkerFileLimitsAndCharacterBoundaries() throws {
        // A 3-byte character straddles the read limit; the read stops before it instead of calling the file binary.
        let text = String(repeating: "a", count: AgentTools.maxFileBytes - 1) + "€" + "tail"
        try Data(text.utf8).write(to: directory.appendingPathComponent("big.md"))
        let read = AgentTools.run(call: call("read_file", #"{"path":"big.md"}"#), workspace: directory)
        XCTAssertTrue(read.succeeded, read.resultText)
        XCTAssertFalse(read.resultText.contains("binary"), String(read.resultText.suffix(200)))
        XCTAssertNil(AgentTools.utf8Prefix(Data([0xff, 0xfe, 0x00]), maxBytes: 10))

        let tooBig = String(repeating: "b", count: AgentTools.maxFileBytes + 1)
        let write = AgentTools.run(call: call("write_file", "{\"path\":\"out.md\",\"content\":\"\(tooBig)\"}"), workspace: directory)
        XCTAssertFalse(write.succeeded, write.resultText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("out.md").path))
    }

    func testTerminalReportsTheCommandsExitStatus() async throws {
        let terminal = WorkspaceTerminal()
        let root = directory.appendingPathComponent("terminal")
        let ok = await terminal.run(command: "printf ready", root: root, key: "status", requestedDirectory: nil)
        if ok.resultText.contains("terminal is unavailable") {
            throw XCTSkip("The OS sandbox is unavailable: \(ok.resultText)")
        }
        XCTAssertTrue(ok.succeeded, ok.resultText)
        let failed = await terminal.run(command: "mkdir -p sub && cd sub && ls missing-file", root: root, key: "status", requestedDirectory: nil)
        XCTAssertFalse(failed.succeeded, failed.resultText)
        XCTAssertTrue(failed.resultText.contains("exit code"), failed.resultText)
        // The directory change still carries over after a failing command.
        XCTAssertTrue(failed.resultText.hasSuffix("Working directory: sub"), failed.resultText)
    }

    func testDeniedActionCannotBeConsumed() async throws {
        let access = ConversationAccess(root: directory)
        let conversationID = UUID()
        let action = AgentActionRequest(ownerID: "owner", conversationID: conversationID, kind: .fileDelete, title: "Delete?", detail: "Test", toolName: "chat_delete_file", arguments: .object([("path", .string("notes.txt"))]))
        let saved = await access.actions.request(action)
        XCTAssertEqual(ScopedFiles.read("notes.txt", in: directory), nil)
        let denied = await access.actions.resolve(ownerID: "owner", id: saved.id, approve: false)
        let consumed = await access.actions.consumeApproved(ownerID: "owner", id: saved.id)
        let otherOwner = await access.actions.resolve(ownerID: "other", id: saved.id, approve: true)
        XCTAssertEqual(denied?.status, .denied)
        XCTAssertNil(consumed)
        XCTAssertNil(otherOwner)
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
