@testable import AgentSamServer
import XCTVapor
import AgentSamCore
import Foundation

final class IdentityGeneratorTests: XCTestCase {
    func testGeneratedIdentitiesAreIndependentAndValid() throws {
        var random = SystemRandomNumberGenerator()
        let generator = IdentityGenerator()
        var emails = Set<String>()
        var names = Set<String>()

        XCTAssertGreaterThanOrEqual(IdentityGenerator.words.count, 2_000)
        for _ in 0 ..< 100 {
            let email = generator.email(domains: ["example.com", "example.net"], excluding: emails, using: &random)
            XCTAssertEqual(try AccountValidation.email(email), email)
            XCTAssertTrue(email.hasSuffix("@example.com") || email.hasSuffix("@example.net"))
            XCTAssertTrue(emails.insert(email).inserted)

            let name = generator.name(excluding: names, using: &random)
            XCTAssertEqual(try AccountValidation.name(name), name)
            XCTAssertTrue(names.insert(name).inserted)

            let password = generator.password(using: &random)
            XCTAssertEqual(password.count, 20)
            XCTAssertNoThrow(try AccountValidation.password(password))
            XCTAssertTrue(password.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0)
            })
        }
    }
}

final class ProvisioningStoreTests: XCTestCase {
    private var dataDir: URL!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-provisioning-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataDir)
        dataDir = nil
    }

    private func makeStore(maxBatch: Int = 50, dailyLimit: Int = 200) -> ProvisioningStore {
        ProvisioningStore(
            dataDir: dataDir,
            secrets: FileKeyRing(url: dataDir.appendingPathComponent("keys.json")),
            maxBatchSize: maxBatch,
            dailyLimit: dailyLimit
        )
    }

    private func spec(count: Int = 1, role: UserRole = .member) -> BatchSpec {
        BatchSpec(count: count, role: role, domains: ["Example.COM"], delivery: .directPasswords, paceSeconds: 1 ... 2)
    }

    func testLifecycleAndInterruptedItemRecovery() async throws {
        let store = makeStore()
        let created = try await store.createBatch(spec: spec(), createdBy: nil)
        XCTAssertEqual(created.status, .queued)
        XCTAssertEqual(created.spec.domains, ["example.com"])
        XCTAssertEqual(created.spec.paceSeconds, 5 ... 5)
        XCTAssertEqual(created.items.count, 1)
        XCTAssertNil(created.items[0].email)
        let itemID = created.items[0].id

        let nextID = await store.nextQueuedBatch()
        XCTAssertEqual(nextID, created.id)
        let work = await store.startNextItem(batchID: created.id)
        XCTAssertEqual(work?.itemID, itemID)
        XCTAssertNotNil(work?.generatedName)
        await store.recordAttempt(batchID: created.id, itemID: itemID, email: "interrupted@example.com")

        let reloaded = makeStore()
        await reloaded.reconcileInterruptedBatches()
        var detail = try await reloaded.detail(id: created.id)
        XCTAssertEqual(detail.batch.status, .queued)
        XCTAssertEqual(detail.batch.items[0].state, .pending)
        XCTAssertNil(detail.batch.items[0].email)
        XCTAssertEqual(detail.batch.items[0].attemptCount, 0)

        _ = try await reloaded.pause(id: created.id)
        let paused = try await reloaded.publicBatch(id: created.id)
        XCTAssertEqual(paused.status, .paused)
        _ = try await reloaded.resume(id: created.id)
        let resumed = try await reloaded.publicBatch(id: created.id)
        XCTAssertEqual(resumed.status, .queued)
        _ = await reloaded.nextQueuedBatch()
        _ = await reloaded.startNextItem(batchID: created.id)
        await reloaded.failItem(batchID: created.id, itemID: itemID, error: "isolated failure")
        detail = try await reloaded.detail(id: created.id)
        XCTAssertEqual(detail.batch.status, .done)
        XCTAssertEqual(detail.batch.items[0].state, .failed)
        XCTAssertEqual(detail.batch.items[0].lastError, "isolated failure")

        let retried = try await reloaded.retryFailed(id: created.id)
        XCTAssertEqual(retried.status, .queued)
        XCTAssertEqual(retried.items[0].state, .pending)
        XCTAssertEqual(retried.items[0].attemptCount, 0)
        let cancelled = try await reloaded.cancel(id: created.id)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.items[0].state, .cancelled)
        do {
            _ = try await reloaded.retryFailed(id: created.id)
            XCTFail("Cancelled batches must not retry")
        } catch let error as ProvisioningError {
            guard case .batchCancelled = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let persisted = try String(contentsOf: dataDir.appendingPathComponent("provisioning.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains("plaintext-secret"))
        let audit = try String(contentsOf: dataDir.appendingPathComponent("provisioning-log.jsonl"), encoding: .utf8)
        XCTAssertFalse(audit.contains("interrupted@example.com"))
        XCTAssertTrue(audit.contains("recovered"))
        XCTAssertTrue(audit.contains("retry-failed"))
        let attributes = try FileManager.default.attributesOfItem(atPath: dataDir.appendingPathComponent("provisioning.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0, 0o600)
    }

    func testLimitsReserveOutstandingItemsAndCancellationReleasesCapacity() async throws {
        let store = makeStore(maxBatch: 2, dailyLimit: 2)
        _ = try await store.createBatch(spec: spec(count: 2), createdBy: nil)
        do {
            _ = try await store.createBatch(spec: spec(), createdBy: nil)
            XCTFail("Outstanding items must count toward the daily limit")
        } catch let error as ProvisioningError {
            guard case .dailyLimitReached = error else { return XCTFail("Unexpected error: \(error)") }
        }
        do {
            _ = try await store.createBatch(spec: spec(count: 3), createdBy: nil)
            XCTFail("Batch over the maximum must fail")
        } catch let error as ProvisioningError {
            guard case .invalidCount = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let batches = await store.listBatches()
        _ = try await store.cancel(id: batches[0].id)
        let replacement = try await store.createBatch(spec: spec(count: 2), createdBy: nil)
        XCTAssertEqual(replacement.status, .queued)

        let disabled = makeStore(dailyLimit: 0)
        do {
            _ = try await disabled.createBatch(spec: spec(), createdBy: nil)
            XCTFail("A zero daily limit must disable provisioning")
        } catch let error as ProvisioningError {
            guard case .disabled = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testDomainValidationAndControlAuditActor() async throws {
        let store = makeStore()
        do {
            _ = try await store.createBatch(
                spec: BatchSpec(count: 1, domains: ["example..com"], delivery: .directPasswords), createdBy: nil
            )
            XCTFail("Empty domain labels must fail validation")
        } catch let error as ProvisioningError {
            guard case .invalidDomains = error else { return XCTFail("Unexpected error: \(error)") }
        }

        let creator = UUID()
        let controller = UUID()
        let created = try await store.createBatch(spec: spec(), createdBy: creator)
        _ = try await store.pause(id: created.id, actor: controller)
        let audit = try String(contentsOf: dataDir.appendingPathComponent("provisioning-log.jsonl"), encoding: .utf8)
        struct AuditLine: Decodable { var actor: UUID? }
        let entries = try audit.split(separator: "\n").map { line in
            try JSONDecoder().decode(AuditLine.self, from: Data(line.utf8))
        }
        XCTAssertEqual(entries[0].actor, creator)
        XCTAssertEqual(entries[1].actor, controller)
    }
}

final class ProvisioningAPITests: XCTestCase {
    private let serverToken = "test-provisioning-server-token-0123456789"
    private var dataDir: URL!
    private var app: Application!

    override func setUp() async throws {
        dataDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsam-provisioning-api-tests-\(UUID().uuidString)")
        setenv("AGENTSAM_DATA", dataDir.path, 1)
        setenv("AGENTSAM_TOKEN", serverToken, 1)
        setenv("AGENTSAM_WEB_DIR", dataDir.appendingPathComponent("no-web").path, 1)
        setenv("AGENTSAM_PROVISIONING_MAX_BATCH", "50", 1)
        setenv("AGENTSAM_PROVISIONING_DAILY_LIMIT", "200", 1)
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        unsetenv("AGENTSAM_PROVISIONING_MAX_BATCH")
        unsetenv("AGENTSAM_PROVISIONING_DAILY_LIMIT")
        try? FileManager.default.removeItem(at: dataDir)
    }

    private enum TestError: Error { case timeout }

    private func authorize(_ req: inout XCTHTTPRequest) {
        req.headers.bearerAuthorization = BearerAuthorization(token: serverToken)
    }

    private func createBatch(delivery: Delivery, role: UserRole = .member, confirmRole: String? = nil) async throws -> PublicBatch {
        let body = CreateProvisioningBatchBody(
            count: 1,
            role: role,
            domains: ["example.com", "example.net"],
            delivery: delivery,
            paceSeconds: 5 ... 5,
            expiresInDays: delivery == .inviteLinks ? 3 : nil,
            confirmRole: confirmRole
        )
        var created: PublicBatch?
        try await app.test(.POST, "api/admin/provisioning/batches", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(body, as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .created, res.body.string)
            created = try res.content.decode(PublicBatch.self)
        })
        return try XCTUnwrap(created)
    }

    private func waitForCompletion(id: UUID) async throws -> BatchDetail {
        for _ in 0 ..< 100 {
            var detail: BatchDetail?
            try await app.test(.GET, "api/admin/provisioning/batches/\(id.uuidString)", beforeRequest: { req in
                self.authorize(&req)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok, res.body.string)
                detail = try res.content.decode(BatchDetail.self)
            })
            if let detail, detail.batch.status == .done { return detail }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw TestError.timeout
    }

    func testDirectPasswordBatchLoginAndAcknowledgement() async throws {
        let created = try await createBatch(delivery: .directPasswords)
        let detail = try await waitForCompletion(id: created.id)
        let item = detail.batch.items[0]
        let email = try XCTUnwrap(item.email)
        let password = try XCTUnwrap(item.secret)
        XCTAssertEqual(item.state, .done)
        XCTAssertNotNil(item.userID)
        XCTAssertEqual(item.attemptCount, 1)
        XCTAssertEqual(password.count, 20)

        try await app.test(.GET, "api/admin/provisioning/batches", beforeRequest: { req in
            self.authorize(&req)
        }, afterResponse: { res async throws in
            let batches = try res.content.decode([PublicBatch].self)
            XCTAssertNil(batches.first?.items.first?.email)
            XCTAssertNil(batches.first?.items.first?.secret)
        })

        try await app.test(.POST, "api/auth/login", beforeRequest: { req in
            try req.content.encode(LoginBody(email: email, password: password), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let me = try res.content.decode(MeResponse.self)
            XCTAssertEqual(me.role, .member)
            XCTAssertEqual(me.user?.email, email)
        })

        let batchURL = "api/admin/provisioning/batches/\(created.id.uuidString)"
        try await app.test(.POST, "\(batchURL)/ack", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(AcknowledgeProvisioningItemsBody(itemIDs: [item.id]), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
        })
        try await app.test(.GET, batchURL, beforeRequest: { req in
            self.authorize(&req)
        }, afterResponse: { res async throws in
            let acknowledged = try res.content.decode(BatchDetail.self)
            XCTAssertNil(acknowledged.batch.items[0].secret)
            XCTAssertTrue(acknowledged.batch.items[0].secretAcknowledged)
        })

        let persisted = try String(contentsOf: dataDir.appendingPathComponent("provisioning.json"), encoding: .utf8)
        let audit = try String(contentsOf: dataDir.appendingPathComponent("provisioning-log.jsonl"), encoding: .utf8)
        let keys = try String(contentsOf: dataDir.appendingPathComponent("keys.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains(password))
        XCTAssertFalse(audit.contains(password))
        XCTAssertFalse(audit.contains(email))
        XCTAssertFalse(keys.contains(password))
    }

    func testInviteBatchReusesSingleUseInviteFlow() async throws {
        let created = try await createBatch(delivery: .inviteLinks)
        let detail = try await waitForCompletion(id: created.id)
        let item = detail.batch.items[0]
        let path = try XCTUnwrap(item.secret)
        let email = try XCTUnwrap(item.email)
        XCTAssertNil(item.userID)
        XCTAssertTrue(path.hasPrefix("/invite#"))
        let secret = String(path.dropFirst("/invite#".count))

        try await app.test(.GET, "api/auth/invite/\(secret)", afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            let preview = try res.content.decode(InvitePreview.self)
            XCTAssertEqual(preview.email, email)
            XCTAssertEqual(preview.role, .member)
            XCTAssertEqual(preview.expiresAt.timeIntervalSinceNow, 3 * 86_400, accuracy: 5)
        })
        try await app.test(.POST, "api/auth/accept-invite", beforeRequest: { req in
            try req.content.encode(AcceptInviteBody(secret: secret, name: "Invited Member", password: "a separate password"), as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
        })
    }

    func testAdminBatchNeedsExplicitRoleConfirmation() async throws {
        let body = CreateProvisioningBatchBody(
            count: 1,
            role: .admin,
            domains: ["example.com"],
            delivery: .directPasswords,
            paceSeconds: 5 ... 5,
            expiresInDays: nil,
            confirmRole: nil
        )
        try await app.test(.POST, "api/admin/provisioning/batches", beforeRequest: { req in
            self.authorize(&req)
            try req.content.encode(body, as: .json)
        }, afterResponse: { res async throws in
            XCTAssertEqual(res.status, .unprocessableEntity, res.body.string)
        })
        try await app.test(.GET, "api/admin/provisioning/batches", beforeRequest: { req in
            self.authorize(&req)
        }, afterResponse: { res async throws in
            XCTAssertEqual(try res.content.decode([PublicBatch].self).count, 0)
        })
    }
}
