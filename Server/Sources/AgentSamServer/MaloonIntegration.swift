import Vapor
import AgentSamCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct OwnerWorkflow: Sendable {
    let model: MissionWorkflow
    let objective: String
}

struct MaloonIntegration: Sendable {
    static let sourceName = "Maloon"
    static let ownerTeamID = UUID(uuidString: "5F4A1D63-3F54-4D5D-A16B-0B97E3654D00")!

    static let workflows: [OwnerWorkflow] = [
        OwnerWorkflow(
            model: MissionWorkflow(
                id: "daily-operations",
                title: "Daily operations brief",
                summary: "Today’s jobs, progress, staffing gaps, upcoming work, and issues needing attention.",
                behavior: "Read-only operational summary"
            ),
            objective: "Prepare a concise owner operations brief for the snapshot’s local date. Cover today’s jobs and completion progress, unassigned or at-risk work, staffing concerns, and important jobs coming up in the next 14 days. Separate facts from recommendations, prioritize concrete owner actions, and cite the relevant job or assignment details. Do not treat incomplete data as proof that work was not done."
        ),
        OwnerWorkflow(
            model: MissionWorkflow(
                id: "quote-follow-ups",
                title: "Quote follow-ups",
                summary: "Find open quotes needing attention and draft follow-ups for owner review.",
                behavior: "Drafts only · nothing is sent"
            ),
            objective: "Review the draft and sent quotes in the snapshot. Prioritize quotes that need owner attention using their status, age, value, and supplied notes. Explain each recommendation and draft concise, courteous follow-up messages where useful. Clearly label every message as a draft for owner review. Do not send messages, change quote statuses, or invent customer history."
        ),
        OwnerWorkflow(
            model: MissionWorkflow(
                id: "staffing-dispatch",
                title: "Staffing and dispatch review",
                summary: "Flag unassigned or at-risk jobs and review options against worker availability.",
                behavior: "Recommendations only · no schedule changes"
            ),
            objective: "Review current and upcoming jobs, assignments, and active worker availability in the snapshot. Flag unassigned work, scheduling risks, and potential overloads or gaps. Suggest practical staffing or dispatch options only when supported by the supplied availability and assignment data. State uncertainty and never claim to have assigned workers or changed a schedule."
        ),
        OwnerWorkflow(
            model: MissionWorkflow(
                id: "customer-marketing",
                title: "Customer and marketing drafts",
                summary: "Draft useful customer communications and service marketing from current business context.",
                behavior: "Drafts only · nothing is published"
            ),
            objective: "Using only the supplied business, service, quote, and job context, propose a small set of useful customer communications and marketing drafts. Ground service descriptions and prices in the snapshot, keep claims supportable, and identify the intended audience and channel for each draft. Do not publish, send, invent testimonials, or make guarantees that are not present in the source data."
        )
    ]

    let baseURL: String
    let token: String
    let session: URLSession

