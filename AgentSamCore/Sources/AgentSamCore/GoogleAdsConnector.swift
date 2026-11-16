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
        if permissions.adsWrite {
            defs += [Self.setStatusTool, Self.setBudgetTool, Self.mutateTool, Self.validateTool]
        }
        return defs
    }

    static let writesDisabled = "Google Ads changes are turned off. Turn on \"Make Google Ads changes\" for the Google Ads connector in Connections."

    private static let customerIDProperty: (String, JSONValue) = ("customer_id", .object([("type", .string("string")), ("description", .string("Customer account ID (with or without the customers/ prefix or dashes). Defaults to the configured login customer."))]))

    /// Entities `googleads_set_status` can pause or enable, mapped to their mutate service.
    static let statusEntities: [String: String] = [
        "campaign": "campaigns",
        "ad_group": "adGroups",
        "ad": "adGroupAds",
        "asset_group": "assetGroups",
        "keyword": "adGroupCriteria",
    ]

    static let setStatusTool = APIToolDef(
        name: "googleads_set_status",
        description: "Pause or enable a Google Ads campaign, ad group, ad, asset group or keyword. Changes live ad delivery and spend; the user approves each call on a card before it runs.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                customerIDProperty,
                ("entity", .object([("type", .string("string")), ("enum", .array(statusEntities.keys.sorted().map { JSONValue.string($0) })), ("description", .string("What to change. Defaults to campaign."))])),
                ("id", .object([("type", .string("string")), ("description", .string("Numeric ID or full resource name. For ad and keyword use adGroupId~adId or adGroupId~criterionId (or the resource name)."))])),
                ("campaign_id", .object([("type", .string("string")), ("description", .string("Same as id with entity campaign; kept for older calls."))])),
                ("status", .object([("type", .string("string")), ("enum", .array([.string("PAUSED"), .string("ENABLED")])), ("description", .string("PAUSED to stop delivery, ENABLED to resume it."))])),
            ])),
            ("required", .array([.string("status")])),
        ])
    )

    static let setBudgetTool = APIToolDef(
        name: "googleads_set_budget",
        description: "Change a campaign's daily budget, in the account's currency (for example 25 means 25.00 per day). Pass campaign_id to change the budget that campaign uses, or budget_id for a specific (possibly shared) budget. Affects spend; the user approves each call on a card before it runs.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                customerIDProperty,
                ("campaign_id", .object([("type", .string("string")), ("description", .string("Campaign whose budget to change."))])),
                ("budget_id", .object([("type", .string("string")), ("description", .string("Campaign budget ID or resource name, instead of campaign_id."))])),
                ("amount", .object([("type", .string("number")), ("description", .string("New daily amount in account currency units, not micros."))])),
            ])),
            ("required", .array([.string("amount")])),
        ])
    )

    /// Mutate services agents may call. `googleAds` is the multi-resource GoogleAdsService.Mutate,
    /// used for atomic creates with temporary negative IDs (budget + campaign + asset group).
    static let mutateResources: [String] = [
        "googleAds",
        "campaigns", "campaignBudgets", "campaignCriteria", "campaignAssets", "campaignLabels", "campaignSharedSets",
        "adGroups", "adGroupAds", "adGroupCriteria", "adGroupAssets", "adGroupLabels", "ads",
        "assetGroups", "assetGroupAssets", "assetGroupSignals", "assetGroupListingGroupFilters", "assets", "assetSets", "assetSetAssets",
        "customerAssets", "biddingStrategies", "sharedSets", "sharedCriteria", "labels", "conversionActions", "customerNegativeCriteria",
    ]

    private static let mutateProperties: [(String, JSONValue)] = [
        customerIDProperty,
        ("resource", .object([("type", .string("string")), ("enum", .array(mutateResources.map { JSONValue.string($0) })), ("description", .string("Mutate service in REST form, e.g. campaigns for CampaignService.MutateCampaigns. Use googleAds for GoogleAdsService.Mutate, whose operations are MutateOperation objects like {\"campaignBudgetOperation\": {...}}."))])),
        ("operations", .object([("type", .string("array")), ("items", .object([("type", .string("object"))])), ("description", .string("Google Ads API REST operations, e.g. [{\"update\": {\"resourceName\": \"customers/123/adGroups/456\", \"cpcBidMicros\": \"1500000\"}, \"updateMask\": \"cpcBidMicros\"}] or [{\"create\": {...}}]. Money is in micros (1.00 = 1000000). Use temporary negative IDs to link new resources in one googleAds call."))])),
        ("partial_failure", .object([("type", .string("boolean")), ("description", .string("Apply the operations that succeed even if others fail. Default false: all or nothing."))])),
    ]

    static let mutateTool = APIToolDef(
        name: "googleads_mutate",
        description: "Create, update or remove Google Ads resources: campaigns, budgets, ad groups, ads, keywords, asset groups, assets and more. Follows the Google Ads API REST mutate format. Changes live ads and spend, and remove cannot be undone; run googleads_validate with the same arguments first, then call this. The user approves each call on a card before it runs.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object(mutateProperties)),
            ("required", .array([.string("resource"), .string("operations")])),
        ])
    )

    static let validateTool = APIToolDef(
        name: "googleads_validate",
        description: "Dry-run a googleads_mutate call: Google Ads checks the operations and reports errors, but changes nothing. Takes the same arguments as googleads_mutate and needs no approval.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object(mutateProperties)),
            ("required", .array([.string("resource"), .string("operations")])),
        ])
    )

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
        description: "Run a raw GAQL query against a Google Ads customer account (read-only SELECT queries). Use it to look up IDs and current values before a change.",
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

            case "googleads_set_status", "googleads_set_campaign_status":
                guard permissions.adsWrite else { return ToolOutcome(resultText: Self.writesDisabled) }
                let entity = (args["entity"]?.stringValue ?? "campaign").lowercased()
                guard let service = Self.statusEntities[entity] else {
                    return ToolOutcome(resultText: "entity must be one of \(Self.statusEntities.keys.sorted().joined(separator: ", ")).")
                }
                guard let id = Self.cleanEntityID(args["id"]?.stringValue ?? args["campaign_id"]?.stringValue, composite: service == "adGroupAds" || service == "adGroupCriteria") else {
                    return ToolOutcome(resultText: "\(name) requires a valid id for the \(entity).")
                }
                guard let status = args["status"]?.stringValue?.uppercased(), ["PAUSED", "ENABLED"].contains(status) else {
                    return ToolOutcome(resultText: "status must be PAUSED or ENABLED.")
                }
                let customerID = try resolveCustomerID(args["customer_id"]?.stringValue, context: context)
                let body = Self.statusBody(customerID: customerID, service: service, id: id, status: status)
                let resources = try await mutate(customerID: customerID, service: service, body: body, context: context, runtime: runtime)
                guard let resource = resources.first else { throw ConnectorError("Google Ads did not confirm the change.") }
                return ToolOutcome(resultText: "\(resource) is now \(status).")

            case "googleads_set_budget":
                guard permissions.adsWrite else { return ToolOutcome(resultText: Self.writesDisabled) }
                guard let amount = args["amount"]?.numberValue ?? args["amount"]?.stringValue.flatMap(Double.init), amount > 0, amount.isFinite else {
                    return ToolOutcome(resultText: "googleads_set_budget requires a positive amount in account currency.")
                }
                let customerID = try resolveCustomerID(args["customer_id"]?.stringValue, context: context)
                let budgetID: String
                if let raw = args["budget_id"]?.stringValue, !raw.isEmpty {
                    guard let id = Self.cleanEntityID(raw, composite: false) else { return ToolOutcome(resultText: "budget_id must be a numeric ID or resource name.") }
                    budgetID = id
                } else if let campaignID = Self.cleanCampaignID(args["campaign_id"]?.stringValue) {
                    budgetID = try await campaignBudgetID(customerID: customerID, campaignID: campaignID, context: context, runtime: runtime)
                } else {
                    return ToolOutcome(resultText: "googleads_set_budget requires campaign_id or budget_id.")
                }
                let micros = Self.micros(amount)
                let body = Self.budgetBody(customerID: customerID, budgetID: budgetID, amountMicros: micros)
                let resources = try await mutate(customerID: customerID, service: "campaignBudgets", body: body, context: context, runtime: runtime)
                guard let resource = resources.first else { throw ConnectorError("Google Ads did not confirm the budget change.") }
                return ToolOutcome(resultText: "\(resource) now has a daily amount of \(String(format: "%.2f", Double(micros) / 1_000_000)).")

            case "googleads_mutate", "googleads_validate":
                guard permissions.adsWrite else { return ToolOutcome(resultText: Self.writesDisabled) }
                let validateOnly = name == "googleads_validate"
                guard let service = args["resource"]?.stringValue, Self.mutateResources.contains(service) else {
                    return ToolOutcome(resultText: "resource must be one of: \(Self.mutateResources.joined(separator: ", ")).")
                }
                guard let operations = args["operations"]?.arrayValue, !operations.isEmpty, operations.allSatisfy({ $0.objectValue != nil }) else {
                    return ToolOutcome(resultText: "\(name) requires a non-empty operations array of objects.")
                }
                let customerID = try resolveCustomerID(args["customer_id"]?.stringValue, context: context)
                let body = Self.mutateBody(service: service, operations: operations, validateOnly: validateOnly, partialFailure: args["partial_failure"]?.boolValue ?? false)
                let (resources, partialError) = try await mutateRaw(customerID: customerID, service: service, body: body, context: context, runtime: runtime)
                var lines: [String] = []
                if validateOnly {
                    lines.append("Validation passed for \(operations.count) operation(s) on \(service). Nothing was changed; call googleads_mutate with the same arguments to apply.")
                } else {
                    lines.append("Applied \(operations.count) operation(s) on \(service) for customer \(customerID).")
                    lines += resources.map { "- \($0)" }
                }
                if let partialError { lines.append("Some operations failed: \(partialError)") }
                return ToolOutcome(resultText: AgentTools.clip(lines.joined(separator: "\n")))

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

    /// Accepts a numeric ID or a resource name. Composite IDs (ads, keywords) look like 123~456.
    static func cleanEntityID(_ raw: String?, composite: Bool) -> String? {
        guard let last = raw?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/").last else { return nil }
        let id = String(last)
        let parts = id.split(separator: "~", omittingEmptySubsequences: false)
        guard parts.count == (composite ? 2 : 1) else { return nil }
        return parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) ? id : nil
    }

    static func campaignStatusBody(customerID: String, campaignID: String, status: String) -> [String: Any] {
        statusBody(customerID: customerID, service: "campaigns", id: campaignID, status: status)
    }

    static func statusBody(customerID: String, service: String, id: String, status: String) -> [String: Any] {
        [
            "operations": [[
                "update": ["resourceName": "customers/\(customerID)/\(service)/\(id)", "status": status],
                "updateMask": "status",
            ]],
        ]
    }

    /// Currency units to micros, rounded to the cent so the API does not reject odd fractions.
    static func micros(_ amount: Double) -> Int64 {
        Int64((amount * 100).rounded()) * 10_000
    }

    static func budgetBody(customerID: String, budgetID: String, amountMicros: Int64) -> [String: Any] {
        [
            "operations": [[
                // int64 fields are strings in the REST API.
                "update": ["resourceName": "customers/\(customerID)/campaignBudgets/\(budgetID)", "amountMicros": String(amountMicros)],
                "updateMask": "amountMicros",
            ]],
        ]
    }

    static func mutateBody(service: String, operations: [JSONValue], validateOnly: Bool, partialFailure: Bool) -> [String: Any] {
        var body: [String: Any] = [service == "googleAds" ? "mutateOperations" : "operations": operations.map(Self.foundationValue)]
        if validateOnly { body["validateOnly"] = true }
        if partialFailure { body["partialFailure"] = true }
        return body
    }

    /// JSONValue to a JSONSerialization-ready value. Whole numbers stay integers so IDs and
    /// micros are not sent as 1.5e+06.
    static func foundationValue(_ value: JSONValue) -> Any {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b
        case .null: return NSNull()
        case .number(let n):
            if n.rounded() == n, abs(n) < 9.0e15 { return Int(n) }
            return n
        case .array(let items): return items.map(foundationValue)
        case .object(let pairs): return pairs.mapValues(foundationValue)
        }
    }

    private func campaignBudgetID(customerID: String, campaignID: String, context: APIContext, runtime: ConnectorRuntime) async throws -> String {
        let query = "SELECT campaign.campaign_budget FROM campaign WHERE campaign.id = \(campaignID)"
        let results = try await searchRaw(customerID: customerID, query: query, pageToken: nil, context: context, runtime: runtime)
        guard let resource = (results.results.first?["campaign"] as? [String: Any])?["campaignBudget"] as? String,
              let id = Self.cleanEntityID(resource, composite: false) else {
            throw ConnectorError("Could not find the budget for campaign \(campaignID).")
        }
        return id
    }

    private func mutate(customerID: String, service: String, body: [String: Any], context: APIContext, runtime: ConnectorRuntime) async throws -> [String] {
        try await mutateRaw(customerID: customerID, service: service, body: body, context: context, runtime: runtime).resources
    }

    private func mutateRaw(customerID: String, service: String, body: [String: Any], context: APIContext, runtime: ConnectorRuntime) async throws -> (resources: [String], partialError: String?) {
        let path = service == "googleAds" ? "googleAds:mutate" : "\(service):mutate"
        guard let url = ConnectorHTTP.url(Self.apiBase, "/\(Self.apiVersion)/customers/\(customerID)/\(path)") else {
            throw ConnectorError("Bad Google Ads URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: "POST", headers: headers(context), jsonBody: body)
        let object: [String: Any] = try data.isEmpty ? [:] : ConnectorHTTP.jsonObject(data)
        return (Self.resourceNames(in: object), (object["partialFailureError"] as? [String: Any])?["message"] as? String)
    }

    /// Resource names from a mutate response. GoogleAdsService.Mutate nests them one level
    /// deeper, e.g. {"mutateOperationResponses": [{"campaignResult": {"resourceName": ...}}]}.
    static func resourceNames(in object: [String: Any]) -> [String] {
        if let results = object["results"] as? [[String: Any]] {
            return results.compactMap { $0["resourceName"] as? String }
        }
        let responses = object["mutateOperationResponses"] as? [[String: Any]] ?? []
        return responses.compactMap { response in
            response.values.compactMap { ($0 as? [String: Any])?["resourceName"] as? String }.first
        }
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


