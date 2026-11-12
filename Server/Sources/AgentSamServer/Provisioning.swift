import Foundation
import Vapor
import AgentSamCore

// MARK: - Models

enum BatchStatus: String, Codable, Sendable {
    case queued, running, paused, done, cancelled
}

enum ItemState: String, Codable, Sendable {
    case pending, creating, done, failed, cancelled
}

enum Delivery: String, Codable, Sendable {
    case inviteLinks, directPasswords
}

struct BatchSpec: Codable, Sendable {
    var count: Int
    var role: UserRole
    var domains: [String]
    var delivery: Delivery
    var paceSeconds: ClosedRange<Double>
    var expiresInDays: Int?

    init(
        count: Int,
        role: UserRole = .member,
        domains: [String],
        delivery: Delivery,
        paceSeconds: ClosedRange<Double> = 30 ... 120,
        expiresInDays: Int? = nil
    ) {
        self.count = count
        self.role = role
        self.domains = domains
        self.delivery = delivery
        self.paceSeconds = paceSeconds
        self.expiresInDays = expiresInDays
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = try container.decode(Int.self, forKey: .count)
        role = try container.decodeIfPresent(UserRole.self, forKey: .role) ?? .member
        domains = try container.decode([String].self, forKey: .domains)
        delivery = try container.decodeIfPresent(Delivery.self, forKey: .delivery) ?? .inviteLinks
        paceSeconds = try container.decodeIfPresent(ClosedRange<Double>.self, forKey: .paceSeconds) ?? 30 ... 120
        expiresInDays = try container.decodeIfPresent(Int.self, forKey: .expiresInDays)
    }
}

struct ProvisioningItem: Codable, Sendable, Identifiable {
    var id: UUID
    var state: ItemState
    var email: String?
    var userID: UUID?
    var attemptCount: Int
    var lastError: String?
    var completedAt: Date?
    var generatedName: String?
    var secretAcknowledged: Bool

    init(id: UUID = UUID(), state: ItemState = .pending) {
        self.id = id
        self.state = state
        secretAcknowledged = false
        attemptCount = 0
    }
}

struct ProvisioningBatch: Codable, Sendable, Identifiable {
    var id: UUID
    var createdBy: UUID?
    var createdAt: Date
    var spec: BatchSpec
    var status: BatchStatus
    var items: [ProvisioningItem]
}

struct PublicProvisioningItem: Codable, Sendable {
    var id: UUID
    var state: ItemState
    var email: String?
    var userID: UUID?
    var attemptCount: Int
    var lastError: String?
    var completedAt: Date?
    var secret: String?
    var secretAcknowledged: Bool
}

struct PublicBatch: Codable, Sendable {
    var id: UUID
    var createdBy: UUID?
    var createdAt: Date
    var spec: BatchSpec
    var status: BatchStatus
    var items: [PublicProvisioningItem]
}

struct BatchDetail: Codable, Sendable {
    var batch: PublicBatch
}

struct CreateProvisioningBatchBody: Codable, Sendable {
    var count: Int
    var role: UserRole?
    var domains: [String]
    var delivery: Delivery?
    var paceSeconds: ClosedRange<Double>?
    var expiresInDays: Int?
    var confirmRole: String?

    var spec: BatchSpec {
        BatchSpec(
            count: count,
            role: role ?? .member,
            domains: domains,
            delivery: delivery ?? .inviteLinks,
            paceSeconds: paceSeconds ?? 30 ... 120,
            expiresInDays: expiresInDays
        )
    }
}

struct AcknowledgeProvisioningItemsBody: Codable, Sendable {
    var itemIDs: [UUID]
}

enum ProvisioningError: AbortError {
    case disabled
    case invalidCount(maximum: Int)
    case dailyLimitReached(Int)
    case invalidDomains
    case invalidPace
    case invalidExpiry
    case adminConfirmationRequired
    case batchNotFound
    case itemNotFound
    case batchCancelled
    case secretStorage

    var status: HTTPResponseStatus {
        switch self {
        case .disabled, .dailyLimitReached: .tooManyRequests
        case .invalidCount, .invalidDomains, .invalidPace, .invalidExpiry,
             .adminConfirmationRequired, .itemNotFound, .batchCancelled: .unprocessableEntity
        case .batchNotFound: .notFound
        case .secretStorage: .internalServerError
        }
    }