    init() {
        baseURL = (Environment.get("AGENTSAM_MALOON_URL") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        token = (Environment.get("AGENTSAM_MALOON_TOKEN") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration)
    }

    var isConfigured: Bool { !baseURL.isEmpty && !token.isEmpty }

    /// Localized integration status for a request in `lang` ("en" | "es").
    func status(lang: String = "en") -> IntegrationStatus {
        IntegrationStatus(
            id: "maloon",
            name: Self.sourceName,
            isConfigured: isConfigured,
            workflows: isConfigured ? Self.workflows.map { workflow in
                let id = workflow.model.id
                return MissionWorkflow(
                    id: id,
                    title: SrvL10n.t("maloon.workflow.\(id).title", lang: lang),
                    summary: SrvL10n.t("maloon.workflow.\(id).summary", lang: lang),
                    behavior: SrvL10n.t("maloon.workflow.\(id).behavior", lang: lang)
                )
            } : []
        )
    }

    func workflow(id: String, lang: String = "en") throws -> OwnerWorkflow {
        guard isConfigured else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.maloonNotConfigured", lang: lang))
        }
        guard let base = Self.workflows.first(where: { $0.model.id == id }) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.maloonUnknownWorkflow", lang: lang))
        }
        return OwnerWorkflow(
            model: MissionWorkflow(
                id: base.model.id,
                title: SrvL10n.t("maloon.workflow.\(base.model.id).title", lang: lang),
                summary: SrvL10n.t("maloon.workflow.\(base.model.id).summary", lang: lang),
                behavior: SrvL10n.t("maloon.workflow.\(base.model.id).behavior", lang: lang)
            ),
            objective: SrvL10n.t("maloon.workflow.\(base.model.id).objective", lang: lang)
        )
    }

    func test(lang: String = "en") async -> IntegrationTestResult {
        do {
            _ = try await snapshot(lang: lang)
            return IntegrationTestResult(ok: true, message: SrvL10n.t("srv.maloonTestOK", lang: lang))
        } catch {
            return IntegrationTestResult(ok: false, message: error.localizedDescription)
        }
    }

    func snapshot(lang: String = "en") async throws -> String {
        guard isConfigured else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.maloonNotConfigured", lang: lang))
        }
        let root = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: root + "/api/integrations/agentsam/snapshot"),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              url.host != nil else {
            throw Abort(.internalServerError, reason: SrvL10n.t("srv.maloonBadURL", lang: lang))
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Abort(.badGateway, reason: SrvL10n.tf("srv.indigoUnreachable", error.localizedDescription, lang: lang))
        }
        guard let http = response as? HTTPURLResponse else {
            throw Abort(.badGateway, reason: SrvL10n.t("srv.indigoInvalidResponse", lang: lang))
        }
        guard http.statusCode == 200 else {
            throw Abort(.badGateway, reason: SrvL10n.tf("srv.indigoStatusFailed", Int64(http.statusCode), lang: lang))
        }
        guard data.count <= 512_000 else {
            throw Abort(.badGateway, reason: SrvL10n.t("srv.indigoTooLarge", lang: lang))
        }

        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schemaVersion"] as? Int == 1,
                  object["generatedAt"] is String,
                  object["timeZone"] is String,
                  object["business"] is [String: Any],
                  object["quotes"] is [Any],
                  object["jobs"] is [Any],
                  object["workers"] is [Any],
                  object["services"] is [Any] else {
                throw Abort(.badGateway, reason: SrvL10n.t("srv.indigoIncomplete", lang: lang))
            }
            let normalized = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            guard let text = String(data: normalized, encoding: .utf8) else {
                throw Abort(.badGateway, reason: SrvL10n.t("srv.indigoNotUTF8", lang: lang))
            }
            return text
        } catch let error as AbortError {
            throw error
        } catch {
            throw Abort(.badGateway, reason: SrvL10n.t("srv.indigoMalformed", lang: lang))
        }
    }

    func ownerTeam(store: MissionStore, keyRing: KeyRing, lang: String = "en") async throws -> Team {
        let providers = await store.loadProviders()
        if let existing = await store.team(id: Self.ownerTeamID) {
            let isUsable = existing.agents.allSatisfy { agent in
                guard let provider = providers.first(where: { $0.id == agent.providerID }) else { return false }
                let key = keyRing.get(provider.keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !key.isEmpty && !agent.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard isUsable, existing.coordinator != nil, !existing.workers.isEmpty else {
                throw Abort(.badRequest, reason: SrvL10n.t("srv.maloonRosterIncomplete", lang: lang))
            }
            return existing
        }
        guard let provider = providers.first(where: {
            let key = keyRing.get($0.keyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = ($0.defaultModel ?? $0.models.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !key.isEmpty && !model.isEmpty
        }) else {
            throw Abort(.badRequest, reason: SrvL10n.t("srv.maloonProviderMissing", lang: lang))
        }
        let model = provider.defaultModel ?? provider.models.first ?? ""
        let rosterNames = ["Ada", "Plot", "Scout", "Quill", "Judge"]
        let agents = rosterNames.compactMap { name in
            AgentProfile.rosterTemplates.first(where: { $0.name == name })
        }.map { original in
            var agent = original
            agent.id = UUID()
            agent.providerID = provider.id
            agent.model = model
            return agent
        }
        let team = Team(
            id: Self.ownerTeamID,
            name: SrvL10n.t("srv.maloonTeamName", lang: lang),
            emoji: "🧭",
            goal: SrvL10n.t("srv.maloonTeamGoal", lang: lang),
            agents: agents
        )
        await store.saveTeam(team)
        return team
    }
}
