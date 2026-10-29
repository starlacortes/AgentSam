import Foundation

public actor MissionStore {
    public nonisolated let root: URL

    private var subscribers: [UUID: [UUID: AsyncStream<RunEvent>.Continuation]] = [:]
    private var seqCounters: [UUID: Int] = [:]

    public init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: teamsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: missionsDirectory, withIntermediateDirectories: true)
    }

    public nonisolated var teamsDirectory: URL { root.appendingPathComponent("teams", isDirectory: true) }
    public nonisolated var missionsDirectory: URL { root.appendingPathComponent("missions", isDirectory: true) }

    public nonisolated func missionDirectory(_ missionID: UUID) -> URL {
        missionsDirectory.appendingPathComponent(missionID.uuidString, isDirectory: true)
    }

    public nonisolated func deliverablesDirectory(_ missionID: UUID) -> URL {
        missionDirectory(missionID).appendingPathComponent("deliverables", isDirectory: true)
    }

    public nonisolated func conversationsDirectory(_ missionID: UUID) -> URL {
        missionDirectory(missionID).appendingPathComponent("conversations", isDirectory: true)
    }

    public nonisolated func eventsURL(_ missionID: UUID) -> URL {
        missionDirectory(missionID).appendingPathComponent("events.jsonl")
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

    // MARK: Providers

    public func loadProviders() -> [ProviderConfig] {
        let url = root.appendingPathComponent("providers.json")
        guard let data = try? Data(contentsOf: url),
              let providers = try? Self.decoder.decode([ProviderConfig].self, from: data),
              !providers.isEmpty else {
            return ProviderConfig.builtin
        }
        return providers
    }

    public func saveProviders(_ providers: [ProviderConfig]) {
        let url = root.appendingPathComponent("providers.json")
        if let data = try? Self.encoder.encode(providers) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: Teams

    public func loadTeams() -> [Team] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: teamsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Self.decoder.decode(Team.self, from: data)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func saveTeam(_ team: Team) {
        let url = teamsDirectory.appendingPathComponent("\(team.id.uuidString).json")
        if let data = try? Self.encoder.encode(team) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func deleteTeam(id: UUID) {
        try? FileManager.default.removeItem(at: teamsDirectory.appendingPathComponent("\(id.uuidString).json"))
    }

    public func team(id: UUID) -> Team? {
        loadTeams().first(where: { $0.id == id })
    }

    // MARK: Missions

    public func createMission(team: Team, objective: String) -> Mission {
        let mission = Mission(teamID: team.id, teamName: team.name, objective: objective)
        try? FileManager.default.createDirectory(at: deliverablesDirectory(mission.id), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: conversationsDirectory(mission.id), withIntermediateDirectories: true)
        saveMission(mission)
        return mission
    }

    public func saveMission(_ mission: Mission) {
        let url = missionDirectory(mission.id).appendingPathComponent("mission.json")
        if let data = try? Self.encoder.encode(mission) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func mission(id: UUID) -> Mission? {
        let url = missionDirectory(id).appendingPathComponent("mission.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(Mission.self, from: data)
    }

    public func listMissions(limit: Int = 100) -> [Mission] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: missionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files
            .compactMap { url -> Mission? in
                let missionURL = url.appendingPathComponent("mission.json")
                guard let data = try? Data(contentsOf: missionURL) else { return nil }
                return try? Self.decoder.decode(Mission.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { $0 }
    }

    public func deleteMission(id: UUID) {
        try? FileManager.default.removeItem(at: missionDirectory(id))
    }

    // MARK: Events

    @discardableResult
    public func appendEvent(
        _ missionID: UUID,
        kind: RunEvent.Kind,
        agent: AgentProfile? = nil,
        text: String? = nil,
        deliverableName: String? = nil,
        costUSD: Double? = nil
    ) -> RunEvent {
        let seq = (seqCounters[missionID] ?? nextSeq(missionID: missionID)) + 1
        seqCounters[missionID] = seq
        let event = RunEvent(
            seq: seq,
            missionID: missionID,
            kind: kind,
            agentID: agent?.id,
            agentName: agent?.name,
            text: text,
            deliverableName: deliverableName,
            costUSD: costUSD
        )
        if let data = try? Self.encoder.encode(event),
           let line = String(data: data, encoding: .utf8) {
            appendLine(line, to: eventsURL(missionID))
        }
        for continuation in subscribers[missionID, default: [:]].values {
            continuation.yield(event)
        }
        return event
    }

    public func events(missionID: UUID, afterSeq: Int = 0) -> [RunEvent] {
        let url = eventsURL(missionID)
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n")
            .compactMap { line -> RunEvent? in
                guard let lineData = String(line).data(using: .utf8) else { return nil }
                guard let event = try? Self.decoder.decode(RunEvent.self, from: lineData) else { return nil }
                return event.seq > afterSeq ? event : nil
            }
            .sorted { $0.seq < $1.seq }
    }

    private func nextSeq(missionID: UUID) -> Int {
        events(missionID: missionID).last?.seq ?? 0
    }

    private func appendLine(_ line: String, to url: URL) {
        let payload = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? payload.write(to: url, options: .atomic)
        }
    }

    // MARK: Deliverables

    public func deliverables(missionID: UUID) -> [String] {
        AgentTools.listWorkspace(deliverablesDirectory(missionID))
            .compactMap { line -> String? in
                let parts = line.split(separator: " — ")
                return parts.first.map(String.init)
            }
    }

    public func deliverable(missionID: UUID, name: String) -> String? {
        guard let url = AgentTools.resolve(name, in: deliverablesDirectory(missionID)),
              url.pathExtension.lowercased() == "md" || url.pathExtension.lowercased() == "txt" || url.pathExtension.isEmpty,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func writeDeliverable(missionID: UUID, name: String, content: String) {
        guard let url = AgentTools.resolve(name, in: deliverablesDirectory(missionID)) else { return }
        try? FileManager.default.createDirectory(at: deliverablesDirectory(missionID), withIntermediateDirectories: true)
        try? Data(content.utf8).write(to: url, options: .atomic)
    }

    // MARK: Conversations

    public func saveConversation(missionID: UUID, agentName: String, messages: [APIMessage]) {
        let dir = conversationsDirectory(missionID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(AgentTools.normalized(agentName).replacingOccurrences(of: " ", with: "-")).json")
        if let data = try? Self.encoder.encode(messages) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func conversation(missionID: UUID, agentName: String) -> [APIMessage] {
        let dir = conversationsDirectory(missionID)
        let url = dir.appendingPathComponent("\(AgentTools.normalized(agentName).replacingOccurrences(of: " ", with: "-")).json")
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([APIMessage].self, from: data)) ?? []
    }

    public func conversationFiles(missionID: UUID) -> [String] {
        let dir = conversationsDirectory(missionID)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return files.map(\.lastPathComponent).sorted()
    }

    // MARK: Live subscriptions

    public func subscribe(missionID: UUID) -> AsyncStream<RunEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RunEvent>.makeStream(bufferingPolicy: .bufferingNewest(512))
        subscribers[missionID, default: [:]][id] = continuation
        continuation.onTermination = { _ in
            Task { await self.unsubscribe(missionID: missionID, id: id) }
        }
        return stream
    }

    public func unsubscribe(missionID: UUID, id: UUID) {
        subscribers[missionID]?[id] = nil
        if subscribers[missionID]?.isEmpty == true { subscribers[missionID] = nil }
    }
}
