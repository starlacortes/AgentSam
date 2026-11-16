import Foundation

public enum WorkspaceKnowledgeDocumentID: String, Codable, CaseIterable, Sendable {
    case capabilities
    case connections
    case projects
}

public enum WorkspaceKnowledgeStatus: String, Codable, Sendable {
    case pending
    case refreshing
    case ready
    case failed
}

public struct WorkspaceKnowledgeDocument: Codable, Identifiable, Hashable, Sendable {
    public var id: WorkspaceKnowledgeDocumentID
    public var title: String
    public var markdown: String
    public var updatedAt: Date

    public init(id: WorkspaceKnowledgeDocumentID, title: String, markdown: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.markdown = markdown
        self.updatedAt = updatedAt
    }
}

public struct WorkspaceKnowledge: Codable, Hashable, Sendable {
    public var status: WorkspaceKnowledgeStatus
    public var documents: [WorkspaceKnowledgeDocument]
    public var discoveredAt: Date?
    public var updatedAt: Date?
    public var nextRefreshAt: Date?
    public var refreshCount: Int
    public var lastError: String?

    public init(status: WorkspaceKnowledgeStatus = .pending, documents: [WorkspaceKnowledgeDocument] = [], discoveredAt: Date? = nil, updatedAt: Date? = nil, nextRefreshAt: Date? = nil, refreshCount: Int = 0, lastError: String? = nil) {
        self.status = status
        self.documents = documents
        self.discoveredAt = discoveredAt
        self.updatedAt = updatedAt
        self.nextRefreshAt = nextRefreshAt
        self.refreshCount = refreshCount
        self.lastError = lastError
    }

    public static let empty = WorkspaceKnowledge()

    public var promptSummary: String {
        documents.map { document in
            "Document \(document.id.rawValue).md:\n\(String(document.markdown.prefix(4_000)))"
        }.joined(separator: "\n\n")
    }
}

private struct WorkspaceKnowledgeMetadata: Codable, Sendable {
    var ownerID: String
    var fingerprint: String
    var discoveredAt: Date?
    var updatedAt: Date?
    var nextRefreshAt: Date?
    var refreshCount: Int
    var lastError: String?
}

private struct WorkspaceKnowledgeDraft: Sendable {
    var id: WorkspaceKnowledgeDocumentID
    var title: String
    var markdown: String
}