    var reason: String {
        switch self {
        case .disabled:
            "Bulk provisioning is disabled on this server"
        case .invalidCount(let maximum):
            "Batch size must be between 1 and \(maximum)"
        case .dailyLimitReached(let limit):
            "This batch would exceed the rolling 24-hour limit of \(limit) accounts"
        case .invalidDomains:
            "Provide 1 to 20 valid domain names, such as example.com"
        case .invalidPace:
            "Pacing must be a finite range no longer than 24 hours"
        case .invalidExpiry:
            "Invite expiry must be between 1 and 365 days"
        case .adminConfirmationRequired:
            "Admin batches require confirmRole set to admin"
        case .batchNotFound:
            "Provisioning batch not found"
        case .itemNotFound:
            "One or more provisioning items do not belong to this batch"
        case .batchCancelled:
            "A cancelled batch cannot be retried"
        case .secretStorage:
            "The credential could not be persisted safely; no account was kept"
        }
    }
}

// MARK: - Identity generation

struct IdentityGenerator: Sendable {
    func email<R: RandomNumberGenerator>(domains: [String], excluding: Set<String> = [], using random: inout R) -> String {
        for _ in 0 ..< 32 {
            let first = Self.words.randomElement(using: &random) ?? "ember"
            let second = Self.words.randomElement(using: &random) ?? "harbor"
            let suffix = Self.randomString(length: Int.random(in: 2 ... 4, using: &random), alphabet: Self.localAlphabet, using: &random)
            let local: String
            if Bool.random(using: &random) {
                local = "\(first).\(second)\(suffix)"
            } else {
                local = "\(first)\(Int.random(in: 10 ... 99, using: &random))\(suffix)"
            }
            let domain = domains.randomElement(using: &random) ?? "example.com"
            let candidate = "\(local)@\(domain)"
            if !excluding.contains(candidate) { return candidate }
        }
        let domain = domains.randomElement(using: &random) ?? "example.com"
        return "\(Self.randomString(length: 20, alphabet: Self.localAlphabet, using: &random))@\(domain)"
    }

    func password<R: RandomNumberGenerator>(using random: inout R) -> String {
        Self.randomString(length: 20, alphabet: Self.passwordAlphabet, using: &random)
    }

    func name<R: RandomNumberGenerator>(excluding usedNames: Set<String>, using random: inout R) -> String {
        var candidates = Self.firstNames.flatMap { first in
            Self.lastNames.map { last in "\(first) \(last)" }
        }.filter { !usedNames.contains($0) }
        if let name = candidates.randomElement(using: &random) { return name }

        candidates = Self.firstNames.flatMap { first in
            Self.lastNames.flatMap { last in
                Self.middleInitials.map { initial in "\(first) \(initial). \(last)" }
            }
        }.filter { !usedNames.contains($0) }
        return candidates.randomElement(using: &random) ?? "Agent \(Self.randomString(length: 12, alphabet: Self.localAlphabet, using: &random))"
    }

    private static func randomString<R: RandomNumberGenerator>(length: Int, alphabet: [Character], using random: inout R) -> String {
        String((0 ..< length).compactMap { _ in alphabet.randomElement(using: &random) })
    }

    private static let localAlphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    private static let passwordAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    private static let middleInitials = (65 ... 90).compactMap { UnicodeScalar($0) }.map(String.init)
    private static let firstNames = [
        "Avery", "Blake", "Cameron", "Dakota", "Elliot", "Finley", "Gray", "Harper",
        "Indigo", "Jordan", "Kai", "Logan", "Morgan", "Noel", "Oakley", "Parker",
        "Quinn", "Reese", "Rowan", "Sage", "Taylor", "Val", "Winter", "Zion",
    ]
    private static let lastNames = [
        "Adler", "Bennett", "Chen", "Diaz", "Ellis", "Foster", "Garcia", "Hayes",
        "Ito", "Johnson", "Kim", "Lopez", "Miller", "Nguyen", "Ortiz", "Patel",
        "Reed", "Singh", "Turner", "Ueda", "Vargas", "Wilson", "Young", "Zhang",
    ]
}

// MARK: - Persistence

private struct ProvisioningFile: Codable {
    var batches: [ProvisioningBatch] = []
}

