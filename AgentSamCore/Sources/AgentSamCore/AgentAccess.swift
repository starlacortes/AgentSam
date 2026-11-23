import Foundation

public struct ProjectScope: Codable, Hashable, Sendable {
    public var ownerID: String
    public var projectName: String

    public init(ownerID: String, projectName: String) {
        self.ownerID = ownerID
        self.projectName = projectName
    }
}

public struct HostFolderGrant: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var ownerID: String
    public var path: String
    public var canWrite: Bool
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: UUID = UUID(), ownerID: String, path: String, canWrite: Bool, createdAt: Date = Date(), lastUsedAt: Date? = nil) {
        self.id = id
        self.ownerID = ownerID
        self.path = path
        self.canWrite = canWrite
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct AccessAuditEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var ownerID: String
    public var action: String
    public var detail: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), ownerID: String, action: String, detail: String) {
        self.id = id
        self.timestamp = timestamp
        self.ownerID = ownerID
        self.action = action
        self.detail = detail
    }
}

public actor AccessAuditLog {
    private let fileURL: URL

    public init(root: URL) {
        fileURL = root.appendingPathComponent("access-audit.jsonl")
    }

    public func record(ownerID: String, action: String, detail: String) {
        let entry = AccessAuditEntry(ownerID: ownerID, action: action, detail: String(detail.prefix(1_000)))
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: fileURL) else {
            try? (data + Data("\n".utf8)).write(to: fileURL)
            return
        }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data + Data("\n".utf8))
    }

    public func entries(ownerID: String, limit: Int = 100) -> [AccessAuditEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(max(1, min(limit, 500))).compactMap {
            try? JSONDecoder().decode(AccessAuditEntry.self, from: Data($0.utf8))
        }.filter { $0.ownerID == ownerID }.reversed()
    }
}

public enum ScopedFiles {
    public static let textExtensions = MissionStore.readableDeliverableExtensions.union([
        "ts", "tsx", "jsx", "py", "rb", "go", "rs", "swift", "java", "kt", "c", "h", "cpp", "sh", "sql", "log", "toml", "ini",
    ])

