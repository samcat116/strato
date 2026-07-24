import Fluent
import NIOConcurrencyHelpers
import Testing
import Vapor
import VaporTesting

@testable import App

/// Centralized audit logging (issue #39): the middleware that records API
/// mutations and admin-bypassed requests, the explicit auth events, and the
/// query API that reads the trail back.
@Suite("Audit Logging Tests", .serialized)
final class AuditLoggingTests {

    private func withApp(
        systemAdmin: Bool = false,
        _ test: (Application, User, Organization, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "audituser",
                email: "audit@example.com",
                displayName: "Audit User",
                isSystemAdmin: systemAdmin
            )
            let org = try await builder.createOrganization(name: "Audit Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let token = try await user.generateAPIKey(on: app.db)
            try await test(app, user, org, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func events(
        ofType type: String, on db: any Database
    ) async throws -> [AuditEvent] {
        try await AuditEvent.query(on: db).filter(\.$eventType == type).all()
    }

    // MARK: - Middleware: API requests

    @Test("API mutation is audited with actor, resource, and status")
    func apiMutationIsAudited() async throws {
        try await withApp { app, user, org, token in
            try await app.test(.POST, "/api/api-keys") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": "audit-test-key"])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.userID == user.id)
            #expect(event.username == "audituser")
            #expect(event.organizationID == org.id)
            #expect(event.method == "POST")
            #expect(event.path == "/api/api-keys")
            #expect(event.status == 200)
            #expect(event.resourceType == "api-keys")
            #expect(event.action == "create")
            #expect(event.adminBypass == false)
            #expect(event.apiKeyID != nil)
        }
    }

    @Test("Reads are not audited by default")
    func readsNotAuditedByDefault() async throws {
        try await withApp { app, _, _, token in
            try await app.test(.GET, "/api/api-keys") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.isEmpty)
        }
    }

    @Test("Requests allowed by the platform-system-admin policy are audited, including reads")
    func adminBypassIsAudited() async throws {
        try await withApp(systemAdmin: true) { app, user, _, token in
            // A route that flows through the evaluator: the admin's allow is
            // determined by platform-system-admin, which is what marks the
            // audit event. (Identity-plane reads like /api/api-keys are
            // self-scoped and involve no evaluator decision anymore.)
            try await app.test(.GET, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.adminBypass == true)
            #expect(event.userID == user.id)
            #expect(event.method == "GET")
            #expect(event.action == "read")
        }
    }

    @Test("Denied requests are audited with their status")
    func deniedRequestIsAudited() async throws {
        try await withApp { app, _, org, _ in
            // Someone whose current org they are not a member of: the
            // middleware's collection gate denies before the handler runs.
            let builder = TestDataBuilder(db: app.db)
            let outsider = try await builder.createUser(
                username: "audit-outsider", email: "audit-outsider@example.com")
            outsider.currentOrganizationId = org.id
            try await outsider.save(on: app.db)
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.status == 403)
            #expect(event.userID == outsider.id)
            #expect(event.resourceType == "vms")
            #expect(event.action == "create")
        }
    }

    @Test("Mutations denied for missing API-key scope are audited")
    func scopeDeniedMutationIsAudited() async throws {
        try await withApp { app, user, _, _ in
            let readOnlyKey = APIKey.generateAPIKey()
            try await APIKey(
                userID: user.id!,
                name: "read-only",
                keyHash: APIKey.hashAPIKey(readOnlyKey),
                keyPrefix: String(readOnlyKey.prefix(16)),
                scopes: ["read"]
            ).save(on: app.db)

            try await app.test(.POST, "/api/api-keys") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: readOnlyKey)
                try req.content.encode(["name": "should-not-exist"])
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.status == 403)
            #expect(event.userID == user.id)
        }
    }

    // MARK: - Auth events

    @Test("Logout records an auth.logout event")
    func logoutIsAudited() async throws {
        try await withApp { app, user, org, token in
            try await app.test(.POST, "/auth/logout") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                // 200 with a LogoutResponse body (sloUrl) since RP-initiated
                // logout support (#365); 204 was the old contract.
                #expect(res.status == .ok)
            }

            let recorded = try await self.events(ofType: "auth.logout", on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.userID == user.id)
            #expect(event.username == "audituser")
            #expect(event.organizationID == org.id)
        }
    }

    // MARK: - Query API

    @Test("Global audit query requires a system administrator")
    func globalQueryRequiresSystemAdmin() async throws {
        try await withApp { app, _, _, token in
            try await app.test(.GET, "/api/audit-events") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("System admin can list and filter all audit events")
    func systemAdminListsAndFilters() async throws {
        try await withApp(systemAdmin: true) { app, _, org, token in
            let otherOrgID = UUID()
            try await AuditEvent(
                from: AuditRecord(eventType: "test.alpha", organizationID: org.id, adminBypass: true)
            ).save(on: app.db)
            try await AuditEvent(
                from: AuditRecord(eventType: "test.alpha", organizationID: otherOrgID)
            ).save(on: app.db)
            try await AuditEvent(
                from: AuditRecord(eventType: "test.beta", organizationID: org.id)
            ).save(on: app.db)

            try await app.test(.GET, "/api/audit-events?eventType=test.alpha") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuditEventListResponse.self)
                #expect(decoded.total == 2)
                let types = Set(decoded.events.map(\.eventType))
                #expect(types == ["test.alpha"])
            }

            try await app.test(.GET, "/api/audit-events?eventType=test.alpha&adminOnly=true") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let decoded = try res.content.decode(AuditEventListResponse.self)
                #expect(decoded.total == 1)
                let bypassFlags = decoded.events.map(\.adminBypass)
                #expect(bypassFlags == [true])
            }

            // A far-future lower bound matches nothing.
            try await app.test(
                .GET, "/api/audit-events?eventType=test.alpha&from=2099-01-01T00:00:00Z"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                let decoded = try res.content.decode(AuditEventListResponse.self)
                #expect(decoded.total == 0)
            }
        }
    }

    @Test("Org audit query is scoped to the organization and gated on org admin")
    func orgQueryScopedAndGated() async throws {
        try await withApp { app, _, org, token in
            try await AuditEvent(
                from: AuditRecord(eventType: "test.org", organizationID: org.id)
            ).save(on: app.db)
            try await AuditEvent(
                from: AuditRecord(eventType: "test.org", organizationID: UUID())
            ).save(on: app.db)

            try await app.test(.GET, "/api/organizations/\(org.id!)/audit-events") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(AuditEventListResponse.self)
                #expect(decoded.total == 1)
                let orgIDs = Set(decoded.events.map(\.organizationID))
                #expect(orgIDs == [org.id])
            }

            // A bare member is not an org admin, so the same query is denied.
            let member = try await TestDataBuilder(db: app.db).createUser(
                username: "audit-member", email: "audit-member@example.com")
            try await TestDataBuilder(db: app.db).addUserToOrganization(
                user: member, organization: org, role: "member")
            let memberToken = try await member.generateAPIKey(on: app.db)
            try await app.test(.GET, "/api/organizations/\(org.id!)/audit-events") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Retention

    /// Build an audit service with an explicit retention window, bypassing
    /// the environment the rest of the config came from.
    private func auditService(on app: Application, retentionDays: Int?) -> AuditService {
        var config = AuditConfig.fromEnvironment(app.environment)
        config.retentionDays = retentionDays
        return AuditService(app: app, config: config)
    }

    /// Persist an event and backdate its creation timestamp (Fluent stamps
    /// `created_at` on insert, so the backdate needs a second save).
    private func saveEvent(type: String, ageDays: Double, on db: any Database) async throws {
        let event = AuditEvent(from: AuditRecord(eventType: type))
        try await event.save(on: db)
        event.createdAt = Date().addingTimeInterval(-ageDays * 86_400)
        try await event.save(on: db)
    }

    @Test("Retention sweep deletes events past the window and keeps newer ones")
    func retentionSweepDeletesExpiredEvents() async throws {
        try await withApp { app, _, _, _ in
            app.audit = self.auditService(on: app, retentionDays: 30)

            try await self.saveEvent(type: "test.expired", ageDays: 40, on: app.db)
            try await self.saveEvent(type: "test.recent", ageDays: 1, on: app.db)

            await app.audit.sweepExpiredEvents()

            let remaining = try await AuditEvent.query(on: app.db).all()
            let types = remaining.map(\.eventType)
            #expect(types == ["test.recent"])
        }
    }

    @Test("Retention sweep is a no-op when AUDIT_RETENTION_DAYS is unset or non-positive")
    func retentionSweepDisabled() async throws {
        try await withApp { app, _, _, _ in
            try await self.saveEvent(type: "test.ancient", ageDays: 365, on: app.db)

            for retentionDays in [nil, 0, -7] {
                app.audit = self.auditService(on: app, retentionDays: retentionDays)
                #expect(app.audit.retentionDays == nil)
                await app.audit.sweepExpiredEvents()

                let count = try await AuditEvent.query(on: app.db).count()
                #expect(count == 1)
            }
        }
    }

    @Test("Retention sweep skips the pass when another replica holds the sweep lock")
    func retentionSweepRespectsSingletonLock() async throws {
        try await withApp { app, _, _, _ in
            app.audit = self.auditService(on: app, retentionDays: 30)
            try await self.saveEvent(type: "test.expired", ageDays: 40, on: app.db)

            // Simulate another replica's in-flight pass.
            let acquired = await app.coordination.acquireSweepLock(
                "audit_retention", ttlSeconds: AuditService.retentionSweepLockTTLSeconds)
            #expect(acquired)

            await app.audit.sweepExpiredEvents()

            let count = try await AuditEvent.query(on: app.db).count()
            #expect(count == 1)
        }
    }

    // MARK: - Background delivery (issue #694)

    /// A backend that records what it was handed, and can be made arbitrarily
    /// slow — standing in for the Loki/webhook POSTs whose five-second timeout
    /// used to be paid on the request path.
    private final class RecordingAuditBackend: AuditBackend, @unchecked Sendable {
        let name = "recording"
        private let delay: Duration?
        private let state = NIOLockedValueBox<[[AuditRecord]]>([])

        init(delay: Duration? = nil) {
            self.delay = delay
        }

        /// The batches this backend received, in delivery order.
        var batches: [[AuditRecord]] { state.withLockedValue { $0 } }
        var records: [AuditRecord] { batches.flatMap { $0 } }

        func write(_ record: AuditRecord) async {
            await write([record])
        }

        func write(_ records: [AuditRecord]) async {
            if let delay { try? await Task.sleep(for: delay) }
            state.withLockedValue { $0.append(records) }
        }
    }

    /// An audit service that delivers in the background, as deployments do.
    private func backgroundAuditService(
        on app: Application, backends: [any AuditBackend], maxQueueDepth: Int = 2048
    ) -> AuditService {
        var config = AuditConfig.fromEnvironment(app.environment)
        config.synchronousWrites = false
        config.maxQueueDepth = maxQueueDepth
        return AuditService(app: app, config: config, backends: backends)
    }

    @Test("Recording an event does not wait for the backends")
    func backgroundRecordingDoesNotBlockTheCaller() async throws {
        try await withApp { app, _, _, _ in
            let slow = RecordingAuditBackend(delay: .seconds(3))
            let audit = self.backgroundAuditService(on: app, backends: [slow])

            let clock = ContinuousClock()
            let elapsed = await clock.measure {
                await audit.record(AuditRecord(eventType: "test.background"))
            }
            // Enqueueing is an actor hop; the three-second backend write is
            // somebody else's problem now.
            #expect(elapsed < .seconds(1))
            #expect(slow.records.isEmpty)

            await audit.flush()
            #expect(slow.records.map(\.eventType) == ["test.background"])
        }
    }

    @Test("Queued events reach the database when the request path never waited")
    func backgroundDeliveryPersistsAuditedMutations() async throws {
        try await withApp { app, user, _, token in
            app.audit = self.backgroundAuditService(
                on: app, backends: [DatabaseAuditBackend(app: app)])

            try await app.test(.POST, "/api/api-keys") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["name": "background-audit-key"])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            await app.audit.flush()

            let recorded = try await self.events(ofType: "api.request", on: app.db)
            #expect(recorded.count == 1)
            #expect(recorded.first?.userID == user.id)
            #expect(recorded.first?.path == "/api/api-keys")
        }
    }

    @Test("Shutdown flushes events the drain has not shipped yet")
    func shutdownFlushesQueuedEvents() async throws {
        try await withApp { app, _, _, _ in
            app.audit = self.backgroundAuditService(
                on: app, backends: [DatabaseAuditBackend(app: app)])

            // Straight onto the queue, so the assertion is about the flush and
            // not about a drain task that may have run already.
            for index in 0..<3 {
                _ = await app.audit.queue.enqueue(AuditRecord(eventType: "test.pending\(index)"))
            }

            await AuditRetentionLifecycleHandler().shutdownAsync(app)

            let persisted = try await AuditEvent.query(on: app.db).all()
            #expect(Set(persisted.map(\.eventType)) == ["test.pending0", "test.pending1", "test.pending2"])
        }
    }

    @Test("A full queue sheds events and counts what it dropped")
    func fullQueueShedsAndCounts() async throws {
        try await withApp { app, _, _, _ in
            let backend = RecordingAuditBackend()
            let audit = self.backgroundAuditService(on: app, backends: [backend], maxQueueDepth: 2)

            // Enqueue directly: `record` would start a drain that empties the
            // queue underneath the overflow this test is about.
            let first = await audit.queue.enqueue(AuditRecord(eventType: "a"))
            let second = await audit.queue.enqueue(AuditRecord(eventType: "b"))
            let third = await audit.queue.enqueue(AuditRecord(eventType: "c"))
            let fourth = await audit.queue.enqueue(AuditRecord(eventType: "d"))
            #expect(first == .enqueued(startDrain: true))
            #expect(second == .enqueued(startDrain: false))
            #expect(third == .shed(total: 1))
            #expect(fourth == .shed(total: 2))

            let stats = await audit.queue.stats
            #expect(stats.queued == 2)
            #expect(stats.shed == 2)

            await audit.flush()
            #expect(backend.records.map(\.eventType) == ["a", "b"])
        }
    }

    @Test("Drained events are shipped in batches")
    func drainedEventsAreBatched() async throws {
        let queue = AuditEventQueue(maxQueueDepth: 16, maxBatchSize: 2)
        for index in 0..<5 {
            _ = await queue.enqueue(AuditRecord(eventType: "test.batch\(index)"))
        }

        var batchSizes: [Int] = []
        while let batch = await queue.nextBatch() {
            batchSizes.append(batch.count)
        }
        #expect(batchSizes == [2, 2, 1])

        // Running dry retires the drain, so the next event starts a new one.
        let stats = await queue.stats
        #expect(!stats.draining)
        let restarted = await queue.enqueue(AuditRecord(eventType: "test.batch5"))
        #expect(restarted == .enqueued(startDrain: true))
    }

    @Test("Batch size is clamped to what one multi-row insert can carry")
    func batchSizeIsClamped() async throws {
        // Postgres refuses a statement with more than 65535 bind parameters and
        // Fluent does not chunk a collection `create`, so an operator asking
        // for a huge batch must get a working smaller one, not an insert that
        // fails every time.
        let queue = AuditEventQueue(maxQueueDepth: 8192, maxBatchSize: 100_000)
        for index in 0..<(AuditEventQueue.maxSupportedBatchSize + 10) {
            _ = await queue.enqueue(AuditRecord(eventType: "test.clamp\(index)"))
        }

        let batch = await queue.nextBatch()
        #expect(batch?.count == AuditEventQueue.maxSupportedBatchSize)
    }

    // MARK: - Resource parsing

    @Test("Resource references are parsed from API paths")
    func resourceParsing() throws {
        let create = parseResource(path: "/api/vms", method: .POST)
        #expect(create == AuditResourceRef(type: "vms", id: nil, action: "create"))

        let vmID = UUID().uuidString
        let start = parseResource(path: "/api/vms/\(vmID)/start", method: .POST)
        #expect(start == AuditResourceRef(type: "vms", id: vmID, action: "start"))

        let orgID = UUID()
        let deleteGroup = parseResource(
            path: "/api/organizations/\(orgID.uuidString)/groups/g1", method: .DELETE)
        #expect(
            deleteGroup
                == AuditResourceRef(type: "groups", id: "g1", action: "delete", organizationID: orgID))

        let updateOrg = parseResource(path: "/api/organizations/\(orgID.uuidString)", method: .PUT)
        #expect(
            updateOrg
                == AuditResourceRef(
                    type: "organizations", id: orgID.uuidString, action: "update", organizationID: nil))

        let list = parseResource(path: "/api/api-keys", method: .GET)
        #expect(list == AuditResourceRef(type: "api-keys", id: nil, action: "read"))
    }
}
