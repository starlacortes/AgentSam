import XCTest
@testable import AgentSamCore

final class ConnectorPrimitiveTests: XCTestCase {
    func testSHA256Vector() {
        // Well-known NIST vector: SHA-256("abc")
        let digest = SHA256Hash.digest(Data("abc".utf8))
        XCTAssertEqual(
            digest.map { String(format: "%02x", $0) }.joined(),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testBase64urlRoundTrip() {
        let data = Data("hello world ✉️".utf8)
        let encoded = GoogleOAuth.base64url(data)
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("="))
        XCTAssertEqual(GoogleOAuth.decodeBase64url(encoded), data)
    }

    func testPKCEChallengeMatchesRFC7636Vector() {
        // RFC 7636 Appendix B test vector.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        XCTAssertEqual(
            GoogleOAuth.challenge(for: verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testGmailRawMessageIsBase64urlMIME() {
        let raw = GmailConnector.rawMessage(to: "a@b.c", subject: "Hi", body: "Body")
        guard let decoded = GoogleOAuth.decodeBase64url(raw),
              let mime = String(data: decoded, encoding: .utf8) else {
            XCTFail("raw message did not decode")
            return
        }
        XCTAssertTrue(mime.hasPrefix("To: a@b.c\r\nSubject: Hi\r\n"))
        XCTAssertTrue(mime.hasSuffix("\r\n\r\nBody"))
    }

    func testGoogleAdsWriteToolsAreGatedAndBuildMutates() throws {
        let ads = GoogleAdsConnector()
        let writeTools = ["googleads_set_status", "googleads_set_budget", "googleads_mutate", "googleads_validate"]
        let readNames = ads.toolDefs(permissions: ConnectorPermissions()).map(\.function.name)
        let writeNames = ads.toolDefs(permissions: ConnectorPermissions(adsWrite: true)).map(\.function.name)
        for tool in writeTools {
            XCTAssertFalse(readNames.contains(tool))
            XCTAssertTrue(writeNames.contains(tool))
        }
        // Real changes go through an approval card; the dry run does not.
        XCTAssertFalse(ConnectorHub.readOnlyToolNames.contains("googleads_set_status"))
        XCTAssertFalse(ConnectorHub.readOnlyToolNames.contains("googleads_set_budget"))
        XCTAssertFalse(ConnectorHub.readOnlyToolNames.contains("googleads_mutate"))
        XCTAssertTrue(ConnectorHub.readOnlyToolNames.contains("googleads_validate"))

        XCTAssertEqual(GoogleAdsConnector.cleanCampaignID("123"), "123")
        XCTAssertEqual(GoogleAdsConnector.cleanCampaignID("customers/9/campaigns/456"), "456")
        XCTAssertNil(GoogleAdsConnector.cleanCampaignID("abc"))
        XCTAssertNil(GoogleAdsConnector.cleanCampaignID(""))
        XCTAssertNil(GoogleAdsConnector.cleanCampaignID(nil))
        XCTAssertEqual(GoogleAdsConnector.cleanEntityID("customers/9/adGroupAds/12~34", composite: true), "12~34")
        XCTAssertNil(GoogleAdsConnector.cleanEntityID("1234", composite: true))
        XCTAssertNil(GoogleAdsConnector.cleanEntityID("12~34", composite: false))

        let body = GoogleAdsConnector.campaignStatusBody(customerID: "111", campaignID: "222", status: "PAUSED")
        let operation = try XCTUnwrap((body["operations"] as? [[String: Any]])?.first)
        XCTAssertEqual(operation["updateMask"] as? String, "status")
        let update = try XCTUnwrap(operation["update"] as? [String: Any])
        XCTAssertEqual(update["resourceName"] as? String, "customers/111/campaigns/222")
        XCTAssertEqual(update["status"] as? String, "PAUSED")

        let adGroup = GoogleAdsConnector.statusBody(customerID: "111", service: "adGroups", id: "333", status: "ENABLED")
        let adGroupUpdate = try XCTUnwrap(((adGroup["operations"] as? [[String: Any]])?.first)?["update"] as? [String: Any])
        XCTAssertEqual(adGroupUpdate["resourceName"] as? String, "customers/111/adGroups/333")
    }

    func testGoogleAdsBudgetIsSentInMicros() throws {
        XCTAssertEqual(GoogleAdsConnector.micros(25), 25_000_000)
        XCTAssertEqual(GoogleAdsConnector.micros(12.346), 12_350_000)
        let body = GoogleAdsConnector.budgetBody(customerID: "1", budgetID: "2", amountMicros: 25_000_000)
        let operation = try XCTUnwrap((body["operations"] as? [[String: Any]])?.first)
        XCTAssertEqual(operation["updateMask"] as? String, "amountMicros")
        let update = try XCTUnwrap(operation["update"] as? [String: Any])
        XCTAssertEqual(update["resourceName"] as? String, "customers/1/campaignBudgets/2")
        XCTAssertEqual(update["amountMicros"] as? String, "25000000")
    }

    func testGoogleAdsMutateBodyAndResponses() throws {
        let operations: [JSONValue] = [.object(["update": .object(["resourceName": .string("customers/1/adGroups/2"), "cpcBidMicros": .number(1_500_000)]), "updateMask": .string("cpcBidMicros")])]
        let body = GoogleAdsConnector.mutateBody(service: "adGroups", operations: operations, validateOnly: true, partialFailure: false)
        XCTAssertEqual(body["validateOnly"] as? Bool, true)
        XCTAssertNil(body["partialFailure"])
        let json = String(data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"cpcBidMicros\":1500000"), json)

        let multi = GoogleAdsConnector.mutateBody(service: "googleAds", operations: operations, validateOnly: false, partialFailure: true)
        XCTAssertNotNil(multi["mutateOperations"])
        XCTAssertNil(multi["operations"])
        XCTAssertNil(multi["validateOnly"])
        XCTAssertEqual(multi["partialFailure"] as? Bool, true)

        XCTAssertEqual(GoogleAdsConnector.resourceNames(in: ["results": [["resourceName": "customers/1/campaigns/2"]]]), ["customers/1/campaigns/2"])
        XCTAssertEqual(GoogleAdsConnector.resourceNames(in: ["mutateOperationResponses": [["campaignBudgetResult": ["resourceName": "customers/1/campaignBudgets/3"]]]]), ["customers/1/campaignBudgets/3"])
    }

    func testPermissionsDecodeWithoutAdsWriteAndIntersect() throws {
        let old = try JSONDecoder().decode(ConnectorPermissions.self, from: Data(#"{"sendEmail":true,"createDraft":false,"dnsWrite":true,"githubWrite":false}"#.utf8))
        XCTAssertFalse(old.adsWrite)
        XCTAssertTrue(old.sendEmail)
        let both = ConnectorPermissions(sendEmail: true, dnsWrite: false, adsWrite: true).intersected(with: ConnectorPermissions(sendEmail: true, dnsWrite: true, adsWrite: false))
        XCTAssertEqual(both, ConnectorPermissions(sendEmail: true))
        XCTAssertEqual(old.intersected(with: .all), old)
    }

    func testFileKeyRingPersistsAndReadsBackValues() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-keyring-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = FileKeyRing(url: directory.appendingPathComponent("nested/keys.json"))
        try keys.set("dummy-test-key", for: "provider.test")
        XCTAssertEqual(keys.get("provider.test"), "dummy-test-key")
        let reloaded = FileKeyRing(url: directory.appendingPathComponent("nested/keys.json"))
        XCTAssertEqual(reloaded.get("provider.test"), "dummy-test-key")
    }

    func testConnectorConfigRoundTrip() throws {
        let config = ConnectorConfig(id: .gmail, enabled: false, permissions: ConnectorPermissions(sendEmail: true, createDraft: false, dnsWrite: false))
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ConnectorConfig.self, from: data)
        XCTAssertEqual(decoded, config)
    }

    func testConnectorStatusCodable() throws {
        let status = ConnectorStatus(id: .cloudflare, name: "Cloudflare", detail: "d", enabled: true, configured: false, permissions: ConnectorPermissions(dnsWrite: true), oauthAvailable: false)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(ConnectorStatus.self, from: data)
        XCTAssertEqual(decoded.id, .cloudflare)
        XCTAssertTrue(decoded.permissions.dnsWrite)
    }
}
