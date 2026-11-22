@testable import AgentSamServer
import XCTVapor
import AgentSamCore
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Records push requests and answers with a chosen status per endpoint path.
final class PushServiceStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var status: [String: Int] = [:]
    private static let lock = NSLock()

    static func reset() { lock.lock(); requests = []; status = [:]; lock.unlock() }
    static func recorded() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let code = Self.status[request.url?.path ?? ""] ?? 201
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class WebPushTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-push-\(UUID().uuidString)")
        PushServiceStub.reset()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func center() -> WebPushCenter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PushServiceStub.self]
        return WebPushCenter(dataDir: directory, contact: "mailto:test@example.com", session: URLSession(configuration: configuration))
    }

    func testOnlyKnownPushServicesCanBeSubscribed() {
        XCTAssertTrue(WebPushCenter.validEndpoint("https://fcm.googleapis.com/fcm/send/abc"))
        XCTAssertTrue(WebPushCenter.validEndpoint("https://web.push.apple.com/QGx"))
        XCTAssertTrue(WebPushCenter.validEndpoint("https://updates.push.services.mozilla.com/wpush/v2/x"))
        XCTAssertFalse(WebPushCenter.validEndpoint("http://fcm.googleapis.com/fcm/send/abc"), "plain http")
        XCTAssertFalse(WebPushCenter.validEndpoint("https://169.254.169.254/latest"), "internal address")
        XCTAssertFalse(WebPushCenter.validEndpoint("https://evilpush.apple.com.attacker.test/x"))
        XCTAssertFalse(WebPushCenter.validEndpoint("https://notfcm.googleapis.com.example/x"))
    }

    func testVapidTokenIsSignedByTheAdvertisedKeyAndKeyPersists() async throws {
        let push = center()
        let token = await push.vapidToken(audience: "https://fcm.googleapis.com")
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let publicKey = try P256.Signing.PublicKey(x963Representation: Self.decode(await push.publicKey()))
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Self.decode(parts[2]))
        XCTAssertTrue(publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.decode(parts[1])) as? [String: Any])
        XCTAssertEqual(claims["aud"] as? String, "https://fcm.googleapis.com")
        XCTAssertEqual(claims["sub"] as? String, "mailto:test@example.com")
        // A new center on the same data folder keeps the same key, so browsers stay subscribed.
        let reloaded = WebPushCenter(dataDir: directory, contact: "mailto:test@example.com")
        let first = await push.publicKey()
        let second = await reloaded.publicKey()
        XCTAssertEqual(first, second)
    }

    func testNotifySendsEmptyVapidPushesAndForgetsGoneSubscriptions() async {
        let push = center()
        let kept = await push.subscribe(ownerID: "owner", endpoint: "https://fcm.googleapis.com/fcm/send/kept", label: "Phone")
        let gone = await push.subscribe(ownerID: "owner", endpoint: "https://fcm.googleapis.com/fcm/send/gone", label: "Old")
        let other = await push.subscribe(ownerID: "someone-else", endpoint: "https://fcm.googleapis.com/fcm/send/other", label: nil)
        let refused = await push.subscribe(ownerID: "owner", endpoint: "https://example.com/push", label: nil)
        XCTAssertTrue(kept && gone && other)
        XCTAssertFalse(refused)
        PushServiceStub.status["/fcm/send/gone"] = 410

        let delivered = await push.notify(ownerID: "owner")
        XCTAssertEqual(delivered, 1)
        let requests = PushServiceStub.recorded()
        XCTAssertEqual(Set(requests.compactMap { $0.url?.path }), ["/fcm/send/kept", "/fcm/send/gone"], "only the owner's devices")
        for request in requests {
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "TTL"), "86400")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("vapid t=") == true)
        }
        let remaining = await push.subscriptions(ownerID: "owner").map(\.endpoint)
        XCTAssertEqual(remaining, ["https://fcm.googleapis.com/fcm/send/kept"])
    }

    func testApprovalRequestsWakeTheNotifier() async throws {
        let access = ConversationAccess(root: directory)
        let woken = Woken()
        await access.actions.setNotifier { action in await woken.add(action.ownerID) }
        let action = AgentActionRequest(ownerID: "owner", conversationID: UUID(), kind: .connectorWrite, title: "Approve", detail: "", toolName: "gmail_send", arguments: .object([]))
        await access.actions.request(action)
        for _ in 0..<50 where await woken.values.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        let owners = await woken.values
        XCTAssertEqual(owners, ["owner"])
        let pending = await access.actions.pending(ownerID: "owner")
        XCTAssertEqual(pending.map(\.id), [action.id])
        let none = await access.actions.pending(ownerID: "someone-else")
        XCTAssertTrue(none.isEmpty)
    }

    func testPushRoutesSubscribeAndDescribeWhatIsWaiting() async throws {
        setenv("AGENTSAM_DATA", directory.path, 1)
        setenv("AGENTSAM_TOKEN", "push-test-token", 1)
        setenv("AGENTSAM_WEB_DIR", directory.appendingPathComponent("none").path, 1)
        let app = try await Application.make(.testing)
        try await configure(app)
        let authorize: (inout XCTHTTPRequest) throws -> Void = { $0.headers.bearerAuthorization = BearerAuthorization(token: "push-test-token") }
        try await app.test(.GET, "api/push/key", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertEqual(try res.content.decode(PushKeyView.self).devices, 0)
        })
        try await app.test(.POST, "api/push/subscribe", beforeRequest: { req in
            try authorize(&req)
            try req.content.encode(PushSubscribeBody(endpoint: "http://127.0.0.1:8080/steal", label: nil), as: .json)
        }, afterResponse: { res async in XCTAssertEqual(res.status, .badRequest) })
        try await app.test(.POST, "api/push/subscribe", beforeRequest: { req in
            try authorize(&req)
            try req.content.encode(PushSubscribeBody(endpoint: "https://fcm.googleapis.com/fcm/send/device", label: "Phone"), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            XCTAssertEqual(try res.content.decode(PushKeyView.self).devices, 1)
        })
        try await app.test(.GET, "api/push/latest", beforeRequest: authorize, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode(PushLatestView.self).body, "Nothing is waiting right now.")
        })
        let ctx = try XCTUnwrap(app.storage[ServerContextKey.self])
        let conversationID = UUID()
        let owner = "shared-server-token"
        await ctx.access.actions.setNotifier(nil)
        await ctx.access.actions.request(AgentActionRequest(ownerID: owner, conversationID: conversationID, kind: .connectorWrite, title: "Approve", detail: "", toolName: "gmail_send", arguments: .object([])))
        try await app.test(.GET, "api/push/latest", beforeRequest: authorize, afterResponse: { res async throws in
            let view = try res.content.decode(PushLatestView.self)
            XCTAssertEqual(view.title, "Ada needs your approval")
            XCTAssertEqual(view.url, "/chats/\(conversationID.uuidString)")
        })
        try await app.asyncShutdown()
    }

    private actor Woken {
        var values: [String] = []
        func add(_ value: String) { values.append(value) }
    }

    static func decode(_ value: String) throws -> Data {
        let padded = (value + String(repeating: "=", count: (4 - value.count % 4) % 4)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return try XCTUnwrap(Data(base64Encoded: padded))
    }
}
