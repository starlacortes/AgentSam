import Foundation
import Crypto
import AgentSamCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One browser's push subscription, owned by one signed-in owner.
struct PushSubscriptionRecord: Codable, Sendable, Equatable {
    var ownerID: String
    var endpoint: String
    var createdAt: Date
    var label: String?
}

/// Phone and browser alerts through the standard Web Push protocol (RFC 8030 + VAPID, RFC 8292).
///
/// Pushes carry no payload, so nothing about an approval leaves the server through the push service:
/// the service worker wakes, asks `/api/push/latest` (same-origin, signed in) what is waiting, and
/// shows that. This avoids the payload encryption of RFC 8291 entirely.
actor WebPushCenter {
    /// Push services that browsers use. Subscriptions to any other host are refused, so a stored
    /// endpoint can never point the server at an internal address.
    static let allowedHostSuffixes = [
        "fcm.googleapis.com", "android.googleapis.com",
        "push.services.mozilla.com",
        "push.apple.com",
        "notify.windows.com",
    ]
    static let maxPerOwner = 10

    private struct StoredKey: Codable { var privateKey: String }

    private let directory: URL
    private let contact: String
    private let session: URLSession
    private var key: P256.Signing.PrivateKey?

    init(dataDir: URL, contact: String, session: URLSession = .shared) {
        directory = dataDir.appendingPathComponent("push", isDirectory: true)
        self.contact = contact
        self.session = session
    }

    // MARK: Keys

    /// The VAPID public key browsers subscribe with: an uncompressed P-256 point, base64url.
    func publicKey() -> String {
        Self.base64URL(signingKey().publicKey.x963Representation)
    }

    private func signingKey() -> P256.Signing.PrivateKey {
        if let key { return key }
        let url = directory.appendingPathComponent("vapid.json")
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(StoredKey.self, from: data),
           let raw = Data(base64Encoded: stored.privateKey),
           let loaded = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            key = loaded
            return loaded
        }
        let created = P256.Signing.PrivateKey()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(StoredKey(privateKey: created.rawRepresentation.base64EncodedString())) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        key = created
        return created
    }

    // MARK: Subscriptions

    static func validEndpoint(_ endpoint: String) -> Bool {
        guard endpoint.count <= 2_000, let url = URL(string: endpoint), url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func subscriptions(ownerID: String) -> [PushSubscriptionRecord] {
        load().filter { $0.ownerID == ownerID }
    }

    @discardableResult
    func subscribe(ownerID: String, endpoint: String, label: String?) -> Bool {
        guard Self.validEndpoint(endpoint) else { return false }
        var all = load().filter { $0.endpoint != endpoint }
        all.append(PushSubscriptionRecord(ownerID: ownerID, endpoint: endpoint, createdAt: Date(), label: label.map { String($0.prefix(80)) }))
        // Keep the newest few per owner.
        let mine = all.filter { $0.ownerID == ownerID }
        if mine.count > Self.maxPerOwner {
            let drop = Set(mine.sorted { $0.createdAt < $1.createdAt }.prefix(mine.count - Self.maxPerOwner).map(\.endpoint))
            all.removeAll { drop.contains($0.endpoint) }
        }
        save(all)
        return true
    }

    func unsubscribe(ownerID: String, endpoint: String) {
        save(load().filter { !($0.ownerID == ownerID && $0.endpoint == endpoint) })
    }

    // MARK: Sending

    /// Wakes every device the owner subscribed. Returns how many push services accepted it.
    @discardableResult
    func notify(ownerID: String) async -> Int {
        var delivered = 0
        for record in subscriptions(ownerID: ownerID) {
            guard let url = URL(string: record.endpoint), let audience = Self.audience(of: url) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.setValue("86400", forHTTPHeaderField: "TTL")
            request.setValue("high", forHTTPHeaderField: "Urgency")
            request.setValue("0", forHTTPHeaderField: "Content-Length")
            request.setValue("vapid t=\(vapidToken(audience: audience)), k=\(publicKey())", forHTTPHeaderField: "Authorization")
            guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { continue }
            if (200..<300).contains(http.statusCode) {
                delivered += 1
            } else if http.statusCode == 404 || http.statusCode == 410 {
                // The browser dropped this subscription; forget it.
                unsubscribe(ownerID: ownerID, endpoint: record.endpoint)
            }
        }
        return delivered
    }

    static func audience(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return url.port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// A VAPID JWT (ES256), valid for 12 hours.
    func vapidToken(audience: String, now: Date = Date()) -> String {
        let header = Self.base64URL(Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8))
        let claims: [String: Any] = ["aud": audience, "exp": Int(now.timeIntervalSince1970) + 12 * 3600, "sub": contact]
        let body = Self.base64URL((try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])) ?? Data())
        let input = "\(header).\(body)"
        let signature = (try? signingKey().signature(for: Data(input.utf8)).rawRepresentation) ?? Data()
        return "\(input).\(Self.base64URL(signature))"
    }

    // MARK: Storage

    private var subscriptionsURL: URL { directory.appendingPathComponent("subscriptions.json") }

    private func load() -> [PushSubscriptionRecord] {
        guard let data = try? Data(contentsOf: subscriptionsURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([PushSubscriptionRecord].self, from: data)) ?? []
    }

    private func save(_ records: [PushSubscriptionRecord]) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(records) else { return }
        try? data.write(to: subscriptionsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: subscriptionsURL.path)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