private struct ProvisioningAuditEntry: Codable {
    var timestamp: Date
    var event: String
    var batchID: UUID
    var actor: UUID?
    var role: UserRole
    var requested: Int
    var done: Int
    var failed: Int
}

struct ProvisioningWork: Sendable {
    var batchID: UUID
    var itemID: UUID
    var createdBy: UUID?
    var spec: BatchSpec
    var generatedName: String
    var currentEmail: String?
    var otherEmails: Set<String>
}

actor ProvisioningStore {
    private let url: URL
    private let auditURL: URL
    private let secrets: any KeyRing
    private let maxBatchSize: Int
    private let dailyLimit: Int
    private var file: ProvisioningFile

    init(
        dataDir: URL,
        secrets: any KeyRing,
        maxBatchSize: Int = 50,
        dailyLimit: Int = 200
    ) {
        url = dataDir.appendingPathComponent("provisioning.json")
        auditURL = dataDir.appendingPathComponent("provisioning-log.jsonl")
        self.secrets = secrets
        self.maxBatchSize = max(1, maxBatchSize)
        self.dailyLimit = max(0, dailyLimit)
        file = SecureFile.load(ProvisioningFile.self, from: url) ?? ProvisioningFile()
    }

    func createBatch(spec rawSpec: BatchSpec, createdBy: UUID?) throws -> PublicBatch {
        guard dailyLimit > 0 else { throw ProvisioningError.disabled }
        var spec = try Self.validate(spec: rawSpec, maxBatchSize: maxBatchSize)
        spec.domains = spec.domains.map(Self.normalizeDomain)

        let now = Date()
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        var reserved = 0
        for batch in file.batches {
            for item in batch.items {
                if item.state == .done, let completedAt = item.completedAt, completedAt > cutoff {
                    reserved += 1
                } else if item.state == .pending || item.state == .creating {
                    reserved += 1
                }
            }
        }
        guard reserved + spec.count <= dailyLimit else {
            throw ProvisioningError.dailyLimitReached(dailyLimit)
        }

        let batch = ProvisioningBatch(
            id: UUID(),
            createdBy: createdBy,
            createdAt: now,
            spec: spec,
            status: .queued,
            items: (0 ..< spec.count).map { _ in ProvisioningItem() }
        )
        file.batches.append(batch)
        persist()
        appendAudit(event: "created", batch: batch, actor: createdBy)
        return publicBatch(batch, includePrivate: false)
    }

    func listBatches() -> [PublicBatch] {
        file.batches.sorted { $0.createdAt > $1.createdAt }.map { publicBatch($0, includePrivate: false) }
    }

    func publicBatch(id: UUID) throws -> PublicBatch {
        try publicBatch(batch(id: id), includePrivate: false)
    }

    func detail(id: UUID) throws -> BatchDetail {
        BatchDetail(batch: try publicBatch(batch(id: id), includePrivate: true))
    }

    func pause(id: UUID, actor: UUID? = nil) throws -> PublicBatch {
        let index = try batchIndex(id: id)
        if file.batches[index].status == .queued || file.batches[index].status == .running {
            file.batches[index].status = .paused
            persist()
            appendAudit(event: "paused", batch: file.batches[index], actor: actor)
        }
        return publicBatch(file.batches[index], includePrivate: false)
    }

    func resume(id: UUID, actor: UUID? = nil) throws -> PublicBatch {
        let index = try batchIndex(id: id)
        if file.batches[index].status == .paused {
            file.batches[index].status = .queued
            persist()
            appendAudit(event: "resumed", batch: file.batches[index], actor: actor)
        }
        return publicBatch(file.batches[index], includePrivate: false)
    }

    func retryFailed(id: UUID, actor: UUID? = nil) throws -> PublicBatch {
        let index = try batchIndex(id: id)
        guard file.batches[index].status != .cancelled else { throw ProvisioningError.batchCancelled }
        var changed = false
        for itemIndex in file.batches[index].items.indices where file.batches[index].items[itemIndex].state == .failed {
            file.batches[index].items[itemIndex].state = .pending
            file.batches[index].items[itemIndex].email = nil
            file.batches[index].items[itemIndex].userID = nil
            file.batches[index].items[itemIndex].attemptCount = 0
            file.batches[index].items[itemIndex].lastError = nil
            file.batches[index].items[itemIndex].completedAt = nil
            file.batches[index].items[itemIndex].generatedName = nil
            changed = true
        }
        if changed {
            if file.batches[index].status == .done || file.batches[index].status == .paused {
                file.batches[index].status = .queued
            }
            persist()
            appendAudit(event: "retry-failed", batch: file.batches[index], actor: actor)
        }
        return publicBatch(file.batches[index], includePrivate: false)
    }

    func cancel(id: UUID, actor: UUID? = nil) throws -> PublicBatch {
        let index = try batchIndex(id: id)
        if file.batches[index].status != .done && file.batches[index].status != .cancelled {
            file.batches[index].status = .cancelled
            let now = Date()
            for itemIndex in file.batches[index].items.indices where file.batches[index].items[itemIndex].state == .pending {
                file.batches[index].items[itemIndex].state = .cancelled
                file.batches[index].items[itemIndex].completedAt = now
            }
            persist()
            appendAudit(event: "cancelled", batch: file.batches[index], actor: actor)
        }
        return publicBatch(file.batches[index], includePrivate: false)
    }

    func acknowledge(batchID: UUID, itemIDs: [UUID]) throws -> Int {
        let index = try batchIndex(id: batchID)
        let requested = Set(itemIDs)
        guard file.batches[index].items.contains(where: { requested.contains($0.id) }) || requested.isEmpty else {
            throw ProvisioningError.itemNotFound
        }
        guard Set(file.batches[index].items.map(\.id)).isSuperset(of: requested) else {
            throw ProvisioningError.itemNotFound
        }
        var acknowledged = 0
        for itemIndex in file.batches[index].items.indices {
            var item = file.batches[index].items[itemIndex]
            guard requested.contains(item.id), item.state == .done, !item.secretAcknowledged else { continue }
            secrets.remove(Self.secretAccount(itemID: item.id))
            item.secretAcknowledged = true
            file.batches[index].items[itemIndex] = item
            acknowledged += 1
        }
        if acknowledged > 0 { persist() }
        return acknowledged
    }

    func reconcileInterruptedBatches() {
        var changed = false
        for batchIndex in file.batches.indices {
            var batchChanged = false
            if file.batches[batchIndex].status == .running {
                file.batches[batchIndex].status = .queued
                batchChanged = true
            }
            for itemIndex in file.batches[batchIndex].items.indices where file.batches[batchIndex].items[itemIndex].state == .creating {
                file.batches[batchIndex].items[itemIndex].state = .pending
                file.batches[batchIndex].items[itemIndex].email = nil
                file.batches[batchIndex].items[itemIndex].attemptCount = 0
                file.batches[batchIndex].items[itemIndex].lastError = nil
                file.batches[batchIndex].items[itemIndex].generatedName = nil
                batchChanged = true
            }
            if batchChanged {
                changed = true
                appendAudit(event: "recovered", batch: file.batches[batchIndex])
            }
        }
        if changed { persist() }
    }

    func nextQueuedBatch() -> UUID? {
        guard let batch = file.batches.filter({ $0.status == .queued }).sorted(by: { $0.createdAt < $1.createdAt }).first,
              let index = file.batches.firstIndex(where: { $0.id == batch.id }) else { return nil }
        file.batches[index].status = .running
        persist()
        appendAudit(event: "running", batch: file.batches[index])
        return batch.id
    }

    func startNextItem(batchID: UUID) -> ProvisioningWork? {
        guard let batchIndex = file.batches.firstIndex(where: { $0.id == batchID }),
              file.batches[batchIndex].status == .running else { return nil }
        guard let itemIndex = file.batches[batchIndex].items.firstIndex(where: { $0.state == .pending }) else {
            finishIfExhausted(batchIndex: batchIndex)
            return nil
        }
        var random = SystemRandomNumberGenerator()
        let usedNames = Set(file.batches[batchIndex].items.compactMap(\.generatedName))
        let name = IdentityGenerator().name(excluding: usedNames, using: &random)
        file.batches[batchIndex].items[itemIndex].state = .creating
        file.batches[batchIndex].items[itemIndex].generatedName = name
        file.batches[batchIndex].items[itemIndex].lastError = nil
        persist()
        let batch = file.batches[batchIndex]
        let item = batch.items[itemIndex]
        return ProvisioningWork(
            batchID: batchID,
            itemID: item.id,
            createdBy: batch.createdBy,
            spec: batch.spec,
            generatedName: name,
            currentEmail: item.email,
            otherEmails: Set(batch.items.filter { $0.id != item.id }.compactMap(\.email))
        )
    }

    func recordAttempt(batchID: UUID, itemID: UUID, email: String) {
        guard let indices = itemIndices(batchID: batchID, itemID: itemID),
              file.batches[indices.batch].items[indices.item].state == .creating else { return }
        file.batches[indices.batch].items[indices.item].attemptCount += 1
        file.batches[indices.batch].items[indices.item].email = email
        persist()
    }

    func completeItem(batchID: UUID, itemID: UUID, userID: UUID?, secret: String) throws {
        guard let indices = itemIndices(batchID: batchID, itemID: itemID),
              file.batches[indices.batch].items[indices.item].state == .creating else { return }
        do {
            try secrets.set(secret, for: Self.secretAccount(itemID: itemID))
            guard secrets.get(Self.secretAccount(itemID: itemID)) == secret else {
                throw ProvisioningError.secretStorage
            }
        } catch {
            throw ProvisioningError.secretStorage
        }
        file.batches[indices.batch].items[indices.item].state = .done
        file.batches[indices.batch].items[indices.item].userID = userID
        file.batches[indices.batch].items[indices.item].lastError = nil
        file.batches[indices.batch].items[indices.item].completedAt = Date()
        file.batches[indices.batch].items[indices.item].secretAcknowledged = false
        persist()
        finishIfExhausted(batchIndex: indices.batch)
    }

    func failItem(batchID: UUID, itemID: UUID, error: String) {
        guard let indices = itemIndices(batchID: batchID, itemID: itemID),
              file.batches[indices.batch].items[indices.item].state == .creating else { return }
        file.batches[indices.batch].items[indices.item].state = .failed
        file.batches[indices.batch].items[indices.item].lastError = error
        file.batches[indices.batch].items[indices.item].completedAt = Date()
        persist()
        finishIfExhausted(batchIndex: indices.batch)
    }

    func shouldWaitForNextItem(batchID: UUID) -> Bool {
        guard let batch = file.batches.first(where: { $0.id == batchID }), batch.status == .running else { return false }
        return batch.items.contains { $0.state == .pending }
    }

    private func batch(id: UUID) throws -> ProvisioningBatch {
        guard let batch = file.batches.first(where: { $0.id == id }) else { throw ProvisioningError.batchNotFound }
        return batch
    }

    private func batchIndex(id: UUID) throws -> Int {
        guard let index = file.batches.firstIndex(where: { $0.id == id }) else { throw ProvisioningError.batchNotFound }
        return index
    }

    private func itemIndices(batchID: UUID, itemID: UUID) -> (batch: Int, item: Int)? {
        guard let batchIndex = file.batches.firstIndex(where: { $0.id == batchID }),
              let itemIndex = file.batches[batchIndex].items.firstIndex(where: { $0.id == itemID }) else { return nil }
        return (batchIndex, itemIndex)
    }

    private func finishIfExhausted(batchIndex: Int) {
        guard file.batches[batchIndex].status == .running || file.batches[batchIndex].status == .paused else { return }
        let unfinished = file.batches[batchIndex].items.contains { $0.state == .pending || $0.state == .creating }
        guard !unfinished else { return }
        file.batches[batchIndex].status = .done
        persist()
        appendAudit(event: "done", batch: file.batches[batchIndex])
    }

    private func publicBatch(_ batch: ProvisioningBatch, includePrivate: Bool) -> PublicBatch {
        PublicBatch(
            id: batch.id,
            createdBy: batch.createdBy,
            createdAt: batch.createdAt,
            spec: batch.spec,
            status: batch.status,
            items: batch.items.map { item in
                PublicProvisioningItem(
                    id: item.id,
                    state: item.state,
                    email: includePrivate ? item.email : nil,
                    userID: item.userID,
                    attemptCount: item.attemptCount,
                    lastError: item.lastError,
                    completedAt: item.completedAt,
                    secret: includePrivate && item.state == .done && !item.secretAcknowledged
                        ? secrets.get(Self.secretAccount(itemID: item.id)) : nil,
                    secretAcknowledged: item.secretAcknowledged
                )
            }
        )
    }

    private static func secretAccount(itemID: UUID) -> String {
        "provisioning.item.\(itemID.uuidString.lowercased())"
    }

    private func persist() {
        SecureFile.save(file, to: url)
    }

    private func appendAudit(event: String, batch: ProvisioningBatch, actor: UUID? = nil) {
        let entry = ProvisioningAuditEntry(
            timestamp: Date(),
            event: event,
            batchID: batch.id,
            actor: actor,
            role: batch.spec.role,
            requested: batch.spec.count,
            done: batch.items.filter { $0.state == .done }.count,
            failed: batch.items.filter { $0.state == .failed }.count
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let line = try? encoder.encode(entry), let text = String(data: line, encoding: .utf8) else { return }
        var data = (try? Data(contentsOf: auditURL)) ?? Data()
        data.append(Data((text + "\n").utf8))
        do {
            try FileManager.default.createDirectory(at: auditURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: auditURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auditURL.path)
        } catch {
            print("AgentSam: failed to append provisioning audit log: \(error)")
        }
    }

    private static func normalizeDomain(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".@"))
    }

    private static func validate(spec: BatchSpec, maxBatchSize: Int) throws -> BatchSpec {
        guard (1 ... maxBatchSize).contains(spec.count) else { throw ProvisioningError.invalidCount(maximum: maxBatchSize) }
        let domains = spec.domains.map(normalizeDomain)
        guard !domains.isEmpty, domains.count <= 20, Set(domains).count == domains.count,
              domains.allSatisfy(isValidDomain) else { throw ProvisioningError.invalidDomains }
        let pace = spec.paceSeconds
        guard pace.lowerBound.isFinite, pace.upperBound.isFinite,
              pace.lowerBound >= 0, pace.upperBound >= pace.lowerBound, pace.upperBound <= 86_400 else {
            throw ProvisioningError.invalidPace
        }
        if let days = spec.expiresInDays, !(1 ... 365).contains(days) { throw ProvisioningError.invalidExpiry }
        var validated = spec
        validated.paceSeconds = max(5, pace.lowerBound) ... max(5, pace.upperBound)
        return validated
    }

    private static func isValidDomain(_ domain: String) -> Bool {
        guard domain.count <= 253, domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard domain.unicodeScalars.allSatisfy(allowed.contains) else { return false }
        return domain.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-"
        }
    }
}

