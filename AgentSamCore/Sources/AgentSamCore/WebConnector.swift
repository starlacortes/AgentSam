import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// General web tools for mission workers: `web_fetch` reads a public page as text, and `web_search`
/// searches the web through the Brave Search API when a Brave key is saved.
public struct WebConnector: ConnectorToolProvider {
    public static let braveKeyAccount = "connector.web.brave"
    public static let braveSearchURL = "https://api.search.brave.com/res/v1/web/search"
    /// Most characters of page text handed back to the model.
    public static let pageClip = 20_000

    public var id: ConnectorID { .web }

    public init() {}

    /// Fetching needs no credentials, so the connector is always usable; search also needs a Brave key.
    public func isConfigured(keyRing: KeyRing) -> Bool { true }

    public static func hasSearchKey(_ keyRing: KeyRing) -> Bool {
        !(keyRing.get(braveKeyAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Tool definitions

    public func toolDefs(permissions: ConnectorPermissions) -> [APIToolDef] {
        [Self.fetchTool, Self.searchTool]
    }

    /// Tools to offer, given the key ring: search only when a Brave key is saved.
    public func toolDefs(keyRing: KeyRing) -> [APIToolDef] {
        Self.hasSearchKey(keyRing) ? [Self.fetchTool, Self.searchTool] : [Self.fetchTool]
    }

    static let fetchTool = APIToolDef(
        name: "web_fetch",
        description: "Read a public web page (http or https) and return its text. Use it to open search results or links you were given.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("url", .object([("type", .string("string")), ("description", .string("The full URL, starting with https:// or http://"))])),
            ])),
            ("required", .array([.string("url")])),
        ])
    )

    static let searchTool = APIToolDef(
        name: "web_search",
        description: "Search the web. Returns titles, URLs and short descriptions; open a result with web_fetch to read it.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("query", .object([("type", .string("string")), ("description", .string("What to search for"))])),
                ("count", .object([("type", .string("integer")), ("description", .string("Number of results, 1 to 20 (default 8)"))])),
            ])),
            ("required", .array([.string("query")])),
        ])
    )

    // MARK: Running

    public func run(_ name: String, args: [String: JSONValue], permissions: ConnectorPermissions, runtime: ConnectorRuntime) async -> ToolOutcome {
        do {
            switch name {
            case "web_fetch":
                guard let raw = args["url"]?.stringValue, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ToolOutcome(resultText: "web_fetch requires a url.")
                }
                return ToolOutcome(resultText: try await fetch(raw))

            case "web_search":
                guard let key = runtime.keyRing.get(Self.braveKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                    return ToolOutcome(resultText: "Web search isn't set up: save a Brave Search key on the Connectors page.")
                }
                guard let query = args["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ToolOutcome(resultText: "web_search requires a query.")
                }
                let count = min(20, max(1, Int(args["count"]?.numberValue ?? 8)))
                return ToolOutcome(resultText: try await search(query: query, count: count, key: key, session: runtime.session))

            default:
                return ToolOutcome(resultText: "Unknown tool: \(name).")
            }
        } catch {
            return ToolOutcome(resultText: "Web error: \(error.localizedDescription)")
        }
    }

    public func test(runtime: ConnectorRuntime) async -> (ok: Bool, message: String) {
        if let key = runtime.keyRing.get(Self.braveKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            do {
                _ = try await search(query: "weather", count: 1, key: key, session: runtime.session)
                return (true, "Web fetch is on, and the Brave Search key works.")
            } catch {
                return (false, "The Brave Search key didn't work: \(error.localizedDescription)")
            }
        }
        return (true, "Web fetch is on. Add a Brave Search key to turn on web search.")
    }

    /// Checks a Brave key with one small search before it is saved.
    public static func verifyBraveKey(_ key: String, session: URLSession) async -> (ok: Bool, message: String) {
        do {
            _ = try await WebConnector().search(query: "weather", count: 1, key: key, session: session)
            return (true, "Brave Search key saved.")
        } catch {
            return (false, "Brave Search rejected the key: \(error.localizedDescription)")
        }
    }

    // MARK: Search

    func search(query: String, count: Int, key: String, session: URLSession) async throws -> String {
        guard let url = ConnectorHTTP.url(Self.braveSearchURL, "", query: [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(count)),
        ]) else {
            throw ConnectorError("Bad search URL.")
        }
        let data = try await ConnectorHTTP.request(session, url: url, headers: [
            "Accept": "application/json",
            "X-Subscription-Token": key,
        ])
        let object = try ConnectorHTTP.jsonObject(data)
        let results = ((object["web"] as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        if results.isEmpty { return "No results for \"\(query)\"." }
        var lines = ["Results for \"\(query)\":"]
        for (index, result) in results.enumerated() {
            let title = Self.plainText(result["title"] as? String ?? "")
            let link = result["url"] as? String ?? ""
            let summary = Self.plainText(result["description"] as? String ?? "")
            lines.append("\(index + 1). \(title)\n   \(link)\n   \(summary)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Fetch

    func fetch(_ raw: String) async throws -> String {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ConnectorError("That isn't a valid URL.")
        }
        guard Self.isAllowed(url) else {
            throw ConnectorError("Only public http and https addresses can be fetched.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (compatible; AgentSam/1.0)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,text/plain,application/json,application/xml;q=0.9,*/*;q=0.5", forHTTPHeaderField: "Accept")
        let (data, response) = try await FetchSession.shared.session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw ConnectorError("HTTP \(status) from \(url.host ?? raw).")
        }
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let isText = type.isEmpty || type.contains("text/") || type.contains("json") || type.contains("xml")
        guard isText else {
            throw ConnectorError("\(url.absoluteString) is \(type), not a text page.")
        }
        let body = String(decoding: data, as: UTF8.self)
        let text = type.contains("html") || type.isEmpty ? Self.plainText(body) : body
        let finalURL = response.url?.absoluteString ?? url.absoluteString
        var clipped = text
        if clipped.count > Self.pageClip {
            clipped = String(clipped.prefix(Self.pageClip)) + "\n…[page clipped at \(Self.pageClip) characters]"
        }
        return "URL: \(finalURL)\n\n\(clipped)"
    }

    /// Public http(s) hosts only: no localhost, private networks, link-local (cloud metadata) or internal names.
    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard var host = url.host?.lowercased(), !host.isEmpty else { return false }
        if host.hasPrefix("[") || host.contains(":") { return false } // IPv6 literals
        if host.hasSuffix(".") { host.removeLast() }
        let blockedNames = ["localhost", "metadata", "metadata.google.internal"]
        if blockedNames.contains(host) { return false }
        for suffix in [".localhost", ".local", ".internal", ".lan", ".home", ".corp"] where host.hasSuffix(suffix) {
            return false
        }
        if !host.contains(".") { return false } // single-label names resolve on the private network
        let parts = host.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ Int($0) != nil }) {
            let octets = parts.compactMap { Int($0) }
            guard octets.allSatisfy({ (0...255).contains($0) }) else { return false }
            let (a, b) = (octets[0], octets[1])
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 169 && b == 254 { return false }
            if a == 172 && (16...31).contains(b) { return false }
            if a == 192 && b == 168 { return false }
            if a == 100 && (64...127).contains(b) { return false }
        }
        return true
    }

    /// Strips an HTML page down to readable text.
    public static func plainText(_ html: String) -> String {
        var text = html
        let rules: [(String, String)] = [
            ("(?is)<(script|style|noscript|svg|template|head)\\b.*?</\\1\\s*>", " "),
            ("(?is)<!--.*?-->", " "),
            ("(?i)<br\\s*/?>", "\n"),
            ("(?i)</(p|div|li|h[1-6]|tr|section|article|header|footer|blockquote|pre)\\s*>", "\n"),
            ("(?s)<[^>]+>", " "),
        ]
        for (pattern, replacement) in rules {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..., in: text)
                text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: replacement)
            }
        }
        let entities = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'"]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }
}

/// A session for `web_fetch` that refuses redirects into private addresses.
final class FetchSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = FetchSession()
    private(set) var session: URLSession!

    override init() {
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let url = request.url, WebConnector.isAllowed(url) {
            completionHandler(request)
        } else {
            completionHandler(nil)
        }
    }
}
