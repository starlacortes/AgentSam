import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal dependency-free SHA-256 used for OAuth PKCE challenges. Works identically on macOS and Linux.
enum SHA256Hash {
    static func digest(_ data: Data) -> Data {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]

        var h0: UInt32 = 0x6a09e667
        var h1: UInt32 = 0xbb67ae85
        var h2: UInt32 = 0x3c6ef372
        var h3: UInt32 = 0xa54ff53a
        var h4: UInt32 = 0x510e527f
        var h5: UInt32 = 0x9b05688c
        var h6: UInt32 = 0x1f83d9ab
        var h7: UInt32 = 0x5be0cd19

        var message = data
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        message.append(Data(withUnsafeBytes(of: bitLength.bigEndian) { Data($0) }))

        let blockCount = message.count / 64
        for blockIndex in 0..<blockCount {
            let base = blockIndex * 64
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let start = base + i * 4
                w[i] = message.subdata(in: start..<start + 4).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }

            var a = h0, b = h1, c = h2, d = h3
            var e = h4, f = h5, g = h6, h = h7

            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                h = g; g = f; f = e
                e = d &+ temp1
                d = c; c = b; b = a
                a = temp1 &+ temp2
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
            h5 = h5 &+ f
            h6 = h6 &+ g
            h7 = h7 &+ h
        }

        var out = Data()
        for word in [h0, h1, h2, h3, h4, h5, h6, h7] {
            out.append(Data(withUnsafeBytes(of: word.bigEndian) { Data($0) }))
        }
        return out
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        (x >> n) | (x << (32 - n))
    }
}

/// OAuth 2.0 client for Google APIs: builds authorization URLs, exchanges codes, and refreshes access tokens.
public struct GoogleOAuth: Sendable {
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!
    public static let authorizeEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!

    public let clientID: String
    public let clientSecret: String
    public let session: URLSession

    public init(clientID: String = "", clientSecret: String = "", session: URLSession? = nil) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: config)
        }
    }

    public var isConfigured: Bool { !clientID.isEmpty }

    public struct TokenResult: Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresIn: Int

        public init(accessToken: String, refreshToken: String?, expiresIn: Int) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresIn = expiresIn
        }
    }

    public func authorizeURL(redirectURI: String, state: String, scopes: [String], codeVerifier: String? = nil, prompt: String? = nil) -> URL? {
        var components = URLComponents(url: Self.authorizeEndpoint, resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "include_granted_scopes", value: "true"),
            URLQueryItem(name: "state", value: state),
        ]
        if let codeVerifier {
            items.append(URLQueryItem(name: "code_challenge", value: Self.challenge(for: codeVerifier)))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        if let prompt {
            items.append(URLQueryItem(name: "prompt", value: prompt))
        }
        components?.queryItems = items
        return components?.url
    }

    public func exchangeCode(code: String, redirectURI: String, codeVerifier: String? = nil) async throws -> TokenResult {
        var params: [String: String] = [
            "code": code,
            "client_id": clientID,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI,
        ]
        if !clientSecret.isEmpty { params["client_secret"] = clientSecret }
        if let codeVerifier { params["code_verifier"] = codeVerifier }
        return try await tokenRequest(params)
    }

    public func refreshAccessToken(refreshToken: String) async throws -> TokenResult {
        var params: [String: String] = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "grant_type": "refresh_token",
        ]
        if !clientSecret.isEmpty { params["client_secret"] = clientSecret }
        return try await tokenRequest(params)
    }

    private func tokenRequest(_ params: [String: String]) async throws -> TokenResult {
        let data = try await ConnectorHTTP.request(session, url: Self.tokenEndpoint, method: "POST", formBody: params)
        let object = try ConnectorHTTP.jsonObject(data)
        if let errorText = object["error"] as? String {
            let description = object["error_description"] as? String ?? ""
            throw ConnectorError("Google OAuth error: \(errorText)\(description.isEmpty ? "" : " — \(description)")")
        }
        guard let accessToken = object["access_token"] as? String else {
            throw ConnectorError("Google token endpoint did not return an access token.")
        }
        return TokenResult(
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            expiresIn: object["expires_in"] as? Int ?? 3600
        )
    }

    // MARK: PKCE helpers

    public static func newVerifier() -> (verifier: String, challenge: String) {
        let verifier = randomString(length: 64)
        return (verifier, challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        base64url(SHA256Hash.digest(Data(verifier.utf8)))
    }

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decodeBase64url(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }

    static func randomString(length: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<length).map { _ in chars[Int.random(in: 0..<chars.count)] })
    }
}

/// Per-connector Google access-token provider with a small cache persisted in the key ring.
public struct GoogleTokenProvider: Sendable {
    public let connectorID: ConnectorID
    public let keyRing: KeyRing
    public let oauth: GoogleOAuth

    public init(connectorID: ConnectorID, keyRing: KeyRing, oauth: GoogleOAuth) {
        self.connectorID = connectorID
        self.keyRing = keyRing
        self.oauth = oauth
    }

    public static func refreshAccount(for id: ConnectorID) -> String {
        "connector.\(id.rawValue).refreshToken"
    }

    public static func cacheAccount(for id: ConnectorID) -> String {
        "connector.\(id.rawValue).accessTokenCache"
    }

    public var hasCredentials: Bool {
        !(keyRing.get(Self.refreshAccount(for: connectorID)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func accessToken() async throws -> String? {
        guard oauth.isConfigured else { return nil }
        if let cached = loadCache(), cached.expiresAt > Date().addingTimeInterval(120).timeIntervalSince1970, !cached.token.isEmpty {
            return cached.token
        }
        guard let refreshToken = keyRing.get(Self.refreshAccount(for: connectorID))?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            return nil
        }
        let result = try await oauth.refreshAccessToken(refreshToken: refreshToken)
        saveCache(token: result.accessToken, expiresIn: result.expiresIn)
        return result.accessToken
    }

    public func clearCache() {
        keyRing.remove(Self.cacheAccount(for: connectorID))
    }

    private struct Cache: Codable {
        var token: String
        var expiresAt: TimeInterval
    }

    private func loadCache() -> Cache? {
        guard let raw = keyRing.get(Self.cacheAccount(for: connectorID)),
              let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func saveCache(token: String, expiresIn: Int) {
        let cache = Cache(token: token, expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(cache) {
            try? keyRing.set(String(data: data, encoding: .utf8) ?? "", for: Self.cacheAccount(for: connectorID))
        }
    }
}