// MARK: - Runner

actor ProvisioningRunner {
    private let store: ProvisioningStore
    private let accounts: AccountStore
    private var worker: Task<Void, Never>?

    init(store: ProvisioningStore, accounts: AccountStore) {
        self.store = store
        self.accounts = accounts
    }

    func start() async {
        await store.reconcileInterruptedBatches()
        ensureWorker()
    }

    func wake() {
        ensureWorker()
    }

    func shutdown() async {
        worker?.cancel()
        await worker?.value
        worker = nil
    }

    private func ensureWorker() {
        guard worker == nil else { return }
        worker = Task { await self.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            guard let batchID = await store.nextQueuedBatch() else {
                worker = nil
                return
            }
            await runBatch(id: batchID)
        }
    }

    private func runBatch(id: UUID) async {
        while !Task.isCancelled {
            guard let work = await store.startNextItem(batchID: id) else { return }
            await process(work)
            guard await store.shouldWaitForNextItem(batchID: id) else { return }
            var random = SystemRandomNumberGenerator()
            let delay = Double.random(in: work.spec.paceSeconds, using: &random)
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
        }
    }

    private func process(_ work: ProvisioningWork) async {
        var random = SystemRandomNumberGenerator()
        let generator = IdentityGenerator()
        for attempt in 1 ... 3 {
            do {
                let existingUsers = await accounts.allUsers().map(\.email)
                let existingInvites = await accounts.pendingInvites().map(\.email)
                var excluded = work.otherEmails.union(existingUsers).union(existingInvites)
                if let currentEmail = work.currentEmail { excluded.insert(currentEmail) }
                let email = generator.email(domains: work.spec.domains, excluding: excluded, using: &random)
                _ = try AccountValidation.email(email)
                await store.recordAttempt(batchID: work.batchID, itemID: work.itemID, email: email)

                switch work.spec.delivery {
                case .directPasswords:
                    let password = generator.password(using: &random)
                    try AccountValidation.password(password)
                    let name = try AccountValidation.name(work.generatedName)
                    let hash = try await Passwords.hash(password)
                    let user = try await accounts.createUser(email: email, name: name, role: work.spec.role, passwordHash: hash)
                    do {
                        try await store.completeItem(batchID: work.batchID, itemID: work.itemID, userID: user.id, secret: password)
                    } catch {
                        try? await accounts.delete(id: user.id)
                        throw error
                    }
                case .inviteLinks:
                    let lifetime = TimeInterval((work.spec.expiresInDays ?? 7) * 86_400)
                    let (invite, rawSecret) = try await accounts.createInvite(
                        email: email, role: work.spec.role, createdBy: work.createdBy, lifetime: lifetime
                    )
                    do {
                        try await store.completeItem(
                            batchID: work.batchID, itemID: work.itemID, userID: nil, secret: "/invite#\(rawSecret)"
                        )
                    } catch {
                        await accounts.revokeInvite(id: invite.id)
                        throw error
                    }
                }
                return
            } catch {
                let collision = (error as? AccountError) == .emailTaken
                if collision && attempt < 3 { continue }
                let reason = (error as? AbortError)?.reason ?? error.localizedDescription
                await store.failItem(batchID: work.batchID, itemID: work.itemID, error: reason)
                return
            }
        }
    }
}

