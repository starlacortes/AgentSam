import Foundation
import Crypto

// MARK: - Models

enum UserRole: String, Codable, Sendable {
    /// Manages users, invites, provider configs and API keys, plus everything a member can do.
    case admin
    /// Launches and stops missions, reads deliverables, edits teams.
    case member
}

struct UserRecord: Codable, Sendable, Identifiable {
    var id: UUID
    var email: String
    var name: String
    var role: UserRole
    var passwordHash: String
    var disabled: Bool
    var createdAt: Date
    var lastLoginAt: Date?
}

/// What the API returns for a user. Never includes the password hash.
struct PublicUser: Codable, Sendable {
    var id: UUID
    var email: String
    var name: String
    var role: UserRole
    var disabled: Bool
    var createdAt: Date
    var lastLoginAt: Date?

    init(_ record: UserRecord) {
        id = record.id
        email = record.email
        name = record.name
        role = record.role
        disabled = record.disabled
        createdAt = record.createdAt
        lastLoginAt = record.lastLoginAt
    }
}

struct InviteRecord: Codable, Sendable, Identifiable {
    var id: UUID
    var email: String
    var role: UserRole
    /// SHA-256 of the one-time invite secret. The secret itself is only shown once, to the admin who created it.
    var secretHash: String
    var createdBy: UUID?
    var createdAt: Date
    var expiresAt: Date
}

struct PublicInvite: Codable, Sendable {
    var id: UUID
    var email: String
    var role: UserRole
    var createdAt: Date
    var expiresAt: Date

    init(_ record: InviteRecord) {
        id = record.id
        email = record.email
        role = record.role
        createdAt = record.createdAt
        expiresAt = record.expiresAt
    }
}

struct SessionRecord: Codable, Sendable {
    /// SHA-256 of the cookie value. A leaked sessions.json can't be replayed as cookies.
    var tokenHash: String
    var userID: UUID
    var createdAt: Date
    var expiresAt: Date
}

private struct AccountsFile: Codable {
    var users: [UserRecord] = []
    var invites: [InviteRecord] = []
}

enum AccountError: Error, Equatable {
    case emailTaken
    case notFound
    case lastAdmin
    case inviteInvalid
}

// MARK: - Secrets helpers

enum Secrets {
    /// 32 random bytes, base64url without padding (43 chars).
    static func randomToken(bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let raw = (0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares two strings in time that depends only on their lengths.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        var diff = UInt8(truncatingIfNeeded: a.count ^ b.count)
        let count = max(a.count, b.count)
        for index in 0..<count {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            diff |= x ^ y
        }
        return diff == 0
    }

    static func normalizeEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - JSON file persistence

enum SecureFile {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Atomic write, then restrict to owner read/write (0600).
    static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? encoder.encode(value) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            print("AgentSam: failed to write \(url.lastPathComponent): \(error)")
        }
    }
}

// MARK: - Account store

