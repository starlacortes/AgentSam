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
