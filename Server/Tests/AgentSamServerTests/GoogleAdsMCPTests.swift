@testable import AgentSamServer
import XCTest
import Foundation
import AgentSamCore

final class GoogleAdsMCPTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ads-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func keyRing() -> FileKeyRing { FileKeyRing(url: directory.appendingPathComponent("keys.json")) }

    private func object(_ data: Data?) throws -> [String: String] {
        let data = try XCTUnwrap(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    func testConfigIsOffUnlessTurnedOn() {
        XCTAssertFalse(GoogleAdsMCPConfig.fromEnvironment([:]).enabled)
        let on = GoogleAdsMCPConfig.fromEnvironment(["AGENTSAM_GOOGLE_ADS_MCP": "1", "AGENTSAM_GOOGLE_ADS_MCP_PORT": "9001"])
        XCTAssertTrue(on.enabled)
        XCTAssertEqual(on.url, "http://127.0.0.1:9001/mcp")
        XCTAssertEqual(on.launcher, "/opt/google-ads-mcp/ada_launch.py")
        XCTAssertNotNil(MCPRegistry.validURL(on.url), "Ada's MCP client accepts the loopback URL")
        XCTAssertEqual(GoogleAdsMCPConfig.fromEnvironment(["AGENTSAM_GOOGLE_ADS_MCP": "true", "AGENTSAM_GOOGLE_ADS_MCP_PORT": "80"]).port, GoogleAdsMCPConfig.defaultPort)
    }

    func testNoCredentialsUntilGoogleAdsIsConnected() throws {
        let keys = keyRing()
        XCTAssertNil(GoogleAdsMCPCredentials.adcJSON(keyRing: keys, clientID: "id", clientSecret: "secret"))
        try keys.set("refresh-1", for: GoogleTokenProvider.refreshAccount(for: .googleads))
        XCTAssertNil(GoogleAdsMCPCredentials.adcJSON(keyRing: keys, clientID: "", clientSecret: ""), "a refresh token needs the OAuth client to be usable")
    }

    func testSignedInAccountBecomesAuthorizedUserCredentials() throws {
        let keys = keyRing()
        try keys.set("refresh-1", for: GoogleTokenProvider.refreshAccount(for: .googleads))
        let adc = try object(GoogleAdsMCPCredentials.adcJSON(keyRing: keys, clientID: "client.apps.googleusercontent.com", clientSecret: "shh"))
        XCTAssertEqual(adc, ["type": "authorized_user", "client_id": "client.apps.googleusercontent.com", "client_secret": "shh", "refresh_token": "refresh-1"])
    }

    func testServiceAccountWinsLikeAdasOwnTools() throws {
        let keys = keyRing()
        try keys.set("refresh-1", for: GoogleTokenProvider.refreshAccount(for: .googleads))
        let key = #"{"type":"service_account","client_email":"ada@project.iam.gserviceaccount.com","private_key":"-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n","private_key_id":"k1"}"#
        try keys.set(key, for: GoogleTokenProvider.serviceAccountAccount(for: .googleads))
        let adc = try object(GoogleAdsMCPCredentials.adcJSON(keyRing: keys, clientID: "id", clientSecret: "secret"))
        XCTAssertEqual(adc["type"], "service_account")
        XCTAssertEqual(adc["client_email"], "ada@project.iam.gserviceaccount.com")
        XCTAssertEqual(adc["private_key_id"], "k1")
        XCTAssertEqual(adc["token_uri"], GoogleOAuth.tokenEndpoint.absoluteString)
    }

    func testEnvironmentCarriesOnlyWhatTheServerNeeds() throws {
        let keys = keyRing()
        try keys.set("dev-token", for: GoogleAdsConnector.developerTokenAccount)
        try keys.set("756-911-6792", for: GoogleAdsConnector.customerIdAccount)
        let config = GoogleAdsMCPConfig.fromEnvironment(["AGENTSAM_GOOGLE_ADS_MCP": "1"])
        let env = GoogleAdsMCPCredentials.environment(config: config, home: directory, credentialsPath: "/tmp/x/adc.json", token: "t0k3n", keyRing: keys)
        XCTAssertEqual(env["GOOGLE_APPLICATION_CREDENTIALS"], "/tmp/x/adc.json")
        XCTAssertEqual(env["GOOGLE_ADS_DEVELOPER_TOKEN"], "dev-token")
        XCTAssertEqual(env["GOOGLE_ADS_LOGIN_CUSTOMER_ID"], "7569116792")
        XCTAssertEqual(env["ADA_MCP_TOKEN"], "t0k3n")
        XCTAssertEqual(env["PORT"], "8765")
        XCTAssertEqual(env["GOOGLE_ADS_MCP_TOOLS_CONFIG"], "/opt/google-ads-mcp/tools_config.yaml")
        XCTAssertNil(env["GOOGLE_ADS_MCP_OAUTH_CLIENT_ID"], "the upstream OAuth proxy stays off")
        XCTAssertFalse(env.keys.contains { $0.hasPrefix("AGENTSAM_") }, "Ada's own secrets are not handed to the server")
    }
}