/// Users and invites, persisted to `<data>/accounts.json` (0600).
actor AccountStore {
    private let url: URL
    private var file: AccountsFile

    init(dataDir: URL) {
        url = dataDir.appendingPathComponent("accounts.json")
        file = SecureFile.load(AccountsFile.self, from: url) ?? AccountsFile()
    }

    private func persist() {
        SecureFile.save(file, to: url)
    }

    var isEmpty: Bool { file.users.isEmpty }

    func allUsers() -> [UserRecord] {
        file.users.sorted { $0.createdAt < $1.createdAt }
    }

    func user(id: UUID) -> UserRecord? {
        file.users.first { $0.id == id }
    }

    func user(email: String) -> UserRecord? {
        let normalized = Secrets.normalizeEmail(email)
        return file.users.first { $0.email == normalized }
    }

    func createUser(email: String, name: String, role: UserRole, passwordHash: String) throws -> UserRecord {
        let normalized = Secrets.normalizeEmail(email)
        guard user(email: normalized) == nil else { throw AccountError.emailTaken }
        let record = UserRecord(
            id: UUID(),
            email: normalized,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            role: role,
            passwordHash: passwordHash,
            disabled: false,
            createdAt: Date(),
            lastLoginAt: nil
        )
        file.users.append(record)
        persist()
        return record
    }

    func update(id: UUID, role: UserRole?, disabled: Bool?, name: String?) throws -> UserRecord {
        guard let index = file.users.firstIndex(where: { $0.id == id }) else { throw AccountError.notFound }
        var record = file.users[index]
        let losesAdmin = record.role == .admin && !record.disabled
            && ((role != nil && role != .admin) || disabled == true)
        if losesAdmin && activeAdminCount() <= 1 { throw AccountError.lastAdmin }
        if let role { record.role = role }
        if let disabled { record.disabled = disabled }
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        file.users[index] = record
        persist()
        return record
    }

    func setPasswordHash(id: UUID, hash: String) throws {
        guard let index = file.users.firstIndex(where: { $0.id == id }) else { throw AccountError.notFound }
        file.users[index].passwordHash = hash
        persist()
    }

    func recordLogin(id: UUID) {
        guard let index = file.users.firstIndex(where: { $0.id == id }) else { return }
        file.users[index].lastLoginAt = Date()
        persist()
    }

    func delete(id: UUID) throws {
        guard let record = user(id: id) else { throw AccountError.notFound }
        if record.role == .admin && !record.disabled && activeAdminCount() <= 1 { throw AccountError.lastAdmin }
        file.users.removeAll { $0.id == id }
        persist()
    }

    private func activeAdminCount() -> Int {
        file.users.filter { $0.role == .admin && !$0.disabled }.count
    }

    // MARK: Invites

    /// Returns the record and the one-time secret to put in the invite link.
    func createInvite(email: String, role: UserRole, createdBy: UUID?, lifetime: TimeInterval) throws -> (InviteRecord, String) {
        let normalized = Secrets.normalizeEmail(email)
        guard user(email: normalized) == nil else { throw AccountError.emailTaken }
        file.invites.removeAll { $0.email == normalized || $0.expiresAt < Date() }
        let secret = Secrets.randomToken()
        let record = InviteRecord(
            id: UUID(),
            email: normalized,
            role: role,
            secretHash: Secrets.sha256Hex(secret),
            createdBy: createdBy,
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(lifetime)
        )
        file.invites.append(record)
        persist()
        return (record, secret)
    }

    func pendingInvites() -> [InviteRecord] {
        file.invites.filter { $0.expiresAt > Date() }.sorted { $0.createdAt > $1.createdAt }
    }

    func invite(secret: String) -> InviteRecord? {
        let hash = Secrets.sha256Hex(secret)
        return file.invites.first { Secrets.constantTimeEquals($0.secretHash, hash) && $0.expiresAt > Date() }
    }

    func revokeInvite(id: UUID) {
        file.invites.removeAll { $0.id == id }
        persist()
    }

    /// Consumes the invite and creates the user in one step.
    func acceptInvite(secret: String, name: String, passwordHash: String) throws -> UserRecord {
        guard let invite = invite(secret: secret) else { throw AccountError.inviteInvalid }
        file.invites.removeAll { $0.id == invite.id }
        return try createUser(email: invite.email, name: name, role: invite.role, passwordHash: passwordHash)
    }
}

// MARK: - Session store

/// Login sessions, persisted to `<data>/sessions.json` (0600) so a redeploy doesn't log everyone out.
actor SessionStore {
    private let url: URL
    private var sessions: [String: SessionRecord]
    let lifetime: TimeInterval

    init(dataDir: URL, lifetime: TimeInterval) {
        url = dataDir.appendingPathComponent("sessions.json")
        self.lifetime = lifetime
        let loaded = SecureFile.load([SessionRecord].self, from: url) ?? []
        sessions = Dictionary(
            loaded.filter { $0.expiresAt > Date() }.map { ($0.tokenHash, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func persist() {
        SecureFile.save(Array(sessions.values), to: url)
    }

    /// Creates a session and returns the raw cookie value.
    func create(userID: UUID) -> String {
        let token = Secrets.randomToken()
        let now = Date()
        sessions[Secrets.sha256Hex(token)] = SessionRecord(
            tokenHash: Secrets.sha256Hex(token),
            userID: userID,
            createdAt: now,
            expiresAt: now.addingTimeInterval(lifetime)
        )
        sessions = sessions.filter { $0.value.expiresAt > now }
        persist()
        return token
    }

    func userID(for token: String) -> UUID? {
        guard let record = sessions[Secrets.sha256Hex(token)] else { return nil }
        guard record.expiresAt > Date() else {
            sessions[record.tokenHash] = nil
            persist()
            return nil
        }
        return record.userID
    }

    func revoke(token: String) {
        sessions[Secrets.sha256Hex(token)] = nil
        persist()
    }

    /// Signs a user out everywhere (password change, disable, delete).
    func revokeAll(userID: UUID, except keepToken: String? = nil) {
        let keepHash = keepToken.map(Secrets.sha256Hex)
        sessions = sessions.filter { $0.value.userID != userID || $0.key == keepHash }
        persist()
    }
}

// MARK: - Login throttling

/// Counts failed sign-in attempts per client and locks the client out for a while after too many.
actor LoginThrottle {
    private var failures: [String: [Date]] = [:]
    let maxFailures: Int
    let window: TimeInterval

    init(maxFailures: Int = 10, window: TimeInterval = 15 * 60) {
        self.maxFailures = maxFailures
        self.window = window
    }

    func isLocked(_ client: String) -> Bool {
        prune(client)
        return (failures[client]?.count ?? 0) >= maxFailures
    }

    func recordFailure(_ client: String) {
        prune(client)
        failures[client, default: []].append(Date())
    }

    func reset(_ client: String) {
        failures[client] = nil
    }

    private func prune(_ client: String) {
        let cutoff = Date().addingTimeInterval(-window)
        failures[client] = failures[client]?.filter { $0 > cutoff }
        if failures[client]?.isEmpty == true { failures[client] = nil }
        if failures.count > 10_000 { failures.removeAll() }
    }
}
