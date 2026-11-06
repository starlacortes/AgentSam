import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GoogleAdsConnector: ConnectorToolProvider {
    public static let apiBase = "https://googleads.googleapis.com"
    public static let apiVersion = "v19"
    public static let oauthScope = "https://www.googleapis.com/auth/adwords"
    public static let developerTokenAccount = "connector.googleads.developerToken"
    public static let customerIdAccount = "connector.googleads.customerId"

    public var id: ConnectorID { .googleads }

    public init() {}

    public func isConfigured(keyRing: KeyRing) -> Bool {
        !(keyRing.get(GoogleTokenProvider.refreshAccount(for: .googleads)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(keyRing.get(Self.developerTokenAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Tool definitions

    public func toolDefs(permissions: ConnectorPermissions) -> [APIToolDef] {
        [Self.accountsTool, Self.campaignsTool, Self.queryTool]
    }

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
                return ToolOutcome(resultText: "Google Ads connector is not connected. Connect it in Settings.")
            }
            let context = try apiContext(token: token, runtime: runtime)
            switch name {
            case "googleads_accounts":
                return ToolOutcome(resultText: try await listAccounts(context: context, runtime: runtime))

            case "googleads_campaigns":
                let customerID = try resolveCustomerID(args["customer_id"]?.stringValue, context: context)
                let query = "SELECT campaign.id, campaign.name, campaign.status, campaign.advertising_channel_type FROM campaign ORDER BY campaign.name LIMIT 200"
                let text = try await search(customerID: customerID, query: query, pageToken: nil, context: context, runtime: runtime)
                return ToolOutcome(resultText: text)

            case "googleads_query":
                guard let query = args["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return ToolOutcome(resultText: "googleads_query requires a GAQL query string.")
                }
                guard query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT") else {
                    return ToolOutcome(resultText: "Only read-only SELECT queries are supported.")
                }
                let customerID = try resolveCustomerID(args["customer_id"]?.stringValue, context: context)
                let text = try await search(customerID: customerID, query: query, pageToken: args["page_token"]?.stringValue, context: context, runtime: runtime)
                return ToolOutcome(resultText: text)

            default:
                return ToolOutcome(resultText: "Unknown tool: \(name).")
            }
        } catch {
            return ToolOutcome(resultText: "Google Ads error: \(error.localizedDescription)")
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
        guard let developerToken = runtime.keyRing.get(Self.developerTokenAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !developerToken.isEmpty else {
            throw ConnectorError("Google Ads developer token is not configured.")
        }
        let loginCustomerID = runtime.keyRing.get(Self.customerIdAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return APIContext(token: token, developerToken: developerToken, loginCustomerID: loginCustomerID)
    }

    private func headers(_ context: APIContext) -> [String: String] {
        var result: [String: String] = [
            "Authorization": "Bearer \(context.token)",
            "developer-token": context.developerToken,
        ]
        if !context.loginCustomerID.isEmpty {
            result["login-customer-id"] = context.loginCustomerID
        }
        return result
    }

    private func resolveCustomerID(_ raw: String?, context: APIContext) throws -> String {
        let cleaned = (raw ?? context.loginCustomerID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "customers/", with: "")
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
                    let id = client?["id"] as? NSNumber
                    let name = client?["descriptiveName"] as? String ?? "?"
                    let status = client?["status"] as? String ?? "?"
                    lines.append("- \(id?.stringValue ?? "?") — \(name) (\(status))")
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

    struct SearchResults {
        var results: [[String: Any]] = []
        var nextPageToken: String?
    }

    private func searchRaw(customerID: String, query: String, pageToken: String?, context: APIContext, runtime: ConnectorRuntime) async throws -> SearchResults {
        guard let url = ConnectorHTTP.url(Self.apiBase, "/\(Self.apiVersion)/customers/\(customerID)/googleAds:search") else {
            throw ConnectorError("Bad Google Ads URL.")
        }
        var body: [String: Any] = ["query": query, "pageSize": 500]
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