// MARK: - Routes

func provisioningRoutes(_ app: Application, ctx: ServerContext, admin: RoutesBuilder) {
    let batches = admin.grouped("admin", "provisioning", "batches")

    batches.post { req async throws -> Response in
        let body = try req.decodeJSON(CreateProvisioningBatchBody.self)
        let spec = body.spec
        if spec.role == .admin && body.confirmRole != "admin" {
            throw ProvisioningError.adminConfirmationRequired
        }
        let batch = try await ctx.provisioning.createBatch(spec: spec, createdBy: req.principal?.userID)
        await ctx.provisioningRunner.wake()
        return try req.json(batch, status: .created)
    }

    batches.get { req async throws -> Response in
        try req.json(await ctx.provisioning.listBatches())
    }

    batches.get(":id") { req async throws -> Response in
        let id = try provisioningBatchID(req)
        return try req.json(await ctx.provisioning.detail(id: id))
    }

    batches.post(":id", "pause") { req async throws -> Response in
        let id = try provisioningBatchID(req)
        return try req.json(await ctx.provisioning.pause(id: id, actor: req.principal?.userID))
    }

    batches.post(":id", "resume") { req async throws -> Response in
        let id = try provisioningBatchID(req)
        let batch = try await ctx.provisioning.resume(id: id, actor: req.principal?.userID)
        await ctx.provisioningRunner.wake()
        return try req.json(batch)
    }

    batches.post(":id", "retry-failed") { req async throws -> Response in
        let id = try provisioningBatchID(req)
        let batch = try await ctx.provisioning.retryFailed(id: id, actor: req.principal?.userID)
        await ctx.provisioningRunner.wake()
        return try req.json(batch)
    }

    batches.post(":id", "ack") { req async throws -> Response in
        let id = try provisioningBatchID(req)
        let body = try req.decodeJSON(AcknowledgeProvisioningItemsBody.self)
        guard body.itemIDs.count <= 50 else {
            throw Abort(.badRequest, reason: "Too many item IDs")
        }
        let count = try await ctx.provisioning.acknowledge(batchID: id, itemIDs: body.itemIDs)
        return try req.json(AckResult(ok: true, detail: "Acknowledged \(count) credential(s)"))
    }

    batches.delete(":id") { req async throws -> Response in
        let id = try provisioningBatchID(req)
        _ = try await ctx.provisioning.cancel(id: id, actor: req.principal?.userID)
        return try req.json(AckResult(ok: true, detail: "Batch cancelled; completed accounts and invites remain"))
    }
}

private func provisioningBatchID(_ req: Request) throws -> UUID {
    guard let id = req.parameters.get("id").flatMap(UUID.init(uuidString:)) else {
        throw Abort(.badRequest, reason: "Bad provisioning batch id")
    }
    return id
}