    public static func resolve(_ path: String, in root: URL) -> URL? {
        guard let candidate = AgentTools.resolve(path, in: root) else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let lexicalBase = root.standardizedFileURL.path
        let lexical = candidate.standardizedFileURL.path
        guard lexical == lexicalBase || lexical.hasPrefix(lexicalBase + "/") else { return nil }
        var current = URL(fileURLWithPath: base, isDirectory: true)
        let relative = lexical == lexicalBase ? "" : String(lexical.dropFirst(lexicalBase.count + 1))
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component))
            let resolved = URL(fileURLWithPath: current.path).resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved == base || resolved.hasPrefix(base + "/") else { return nil }
            current = URL(fileURLWithPath: resolved)
        }
        return current
    }

    public static func files(in root: URL) -> [String] {
        AgentTools.listWorkspace(root).compactMap { line in
            line.range(of: " — ").map { String(line[..<$0.lowerBound]) }
        }
    }

    public static func manifest(in root: URL) -> String {
        AgentTools.listWorkspace(root).joined(separator: "\n")
    }

    public static func read(_ path: String, in root: URL, startLine: Int = 1) -> String? {
        guard startLine >= 1, let url = resolve(path, in: root),
              textExtensions.contains(url.pathExtension.lowercased()),
              let data = try? Data(contentsOf: url), data.count <= AgentTools.maxFileBytes,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        guard startLine <= lines.count else { return nil }
        return lines[(startLine - 1)...].joined(separator: "\n")
    }

    @discardableResult
    public static func write(_ path: String, content: String, in root: URL) -> String? {
        guard content.utf8.count <= AgentTools.maxFileBytes, let url = resolve(path, in: root) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let checked = resolve(path, in: root) else { return nil }
            try Data(content.utf8).write(to: checked, options: .atomic)
            return AgentTools.normalized(path)
        } catch { return nil }
    }

    @discardableResult
    public static func upload(_ path: String, data: Data, in root: URL) -> String? {
        guard !data.isEmpty, data.count <= 5_000_000, let url = resolve(path, in: root),
              !isSensitive(url.lastPathComponent) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let checked = resolve(path, in: root) else { return nil }
            try data.write(to: checked, options: .atomic)
            return AgentTools.normalized(path)
        } catch { return nil }
    }

    public static func patch(_ path: String, old: String, new: String, in root: URL) -> String? {
        guard !old.isEmpty, let text = read(path, in: root), text.contains(old),
              text.range(of: old)?.upperBound == text.range(of: old, options: .backwards)?.upperBound,
              text.count - old.count + new.count <= AgentTools.maxFileBytes else { return nil }
        return write(path, content: text.replacingOccurrences(of: old, with: new), in: root)
    }

    public static func move(_ path: String, to destination: String, in root: URL) -> Bool {
        guard let source = resolve(path, in: root), let target = resolve(destination, in: root),
              FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { return false }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let checked = resolve(destination, in: root) else { return false }
            try FileManager.default.moveItem(at: source, to: checked)
            return true
        } catch { return false }
    }

    public static func delete(_ path: String, in root: URL) -> Bool {
        guard let url = resolve(path, in: root), url.path != root.resolvingSymlinksInPath().standardizedFileURL.path else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    public static func copy(from source: URL, to destination: URL, prefix: String = "") -> [String] {
        var copied: [String] = []
        for name in files(in: source) {
            guard let sourceURL = resolve(name, in: source),
                  textExtensions.contains(sourceURL.pathExtension.lowercased()),
                  let data = try? Data(contentsOf: sourceURL), data.count <= AgentTools.maxFileBytes else { continue }
            let destinationName = prefix + name
            guard let target = resolve(destinationName, in: destination) else { continue }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: target, options: .atomic)
                copied.append(destinationName)
            } catch { continue }
        }
        return copied.sorted()
    }

    public static func isSensitive(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix(".env") || lower.hasSuffix(".pem") || lower.hasSuffix(".key") || lower.hasSuffix(".p12") || lower == "keys.json"
    }
}

