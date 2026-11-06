import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GmailConnector: ConnectorToolProvider {
    public static let apiBase = "https://gmail.googleapis.com/gmail/v1"

    public var id: ConnectorID { .gmail }

    public init() {}

    public func isConfigured(keyRing: KeyRing) -> Bool {
        !(keyRing.get(GoogleTokenProvider.refreshAccount(for: .gmail)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static func scopes(permissions: ConnectorPermissions) -> [String] {
        if permissions.createDraft || permissions.sendEmail {
            return ["https://www.googleapis.com/auth/gmail.modify"]
        }
        return ["https://www.googleapis.com/auth/gmail.readonly"]
    }

    // MARK: Tool definitions

    public func toolDefs(permissions: ConnectorPermissions) -> [APIToolDef] {
        var defs: [APIToolDef] = [Self.searchTool, Self.readTool]
        if permissions.createDraft { defs.append(Self.draftTool) }
        if permissions.sendEmail { defs.append(Self.sendTool) }
        return defs
    }

    static let searchTool = APIToolDef(
        name: "gmail_search",
        description: "Search your Gmail inbox using Gmail query syntax (e.g. \"from:boss@example.com newer_than:7d\"). Returns message IDs with sender, date, subject, and a snippet.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("query", .object([("type", .string("string")), ("description", .string("Gmail search query, same syntax as the Gmail search box"))])),
                ("max_results", .object([("type", .string("integer")), ("description", .string("Maximum messages to return (default 10, max 50)"))])),
            ])),
            ("required", .array([.string("query")])),
        ])
    )

    static let readTool = APIToolDef(
        name: "gmail_read",
        description: "Read a full Gmail message by ID (from gmail_search): headers, labels, and body text.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("message_id", .object([("type", .string("string")), ("description", .string("Message ID returned by gmail_search"))])),
            ])),
            ("required", .array([.string("message_id")])),
        ])
    )

    static let draftTool = APIToolDef(
        name: "gmail_draft",
        description: "Create a draft email in Gmail. Does NOT send anything (requires draft permission).",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("to", .object([("type", .string("string")), ("description", .string("Recipient email address"))])),
                ("subject", .object([("type", .string("string")), ("description", .string("Subject line"))])),
                ("body", .object([("type", .string("string")), ("description", .string("Plain-text body"))])),
            ])),
            ("required", .array([.string("to"), .string("subject"), .string("body")])),
        ])
    )

    static let sendTool = APIToolDef(
        name: "gmail_send",
        description: "Send an email from your Gmail account. Requires explicit send permission.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("to", .object([("type", .string("string")), ("description", .string("Recipient email address"))])),
                ("subject", .object([("type", .string("string")), ("description", .string("Subject line"))])),
                ("body", .object([("type", .string("string")), ("description", .string("Plain-text body"))])),
            ])),
            ("required", .array([.string("to"), .string("subject"), .string("body")])),
        ])
    )

    // MARK: Execution

    public func run(_ name: String, args: [String: JSONValue], permissions: ConnectorPermissions, runtime: ConnectorRuntime) async -> ToolOutcome {
        do {
            let provider = runtime.googleTokens(for: .gmail)
            guard let token = try await provider.accessToken() else {
                return ToolOutcome(resultText: "Gmail connector is not connected. Connect it in Settings.")
            }
            let headers = ["Authorization": "Bearer \(token)"]
            switch name {
            case "gmail_search":
                guard let query = args["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ToolOutcome(resultText: "gmail_search requires a query string.")
                }
                let maxResults = min(50, max(1, Int(args["max_results"]?.numberValue ?? 10)))
                let text = try await search(query: query, maxResults: maxResults, headers: headers, runtime: runtime)
                return ToolOutcome(resultText: text)

            case "gmail_read":
                guard let messageID = args["message_id"]?.stringValue else {
                    return ToolOutcome(resultText: "gmail_read requires message_id.")
                }
                let text = try await readMessage(messageID: messageID, headers: headers, runtime: runtime)
                return ToolOutcome(resultText: text)

            case "gmail_draft":
                guard permissions.createDraft else { return ToolOutcome(resultText: "Draft creation is disabled for the Gmail connector. Enable it in Settings.") }
                guard let to = args["to"]?.stringValue, let subject = args["subject"]?.stringValue, let body = args["body"]?.stringValue else {
                    return ToolOutcome(resultText: "gmail_draft requires to, subject, and body.")
                }
                let text = try await createDraft(to: to, subject: subject, body: body, headers: headers, runtime: runtime)
                return ToolOutcome(resultText: text)

            case "gmail_send":
                guard permissions.sendEmail else { return ToolOutcome(resultText: "Sending email is disabled for the Gmail connector. Enable it in Settings.") }
                guard let to = args["to"]?.stringValue, let subject = args["subject"]?.stringValue, let body = args["body"]?.stringValue else {
                    return ToolOutcome(resultText: "gmail_send requires to, subject, and body.")
                }
                let text = try await send(to: to, subject: subject, body: body, headers: headers, runtime: runtime)
                return ToolOutcome(resultText: text)

            default:
                return ToolOutcome(resultText: "Unknown tool: \(name).")
            }
        } catch {
            return ToolOutcome(resultText: "Gmail error: \(error.localizedDescription)")
        }
    }

    public func test(runtime: ConnectorRuntime) async -> (ok: Bool, message: String) {
        do {
            let provider = runtime.googleTokens(for: .gmail)
            guard let token = try await provider.accessToken() else {
                return (false, "Gmail connector is not connected yet.")
            }
            guard let url = ConnectorHTTP.url(Self.apiBase, "/users/me/profile") else {
                return (false, "Bad Gmail URL.")
            }
            let data = try await ConnectorHTTP.request(runtime.session, url: url, headers: ["Authorization": "Bearer \(token)"])
            let object = try ConnectorHTTP.jsonObject(data)
            let email = object["emailAddress"] as? String ?? "your account"
            let messages = object["messagesTotal"] as? Int ?? 0
            return (true, "Connected as \(email) — \(messages) messages in mailbox.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: API calls

    private func search(query: String, maxResults: Int, headers: [String: String], runtime: ConnectorRuntime) async throws -> String {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = ConnectorHTTP.url(Self.apiBase, "/users/me/messages", query: [
            URLQueryItem(name: "q", value: encoded),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "Date"),
        ]) else {
            throw ConnectorError("Bad Gmail URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, headers: headers)
        let object = try ConnectorHTTP.jsonObject(data)
        let messages = object["messages"] as? [[String: Any]] ?? []
        var lines: [String] = ["Matches: \(object["resultSizeEstimate"] as? Int ?? messages.count)"]
        if messages.isEmpty {
            lines.append("No messages matched the query.")
        }
        for message in messages {
            let id = message["id"] as? String ?? "?"
            let snippet = message["snippet"] as? String ?? ""
            let payload = message["payload"] as? [String: Any]
            let messageHeaders = payload?["headers"] as? [[String: Any]] ?? []
            func header(_ name: String) -> String {
                messageHeaders.first(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() })?["value"] as? String ?? ""
            }
            lines.append("\(id) — From: \(header("From")) — Date: \(header("Date")) — Subject: \(header("Subject"))")
            if !snippet.isEmpty {
                lines.append("    \(snippet.replacingOccurrences(of: "\n", with: " "))")
            }
        }
        return AgentTools.clip(lines.joined(separator: "\n"))
    }

    private func readMessage(messageID: String, headers: [String: String], runtime: ConnectorRuntime) async throws -> String {
        guard let encoded = messageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = ConnectorHTTP.url(Self.apiBase, "/users/me/messages/\(encoded)", query: [URLQueryItem(name: "format", value: "full")]) else {
            throw ConnectorError("Bad Gmail URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, headers: headers)
        let object = try ConnectorHTTP.jsonObject(data)
        let payload = object["payload"] as? [String: Any]
        let messageHeaders = payload?["headers"] as? [[String: Any]] ?? []
        func header(_ name: String) -> String {
            messageHeaders.first(where: { ($0["name"] as? String)?.lowercased() == name.lowercased() })?["value"] as? String ?? ""
        }
        var lines: [String] = [
            "Message: \(object["id"] as? String ?? messageID)",
            "Thread: \(object["threadId"] as? String ?? "?")",
            "Labels: \((object["labelIds"] as? [String] ?? []).joined(separator: ", "))",
            "From: \(header("From"))",
            "To: \(header("To"))",
            "Date: \(header("Date"))",
            "Subject: \(header("Subject"))",
        ]
        if let parts = payload?["parts"] as? [[String: Any]] {
            let attachments = parts.filter { ($0["filename"] as? String)?.isEmpty == false }
                .map { "\($0["filename"] as? String ?? "?") (\($0["mimeType"] as? String ?? "?"))" }
            if !attachments.isEmpty {
                lines.append("Attachments: \(attachments.joined(separator: ", "))")
            }
        }
        let body = Self.extractBody(payload) ?? "(no plain-text body)"
        lines.append("")
        lines.append(body)
        return AgentTools.clip(lines.joined(separator: "\n"))
    }

    private func createDraft(to: String, subject: String, body: String, headers: [String: String], runtime: ConnectorRuntime) async throws -> String {
        guard let url = ConnectorHTTP.url(Self.apiBase, "/users/me/drafts") else {
            throw ConnectorError("Bad Gmail URL.")
        }
        let payload: [String: Any] = ["message": ["raw": Self.rawMessage(to: to, subject: subject, body: body)]]
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: "POST", headers: headers, jsonBody: payload)
        let object = try ConnectorHTTP.jsonObject(data)
        guard let draftID = object["id"] as? String else {
            throw ConnectorError("Gmail did not create the draft.")
        }
        let messageID = (object["message"] as? [String: Any])?["id"] as? String ?? "?"
        return "Draft created (id \(draftID), message \(messageID)). Nothing was sent."
    }

    private func send(to: String, subject: String, body: String, headers: [String: String], runtime: ConnectorRuntime) async throws -> String {
        guard let url = ConnectorHTTP.url(Self.apiBase, "/users/me/messages/send") else {
            throw ConnectorError("Bad Gmail URL.")
        }
        let payload: [String: Any] = ["raw": Self.rawMessage(to: to, subject: subject, body: body)]
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: "POST", headers: headers, jsonBody: payload)
        let object = try ConnectorHTTP.jsonObject(data)
        guard let messageID = object["id"] as? String else {
            throw ConnectorError("Gmail did not send the message.")
        }
        return "Sent: message \(messageID), thread \((object["threadId"] as? String) ?? "?")."
    }

    // MARK: MIME helpers

    static func rawMessage(to: String, subject: String, body: String) -> String {
        let mime = "To: \(to)\r\nSubject: \(subject)\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=\"UTF-8\"\r\n\r\n\(body)"
        return GoogleOAuth.base64url(Data(mime.utf8))
    }

    static func extractBody(_ payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        if let mime = payload["mimeType"] as? String, mime == "text/plain",
           let raw = (payload["body"] as? [String: Any])?["data"] as? String,
           let data = GoogleOAuth.decodeBase64url(raw),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        if let parts = payload["parts"] as? [[String: Any]] {
            for part in parts where (part["mimeType"] as? String) == "text/plain" {
                if let raw = (part["body"] as? [String: Any])?["data"] as? String,
                   let data = GoogleOAuth.decodeBase64url(raw),
                   let text = String(data: data, encoding: .utf8) {
                    return text
                }
            }
            for part in parts {
                if let raw = (part["body"] as? [String: Any])?["data"] as? String,
                   let data = GoogleOAuth.decodeBase64url(raw),
                   let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    return text
                }
            }
        }
        if let raw = (payload["body"] as? [String: Any])?["data"] as? String,
           let data = GoogleOAuth.decodeBase64url(raw),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return nil
    }
}



