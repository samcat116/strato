import Testing
import ControlPlanePostgres
import Vapor
import Fluent
import VaporTesting
import StratoShared
import AppTestSupport
@testable import App

/// Absolute per-volume I/O ceilings (STR-19).
///
/// Two things here carry more weight than the endpoint's own validation,
/// because no agent implements ceilings yet and so nothing downstream would
/// catch getting them wrong:
///
/// * the **normalization asymmetry** — an all-null desired pair must leave the
///   sync as an *absent* field, while an observed nil and an observed
///   present-but-empty must stay distinguishable;
/// * the **echo rule** — an agent that says nothing about applied limits must
///   not have its silence recorded as "the caps were removed", which is the one
///   misreading this feature's lack of a wire capability gate makes possible.
@Suite("Volume I/O Limits Tests", .serialized)
final class VolumeIOLimitsTests {

    private func withVolumeApp(
        _ test: (Application, User, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "iolimituser",
                email: "iolimit@example.com",
                displayName: "IO Limit User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "IO Limit Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            try await user.replacingCurrentOrganization(org.id).save(on: app.db)

            let project = try await builder.createProject(
                name: "IO Limit Project",
                description: "Project for volume I/O limit tests",
                organization: org
            )
            let token = try await user.generateAPIKey(on: app)

            try await test(app, user, project, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func registerAgent(
        app: Application, named name: String, protocolVersion: Int = WireProtocol.currentVersion
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: "\(name).test",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            protocolVersion: protocolVersion
        )
        let orgID = try await Organization.all(on: app.db).first?.id
        let uuid = try await app.agentService.registerAgent(
            message, agentName: name, organizationScope: orgID.map { .organization($0) })
        return uuid.uuidString
    }

    /// Inserts a resting volume owned by `user`, with the creator's admin
    /// binding so the endpoint's `update` check authorizes.
    @discardableResult
    private func makeVolume(
        app: Application,
        user: User,
        project: Project,
        agentId: String?,
        iopsTotal: Int64? = nil,
        bpsTotal: Int64? = nil,
        appliedIOPSTotal: Int64? = nil,
        appliedBPSTotal: Int64? = nil,
        generation: Int64 = 1,
        observedGeneration: Int64 = 1
    ) async throws -> Volume {
        let pool = try await app.storagePoolsPersistence.defaultPool()
        let volume = Volume(
            name: "io-limit-target",
            description: "",
            projectID: project.id!, environment: "development",
            size: 10 << 30,
            format: .qcow2,
            volumeType: .data,
            status: .available,
            generation: generation,
            observedGeneration: observedGeneration,
            createdByID: user.id!,
            poolID: pool.id,
            iopsTotal: iopsTotal,
            bpsTotal: bpsTotal,
            appliedIOPSTotal: appliedIOPSTotal,
            appliedBPSTotal: appliedBPSTotal
        )
        try await app.db.transaction { db in
            try await volume.save(on: db)
            try await placeVolume(volume, on: agentId, using: db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                role: .admin,
                nodeType: .volume,
                nodeID: volume.id!,
                createdBy: user.id,
                on: db
            )
        }
        return volume
    }

    private func report(agentId: String, volumes: [ObservedVolumeState]?) -> ObservedStateReport {
        ObservedStateReport(
            agentId: agentId,
            vms: [],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            volumes: volumes
        )
    }

    private func createBody(project: Project, iopsTotal: Int64?, bpsTotal: Int64?) -> CreateVolumeRequest {
        CreateVolumeRequest(
            name: "io-limit-create",
            description: "volume created with ceilings",
            projectId: project.id!, environment: nil,
            sizeGB: 10,
            format: "qcow2",
            volumeType: "data",
            sourceImageId: nil,
            iopsTotal: iopsTotal,
            bpsTotal: bpsTotal
        )
    }

    // MARK: - The create path

    /// `validateIOLimits` has two call sites; this is the one whose comment
    /// claims "a volume never exists uncapped even briefly", so the ceilings
    /// have to be on the row the insert produces rather than applied by a
    /// follow-up mutation.
    @Test("Creating a volume with ceilings persists them on the inserted row")
    func createPersistsCeilings() async throws {
        try await withVolumeApp { app, _, project, token in
            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    self.createBody(project: project, iopsTotal: 500, bpsTotal: 1 << 20))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            // Placement runs on a detached task that touches app.db; wait for it
            // to settle (no agents connected → degraded) so it cannot race
            // application shutdown during teardown.
            var placed: Volume?
            for _ in 0..<100 {
                placed = try await Volume.all(on: app.db).first
                if placed?.conditions.degraded != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let stored = try #require(placed)
            #expect(stored.iopsTotal == 500)
            #expect(stored.bpsTotal == 1 << 20)
            #expect(stored.ioLimits?.iopsTotal == 500)
            // Requested at create is still only requested: nothing has applied it.
            #expect(stored.appliedIOLimits == nil)
        }
    }

    @Test(
        "Creating a volume with out-of-range ceilings is rejected with 400",
        arguments: [
            (Int64(0), Int64?.none),
            (Volume.maxIOPSTotal + 1, Int64?.none),
            (Int64?.none, Int64(0)) as (Int64?, Int64?),
            (Int64?.none, Volume.maxBPSTotal + 1) as (Int64?, Int64?),
        ] as [(Int64?, Int64?)]
    )
    func createRejectsOutOfRangeCeilings(iops: Int64?, bps: Int64?) async throws {
        try await withVolumeApp { app, _, project, token in
            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    self.createBody(project: project, iopsTotal: iops, bpsTotal: bps))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Rejected before the insert: no row, not a row with the caps dropped.
            let count = try await Volume.all(on: app.db).count
            #expect(count == 0)
        }
    }

    // MARK: - The endpoint

    @Test("Setting both ceilings is accepted and bumps the generation")
    func setBothCeilings() async throws {
        try await withVolumeApp { app, user, project, token in
            let agentId = try await self.registerAgent(app: app, named: "io-agent")
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId, generation: 4)

            try await app.test(.POST, "/api/volumes/\(volume.id!)/io-limits") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(SetVolumeIOLimitsRequest(iopsTotal: 500, bpsTotal: 1 << 20))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let stored = try #require(try await Volume.find(volume.id!, on: app.db))
            #expect(stored.iopsTotal == 500)
            #expect(stored.bpsTotal == 1 << 20)
            #expect(stored.generation == 5)
            // Nothing has applied them, and nothing should have pretended to.
            #expect(stored.appliedIOLimits == nil)

            let event = try #require(
                try await ResourceEvent.latest(
                    .requested, resourceKind: .volume, resourceID: volume.id!, on: app.db))
            #expect(event.mutation == .throttle)
            #expect(event.targetGeneration == 5)
        }
    }

    /// The clear path, and the reason the endpoint replaces rather than patches:
    /// an omitted field is the *only* way to say "remove this cap".
    @Test("An empty body clears both ceilings")
    func emptyBodyClearsCeilings() async throws {
        try await withVolumeApp { app, user, project, token in
            let agentId = try await self.registerAgent(app: app, named: "io-clear-agent")
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId,
                iopsTotal: 500, bpsTotal: 1 << 20)

            try await app.test(.POST, "/api/volumes/\(volume.id!)/io-limits") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(SetVolumeIOLimitsRequest(iopsTotal: nil, bpsTotal: nil))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let stored = try #require(try await Volume.find(volume.id!, on: app.db))
            #expect(stored.iopsTotal == nil)
            #expect(stored.bpsTotal == nil)
            #expect(stored.ioLimits == nil)
        }
    }

    /// Zero is a typo, not a removal. QEMU spells unlimited as zero, so
    /// accepting it would make the two indistinguishable on the one setting
    /// where the difference is "this tenant is capped" or not.
    @Test(
        "Out-of-range ceilings are rejected with 400",
        arguments: [
            (Int64(0), Int64?.none),
            (Int64(-1), Int64?.none),
            (Volume.maxIOPSTotal + 1, Int64?.none),
            (Int64?.none, Int64(0)) as (Int64?, Int64?),
            (Int64?.none, Volume.maxBPSTotal + 1) as (Int64?, Int64?),
        ] as [(Int64?, Int64?)]
    )
    func rejectsOutOfRangeCeilings(iops: Int64?, bps: Int64?) async throws {
        try await withVolumeApp { app, user, project, token in
            let agentId = try await self.registerAgent(app: app, named: "io-reject-agent")
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId)

            try await app.test(.POST, "/api/volumes/\(volume.id!)/io-limits") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(SetVolumeIOLimitsRequest(iopsTotal: iops, bpsTotal: bps))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let stored = try #require(try await Volume.find(volume.id!, on: app.db))
            #expect(stored.ioLimits == nil)
            #expect(stored.generation == 1)
        }
    }

    @Test("An unplaced volume cannot be throttled")
    func unplacedVolumeIsRefused() async throws {
        try await withVolumeApp { app, user, project, token in
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: nil)

            try await app.test(.POST, "/api/volumes/\(volume.id!)/io-limits") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(SetVolumeIOLimitsRequest(iopsTotal: 500, bpsTotal: nil))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("A terminating volume cannot be throttled")
    func terminatingVolumeIsRefused() async throws {
        try await withVolumeApp { app, user, project, token in
            let agentId = try await self.registerAgent(app: app, named: "io-terminating-agent")
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId)
            try await volume.replacing(desiredStatus: .absent).save(on: app.db)

            try await app.test(.POST, "/api/volumes/\(volume.id!)/io-limits") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(SetVolumeIOLimitsRequest(iopsTotal: 500, bpsTotal: nil))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    // MARK: - Assembly: the desired side normalizes

    @Test("A capped volume carries its ceilings on the sync; an uncapped one omits them")
    func assemblyNormalizesDesiredLimits() async throws {
        try await withVolumeApp { app, user, project, _ in
            let agentId = try await self.registerAgent(app: app, named: "io-assemble-agent")
            try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId,
                iopsTotal: 500, bpsTotal: nil)

            var message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            var entry = try #require(message.volumes.first)
            #expect(entry.ioLimits?.iopsTotal == 500)
            #expect(entry.ioLimits?.bpsTotal == nil)

            // An all-null pair leaves as an *absent* field, not as a
            // present-but-empty object. Two spellings of "uncapped" is what
            // would make a planner re-plan a throttle that is already applied.
            let volume = try #require(try await Volume.all(on: app.db).first)
            try await volume.replacing(iopsTotal: nil).save(on: app.db)

            message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            entry = try #require(message.volumes.first)
            #expect(entry.ioLimits == nil)
        }
    }

    // MARK: - The echo: the observed side does not normalize

    /// The scenario every agent is in today. A report that says nothing about
    /// applied limits must leave the recorded ones alone — writing its silence
    /// through would show an operator "the caps were removed".
    @Test("A report with no ioLimits leaves the applied ceilings untouched")
    func silentAgentDoesNotClearAppliedLimits() async throws {
        try await withVolumeApp { app, user, project, _ in
            let agentId = try await self.registerAgent(app: app, named: "io-silent-agent")
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId,
                iopsTotal: 500, appliedIOPSTotal: 500,
                generation: 2, observedGeneration: 1)

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volume.id!,
                            present: true,
                            attachment: .file(
                                path: "/var/lib/strato/volumes/v/volume.qcow2", format: .qcow2),
                            observedGeneration: 2,
                            ioLimits: nil)
                    ]))

            let stored = try #require(try await Volume.find(volume.id!, on: app.db))
            #expect(stored.appliedIOPSTotal == 500)
            // And the volume still converges by generation: an agent that
            // cannot apply ceilings is not a degraded volume, it is a volume
            // whose ceilings are not in effect.
            #expect(stored.observedGeneration == 2)
            #expect(stored.status == .available)
        }
    }

    /// The other half of the same rule. "Applied, and the answer is uncapped"
    /// is a present-but-empty value, and that one *does* clear the columns.
    @Test("A present-but-empty ioLimits clears the applied ceilings")
    func explicitlyUncappedAgentClearsAppliedLimits() async throws {
        try await withVolumeApp { app, user, project, _ in
            let agentId = try await self.registerAgent(app: app, named: "io-uncapped-agent")
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId,
                appliedIOPSTotal: 500, appliedBPSTotal: 1 << 20,
                generation: 2, observedGeneration: 1)

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volume.id!,
                            present: true,
                            attachment: .file(
                                path: "/var/lib/strato/volumes/v/volume.qcow2", format: .qcow2),
                            observedGeneration: 2,
                            ioLimits: VolumeIOLimits(iopsTotal: nil, bpsTotal: nil))
                    ]))

            let stored = try #require(try await Volume.find(volume.id!, on: app.db))
            #expect(stored.appliedIOPSTotal == nil)
            #expect(stored.appliedBPSTotal == nil)
        }
    }

    @Test("An agent's applied ceilings are recorded as reported")
    func appliedCeilingsAreRecorded() async throws {
        try await withVolumeApp { app, user, project, _ in
            let agentId = try await self.registerAgent(app: app, named: "io-applied-agent")
            let volume = try await self.makeVolume(
                app: app, user: user, project: project, agentId: agentId,
                iopsTotal: 500, generation: 2, observedGeneration: 1)

            _ = try await app.observedStateApplier.apply(
                report(
                    agentId: agentId,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volume.id!,
                            present: true,
                            attachment: .file(
                                path: "/var/lib/strato/volumes/v/volume.qcow2", format: .qcow2),
                            observedGeneration: 2,
                            ioLimits: VolumeIOLimits(iopsTotal: 500, bpsTotal: nil))
                    ]))

            let stored = try #require(try await Volume.find(volume.id!, on: app.db))
            #expect(stored.appliedIOLimits?.iopsTotal == 500)
            #expect(stored.appliedIOLimits?.bpsTotal == nil)
            // Requested and applied agree, which is the only way a caller can
            // tell a ceiling is actually in force.
            #expect(stored.ioLimits == stored.appliedIOLimits)
        }
    }
}