public actor HostAccessStore {
    private let fileURL: URL
    private let protectedDataRoot: URL
    private let audit: AccessAuditLog
    private var grants: [HostFolderGrant] = []

    public init(root: URL, audit: AccessAuditLog) {
        fileURL = root.appendingPathComponent("host-grants.json")
        protectedDataRoot = root.resolvingSymlinksInPath().standardizedFileURL
        self.audit = audit
        if let data = try? Data(contentsOf: fileURL), let saved = try? Self.decoder.decode([HostFolderGrant].self, from: data) {
            grants = saved
        }
    }

    public func list(ownerID: String) -> [HostFolderGrant] {
        grants.filter { $0.ownerID == ownerID }.sorted { $0.path < $1.path }
    }

    public func grant(ownerID: String, path: String, canWrite: Bool) -> HostFolderGrant? {
        let url = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespacesAndNewlines), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        let protected = protectedDataRoot.path
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix("/"), url.path != "/", url.path != home,
              url.path != protected, !url.path.hasPrefix(protected + "/"), !protected.hasPrefix(url.path + "/"),
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        if let index = grants.firstIndex(where: { $0.ownerID == ownerID && $0.path == url.path }) {
            grants[index].canWrite = canWrite
            save()
            return grants[index]
        }
        let grant = HostFolderGrant(ownerID: ownerID, path: url.path, canWrite: canWrite)
        grants.append(grant)
        save()
        return grant
    }

    public func revoke(ownerID: String, id: UUID) -> Bool {
        guard let index = grants.firstIndex(where: { $0.id == id && $0.ownerID == ownerID }) else { return false }
        grants.remove(at: index)
        save()
        return true
    }

    public func root(ownerID: String, id: UUID, write: Bool = false) -> URL? {
        guard let index = grants.firstIndex(where: { $0.id == id && $0.ownerID == ownerID && (!write || $0.canWrite) }) else { return nil }
        let url = URL(fileURLWithPath: grants[index].path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        grants[index].lastUsedAt = Date()
        save()
        return url
    }

    public func summary(ownerID: String) -> String {
        list(ownerID: ownerID).map { "- ID: \($0.id.uuidString); path: \($0.path); access: \($0.canWrite ? "read/write" : "read only")" }.joined(separator: "\n")
    }

    public func read(ownerID: String, id: UUID, path: String, startLine: Int) -> String? {
        guard let root = root(ownerID: ownerID, id: id), !ScopedFiles.isSensitive(URL(fileURLWithPath: path).lastPathComponent) else { return nil }
        return ScopedFiles.read(path, in: root, startLine: startLine)
    }

    public func write(ownerID: String, id: UUID, path: String, content: String) -> String? {
        guard !ScopedFiles.isSensitive(URL(fileURLWithPath: path).lastPathComponent),
              let root = root(ownerID: ownerID, id: id, write: true),
              let result = ScopedFiles.write(path, content: content, in: root) else { return nil }
        Task { await audit.record(ownerID: ownerID, action: "host.write", detail: "\(id.uuidString): \(result)") }
        return result
    }

    private func save() {
        guard let data = try? Self.encoder.encode(grants) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public struct AgentActionRequest: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case connectorWrite, fileDelete, workstation, mcpCall, helperSave }
    public enum Status: String, Codable, Sendable { case pending, approved, executing, completed, denied, expired, failed }
    public enum FileScope: String, Codable, Sendable { case conversation, project }

    public var id: UUID
    public var ownerID: String
    public var conversationID: UUID
    public var missionID: UUID?
    public var kind: Kind
    public var title: String
    public var detail: String
    public var toolName: String
    public var arguments: JSONValue
    public var teamID: UUID?
    public var toolScope: ToolScope?
    public var fileScope: FileScope?
    public var projectName: String?
    public var status: Status
    public var createdAt: Date
    public var expiresAt: Date
    public var result: String?
    /// True when a standing permission ran this without a card; the record is kept so the chat shows it.
    public var automatic: Bool?

    public init(ownerID: String, conversationID: UUID, missionID: UUID? = nil, kind: Kind, title: String, detail: String, toolName: String, arguments: JSONValue, teamID: UUID? = nil, toolScope: ToolScope? = nil, fileScope: FileScope? = nil, projectName: String? = nil, lifetime: TimeInterval = 15 * 60) {
        id = UUID()
        self.ownerID = ownerID
        self.conversationID = conversationID
        self.missionID = missionID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.toolName = toolName
        self.arguments = arguments
        self.teamID = teamID
        self.toolScope = toolScope
        self.fileScope = fileScope
        self.projectName = projectName
        status = .pending
        createdAt = Date()
        expiresAt = Date().addingTimeInterval(max(60, lifetime))
        result = nil
    }
}

public struct ConversationAccess: Sendable {
    public let hosts: HostAccessStore
    public let actions: AgentActionCenter
    public let audit: AccessAuditLog
    public let terminal: WorkspaceTerminal
    public let permissions: PermissionStore
    public let spend: SpendLedger
    /// Ada's own machine, when the server operator turned it on.
    public let workstation: Workstation?
    /// Whether this conversation owner may use the workstation (admins and the server token).
    public let workstationOwner: @Sendable (String) async -> Bool
    /// MCP servers an admin connected; their tools are offered in every conversation with access.
    public let mcp: MCPRegistry?

    public init(root: URL, workstation: Workstation? = nil, workstationOwner: @escaping @Sendable (String) async -> Bool = { _ in false }, mcp: MCPRegistry? = nil) {
        self.mcp = mcp
        self.workstation = workstation
        self.workstationOwner = workstationOwner
        spend = SpendLedger(root: root)
        let audit = AccessAuditLog(root: root)
        self.audit = audit
        permissions = PermissionStore(root: root, audit: audit)
        hosts = HostAccessStore(root: root, audit: audit)
        actions = AgentActionCenter(root: root, audit: audit)
        terminal = WorkspaceTerminal()
    }
}

