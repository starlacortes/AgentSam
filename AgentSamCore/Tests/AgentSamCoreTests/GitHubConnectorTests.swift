import XCTest
@testable import AgentSamCore

final class GitHubConnectorTests: XCTestCase {
    func testRepoValidationRejectsPathTricks() throws {
        XCTAssertEqual(try GitHubConnector.validRepo(" octocat/hello-world "), "octocat/hello-world")
        for bad in ["octocat", "a/b/c", "../x", "a/..", "a/b?x=1", "a/b#c", "/b", "a/", "a b/c"] {
            XCTAssertThrowsError(try GitHubConnector.validRepo(bad), bad)
        }
    }

    func testPathEncodingDropsTraversalAndEncodes() {
        XCTAssertEqual(GitHubConnector.encodedPath("src/../a b/c.txt"), "src/a%20b/c.txt")
        XCTAssertEqual(GitHubConnector.encodedPath(""), "")
    }

    func testHubExposesOnlyReadOnlyGitHubTools() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = MissionStore(root: directory)
        let keys = FileKeyRing(url: directory.appendingPathComponent("keys.json"))
        try keys.set("token", for: GitHubConnector.tokenAccount)
        let hub = ConnectorHub(store: store, keyRing: keys, google: GoogleOAuth(clientID: "", clientSecret: ""))
        let readDefs = await hub.toolDefs(readOnly: true)
        let allDefs = await hub.toolDefs()
        let names = Set(readDefs.map(\.function.name).filter { $0.hasPrefix("github_") })
        XCTAssertEqual(names, ["github_repos", "github_read", "github_search", "github_issues", "github_issue"])
        XCTAssertEqual(Set(allDefs.map(\.function.name).filter { $0.hasPrefix("github_") }), names)
        await store.saveConnectorConfigs([ConnectorConfig(id: .github, enabled: true, permissions: ConnectorPermissions(githubWrite: true))])
        let writeNames = Set(await hub.toolDefs().map(\.function.name).filter { $0.hasPrefix("github_") })
        XCTAssertTrue(writeNames.isSuperset(of: ["github_write_file", "github_comment"]))
        let denied = await hub.run(call: APIToolCall(id: "1", function: .init(name: "github_write_file", arguments: "{}")), readOnly: true)
        XCTAssertTrue(denied.resultText.contains("read-only"))
        let noPermission = await hub.run(call: APIToolCall(id: "2", function: .init(name: "github_comment", arguments: "{}")), scope: ToolScope(connectorIDs: [.github]), approved: true)
        XCTAssertTrue(noPermission.resultText.contains("disabled"))
        XCTAssertFalse(noPermission.succeeded)
        hub.disconnect(.github)
        XCTAssertFalse(hub.isConfigured(.github))
    }
}

extension GitHubConnectorTests {
    func testOldPermissionsJSONStillDecodes() throws {
        let old = #"{"sendEmail":true,"createDraft":false,"dnsWrite":false}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConnectorPermissions.self, from: old)
        XCTAssertTrue(decoded.sendEmail)
        XCTAssertFalse(decoded.githubWrite)
    }
}
