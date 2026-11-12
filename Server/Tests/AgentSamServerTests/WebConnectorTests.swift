import XCTest
import AgentSamCore

final class WebConnectorTests: XCTestCase {
    func testAllowsPublicAddresses() {
        for raw in ["https://example.com/page", "http://news.ycombinator.com", "https://8.8.8.8/x"] {
            XCTAssertTrue(WebConnector.isAllowed(URL(string: raw)!), raw)
        }
    }

    func testBlocksPrivateAndNonWebAddresses() {
        let blocked = [
            "http://localhost:8080", "http://127.0.0.1", "http://10.0.0.5", "http://172.20.1.1",
            "http://192.168.1.1", "http://169.254.169.254/latest/meta-data", "http://100.64.0.1",
            "http://agentsam.railway.internal", "http://printer.local", "http://intranet",
            "http://[::1]/", "file:///etc/passwd", "ftp://example.com",
        ]
        for raw in blocked {
            XCTAssertFalse(WebConnector.isAllowed(URL(string: raw)!), raw)
        }
    }

    func testPlainTextStripsMarkup() {
        let html = "<html><head><title>T</title><style>p{}</style></head><body><script>x()</script><h1>Hello</h1><p>Fish &amp; chips</p></body></html>"
        XCTAssertEqual(WebConnector.plainText(html), "Hello\nFish & chips")
    }

    func testSearchToolOnlyWithKey() {
        let ring = MemoryKeyRing()
        XCTAssertEqual(WebConnector().toolDefs(keyRing: ring).map { $0.function.name }, ["web_fetch"])
        try? ring.set("k", for: WebConnector.braveKeyAccount)
        XCTAssertEqual(WebConnector().toolDefs(keyRing: ring).map { $0.function.name }, ["web_fetch", "web_search"])
    }
}

private final class MemoryKeyRing: KeyRing, @unchecked Sendable {
    private var values: [String: String] = [:]
    func get(_ account: String) -> String? { values[account] }
    func set(_ value: String, for account: String) throws { values[account] = value }
    func remove(_ account: String) { values[account] = nil }
}
