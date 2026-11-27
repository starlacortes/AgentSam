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
        var defs = [Self.accountsTool, Self.campaignsTool, Self.queryTool, Self.recommendationsTool]
        if permissions.adsWrite {
            defs += [Self.setStatusTool, Self.setBudgetTool, Self.mutateTool, Self.validateTool, Self.applyRecommendationsTool, Self.dismissRecommendationsTool]
        }
        return defs
    }

    static let writesDisabled = "Google Ads changes are turned off. An admin turns on \"Allow Google Ads changes\" under Settings → Connections → Google Ads."

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
        "customerConversionGoals", "campaignConversionGoals", "conversionGoalCampaignConfigs", "conversionValueRules",
    ]

    private static let mutateProperties: [(String, JSONValue)] = [
        customerIDProperty,
        ("resource", .object([("type", .string("string")), ("enum", .array(mutateResources.map { JSONValue.string($0) })), ("description", .string("Mutate service in REST form, e.g. campaigns for CampaignService.MutateCampaigns. Use googleAds for GoogleAdsService.Mutate, whose operations are MutateOperation objects like {\"campaignBudgetOperation\": {...}}."))])),
        ("operations", .object([("type", .string("array")), ("items", .object([("type", .string("object"))])), ("description", .string("Google Ads API REST operations, e.g. [{\"update\": {\"resourceName\": \"customers/123/adGroups/456\", \"cpcBidMicros\": \"1500000\"}, \"updateMask\": \"cpcBidMicros\"}] or [{\"create\": {...}}]. Money is in micros (1.00 = 1000000). Use temporary negative IDs to link new resources in one googleAds call."))])),
        ("partial_failure", .object([("type", .string("boolean")), ("description", .string("Apply the operations that succeed even if others fail. Default false: all or nothing."))])),
    ]

    static let mutateTool = APIToolDef(
        name: "googleads_mutate",
        description: "Create, update or remove Google Ads resources: campaigns, budgets, bids, ad groups, ads, keywords, asset groups, assets, conversion actions and conversion goals, and more. Follows the Google Ads API REST mutate format. Changes live ads and spend, and remove cannot be undone; run googleads_validate with the same arguments first, then call this. The user approves each call on a card before it runs.",
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

    // MARK: Recommendations (they drive the optimization score)

    static let recommendationsTool = APIToolDef(
        name: "googleads_recommendations",
        description: "Read the account's optimization score as a percent (also per campaign; in GAQL, customer.optimization_score is 0 to 1, so 1 means 100%) and Google's open recommendations: each one's resource name, type, campaign, suggested values and estimated impact. The score itself cannot be set; it rises when recommendations are applied (googleads_apply_recommendations) or dismissed (googleads_dismiss_recommendations), or when the account is changed the way a recommendation suggests.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                customerIDProperty,
                ("types", .object([("type", .string("array")), ("items", .object([("type", .string("string"))])), ("description", .string("Only these recommendation types, e.g. [\"CAMPAIGN_BUDGET\", \"KEYWORD\", \"SITELINK_ASSET\"]. Default: all."))])),
                ("campaign_id", .object([("type", .string("string")), ("description", .string("Only recommendations for this campaign."))])),
            ])),
        ])
    )

    private static func recommendationNamesProperty(_ verb: String) -> (String, JSONValue) {
        ("recommendations", .object([("type", .string("array")), ("items", .object([("type", .string("string"))])), ("description", .string("Recommendation resource names (customers/123/recommendations/456) or bare IDs from googleads_recommendations, to \(verb)."))]))
    }

    static let applyRecommendationsTool = APIToolDef(
        name: "googleads_apply_recommendations",
        description: "Apply Google Ads recommendations (RecommendationService.ApplyRecommendation), which makes the change each one suggests (budgets, bids and bidding strategies, keywords, assets, ads) and raises the optimization score. Changes live ads and spend. Google offers no dry run for this, so read the recommendations first and say what each will change. The user approves each call on a card before it runs.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                customerIDProperty,
                recommendationNamesProperty("apply as Google suggests"),
                ("operations", .object([("type", .string("array")), ("items", .object([("type", .string("object"))])), ("description", .string("Instead of recommendations, ApplyRecommendationOperation objects in REST form, to change a suggested value, e.g. [{\"resourceName\": \"customers/123/recommendations/456\", \"campaignBudget\": {\"newBudgetAmountMicros\": \"30000000\"}}]. Money is in micros (1.00 = 1000000)."))])),
                ("partial_failure", .object([("type", .string("boolean")), ("description", .string("Apply the ones that succeed even if others fail. Default false: all or nothing."))])),
            ])),
        ])
    )

    static let dismissRecommendationsTool = APIToolDef(
        name: "googleads_dismiss_recommendations",
        description: "Dismiss Google Ads recommendations that do not fit the business (RecommendationService.DismissRecommendation). Changes no ads or spend, and also counts toward the optimization score. The user approves each call on a card before it runs.",
        parameters: .object([
            ("type", .string("object")),
            ("properties", .object([
                customerIDProperty,
                recommendationNamesProperty("dismiss"),
                ("partial_failure", .object([("type", .string("boolean")), ("description", .string("Dismiss the ones that succeed even if others fail. Default false: all or nothing."))])),
            ])),
            ("required", .array([.string("recommendations")])),
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

            case "googleads_recommendations":
                let customerID = try resolveCustomerID(args["customer_id"]?.stringValue, context: context)
                var campaignID: String?
                if let raw = args["campaign_id"]?.stringValue, !raw.isEmpty {
                    guard let id = Self.cleanCampaignID(raw) else { return ToolOutcome(resultText: "campaign_id must be a numeric ID or resource name.") }
                    campaignID = id
                }
                let types = (args["types"]?.arrayValue ?? []).compactMap(\.stringValue)
                guard let filter = Self.recommendationFilter(types: types) else {
                    return ToolOutcome(resultText: "types must be recommendation type names such as CAMPAIGN_BUDGET or KEYWORD.")
                }
                return ToolOutcome.success(try await recommendations(customerID: customerID, filter: filter, campaignID: campaignID, context: context, runtime: runtime))

            case "googleads_apply_recommendations", "googleads_dismiss_recommendations":
                guard permissions.adsWrite else { return ToolOutcome(resultText: Self.writesDisabled) }
                let apply = name == "googleads_apply_recommendations"
                let names = args["recommendations"]?.arrayValue ?? []
                let objects = apply ? (args["operations"]?.arrayValue ?? []) : []
                // Resource names carry their account, so a sub-account works without customer_id.
                let named = (names.compactMap(\.stringValue) + objects.compactMap { $0.objectValue?["resourceName"]?.stringValue }).first.flatMap(Self.recommendationCustomer)
                let customerID = try resolveCustomerID(args["customer_id"]?.stringValue ?? named, context: context)
                let operations: [[String: Any]]
                switch Self.recommendationOperations(customerID: customerID, names: names, operations: objects) {
                case .success(let built): operations = built
                case .failure(let error): return ToolOutcome(resultText: "\(name): \(error.message)")
                }
                var body: [String: Any] = ["operations": operations]
                if args["partial_failure"]?.boolValue == true { body["partialFailure"] = true }
                let (resources, partialError) = try await recommendationCall(customerID: customerID, method: apply ? "apply" : "dismiss", body: body, context: context, runtime: runtime)
                var lines = ["\(apply ? "Applied" : "Dismissed") \(resources.count) of \(operations.count) recommendation(s) for customer \(customerID)."]
                lines += resources.map { "- \($0)" }
                if let partialError { lines.append("Some failed: \(partialError)") }
                if apply { lines.append("Google can take a few minutes to update the optimization score; some applies (target CPA changes) finish in the background.") }
                return ToolOutcome(resultText: AgentTools.clip(lines.joined(separator: "\n")))

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

    // MARK: Recommendation helpers

    /// Detail fields for the common types. A recommendation only fills its own type's field.
    static let recommendationDetailFields = [
        "recommendation.campaign_budget_recommendation", "recommendation.keyword_recommendation",
        "recommendation.target_cpa_opt_in_recommendation", "recommendation.set_target_cpa_recommendation",
        "recommendation.set_target_roas_recommendation", "recommendation.raise_target_cpa_bid_too_low_recommendation",
        "recommendation.use_broad_match_keyword_recommendation", "recommendation.forecasting_campaign_budget_recommendation",
    ]
    static let recommendationBaseFields = [
        "recommendation.resource_name", "recommendation.type", "recommendation.campaign", "recommendation.ad_group",
        "recommendation.campaign_budget", "recommendation.dismissed", "recommendation.impact",
    ]

    /// GAQL WHERE clause (possibly empty), or nil when a type name is not a plain enum name.
    static func recommendationFilter(types: [String]) -> String? {
        var conditions: [String] = []
        let cleaned = types.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }.filter { !$0.isEmpty }
        guard cleaned.allSatisfy({ name in name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }) else { return nil }
        if !cleaned.isEmpty { conditions.append("recommendation.type IN (\(cleaned.joined(separator: ", ")))") }
        return conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
    }

    struct RecommendationInputError: Error { var message: String }

    /// Apply or dismiss operations from resource names, bare IDs, or (apply only) REST operation objects.
    static func recommendationOperations(customerID: String, names: [JSONValue], operations: [JSONValue]) -> Result<[[String: Any]], RecommendationInputError> {
        var built: [[String: Any]] = []
        for value in names {
            guard let raw = value.stringValue, let resource = recommendationResource(raw, customerID: customerID) else {
                return .failure(RecommendationInputError(message: "each recommendation must be a resource name like customers/\(customerID)/recommendations/456 or an ID."))
            }
            built.append(["resourceName": resource])
        }
        for value in operations {
            guard let pairs = value.objectValue, let raw = pairs["resourceName"]?.stringValue ?? pairs["resource_name"]?.stringValue,
                  let resource = recommendationResource(raw, customerID: customerID) else {
                return .failure(RecommendationInputError(message: "each operation needs a resourceName like customers/\(customerID)/recommendations/456."))
            }
            var operation = (foundationValue(value) as? [String: Any]) ?? [:]
            operation.removeValue(forKey: "resource_name")
            operation["resourceName"] = resource
            built.append(operation)
        }
        guard !built.isEmpty else { return .failure(RecommendationInputError(message: "list at least one recommendation.")) }
        guard built.count <= 100 else { return .failure(RecommendationInputError(message: "at most 100 recommendations per call.")) }
        return .success(built)
    }

    /// A recommendation resource name for this customer. IDs are opaque strings, not always numeric.
    static func recommendationResource(_ raw: String, customerID: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: Substring
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/")
            guard parts.count == 4, parts[0] == "customers", parts[2] == "recommendations",
                  parts[1].replacingOccurrences(of: "-", with: "") == customerID else { return nil }
            id = parts[3]
        } else {
            id = Substring(trimmed)
        }
        guard !id.isEmpty, !id.contains(where: { $0.isWhitespace || $0 == "?" || $0 == "#" }) else { return nil }
        return "customers/\(customerID)/recommendations/\(id)"
    }

    /// An optimization score (0 to 1 in the API) as a percent, e.g. 1 -> "100%", 0.734 -> "73.4%".
    static func scorePercent(_ value: Double) -> String {
        let percent = value * 100
        return percent.rounded() == percent ? "\(Int(percent))%" : String(format: "%.1f%%", percent)
    }

    /// The account in a recommendation resource name, e.g. 123 from customers/123/recommendations/abc.
    static func recommendationCustomer(_ raw: String) -> String? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
        guard parts.count == 4, parts[0] == "customers", parts[2] == "recommendations" else { return nil }
        return parts[1].replacingOccurrences(of: "-", with: "")
    }

    private func recommendations(customerID: String, filter: String, campaignID: String?, context: APIContext, runtime: ConnectorRuntime) async throws -> String {
        var lines = ["Customer: \(customerID)"]
        // The score is null for manager accounts; a failure here should not hide the recommendations.
        if let score = try? await searchRaw(customerID: customerID, query: "SELECT customer.optimization_score, customer.optimization_score_weight FROM customer", pageToken: nil, context: context, runtime: runtime),
           let customer = score.results.first?["customer"] as? [String: Any] {
            if let value = customer["optimizationScore"] as? Double {
                lines.append("Account optimization score: \(Self.scorePercent(value)) (Google reports it from 0 to 1, so 1 means 100%; it rises as recommendations are applied or dismissed).")
            } else {
                lines.append("Account optimization score: not available (manager accounts and some campaign types have none).")
            }
        }
        if let campaigns = try? await searchRaw(customerID: customerID, query: "SELECT campaign.id, campaign.name, campaign.optimization_score FROM campaign WHERE campaign.status = 'ENABLED'", pageToken: nil, context: context, runtime: runtime) {
            let scored = campaigns.results.compactMap { row -> String? in
                guard let campaign = row["campaign"] as? [String: Any], let value = campaign["optimizationScore"] as? Double else { return nil }
                return "- \(campaign["name"] as? String ?? "?") (\(campaign["id"] as? String ?? "?")): \(Self.scorePercent(value))"
            }
            if !scored.isEmpty { lines.append("Campaign optimization scores:"); lines += scored }
        }
        let fields = Self.recommendationBaseFields + Self.recommendationDetailFields
        let rows: [[String: Any]]
        do {
            rows = try await searchRaw(customerID: customerID, query: "SELECT \(fields.joined(separator: ", ")) FROM recommendation\(filter)", pageToken: nil, context: context, runtime: runtime).results
        } catch {
            // A detail field this API version rejects should not hide the list: retry with the basics.
            rows = try await searchRaw(customerID: customerID, query: "SELECT \(Self.recommendationBaseFields.joined(separator: ", ")) FROM recommendation\(filter)", pageToken: nil, context: context, runtime: runtime).results
        }
        let open = rows.compactMap { $0["recommendation"] as? [String: Any] }.filter { recommendation in
            guard (recommendation["dismissed"] as? Bool) != true else { return false }
            guard let campaignID else { return true }
            let campaigns = ((recommendation["campaigns"] as? [String]) ?? []) + [recommendation["campaign"] as? String].compactMap { $0 }
            return campaigns.contains { $0.hasSuffix("/campaigns/\(campaignID)") }
        }
        lines.append("Open recommendations: \(open.count)")
        if open.isEmpty { lines.append("None. This is normal when the score is at or near 100%. Google refreshes recommendations daily.") }
        for recommendation in open {
            if let data = try? JSONSerialization.data(withJSONObject: recommendation, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                lines.append(text)
            }
        }
        return AgentTools.clip(lines.joined(separator: "\n"))
    }

    private func recommendationCall(customerID: String, method: String, body: [String: Any], context: APIContext, runtime: ConnectorRuntime) async throws -> (resources: [String], partialError: String?) {
        guard let url = ConnectorHTTP.url(Self.apiBase, "/\(Self.apiVersion)/customers/\(customerID)/recommendations:\(method)") else {
            throw ConnectorError("Bad Google Ads URL.")
        }
        let data = try await ConnectorHTTP.request(runtime.session, url: url, method: "POST", headers: headers(context), jsonBody: body)
        let object: [String: Any] = try data.isEmpty ? [:] : ConnectorHTTP.jsonObject(data)
        return (Self.resourceNames(in: object), (object["partialFailureError"] as? [String: Any])?["message"] as? String)
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

    /// The REST API leaves out "results" when no row matches, so a missing key is an empty
    /// result, not an error (an error here made "no recommendations" look like a failure).
    static func searchResults(from object: [String: Any]) -> SearchResults {
        SearchResults(results: object["results"] as? [[String: Any]] ?? [], nextPageToken: object["nextPageToken"] as? String)
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
        return Self.searchResults(from: object)
    }
}


