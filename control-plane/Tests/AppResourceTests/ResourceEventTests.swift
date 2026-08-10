import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport

@testable import App

/// The append-only mutation audit trail (ADR 0001 stage 2, STR-143): every
/// mutation that writes an operation row also appends a `resource_events` row
/// naming the principal, the mutation, and the generation the agent has to
/// reach — and unlike the operation row, that record outlives the resource and
/// is never rewritten.
@Suite("Resource Event Tests", .serialized)
final class ResourceEventTests {

    /// Boots a configured test app with a non-admin user, org, project and one
    /// VM — the same harness `VMOperationTests` uses, so requests traverse the
    /// full middleware stack.
    private func withEventTestApp(
        _ test: (Application, User, Organization, Project, VM, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "eventuser",
                email: "event@example.com",
                displayName: "Event User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Event Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Event Project",
                description: "Project for resource event tests",
                organization: org
            )
            let vm = try await builder.createVM(name: "event-vm", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, org, project, vm, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func events(
        for resourceID: UUID, on db: any Database
    ) async throws -> [ResourceEvent] {
        try await ResourceEvent.query(on: db)
            .filter(\.$resourceID == resourceID)
            .sort(\.$createdAt)
            .all()
    }

    // MARK: - Attribution at mutation time

    @Test("A lifecycle mutation appends one event naming the acting user and target generation")
    func lifecycleMutationAppendsEvent() async throws {
        try await withEventTestApp { app, user, org, project, vm, token in
            let vmID = try vm.requireID()

            try await app.test(.POST, "/api/vms/\(vmID)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let recorded = try await self.events(for: vmID, on: app.db)
            #expect(recorded.count == 1)
            let event = try #require(recorded.first)
            #expect(event.mutation == .boot)
            #expect(event.actorType == .user)
            #expect(event.actorID == user.id)
            #expect(event.resourceKind == .virtualMachine)
            #expect(event.resourceName == "event-vm")
            #expect(event.organizationID == org.id)
            #expect(event.projectID == project.id)
            #expect(event.createdAt != nil)
            // The generation the mutation just set — the one an observed
            // report has to reach for the boot to count as converged. The
            // fixture VM starts at 0 and `setDesiredStatus` bumps it to 1.
            #expect(event.targetGeneration == 1)
        }
    }

    @Test("Create appends an event even though it never goes through the mutation accept path")
    func createAppendsEvent() async throws {
        try await withEventTestApp { app, user, org, project, _, token in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            let network = try await builder.createNetwork(name: "event-net", project: project)

            struct CreateVMBody: Content {
                let name: String
                let imageId: UUID?
                let projectId: UUID?
                let cpu: Int?
                let memory: Int64?
                let disk: Int64?
                let networkId: UUID?
            }
            let gb = Int64(1) << 30

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVMBody(
                        name: "created-vm", imageId: image.id, projectId: project.id,
                        cpu: 1, memory: gb, disk: 10 * gb, networkId: try network.requireID()))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let created = try #require(
                try await VM.query(on: app.db).filter(\.$name == "created-vm").first())
            let createdID = try created.requireID()
            let bootVolumes = try await Volume.query(on: app.db)
                .filter(\.$vm.$id == createdID)
                .filter(\.$volumeType == .boot)
                .all()
            let bootVolume = try #require(bootVolumes.first)
            #expect(bootVolumes.count == 1)
            #expect(bootVolume.deviceName == VolumeDeviceName.disk(0).rawValue)
            #expect(bootVolume.bootOrder == 0)
            #expect(!bootVolume.readonly)
            #expect(bootVolume.size == created.disk)
            #expect(bootVolume.$sourceImage.id == image.id)

            let recorded = try await self.events(for: createdID, on: app.db)
            let create = try #require(recorded.first { $0.mutation == .create })
            #expect(create.actorType == .user)
            #expect(create.actorID == user.id)
            #expect(create.resourceName == "created-vm")
            #expect(create.organizationID == org.id)
            #expect(create.projectID == project.id)
            // A fresh VM is desired-shutdown at generation 1, which is what
            // distinguishes "never confirmed by any agent" from "confirmed".
            #expect(create.targetGeneration == 1)

            let volumeEvents = try await self.events(for: try bootVolume.requireID(), on: app.db)
            #expect(
                volumeEvents.contains {
                    $0.resourceKind == .volume && $0.mutation == .create
                })
        }
    }

