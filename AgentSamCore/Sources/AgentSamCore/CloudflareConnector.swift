import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CloudflareConnector: ConnectorToolProvider {
    public static let apiBase = "https://api.cloudflare.com/client/v4"
    public static let tokenAccount = "connector.cloudflare.token"

    public var id: ConnectorID { .cloudflare }

    public init() {}

    public func isConfigured(keyRing: KeyRing) -> Bool {
        !(keyRing.get(Self.tokenAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Tool definitions

    public func toolDefs(permissions: ConnectorPermissions) -> [APIToolDef] {
        var defs: [APIToolDef] = [Self.zonesTool, Self.dnsListTool]
        if permissions.dnsWrite {
            defs += [Self.dnsCreateTool, Self.dnsUpdateTool, Self.dnsDeleteTool, Self.purgeTool]
        }
        return defs
    }

    static let zonesTool = APIToolDef(
        name: "cloudflare_zones",
        description: "List Cloudflare zones (domains) visible to the configured API token.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("name", .object([("type", .string("string")), ("description", .string("Optional substring filter on zone name"))])),
            ])),
        ])
    )

    static let dnsListTool = APIToolDef(
        name: "cloudflare_dns_list",
        description: "List DNS records in a Cloudflare zone. Accepts a zone name or a zone ID.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("zone_id", .object([("type", .string("string")), ("description", .string("Zone name (e.g. example.com) or zone ID"))])),
                ("name", .object([("type", .string("string")), ("description", .string("Optional filter: record name contains this"))])),
                ("type", .object([("type", .string("string")), ("description", .string("Optional record type: A, AAAA, CNAME, TXT, MX, …"))])),
            ])),
            ("required", .array([.string("zone_id")])),
        ])
    )

    static let dnsCreateTool = APIToolDef(
        name: "cloudflare_dns_create",
        description: "Create a DNS record in a Cloudflare zone (requires DNS write permission).",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("zone_id", .object([("type", .string("string")), ("description", .string("Zone name (e.g. example.com) or zone ID"))])),
                ("type", .object([("type", .string("string")), ("description", .string("Record type: A, AAAA, CNAME, TXT, MX, …"))])),
                ("name", .object([("type", .string("string")), ("description", .string("Record name, e.g. www.example.com"))])),
                ("content", .object([("type", .string("string")), ("description", .string("Record content, e.g. 203.0.113.7"))])),
                ("ttl", .object([("type", .string("integer")), ("description", .string("TTL in seconds; 1 means automatic (default)"))])),
                ("proxied", .object([("type", .string("boolean")), ("description", .string("Route through Cloudflare proxy (default false)"))])),
            ])),
            ("required", .array([.string("zone_id"), .string("type"), .string("name"), .string("content")])),
        ])
    )

    static let dnsUpdateTool = APIToolDef(
        name: "cloudflare_dns_update",
        description: "Update an existing DNS record (requires DNS write permission). Provide record_id, or name to update the first matching record.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("zone_id", .object([("type", .string("string")), ("description", .string("Zone name (e.g. example.com) or zone ID"))])),
                ("record_id", .object([("type", .string("string")), ("description", .string("Record ID from cloudflare_dns_list"))])),
                ("name", .object([("type", .string("string")), ("description", .string("Alternate selector: update the first record with this name"))])),
                ("type", .object([("type", .string("string")), ("description", .string("Optional new record type"))])),
                ("content", .object([("type", .string("string")), ("description", .string("Optional new record content"))])),
                ("ttl", .object([("type", .string("integer")), ("description", .string("Optional new TTL"))])),
                ("proxied", .object([("type", .string("boolean")), ("description", .string("Optional new proxied flag"))])),
            ])),
            ("required", .array([.string("zone_id")])),
        ])
    )

    static let dnsDeleteTool = APIToolDef(
        name: "cloudflare_dns_delete",
        description: "Delete a DNS record (requires DNS write permission). Provide record_id, or name to delete the first matching record.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("zone_id", .object([("type", .string("string")), ("description", .string("Zone name (e.g. example.com) or zone ID"))])),
                ("record_id", .object([("type", .string("string")), ("description", .string("Record ID from cloudflare_dns_list"))])),
                ("name", .object([("type", .string("string")), ("description", .string("Alternate selector: delete the first record with this name"))])),
            ])),
            ("required", .array([.string("zone_id")])),
        ])
    )

    static let purgeTool = APIToolDef(
        name: "cloudflare_purge_cache",
        description: "Purge the Cloudflare cache for a zone (requires DNS write permission).",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("zone_id", .object([("type", .string("string")), ("description", .string("Zone name (e.g. example.com) or zone ID"))])),
                ("purge_everything", .object([("type", .string("boolean")), ("description", .string("Purge the entire cache (default false)"))])),
                ("urls", .object([("type", .string("array")), ("items", .object([("type", .string("string"))])), ("description", .string("Specific URLs to purge (alternative to purge_everything)"))])),
            ])),
            ("required", .array([.string("zone_id")])),
        ])
    )

    // MARK: Execution

    public func run(_ name: String, args: [String: JSONValue], permissions: ConnectorPermissions, runtime: ConnectorRuntime) async -> ToolOutcome {
        do {
            switch name {
            case "cloudflare_zones":
                let filter = args["name"]?.stringValue
                return ToolOutcome(resultText: try await listZones(nameFilter: filter, runtime: runtime))

            case "cloudflare_dns_list":
                guard let zone = args["zone_id"]?.stringValue else {
                    return ToolOutcome(resultText: "cloudflare_dns_list requires zone_id (a zone name is also accepted).")
                }
                let text = try await listDNS(zone: zone, nameFilter: args["name"]?.stringValue, typeFilter: args["type"]?.stringValue, runtime: runtime)
                return ToolOutcome(resultText: text)

            case "cloudflare_dns_create":
                guard permissions.dnsWrite else { return ToolOutcome(resultText: "DNS writes are disabled for the Cloudflare connector. Enable them in Settings.") }
                guard let zone = args["zone_id"]?.stringValue, let type = args["type"]?.stringValue,
                      let name = args["name"]?.stringValue, let content = args["content"]?.stringValue else {
                    return ToolOutcome(resultText: "cloudflare_dns_create requires zone_id, type, name, and content.")
                }
                let text = try await createDNS(zone: zone, type: type, name: name, content: content, ttl: args["ttl"]?.numberValue, proxied: args["proxied"]?.boolValue, runtime: runtime)
                return ToolOutcome(resultText: text)

            case "cloudflare_dns_update":
                guard permissions.dnsWrite else { return ToolOutcome(resultText: "DNS writes are disabled for the Cloudflare connector. Enable them in Settings.") }
                guard let zone = args["zone_id"]?.stringValue else {
                    return ToolOutcome(resultText: "cloudflare_dns_update requires zone_id.")
                }
                let text = try await updateDNS(
                    zone: zone,
                    recordID: args["record_id"]?.stringValue,
                    name: args["name"]?.stringValue,
                    type: args["type"]?.stringValue,
                    content: args["content"]?.stringValue,
                    ttl: args["ttl"]?.numberValue,
                    proxied: args["proxied"]?.boolValue,
                    runtime: runtime
                )
                return ToolOutcome(resultText: text)

            case "cloudflare_dns_delete":
                guard permissions.dnsWrite else { return ToolOutcome(resultText: "DNS writes are disabled for the Cloudflare connector. Enable them in Settings.") }
                guard let zone = args["zone_id"]?.stringValue else {
                    return ToolOutcome(resultText: "cloudflare_dns_delete requires zone_id.")
                }
                let text = try await deleteDNS(zone: zone, recordID: args["record_id"]?.stringValue, name: args["name"]?.stringValue, runtime: runtime)
                return ToolOutcome(resultText: text)

            case "cloudflare_purge_cache":
                guard permissions.dnsWrite else { return ToolOutcome(resultText: "DNS writes are disabled for the Cloudflare connector. Enable them in Settings.") }
                guard let zone = args["zone_id"]?.stringValue else {
                    return ToolOutcome(resultText: "cloudflare_purge_cache requires zone_id.")
                }
                let text = try await purgeCache(zone: zone, everything: args["purge_everything"]?.boolValue, urls: args["urls"]?.arrayValue?.compactMap(\.stringValue), runtime: runtime)
                return ToolOutcome(resultText: text)

            default:
                return ToolOutcome(resultText: "Unknown tool: \(name).")
            }
        } catch {
            return ToolOutcome(resultText: "Cloudflare error: \(error.localizedDescription)")
        }
    }

    public func test(runtime: ConnectorRuntime) async -> (ok: Bool, message: String) {
        guard let token = runtime.keyRing.get(Self.tokenAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return (false, "No Cloudflare API token saved.")
        }
        return await Self.verifyToken(token, session: runtime.session)
    }

    public static func verifyToken(_ token: String, session: URLSession) async -> (ok: Bool, message: String) {
        do {
            guard let url = ConnectorHTTP.url(apiBase, "/user/tokens/verify") else {
                return (false, "Bad Cloudflare URL.")
            }
            let data = try await ConnectorHTTP.request(session, url: url, method: "GET", headers: ["Authorization": "Bearer \(token)"])
            let object = try ConnectorHTTP.jsonObject(data)
            guard let result = object["result"] as? [String: Any], result["status"] as? String == "active" else {
                return (false, "Cloudflare rejected the token. Check its value and permissions.")
            }
            return (true, "Cloudflare token verified.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: Private helpers

    private func authHeaders(_ runtime: ConnectorRuntime) throws -> [String: String] {
        guard let token = runtime.keyRing.get(Self.tokenAccount)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw ConnectorError("Cloudflare connector is not connected.")
        }
        return ["Authorization": "Bearer \(token)"]
    }

    private func resolveZone(_ zoneIDOrName: String, runtime: ConnectorRuntime) async throws -> (id: String, name: String) {
        let headers = try authHeaders(runtime)
        if zoneIDOrName.count == 32, zoneIDOrName.allSatisfy({ $0.isHexDigit }) {
            return (zoneIDOrName, zoneIDOrName)
        }
        guard let url = ConnectorHTTP.url(Self.apiBase, "/zones", query: [
            URLQueryItem(name: "name", value: zoneIDOrName),
            URLQueryItem(name: "per_page", value: "1"),
        ]) else {
            throw ConnectorError("Bad Cloudflare URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, headers: headers)
        let object = try ConnectorHTTP.jsonObject(data)
        guard let zones = object["result"] as? [[String: Any]], let zone = zones.first,
              let id = zone["id"] as? String else {
            throw ConnectorError("Zone not found: \(zoneIDOrName). Check the name or use the zone ID from cloudflare_zones.")
        }
        return (id, zone["name"] as? String ?? zoneIDOrName)
    }

    private func cloudflareError(_ object: [String: Any], fallback: String) -> String {
        if let errors = object["errors"] as? [[String: Any]],
           let first = errors.first?["message"] as? String, !first.isEmpty {
            return first
        }
        if object["success"] as? Bool == false {
            return fallback
        }
        return fallback
    }

    private func listZones(nameFilter: String?, runtime: ConnectorRuntime) async throws -> String {
        let headers = try authHeaders(runtime)
        guard let url = ConnectorHTTP.url(Self.apiBase, "/zones", query: [URLQueryItem(name: "per_page", value: "50")]) else {
            throw ConnectorError("Bad Cloudflare URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, headers: headers)
        let object = try ConnectorHTTP.jsonObject(data)
        guard let zones = object["result"] as? [[String: Any]] else {
            throw ConnectorError(cloudflareError(object, fallback: "No zones returned."))
        }
        let filter = nameFilter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let lines = zones.compactMap { zone -> String? in
            guard let id = zone["id"] as? String, let name = zone["name"] as? String else { return nil }
            if !filter.isEmpty, !name.lowercased().contains(filter) { return nil }
            return "\(id) — \(name) — \(zone["status"] as? String ?? "?")"
        }
        if lines.isEmpty { return "No zones found." }
        return lines.joined(separator: "\n")
    }

    private func listDNS(zone: String, nameFilter: String?, typeFilter: String?, runtime: ConnectorRuntime) async throws -> String {
        let zoneInfo = try await resolveZone(zone, runtime: runtime)
        let headers = try authHeaders(runtime)
        var query = [URLQueryItem(name: "per_page", value: "100")]
        if let name = nameFilter?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            query.append(URLQueryItem(name: "name", value: name))
        }
        if let type = typeFilter?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !type.isEmpty {
            query.append(URLQueryItem(name: "type", value: type))
        }
        guard let url = ConnectorHTTP.url(Self.apiBase, "/zones/\(zoneInfo.id)/dns_records", query: query) else {
            throw ConnectorError("Bad Cloudflare URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, headers: headers)
        let object = try ConnectorHTTP.jsonObject(data)
        guard let records = object["result"] as? [[String: Any]] else {
            throw ConnectorError(cloudflareError(object, fallback: "No DNS records returned."))
        }
        var lines = ["Zone: \(zoneInfo.name) (\(zoneInfo.id))"]
        if records.isEmpty {
            lines.append("No DNS records found.")
        }
        for record in records {
            let id = record["id"] as? String ?? "?"
            let type = record["type"] as? String ?? "?"
            let name = record["name"] as? String ?? "?"
            let content = record["content"] as? String ?? ""
            let ttl = record["ttl"] as? Int ?? 1
            let proxied = record["proxied"] as? Bool ?? false
            lines.append("\(id) — \(type) \(name) → \(content) (TTL \(ttl == 1 ? "auto" : String(ttl)), proxied \(proxied ? "yes" : "no"))")
        }
        return lines.joined(separator: "\n")
    }

    private func createDNS(zone: String, type: String, name: String, content: String, ttl: Double?, proxied: Bool?, runtime: ConnectorRuntime) async throws -> String {
        let zoneInfo = try await resolveZone(zone, runtime: runtime)
        let headers = try authHeaders(runtime)
        var body: [String: Any] = ["type": type.uppercased(), "name": name, "content": content]
        body["ttl"] = ttl.map { Int($0) } ?? 1
        body["proxied"] = proxied ?? false
        guard let url = ConnectorHTTP.url(Self.apiBase, "/zones/\(zoneInfo.id)/dns_records") else {
            throw ConnectorError("Bad Cloudflare URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: "POST", headers: headers, jsonBody: body)
        let object = try ConnectorHTTP.jsonObject(data)
        guard let record = object["result"] as? [String: Any], let id = record["id"] as? String else {
            throw ConnectorError(cloudflareError(object, fallback: "Cloudflare did not create the record."))
        }
        return "Created DNS record \(type.uppercased()) \(name) → \(content) in zone \(zoneInfo.name) (record id \(id))."
    }

    private func updateDNS(zone: String, recordID: String?, name: String?, type: String?, content: String?, ttl: Double?, proxied: Bool?, runtime: ConnectorRuntime) async throws -> String {
        let zoneInfo = try await resolveZone(zone, runtime: runtime)
        let headers = try authHeaders(runtime)
        let resolvedID = try await resolveRecordID(zone: zoneInfo.id, recordID: recordID, name: name, runtime: runtime)
        var body: [String: Any] = [:]
        if let type { body["type"] = type.uppercased() }
        if let name { body["name"] = name }
        if let content { body["content"] = content }
        if let ttl { body["ttl"] = Int(ttl) }
        if let proxied { body["proxied"] = proxied }
        guard !body.isEmpty else {
            throw ConnectorError("cloudflare_dns_update needs at least one of type, name, content, ttl, or proxied.")
        }
        guard let url = ConnectorHTTP.url(Self.apiBase, "/zones/\(zoneInfo.id)/dns_records/\(resolvedID)") else {
            throw ConnectorError("Bad Cloudflare URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: "PATCH", headers: headers, jsonBody: body)
        let object = try ConnectorHTTP.jsonObject(data)
        guard object["result"] as? [String: Any] != nil else {
            throw ConnectorError(cloudflareError(object, fallback: "Cloudflare did not update the record."))
        }
        return "Updated DNS record \(resolvedID) in zone \(zoneInfo.name)."
    }

    private func deleteDNS(zone: String, recordID: String?, name: String?, runtime: ConnectorRuntime) async throws -> String {
        let zoneInfo = try await resolveZone(zone, runtime: runtime)
        let headers = try authHeaders(runtime)
        let resolvedID = try await resolveRecordID(zone: zoneInfo.id, recordID: recordID, name: name, runtime: runtime)
        guard let url = ConnectorHTTP.url(Self.apiBase, "/zones/\(zoneInfo.id)/dns_records/\(resolvedID)") else {
            throw ConnectorError("Bad Cloudflare URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: "DELETE", headers: headers)
        let object = try ConnectorHTTP.jsonObject(data)
        guard let record = object["result"] as? [String: Any], let id = record["id"] as? String else {
            throw ConnectorError(cloudflareError(object, fallback: "Cloudflare did not delete the record."))
        }
        return "Deleted DNS record \(id) in zone \(zoneInfo.name)."
    }

    private func purgeCache(zone: String, everything: Bool?, urls: [String]?, runtime: ConnectorRuntime) async throws -> String {
        let zoneInfo = try await resolveZone(zone, runtime: runtime)
        let headers = try authHeaders(runtime)
        var body: [String: Any] = [:]
        if let urls, !urls.isEmpty {
            body["files"] = urls
        } else {
            body["purge_everything"] = everything ?? true
        }
        guard let url = ConnectorHTTP.url(Self.apiBase, "/zones/\(zoneInfo.id)/purge_cache") else {
            throw ConnectorError("Bad Cloudflare URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: "POST", headers: headers, jsonBody: body)
        let object = try ConnectorHTTP.jsonObject(data)
        guard object["success"] as? Bool == true else {
            throw ConnectorError(cloudflareError(object, fallback: "Cloudflare did not purge the cache."))
        }
        if let files = body["files"] as? [String] {
            return "Purged cache for \(files.count) URL(s) in zone \(zoneInfo.name)."
        }
        return "Purged the entire cache for zone \(zoneInfo.name)."
    }

    private func resolveRecordID(zone: String, recordID: String?, name: String?, runtime: ConnectorRuntime) async throws -> String {
        if let recordID = recordID?.trimmingCharacters(in: .whitespacesAndNewlines), !recordID.isEmpty {
            return recordID
        }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            throw ConnectorError("Provide record_id, or a record name to resolve.")
        }
        let headers = try authHeaders(runtime)
        guard let url = ConnectorHTTP.url(Self.apiBase, "/zones/\(zone)/dns_records", query: [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "per_page", value: "1"),
        ]) else {
            throw ConnectorError("Bad Cloudflare URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, headers: headers)
        let object = try ConnectorHTTP.jsonObject(data)
        guard let records = object["result"] as? [[String: Any]], let first = records.first,
              let id = first["id"] as? String else {
            throw ConnectorError("No DNS record named \(name) found in the zone.")
        }
        return id
    }
}