public actor WorkspaceKnowledgeStore {
    public static let refreshInterval: TimeInterval = 86_400

    private nonisolated let root: URL
    private let store: MissionStore
    private let conversations: ConversationStore
    private let connectors: ConnectorHub
    private let keyRing: KeyRing
    private let includeExtendedTools: Bool
    private var refreshing: Set<String> = []

    private nonisolated var directory: URL {
        root.appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("knowledge", isDirectory: true)
    }

    public init(store: MissionStore, conversations: ConversationStore, connectors: ConnectorHub, keyRing: KeyRing, includeExtendedTools: Bool = false) {
        self.root = store.root
        self.store = store
        self.conversations = conversations
        self.connectors = connectors
        self.keyRing = keyRing
        self.includeExtendedTools = includeExtendedTools
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private func ownerDirectory(_ ownerID: String) -> URL {
        let key = Data(ownerID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(key, isDirectory: true)
    }

    private func metadataURL(_ ownerID: String) -> URL {
        ownerDirectory(ownerID).appendingPathComponent("state.json")
    }

    private func metadata(_ ownerID: String) -> WorkspaceKnowledgeMetadata? {
        guard let data = try? Data(contentsOf: metadataURL(ownerID)) else { return nil }
        return try? Self.decoder.decode(WorkspaceKnowledgeMetadata.self, from: data)
    }

    public func state(ownerID: String) -> WorkspaceKnowledge {
        guard let saved = metadata(ownerID) else {
            return WorkspaceKnowledge(status: refreshing.contains(ownerID) ? .refreshing : .pending)
        }
        let documents = WorkspaceKnowledgeDocumentID.allCases.compactMap { id -> WorkspaceKnowledgeDocument? in
            guard let updatedAt = saved.updatedAt,
                  let markdown = try? String(contentsOf: ownerDirectory(ownerID).appendingPathComponent("\(id.rawValue).md"), encoding: .utf8) else { return nil }
            return WorkspaceKnowledgeDocument(id: id, title: title(for: id), markdown: markdown, updatedAt: updatedAt)
        }
        return WorkspaceKnowledge(
            status: refreshing.contains(ownerID) ? .refreshing : (saved.lastError == nil ? .ready : .failed),
            documents: documents,
            discoveredAt: saved.discoveredAt,
            updatedAt: saved.updatedAt,
            nextRefreshAt: saved.nextRefreshAt,
            refreshCount: saved.refreshCount,
            lastError: saved.lastError
        )
    }

    @discardableResult
    public func refresh(ownerID: String, force: Bool = false, now: Date = Date()) async -> WorkspaceKnowledge {
        guard !refreshing.contains(ownerID) else { return state(ownerID: ownerID) }
        refreshing.insert(ownerID)
        do {
            let drafts = try await discover(ownerID: ownerID)
            let fingerprint = Self.fingerprint(drafts)
            let previous = metadata(ownerID)
            let documentsExist = WorkspaceKnowledgeDocumentID.allCases.allSatisfy {
                FileManager.default.fileExists(atPath: ownerDirectory(ownerID).appendingPathComponent("\($0.rawValue).md").path)
            }
            if !force, previous?.fingerprint == fingerprint, previous?.updatedAt != nil,
               previous?.nextRefreshAt ?? .distantPast > now, documentsExist {
                refreshing.remove(ownerID)
                return state(ownerID: ownerID)
            }
            let documents = drafts.map {
                WorkspaceKnowledgeDocument(id: $0.id, title: $0.title, markdown: $0.markdown, updatedAt: now)
            }
            let folder = ownerDirectory(ownerID)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for document in documents {
                try Data(document.markdown.utf8).write(to: folder.appendingPathComponent("\(document.id.rawValue).md"), options: .atomic)
            }
            let saved = WorkspaceKnowledgeMetadata(
                ownerID: ownerID,
                fingerprint: fingerprint,
                discoveredAt: previous?.discoveredAt ?? now,
                updatedAt: now,
                nextRefreshAt: now.addingTimeInterval(Self.refreshInterval),
                refreshCount: (previous?.refreshCount ?? 0) + 1,
                lastError: nil
            )
            try Self.encoder.encode(saved).write(to: metadataURL(ownerID), options: .atomic)
        } catch {
            var saved = metadata(ownerID) ?? WorkspaceKnowledgeMetadata(
                ownerID: ownerID,
                fingerprint: "",
                discoveredAt: nil,
                updatedAt: nil,
                nextRefreshAt: nil,
                refreshCount: 0,
                lastError: nil
            )
            saved.lastError = error.localizedDescription
            saved.nextRefreshAt = now.addingTimeInterval(300)
            try? FileManager.default.createDirectory(at: ownerDirectory(ownerID), withIntermediateDirectories: true)
            try? Self.encoder.encode(saved).write(to: metadataURL(ownerID), options: .atomic)
        }
        refreshing.remove(ownerID)
        return state(ownerID: ownerID)
    }

    public func refreshAll(now: Date = Date()) async {
        for ownerID in knownOwners() {
            _ = await refresh(ownerID: ownerID, now: now)
        }
    }

    private func knownOwners() -> [String] {
        guard let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return folders.compactMap { folder in
            let url = folder.appendingPathComponent("state.json")
            guard let data = try? Data(contentsOf: url),
                  let saved = try? Self.decoder.decode(WorkspaceKnowledgeMetadata.self, from: data) else { return nil }
            return saved.ownerID
        }.sorted()
    }

    private func discover(ownerID: String) async throws -> [WorkspaceKnowledgeDraft] {
        let teams = await store.loadTeams()
        let providers = await store.loadProviders()
        let chats = try await conversations.list(ownerID: ownerID)
        var statuses: [ConnectorStatus] = []
        for id in ConnectorID.allCases {
            statuses.append(await connectors.status(for: id))
        }
        let activeTools = await connectors.toolDefs()
        return [
            WorkspaceKnowledgeDraft(id: .capabilities, title: title(for: .capabilities), markdown: capabilitiesDocument(teams: teams, providers: providers)),
            WorkspaceKnowledgeDraft(id: .connections, title: title(for: .connections), markdown: connectionsDocument(statuses: statuses, activeTools: activeTools)),
            WorkspaceKnowledgeDraft(id: .projects, title: title(for: .projects), markdown: projectsDocument(chats: chats)),
        ]
    }

    private func capabilitiesDocument(teams: [Team], providers: [ProviderConfig]) -> String {
        var lines = [
            "# Workspace capabilities",
            "",
            "Generated from the live workspace configuration. No credentials, private agent prompts, or connected content are included.",
            "",
            "## Model providers",
        ]
        if providers.isEmpty {
            lines.append("- No model providers are configured.")
        } else {
            for provider in providers.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                let keyState = keyRing.get(provider.keyAccount) == nil ? "API key not configured" : "API key configured"
                let models = provider.models.map { Self.inline($0) }.joined(separator: ", ")
                lines.append("- **\(Self.inline(provider.name))** (`\(provider.id)`): \(keyState). Models: \(models).")
            }
        }
        lines += ["", "## Direct chat tools"]
        var directTools = ChatWorkspaceTools.definitions
        if includeExtendedTools { directTools += ExtendedWorkspaceTools.definitions }
        for tool in directTools.sorted(by: { $0.function.name < $1.function.name }) {
            lines.append("- `\(tool.function.name)`: \(Self.inline(tool.function.description, limit: 360))")
        }
        lines += [
            "",
            "Ada can answer directly, work alone on a multi-step mission, route work to an approved specialist team, or propose a new team for user approval. Direct chat and mission schedules run through the server. Workspace memory retains durable user context across projects.",
            "",
            "## Specialist teams",
        ]
        if teams.isEmpty {
            lines.append("- No specialist teams exist yet.")
        } else {
            for team in teams.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
                lines.append("- **\(Self.inline(team.name))** (`\(team.id.uuidString)`): \(Self.inline(team.goal.isEmpty ? "No goal provided." : team.goal))")
                for agent in team.agents {
                    lines.append("  - \(Self.inline(agent.name)) — \(Self.inline(agent.title)); \(agent.role.rawValue); \(agent.providerID)/\(Self.inline(agent.model)).")
                }
                if let scope = team.toolScope {
                    let connectorNames = scope.connectorIDs.map(\.rawValue).joined(separator: ", ")
                    var permissions: [String] = []
                    if scope.permissions.sendEmail { permissions.append("send email") }
                    if scope.permissions.createDraft { permissions.append("create drafts") }
                    if scope.permissions.dnsWrite { permissions.append("DNS writes") }
                    if scope.permissions.githubWrite { permissions.append("GitHub writes") }
                    lines.append("  - Connector scope: \(connectorNames.isEmpty ? "none" : connectorNames). Optional writes: \(permissions.isEmpty ? "none" : permissions.joined(separator: ", ")).")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func connectionsDocument(statuses: [ConnectorStatus], activeTools: [APIToolDef]) -> String {
        var lines = [
            "# Workspace connections",
            "",
            "Generated from connector configuration and registered tools. Discovery does not call connector APIs or read connected content. Credentials are never included.",
            "",
        ]
        for status in statuses {
            let state: String
            if !status.enabled {
                state = "Disabled"
            } else if status.id == .web {
                state = status.configured ? "Web fetch and search configured" : "Web fetch available; search key not configured"
            } else {
                state = status.configured ? "Connected" : "Not connected"
            }
            lines.append("## \(Self.inline(status.name))")
            lines.append("- Status: \(state).")
            lines.append("- Capability: \(Self.inline(status.detail))")
            var permissions: [String] = []
            if status.permissions.sendEmail { permissions.append("send email") }
            if status.permissions.createDraft { permissions.append("create drafts") }
            if status.permissions.dnsWrite { permissions.append("DNS writes and cache purge") }
            if status.permissions.githubWrite { permissions.append("GitHub branch writes and comments") }
            lines.append("- Optional write permissions: \(permissions.isEmpty ? "none" : permissions.joined(separator: ", ")).")
            let tools = activeTools.filter { $0.function.name.hasPrefix(status.id.rawValue + "_") }.sorted { $0.function.name < $1.function.name }
            if tools.isEmpty {
                lines.append("- Active tools: none. Connect and enable this connector to expose its tools.")
            } else {
                lines.append("- Active tools:")
                for tool in tools {
                    let access = ConnectorHub.readOnlyToolNames.contains(tool.function.name) ? "read-only" : "write, subject to workspace approval rules"
                    lines.append("  - `\(tool.function.name)` (\(access)): \(Self.inline(tool.function.description, limit: 360))")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func projectsDocument(chats: [ConversationSummary]) -> String {
        var lines = [
            "# Workspace projects",
            "",
            "Project names and activity derived from this user's conversations. Chat contents and private workspace files are not included.",
            "",
        ]
        let grouped = Dictionary(grouping: chats, by: \.projectName)
        if grouped.isEmpty {
            lines.append("No projects or conversations exist yet.")
        } else {
            for (project, conversations) in grouped.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
                let latest = conversations.map(\.updatedAt).max()
                let activity = latest.map { Self.timestamp.string(from: $0) } ?? "unknown"
                lines.append("- **\(Self.inline(project))**: \(conversations.count) conversation\(conversations.count == 1 ? "" : "s"); latest activity \(activity).")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func title(for id: WorkspaceKnowledgeDocumentID) -> String {
        switch id {
        case .capabilities: "Workspace capabilities"
        case .connections: "Workspace connections"
        case .projects: "Workspace projects"
        }
    }

    private static func inline(_ value: String, limit: Int = 500) -> String {
        let clean = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(clean.prefix(limit))
    }

    private static func fingerprint(_ drafts: [WorkspaceKnowledgeDraft]) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in drafts.map({ "\($0.id.rawValue)\n\($0.markdown)" }).joined(separator: "\n\n").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

public actor WorkspaceKnowledgeScheduler {
    public static let tickSeconds: TimeInterval = 60

    private let knowledge: WorkspaceKnowledgeStore
    private var ticker: Task<Void, Never>?

    public init(knowledge: WorkspaceKnowledgeStore) {
        self.knowledge = knowledge
    }

    public func start() {
        guard ticker == nil else { return }
        ticker = Task { await run() }
    }

    public func shutdown() async {
        ticker?.cancel()
        await ticker?.value
        ticker = nil
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.tickSeconds * 1_000_000_000))
                await tick()
            } catch is CancellationError {
                return
            } catch {
                // Keep later refresh attempts alive after a failed tick.
            }
        }
    }

    public func tick(now: Date = Date()) async {
        await knowledge.refreshAll(now: now)
    }
}