    @Test("Sandbox create appends its own event, like the VM create path it mirrors")
    func sandboxCreateAppendsEvent() async throws {
        try await withEventTestApp { app, user, org, project, _, token in
            let builder = TestDataBuilder(db: app.db)
            let network = try await builder.createNetwork(name: "event-sandbox-net", project: project)

            struct CreateSandboxBody: Content {
                let name: String
                let projectId: UUID?
                let image: String
                let cpus: Int?
                let memory: Int64?
                let networkId: UUID?
            }

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSandboxBody(
                        name: "created-sandbox", projectId: project.id,
                        image: "ghcr.io/acme/worker:v1", cpus: 1, memory: Int64(1) << 30,
                        networkId: try network.requireID()))
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let created = try #require(
                try await Sandbox.query(on: app.db).filter(\.$name == "created-sandbox").first())
            let event = try #require(
                try await self.events(for: try created.requireID(), on: app.db)
                    .first { $0.mutation == .create })
            #expect(event.actorType == .user)
            #expect(event.actorID == user.id)
            #expect(event.resourceKind == .sandbox)
            #expect(event.resourceName == "created-sandbox")
            #expect(event.organizationID == org.id)
            #expect(event.projectID == project.id)
            #expect(event.targetGeneration == created.generation)
        }
    }

    @Test("An unattended sweep records the system actor, not a user that does not exist")
    func systemActorRecorded() async throws {
        try await withEventTestApp { app, _, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let sandbox = try await builder.createSandbox(name: "expiring", project: project)
            let sandboxID = try sandbox.requireID()

            // The path the sandbox expiry sweep takes (issue #424). It used to
            // name the actor with a sentinel user id that matched no real user,
            // which `MutationActor` derived `.system` from; the sentinel went
            // with the operations table (STR-152) and the sweep passes the
            // actor directly.
            _ = try await app.resourceMutation.accept(
                .delete, on: sandbox, actor: .system, dispatch: .stateSync,
                on: app.db, app: app
            ) { db in
                sandbox.setDesiredStatus(.absent)
                try await sandbox.save(on: db)
            }

            let event = try #require(try await self.events(for: sandboxID, on: app.db).first)
            #expect(event.actorType == .system)
            #expect(event.actorID == nil)
            #expect(event.mutation == .delete)
            #expect(event.resourceKind == .sandbox)
        }
    }

    // MARK: - Durability

    @Test("The event outlives the resource it describes")
    func eventOutlivesResource() async throws {
        try await withEventTestApp { app, user, org, project, vm, token in
            let vmID = try vm.requireID()

            // Unplaced VM: the delete resolves directly, removing the row
            // rather than waiting for an agent to confirm absence.
            try await app.test(.DELETE, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            var removed = false
            for _ in 0..<100 {
                if try await VM.find(vmID, on: app.db) == nil {
                    removed = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard removed else {
                let conditions = try await VM.find(vmID, on: app.db)?.conditions
                Issue.record(
                    """
                    VM \(vmID) was still present after 5s, so the delete never resolved; \
                    observed generation \(conditions?.observedGeneration.description ?? "<none>") \
                    of \(conditions?.targetGeneration.description ?? "<none>"), \
                    degraded \(conditions?.degraded?.reason ?? "<none>")
                    """)
                return
            }

            // Nothing resolves against the VM row any more, so everything the
            // trail needs had to be snapshotted at mutation time.
            let event = try #require(try await self.events(for: vmID, on: app.db).first)
            #expect(event.mutation == .delete)
            #expect(event.actorID == user.id)
            #expect(event.resourceName == "event-vm")
            #expect(event.organizationID == org.id)
            #expect(event.projectID == project.id)
        }
    }

    @Test("A rejected mutation appends nothing")
    func rejectedMutationAppendsNothing() async throws {
        try await withEventTestApp { app, _, _, _, vm, token in
            let vmID = try vm.requireID()

            // A state guard rejects the pause before any mutation applies (the
            // VM is `.created`, not running), so the trail must not claim a
            // pause was requested.
            try await app.test(.POST, "/api/vms/\(vmID)/pause") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            #expect(try await self.events(for: vmID, on: app.db).isEmpty)
        }
    }

    @Test("A mutation that throws mid-transaction appends nothing either")
    func failedMutationAppendsNothing() async throws {
        try await withEventTestApp { app, user, _, _, vm, _ in
            let vmID = try vm.requireID()

            struct MutationFailure: Error {}

            // The other half of "the trail cannot disagree with what applied":
            // a mutation that throws after its desired-state write relies on
            // the transaction rolling the generation bump and the event back
            // together.
            await #expect(throws: MutationFailure.self) {
                _ = try await app.resourceMutation.accept(
                    .boot, on: vm, actor: .user(try user.requireID()),
                    dispatch: .stateSync, on: app.db, app: app
                ) { db in
                    vm.setDesiredStatus(.running)
                    try await vm.save(on: db)
                    throw MutationFailure()
                }
            }

            #expect(try await self.events(for: vmID, on: app.db).isEmpty)
            #expect(try await VM.find(vmID, on: app.db)?.generation == 0)
        }
    }

    @Test("A machine principal round-trips through the actor columns")
    func machinePrincipalActorRoundTrips() async throws {
        try await withEventTestApp { app, _, _, _, vm, _ in
            let vmID = try vm.requireID()

            // Unreachable until STR-15 widens the mutation endpoints, so these
            // raw values would otherwise sit behind a `CHECK` untested —
            // `service_account` being the one whose raw value differs from its
            // case name, which is the shape a typo takes.
            let serviceAccountID = UUID()
            let workloadID = UUID()
            try await ResourceEvent.record(
                .boot, resourceKind: .virtualMachine, resourceID: vmID,
                actor: .serviceAccount(serviceAccountID), on: app.db)
            try await ResourceEvent.record(
                .shutdown, resourceKind: .virtualMachine, resourceID: vmID,
                actor: .workload(workloadID), on: app.db)

            let recorded = try await self.events(for: vmID, on: app.db)
            #expect(recorded.map(\.actorType) == [.serviceAccount, .workload])
            #expect(recorded.map(\.actorID) == [serviceAccountID, workloadID])
        }
    }
}