public actor AgentActionCenter {
    private struct Link: Codable {
        var ownerID: String
        var conversationID: UUID
    }
    private let directory: URL
    private let linksURL: URL
    private var links: [UUID: Link] = [:]
    private let audit: AccessAuditLog

    public init(root: URL, audit: AccessAuditLog) {
        directory = root.appendingPathComponent("action-requests", isDirectory: true)
        linksURL = root.appendingPathComponent("mission-conversations.json")
        self.audit = audit
        if let data = try? Data(contentsOf: linksURL), let saved = try? Self.decoder.decode([UUID: Link].self, from: data) { links = saved }
    }

    public func link(missionID: UUID, conversationID: UUID, ownerID: String) {
        links[missionID] = Link(ownerID: ownerID, conversationID: conversationID)
        saveLinks()
    }

    public func owner(missionID: UUID) -> String? {
        links[missionID]?.ownerID
    }

    public func conversation(missionID: UUID) -> UUID? {
        links[missionID]?.conversationID
    }

    /// Called for every new approval request, for example to send a phone alert. Set by the server.
    private var notifier: (@Sendable (AgentActionRequest) async -> Void)?

    public func setNotifier(_ notifier: (@Sendable (AgentActionRequest) async -> Void)?) {
        self.notifier = notifier
    }

    @discardableResult
    public func request(_ action: AgentActionRequest) -> AgentActionRequest {
        save(action)
        Task { await audit.record(ownerID: action.ownerID, action: "approval.request", detail: "\(action.kind.rawValue): \(action.toolName)") }
        if action.status == .pending, let notifier {
            Task { await notifier(action) }
        }
        return action
    }

    public func list(ownerID: String, conversationID: UUID) -> [AgentActionRequest] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { load($0) }.filter { $0.ownerID == ownerID && $0.conversationID == conversationID }.sorted { $0.createdAt > $1.createdAt }.prefix(50).map { action in
            guard action.status == .pending, action.expiresAt < Date() else { return action }
            var expired = action
            expired.status = .expired
            save(expired)
            return expired
        }
    }

    /// The owner's approval requests of any status created since a date, in every conversation, newest first.
    public func recent(ownerID: String, since: Date, limit: Int = 200) -> [AgentActionRequest] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let now = Date()
        return files.compactMap { load($0) }
            .filter { $0.ownerID == ownerID && $0.createdAt >= since }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
            .map { action in
                guard action.status == .pending, action.expiresAt < now else { return action }
                var expired = action
                expired.status = .expired
                return expired
            }
    }

    /// The owner's open approval requests in every conversation, newest first.
    public func pending(ownerID: String, limit: Int = 10) -> [AgentActionRequest] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        let now = Date()
        return files.compactMap { load($0) }
            .filter { $0.ownerID == ownerID && $0.status == .pending && $0.expiresAt > now }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit).map { $0 }
    }

    public func get(ownerID: String, id: UUID) -> AgentActionRequest? {
        load(directory.appendingPathComponent("\(id.uuidString).json")).flatMap { $0.ownerID == ownerID ? $0 : nil }
    }

    public func resolve(ownerID: String, id: UUID, approve: Bool) -> AgentActionRequest? {
        guard var action = get(ownerID: ownerID, id: id) else { return nil }
        if action.status == .pending, action.expiresAt < Date() {
            action.status = .expired
            save(action)
        }
        guard action.status == .pending else { return nil }
        action.status = approve ? .approved : .denied
        save(action)
        Task { await audit.record(ownerID: ownerID, action: approve ? "approval.granted" : "approval.denied", detail: action.toolName) }
        return action
    }

    public func consumeApproved(ownerID: String, id: UUID) -> AgentActionRequest? {
        guard var action = get(ownerID: ownerID, id: id), action.status == .approved else { return nil }
        action.status = .executing
        save(action)
        return action
    }

    public func finish(ownerID: String, id: UUID, result: String, succeeded: Bool = true) {
        guard var action = get(ownerID: ownerID, id: id) else { return }
        action.status = succeeded ? .completed : .failed
        action.result = String(result.prefix(4_000))
        save(action)
        Task { await audit.record(ownerID: ownerID, action: Self.finishedAuditAction(action.kind), detail: "\(action.toolName): \(action.status.rawValue)") }
    }

    /// Keeps a record of a write a standing permission ran without a card, so it shows in the chat
    /// beside approval cards and in the audit log.
    @discardableResult
    public func recordAutomatic(_ action: AgentActionRequest, result: String, succeeded: Bool) -> AgentActionRequest {
        var record = action
        record.automatic = true
        record.status = succeeded ? .completed : .failed
        record.result = String(result.prefix(4_000))
        save(record)
        Task { await audit.record(ownerID: record.ownerID, action: Self.finishedAuditAction(record.kind), detail: "\(record.toolName): \(record.status.rawValue) (standing permission)") }
        return record
    }

    static func finishedAuditAction(_ kind: AgentActionRequest.Kind) -> String {
        switch kind {
        case .connectorWrite: return "connector.executed"
        case .fileDelete: return "file.deletion.finished"
        case .workstation: return "workstation.executed"
        case .mcpCall: return "mcp.executed"
        case .helperSave: return "helper.saved"
        }
    }

    /// Puts a mission worker's action on an approval card in the conversation that launched the
    /// mission, then waits until it has run. The approve route runs the action (as it does for
    /// chat cards), so the worker gets its real result instead of racing the route to run it.
    public func awaitMissionAction(missionID: UUID, kind: AgentActionRequest.Kind, call: APIToolCall, title: String, detail: String, scope: ToolScope? = nil, lifetime: TimeInterval = 15 * 60, runAllowance: TimeInterval = 15 * 60, pollInterval: TimeInterval = 0.25) async -> ToolOutcome {
        guard let link = links[missionID] else {
            return .failure("No conversation owns this mission, so nobody can approve this. Launch missions from a conversation. Nothing ran.")
        }
        let action = AgentActionRequest(
            ownerID: link.ownerID, conversationID: link.conversationID, missionID: missionID, kind: kind,
            title: title, detail: detail,
            toolName: call.function.name, arguments: .object([("raw", .string(call.function.arguments))]), toolScope: scope, lifetime: lifetime
        )
        let saved = request(action)
        // Once approved, a command may run for minutes, so keep waiting past the card's expiry.
        let giveUp = saved.expiresAt.addingTimeInterval(runAllowance)
        while Date() < giveUp {
            if Task.isCancelled { return .failure("The mission was stopped while waiting for approval (\(saved.id.uuidString)).") }
            guard var current = get(ownerID: link.ownerID, id: saved.id) else { return .failure("The approval request disappeared. Nothing ran.") }
            switch current.status {
            case .pending:
                if current.expiresAt < Date() {
                    current.status = .expired
                    save(current)
                    return .failure("Not approved: the approval card expired. Nothing ran.")
                }
            case .denied:
                return .failure("The person denied this on the approval card. Nothing ran.")
            case .expired:
                return .failure("Not approved: the approval card expired. Nothing ran.")
            case .completed:
                return ToolOutcome(resultText: "Approved by the person and run.\n\n" + (current.result ?? "(no output)"))
            case .failed:
                return .failure("Approved by the person, but it failed:\n\n" + (current.result ?? "(no output)"))
            case .approved, .executing:
                break
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return .failure("Approved, but no result came back in time (\(saved.id.uuidString)). Check before running it again.")
    }

    private func save(_ action: AgentActionRequest) {
        guard let data = try? Self.encoder.encode(action) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("\(action.id.uuidString).json"), options: .atomic)
    }

    private func saveLinks() {
        guard let data = try? Self.encoder.encode(links) else { return }
        try? data.write(to: linksURL, options: .atomic)
    }

    private func load(_ url: URL) -> AgentActionRequest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder.decode(AgentActionRequest.self, from: data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
