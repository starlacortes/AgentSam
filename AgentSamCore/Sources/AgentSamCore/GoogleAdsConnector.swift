import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleAdsConnector: ConnectorToolProvider {
    public static let apiBase = "https://googleads.googleapis.com"
    /// Google retires each Ads API version about a year after release; override with AGENTSAM_GOOGLE_ADS_API_VERSION.
    public static let apiVersion = ProcessInfo.processInfo.environment["AGENTSAM_GOOGLE_ADS_API_VERSION"].flatMap { $0.isEmpty ? nil : $0 } ?? "v26"
    public static let oauthScope = "https://www.googleapis.com/auth/adwords"
    public static let developerTokenAccount = "connector.googleads.developerToken"
    public static let customerIdAccount = "connector.googleads.customerId"

    public var id: ConnectorID { .googleads }

    public init() {}

    public func isConfigured(keyRing: KeyRing) -> Bool {
        // Google sign-in is enough: API access is now granted to the Google Cloud project, and a
        // developer token is only sent when one was saved (older setups still use one).
        // A service-account key works in place of sign-in.
        !(keyRing.get(GoogleTokenProvider.refreshAccount(for: .googleads)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || GoogleTokenProvider.serviceAccount(for: .googleads, keyRing: keyRing) != nil
    }

    // MARK: Tool definitions

    public func toolDefs(permissions: ConnectorPermissions) -> [APIToolDef] {
        var defs = [Self.accountsTool, Self.campaignsTool, Self.queryTool]
        if permissions.adsWrite { defs.append(Self.setCampaignStatusTool) }
        return defs
    }

    static let setCampaignStatusTool = APIToolDef(
        name: "googleads_set_campaign_status",
        description: "Pause or enable one Google Ads campaign (requires Google Ads write permission). Changes live ad delivery and spend, so only do this when the user explicitly asked for this exact campaign.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("customer_id", .object([("type", .string("string")), ("description", .string("Customer account ID (with or without the customers/ prefix). Defaults to the configured login customer."))])),
                ("campaign_id", .object([("type", .string("string")), ("description", .string("Numeric campaign ID, from googleads_campaigns."))])),
                ("status", .object([("type", .string("string")), ("enum", .array([.string("PAUSED"), .string("ENABLED")])), ("description", .string("PAUSED to stop delivery, ENABLED to resume it."))])),
            ])),
            ("required", .array([.string("campaign_id"), .string("status")])),
        ])
    )

    static let writesDisabled = "Campaign changes are disabled for the Google Ads connector. Enable Google Ads writes in Connections."

    static let accountsTool = APIToolDef(
        name: "googleads_accounts",
        description: "List the Google Ads customer accounts accessible to the connection, and sub-accounts of the configured login customer.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([:])),
        ])
    )

    static let campaignsTool = APIToolDef(
        name: "googleads_campaigns",
        description: "List campaigns (id, name, status, channel) for a Google Ads customer account.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("customer_id", .object([("type", .string("string")), ("description", .string("Customer account ID (with or without the customers/ prefix). Defaults to the configured login customer."))])),
            ])),
        ])
    )

    static let queryTool = APIToolDef(
        name: "googleads_query",
        description: "Run a raw GAQL query against a Google Ads customer account (read-only SELECT queries).",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                ("customer_id", .object([("type", .string("string")), ("description", .string("Customer account ID (with or without the customers/ prefix). Defaults to the configured login customer."))])),
                ("query", .object([("type", .string("string")), ("description", .string("GAQL query, e.g. SELECT campaign.id, campaign.name FROM campaign WHERE campaign.status = 'ENABLED'"))])),
                ("page_token", .object([("type", .string("string")), ("description", .string("Optional nextPageToken from a previous response"))])),
            ])),
            ("required", .array([.string("query")])),
        ])
    )

    // MARK: Execution

    public func run(_ name: String, args: [String: JSONValue], permissions: ConnectorPermissions, runtime: ConnectorRuntime) async -> ToolOutcome {
        do {
            let provider = runtime.googleTokens(for: .googleads)
            guard let token = try await provider.accessToken() else {
                return .failure("Google Ads connector is not connected. Connect it in Settings.")
            }
            let context = try apiContext(token: token, runtime: runtime)
            switch name {
            case "googleads_accounts":
                return ToolOutcome.success(try await listAccounts(context: context, runtime: runtime))

            case "googleads_campaigns":
                let customerID = try resolveCustomerID(args["customer_id"]?.stringValue, context: context)
                let query = "SELECT campaign.id, campaign.name, campaign.status, campaign.advertising_channel_type FROM campaign ORDER BY campaign.name LIMIT 200"
                let text = try await search(customerID: customerID, query: query, pageToken: nil, context: context, runtime: runtime)
                return ToolOutcome.success(text)

            case "googleads_query":
                guard let query = args["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .failure("googleads_query requires a GAQL query string.")
                }
                guard query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT") else {
                    return .failure("Only read-only SELECT queries are supported.")
                }
                let customerID = try resolveCustomerID(args["customer_id"]?.stringValue, context: context)
                let text = try await search(customerID: customerID, query: query, pageToken: args["page_token"]?.stringValue, context: context, runtime: runtime)
                return ToolOutcome.success(text)

            case "googleads_set_campaign_status":
                guard permissions.adsWrite else { return ToolOutcome(resultText: Self.writesDisabled) }
                guard let campaignID = Self.cleanCampaignID(args["campaign_id"]?.stringValue) else {
                    return ToolOutcome(resultText: "googleads_set_campaign_status requires a numeric campaign_id.")
                }
                guard let status = args["status"]?.stringValue?.uppercased(), ["PAUSED", "ENABLED"].contains(status) else {
                    return ToolOutcome(resultText: "status must be PAUSED or ENABLED.")
                }
                let customerID = try resolveCustomerID(args["customer_id"]?.stringValue, context: context)
                let text = try await setCampaignStatus(customerID: customerID, campaignID: campaignID, status: status, context: context, runtime: runtime)
                return ToolOutcome(resultText: text)

            default:
                return .failure("Unknown tool: \(name).")
            }
        } catch {
            return .failure("Google Ads error: \(error.localizedDescription)")
        }
    }

    public func test(runtime: ConnectorRuntime) async -> (ok: Bool, message: String) {
        do {
            let provider = runtime.googleTokens(for: .googleads)
            guard let token = try await provider.accessToken() else {
                return (false, "Google Ads connector is not connected yet.")
            }
            let context = try apiContext(token: token, runtime: runtime)
            let customers = try await listAccessibleCustomers(context: context, runtime: runtime)
            // Also run a tiny GAQL search: listing accounts can succeed while queries are rejected.
            let probe = context.loginCustomerID.isEmpty
                ? customers.first?.replacingOccurrences(of: "customers/", with: "")
                : context.loginCustomerID
            if let probe {
                _ = try await searchRaw(customerID: probe, query: "SELECT customer.id FROM customer LIMIT 1", pageToken: nil, context: context, runtime: runtime)
            }
            return (true, "Connected — \(customers.count) customer account(s) accessible.")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    // MARK: Helpers

    struct APIContext: Sendable {
        var token: String
        var developerToken: String
        var loginCustomerID: String
    }

    private func apiContext(token: String, runtime: ConnectorRuntime) throws -> APIContext {
        let developerToken = runtime.keyRing.get(Self.developerTokenAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let loginCustomerID = (runtime.keyRing.get(Self.customerIdAccount) ?? "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return APIContext(token: token, developerToken: developerToken, loginCustomerID: loginCustomerID)
    }

    private func headers(_ context: APIContext) -> [String: String] {
        var result: [String: String] = [
            "Authorization": "Bearer \(context.token)",
        ]
        if !context.developerToken.isEmpty {
            result["developer-token"] = context.developerToken
        }
        if !context.loginCustomerID.isEmpty {
            result["login-customer-id"] = context.loginCustomerID
        }
        return result
    }

    private func resolveCustomerID(_ raw: String?, context: APIContext) throws -> String {
        let cleaned = (raw ?? context.loginCustomerID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "customers/", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard !cleaned.isEmpty else {
            throw ConnectorError("Provide customer_id or configure a login customer ID for the Google Ads connector.")
        }
        return cleaned
    }

    private func listAccessibleCustomers(context: APIContext, runtime: ConnectorRuntime) async throws -> [String] {
        guard let url = ConnectorHTTP.url(Self.apiBase, "/\(Self.apiVersion)/customers:listAccessibleCustomers") else {
            throw ConnectorError("Bad Google Ads URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, headers: headers(context))
        let object = try ConnectorHTTP.jsonObject(data)
        return object["resourceNames"] as? [String] ?? []
    }

    private func listAccounts(context: APIContext, runtime: ConnectorRuntime) async throws -> String {
        let accessible = try await listAccessibleCustomers(context: context, runtime: runtime)
        var lines = ["Accessible accounts:"]
        if accessible.isEmpty {
            lines.append("- none")
        } else {
            lines += accessible.map { "- \($0)" }
        }
        if !context.loginCustomerID.isEmpty {
            lines.append("")
            lines.append("Sub-accounts of login customer \(context.loginCustomerID):")
            let query = "SELECT customer_client.id, customer_client.descriptive_name, customer_client.status FROM customer_client LIMIT 500"
            let results = try await searchRaw(customerID: context.loginCustomerID, query: query, pageToken: nil, context: context, runtime: runtime)
            if results.results.isEmpty {
                lines.append("- none")
            } else {
                for result in results.results {
                    let client = result["customerClient"] as? [String: Any]
                    // REST returns int64 fields as strings.
                    let id = (client?["id"] as? String) ?? (client?["id"] as? NSNumber)?.stringValue
                    let name = client?["descriptiveName"] as? String ?? "?"
                    let status = client?["status"] as? String ?? "?"
                    lines.append("- \(id ?? "?") — \(name) (\(status))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func search(customerID: String, query: String, pageToken: String?, context: APIContext, runtime: ConnectorRuntime) async throws -> String {
        let results = try await searchRaw(customerID: customerID, query: query, pageToken: pageToken, context: context, runtime: runtime)
        var lines = ["Customer: \(customerID)", "Results: \(results.results.count)"]
        if let token = results.nextPageToken {
            lines.append("nextPageToken: \(token) (pass as page_token to continue)")
        }
        if results.results.isEmpty {
            lines.append("No rows returned.")
        }
        for result in results.results {
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                lines.append(text)
            }
        }
        return AgentTools.clip(lines.joined(separator: "\n"))
    }

    /// Accepts "123", "campaigns/123" or a full resource name; returns the bare numeric ID.
    static func cleanCampaignID(_ raw: String?) -> String? {
        guard let last = raw?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last else { return nil }
        let id = String(last)
        return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
    }

    static func campaignStatusBody(customerID: String, campaignID: String, status: String) -> [String: Any] {
        [
            "operations": [[
                "update": ["resourceName": "customers/\(customerID)/campaigns/\(campaignID)", "status": status],
                "updateMask": "status",
            ]],
        ]
    }

    private func setCampaignStatus(customerID: String, campaignID: String, status: String, context: APIContext, runtime: ConnectorRuntime) async throws -> String {
        guard let url = ConnectorHTTP.url(Self.apiBase, "/\(Self.apiVersion)/customers/\(customerID)/campaigns:mutate") else {
            throw ConnectorError("Bad Google Ads URL.")
        }
        let body = Self.campaignStatusBody(customerID: customerID, campaignID: campaignID, status: status)
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: "POST", headers: headers(context), jsonBody: body)
        let object = try ConnectorHTTP.jsonObject(data)
        let resource = (object["results"] as? [[String: Any]])?.first?["resourceName"] as? String
        guard let resource else { throw ConnectorError("Google Ads did not confirm the campaign change.") }
        return "Campaign \(resource) is now \(status)."
    }

    struct SearchResults {
        var results: [[String: Any]] = []
        var nextPageToken: String?
    }

    private func searchRaw(customerID: String, query: String, pageToken: String?, context: APIContext, runtime: ConnectorRuntime) async throws -> SearchResults {
        guard let url = ConnectorHTTP.url(Self.apiBase, "/\(Self.apiVersion)/customers/\(customerID)/googleAds:search") else {
            throw ConnectorError("Bad Google Ads URL.")
        }
        // No pageSize: the API rejects it (PAGE_SIZE_NOT_SUPPORTED); pages are a fixed 10,000 rows.
        var body: [String: Any] = ["query": query]
        if let pageToken, !pageToken.isEmpty {
            body["pageToken"] = pageToken
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: "POST", headers: headers(context), jsonBody: body)
        let object = try ConnectorHTTP.jsonObject(data)
        guard let results = object["results"] as? [[String: Any]] else {
            throw ConnectorError("Google Ads returned no results.")
        }
        return SearchResults(results: results, nextPageToken: object["nextPageToken"] as? String)
    }
}


