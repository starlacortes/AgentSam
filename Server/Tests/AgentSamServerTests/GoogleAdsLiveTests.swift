@testable import AgentSamServer
import XCTest
import Foundation
import AgentSamCore

/// Live calls against the Google Ads API with a service-account key. Skipped unless
/// AGENTSAM_TEST_GOOGLEADS_KEY points at the key JSON, e.g.
///   AGENTSAM_TEST_GOOGLEADS_KEY=$PWD/secrets/google-ads-service-account.json swift test --filter GoogleAdsLive
/// Optionally set AGENTSAM_TEST_GOOGLEADS_CUSTOMER to a 10-digit customer ID.
final class GoogleAdsLiveTests: XCTestCase {
    private func makeRuntime() throws -> (ConnectorRuntime, URL) {
        guard let keyPath = ProcessInfo.processInfo.environment["AGENTSAM_TEST_GOOGLEADS_KEY"], !keyPath.isEmpty else {
            throw XCTSkip("Set AGENTSAM_TEST_GOOGLEADS_KEY to run live Google Ads tests.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ads-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyRing = FileKeyRing(url: dir.appendingPathComponent("keys.json"))
        try keyRing.set(keyPath, for: GoogleTokenProvider.serviceAccountAccount(for: .googleads))
        if let customer = ProcessInfo.processInfo.environment["AGENTSAM_TEST_GOOGLEADS_CUSTOMER"], !customer.isEmpty {
            try keyRing.set(customer, for: GoogleAdsConnector.customerIdAccount)
        }
        let google = GoogleOAuth(rs256Signer: GoogleRS256.sign)
        return (ConnectorRuntime(keyRing: keyRing, session: google.session, google: google), dir)
    }

    func testToolsReturnData() async throws {
        let (runtime, dir) = try makeRuntime()
        defer { try? FileManager.default.removeItem(at: dir) }
        let connector = GoogleAdsConnector()
        XCTAssertTrue(connector.isConfigured(keyRing: runtime.keyRing))

        let test = await connector.test(runtime: runtime)
        XCTAssertTrue(test.ok, test.message)

        let accounts = await connector.run("googleads_accounts", args: [:], permissions: ConnectorPermissions(), runtime: runtime)
        XCTAssertFalse(accounts.resultText.contains("error"), accounts.resultText)
        XCTAssertTrue(accounts.resultText.contains("customers/"), accounts.resultText)

        let customer = accounts.resultText
            .components(separatedBy: "customers/").dropFirst().first?
            .prefix { $0.isNumber }
        let args: [String: JSONValue] = customer.map { ["customer_id": .string(String($0))] } ?? [:]

        let campaigns = await connector.run("googleads_campaigns", args: args, permissions: ConnectorPermissions(), runtime: runtime)
        XCTAssertTrue(campaigns.resultText.hasPrefix("Customer:"), campaigns.resultText)

        var queryArgs = args
        queryArgs["query"] = .string("SELECT customer.id, customer.descriptive_name FROM customer")
        let query = await connector.run("googleads_query", args: queryArgs, permissions: ConnectorPermissions(), runtime: runtime)
        XCTAssertTrue(query.resultText.contains("descriptiveName"), query.resultText)
        print(accounts.resultText, campaigns.resultText.prefix(600), query.resultText, separator: "\n---\n")
    }
}
