import Testing
import Vapor
import Fluent
import VaporTesting
import StratoShared
import AppTestSupport
@testable import App

/// Tests for the sandbox resource surface (issue #413): `/api/sandboxes` CRUD
/// and lifecycle endpoints return `202 Accepted` with the sandbox and the
/// generation it is converging on, mutations write desired state atomically
/// with their attribution event, the Cedar evaluator guards the routes through
/// the generalized prefix mapping, desired-state syncs carry sandboxes, and
/// observed-state reports settle convergence by generation — all mirroring the
/// VM contracts.
@Suite("Sandbox Tests", .serialized)
final class SandboxTests {

    /// The `202` body a sandbox lifecycle mutation answers with (STR-147).
    typealias AcceptedSandbox = AcceptedMutation<SandboxDetailResponse>

    /// Same harness shape as `VMOperationTests`: full middleware stack,
    /// role-binding-backed authorization, API-key auth, one org/project and
    /// one pre-created sandbox.
    private func withSandboxTestApp(
        _ test: (Application, User, Project, Sandbox, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "sandboxuser",
                email: "sandbox@example.com",
                displayName: "Sandbox User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Sandbox Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Sandbox Project",
                description: "Project for sandbox tests",
                organization: org
            )
            let sandbox = try await builder.createSandbox(name: "test-sandbox", project: project)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, project, sandbox, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Registers an in-memory Firecracker-capable agent and (optionally) maps
    /// the sandbox to it. Returns the agent's UUID string.
    private func registerAgent(
        app: Application,
        sandbox: Sandbox? = nil,
        named agentName: String = "sandbox-agent",
        sandboxCapable: Bool? = nil,
        sandboxNetworkingCapable: Bool? = nil,
        protocolVersion: Int? = WireProtocol.currentVersion,
        architecture: CPUArchitecture? = nil,
        // Recent enough to remap a restored network device (STR-104), which is
        // what a networked fork places on. Tests probing that gate pass an
        // older one; everything else wants a host that is simply current.
        firecrackerVersion: String? = FirecrackerSnapshotFeatures.networkOverridesMinimumVersion
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: agentName,
            hostname: "test-host",
            version: "1.0.0",
            capabilities: ["firecracker"],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            architecture: architecture,
            hypervisors: [
                HypervisorSupport(
                    type: .firecracker, available: true, accelerated: true,
                    capabilities: .firecracker, version: firecrackerVersion)
            ],
            // A sandbox NIC is OVN-only, so an agent that can realize one is by
            // construction an overlay host — the two travel together here so a
            // test never has to remember to set both.
            networkCapability: (sandboxNetworkingCapable ?? false) ? .overlay : nil,
            protocolVersion: protocolVersion,
            sandboxCapable: sandboxCapable,
            sandboxNetworkingCapable: sandboxNetworkingCapable
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let agentUUID = try await app.agentService.registerAgent(
            message, agentName: agentName,
            organizationScope: orgID.map { .organization($0) })
        if let sandbox {
            sandbox.hypervisorId = agentUUID.uuidString
            try await sandbox.save(on: app.db)
        }
        return agentUUID.uuidString
    }

    private func report(
        agentId: String,
        sandboxes: [ObservedSandboxState]
    ) throws -> MessageEnvelope {
        let report = ObservedStateReport(
            agentId: agentId,
            vms: [],
            sandboxes: sandboxes,
            resources: AgentResources(
                totalCPU: 16, availableCPU: 12,
                totalMemory: 1 << 34, availableMemory: 1 << 33,
                totalDisk: 1 << 40, availableDisk: 1 << 39
            )
        )
        return try MessageEnvelope(message: report)
    }

    /// Waits for the background task to resolve the sandbox to `expected`.
    /// The operation row and the sandbox row are written separately, so tests
    /// must poll the row they assert on.
    private func pollSandboxStatus(
        _ sandboxID: UUID, until expected: SandboxStatus, on db: any Database
    ) async throws {
        for _ in 0..<100 {
            if let sandbox = try await Sandbox.find(sandboxID, on: db), sandbox.status == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Sandbox \(sandboxID) never reached status \(expected.rawValue)")
    }

    /// Waits for the background dispatch to degrade the sandbox — the shape a
    /// failed mutation takes now that there is no operation row to fail
    /// (STR-147).
    private func pollSandboxDegraded(_ sandboxID: UUID, on db: any Database) async throws {
        for _ in 0..<100 {
            if let sandbox = try await Sandbox.find(sandboxID, on: db),
                sandbox.conditions.degraded != nil
            {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Sandbox \(sandboxID) never went degraded")
    }

    /// Waits for the delete's background dispatch to reap the row.
    private func pollSandboxRemoved(_ sandboxID: UUID, on db: any Database) async throws {
        for _ in 0..<100 {
            if try await Sandbox.find(sandboxID, on: db) == nil { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Sandbox \(sandboxID) was never removed")
    }

    // MARK: - Model defaults

    @Test("New sandboxes rest at desired stopped with generation zero")
    func modelDefaults() async throws {
        try await withSandboxTestApp { _, _, _, sandbox, _ in
            #expect(sandbox.status == .stopped)
            #expect(sandbox.desiredStatus == .stopped)
            #expect(sandbox.generation == 0)
            #expect(sandbox.observedGeneration == 0)

            sandbox.setFixtureDesiredStatus(.running)
            #expect(sandbox.generation == 1)
        }
    }

    @Test("revertDesiredToObserved leaves a satisfied desired state alone")
    func revertRespectsExited() async throws {
        try await withSandboxTestApp { _, _, _, sandbox, _ in
            // `.exited` satisfies desired `.running`, so a failed unrelated
            // operation must not flip desired to `.stopped`.
            sandbox.setFixtureDesiredStatus(.running)
            sandbox.setStatus(.exited)
            #expect(sandbox.revertDesiredToObserved() == false)
            #expect(sandbox.desiredStatus == .running)

            // A failed delete's `.absent` is never abandoned (issue #734):
            // reverting it would resurrect a sandbox the user deleted, and the
            // reconciler would recreate a blank one once the agent had torn it
            // down. The generation must not move either.
            sandbox.setStatus(.running)
            sandbox.setFixtureDesiredStatus(.absent)
            let generation = sandbox.generation
            #expect(sandbox.revertDesiredToObserved() == false)
            #expect(sandbox.desiredStatus == .absent)
            #expect(sandbox.generation == generation)
        }
    }

    // MARK: - Scheduler gating (issue #415)

    @Test("Registration persists the advertised sandbox capability and its absence clears it")
    func registrationPersistsSandboxCapability() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let agentId = try await registerAgent(app: app, named: "capable-agent", sandboxCapable: true)
            let registered = try await Agent.find(UUID(uuidString: agentId), on: app.db)
            #expect(registered?.sandboxCapable == true)

            // Re-registration without the flag (e.g. the guest image was
            // removed, or the agent was downgraded) must clear it.
            _ = try await registerAgent(app: app, named: "capable-agent", sandboxCapable: nil)
            let reRegistered = try await Agent.find(UUID(uuidString: agentId), on: app.db)
            #expect(reRegistered?.sandboxCapable == false)
        }
    }

    @Test("createSandbox places onto a sandbox-capable agent")
    func createSandboxPlacesOnCapableAgent() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let agentId = try await registerAgent(app: app, named: "runtime-agent", sandboxCapable: true)

            try await app.agentService.createSandbox(sandbox: sandbox, db: app.db)

            let placed = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(placed?.hypervisorId == agentId)
        }
    }

    @Test("createSandbox refuses a Firecracker fleet that never advertised the runtime")
    func createSandboxRefusesRuntimelessFleet() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            // Firecracker-capable and current protocol, but no sandboxCapable —
            // e.g. a v5 build without the runtime, or no guest image on disk.
            _ = try await registerAgent(app: app, named: "runtimeless-agent", sandboxCapable: nil)

            do {
                try await app.agentService.createSandbox(sandbox: sandbox, db: app.db)
                Issue.record("Expected schedulingFailed error")
            } catch let error as AgentServiceError {
                guard case .schedulingFailed(let reason) = error else {
                    Issue.record("Expected schedulingFailed, got \(error)")
                    return
                }
                #expect(reason.contains("sandbox runtime"))
            }

            let unplaced = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(unplaced?.hypervisorId == nil)
        }
    }

    // MARK: - Sandbox networking gating (STR-103)

    @Test("Registration persists the sandbox-networking capability separately, and its absence clears it")
    func registrationPersistsSandboxNetworkingCapability() async throws {
        try await withSandboxTestApp { app, _, _, _, _ in
            let agentId = try await registerAgent(
                app: app, named: "networked-agent", sandboxCapable: true, sandboxNetworkingCapable: true)
            let registered = try await Agent.find(UUID(uuidString: agentId), on: app.db)
            #expect(registered?.sandboxNetworkingCapable == true)

            // A guest-image rollback, OVN going down, or the jailer no longer
            // resolving must be able to take the flag back down. The runtime
            // capability is unaffected — that is the whole reason these are two
            // signals rather than one.
            _ = try await registerAgent(
                app: app, named: "networked-agent", sandboxCapable: true, sandboxNetworkingCapable: nil)
            let reRegistered = try await Agent.find(UUID(uuidString: agentId), on: app.db)
            #expect(reRegistered?.sandboxNetworkingCapable == false)
            #expect(reRegistered?.sandboxCapable == true)
        }
    }

    @Test("createSandbox refuses to place a networked sandbox on a fleet that cannot realize a NIC")
    func createSandboxRefusesNetworkedSandboxOnIncapableFleet() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, _ in
            // Runs sandboxes, cannot network them — e.g. an unjailed host, or
            // one whose installed guest image predates STR-101.
            _ = try await registerAgent(
                app: app, named: "no-sandbox-net", sandboxCapable: true, sandboxNetworkingCapable: nil)

            let network = try await self.projectNetwork(project: project, on: app.db)
            try await SandboxNetworkInterface(
                sandboxID: try sandbox.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: "00:0c:29:ab:cd:22"
            ).save(on: app.db)

            do {
                try await app.agentService.createSandbox(sandbox: sandbox, db: app.db)
                Issue.record("Expected schedulingFailed error")
            } catch let error as AgentServiceError {
                guard case .schedulingFailed(let reason) = error else {
                    Issue.record("Expected schedulingFailed, got \(error)")
                    return
                }
                #expect(reason.contains("sandbox a NIC"))
            }

            // Refused, not degraded: booting it unnetworked would leave the API
            // reporting an address the workload never gets.
            let unplaced = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(unplaced?.hypervisorId == nil)
        }
    }

    /// The same fleet still hosts sandboxes — the constraint is a property of
    /// the workload's NIC, not of the host's ability to run sandboxes at all.
    @Test("A network-free sandbox still places on an agent that cannot realize a NIC")
    func createSandboxPlacesNetworkFreeOnNetworklessAgent() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let agentId = try await registerAgent(
                app: app, named: "no-sandbox-net", sandboxCapable: true, sandboxNetworkingCapable: nil)

            try await app.agentService.createSandbox(sandbox: sandbox, db: app.db)

            let placed = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(placed?.hypervisorId == agentId)
        }
    }

    @Test("createSandbox places a networked sandbox on the agent that advertises sandbox networking")
    func createSandboxPlacesNetworkedOnCapableAgent() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, _ in
            _ = try await registerAgent(
                app: app, named: "no-sandbox-net", sandboxCapable: true, sandboxNetworkingCapable: nil)
            let capableId = try await registerAgent(
                app: app, named: "sandbox-net", sandboxCapable: true, sandboxNetworkingCapable: true)

            let network = try await self.projectNetwork(project: project, on: app.db)
            try await SandboxNetworkInterface(
                sandboxID: try sandbox.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: "00:0c:29:ab:cd:33"
            ).save(on: app.db)

            try await app.agentService.createSandbox(sandbox: sandbox, db: app.db)

            let placed = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(placed?.hypervisorId == capableId)
        }
    }

    // MARK: - Create

    @Test("POST /api/sandboxes returns 202 with a pending create operation")
    func createReturnsAccepted() async throws {
        try await withSandboxTestApp { app, user, project, _, token in
            var accepted: AcceptedSandbox?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "worker",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedSandbox.self)
            }

            let body = try #require(accepted)
            // The generation the client waits for, and the mutation id the
            // operations façade still answers for.
            #expect(body.targetGeneration == 1)
            #expect(body.resource.conditions.targetGeneration == 1)

            let sandbox = try #require(await Sandbox.find(body.resource.id!, on: app.db))
            #expect(sandbox.name == "worker")
            #expect(sandbox.image == "ghcr.io/acme/worker:v3")
            #expect(sandbox.desiredStatus == .stopped)
            #expect(sandbox.generation == 1)
            #expect(sandbox.observedGeneration == 0)
            #expect(sandbox.$project.id == project.id)

            // Ownership: the creator gets an admin binding on the sandbox node
            // in the create transaction.
            let ownerBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.user.rawValue)
                .filter(\.$principalID == user.id!)
                .filter(\.$role == IAMRole.admin.seededID.uuidString)
                .filter(\.$nodeType == IAMNodeType.sandbox.rawValue)
                .filter(\.$nodeID == body.resource.id!)
                .count()
            #expect(ownerBindings == 1)

            // No schedulable agent exists, so background placement must degrade
            // the sandbox and surface it as error.
            try await self.pollSandboxStatus(body.resource.id!, until: .error, on: app.db)
            let degraded = try #require(await Sandbox.find(body.resource.id!, on: app.db))
            #expect(degraded.conditions.degraded != nil)
        }
    }

    @Test("POST /api/sandboxes forks a ready snapshot with new identity and pinned placement")
    func createFromSnapshot() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app,
                sandbox: source,
                named: "fork-agent",
                sandboxCapable: true,
                // The fork below names a network, so it gets a NIC — and since
                // STR-103 that constrains placement to a host that can realize
                // one.
                sandboxNetworkingCapable: true,
                architecture: CPUArchitecture.current)

            source.imageDigest = "sha256:" + String(repeating: "a", count: 64)
            source.cpus = 3
            source.memory = 2 * 1024 * 1024 * 1024
            source.entrypoint = ["/usr/bin/worker"]
            source.cmd = ["--serve"]
            source.env = ["MODE": "source"]
            source.workingDir = "/srv"
            try await source.save(on: app.db)

            let sourceNetwork = try await self.projectNetwork(project: project, on: app.db)
            let sourceNIC = SandboxNetworkInterface(
                sandboxID: source.id!,
                logicalNetworkID: try sourceNetwork.requireID(),
                macAddress: "52:54:00:00:00:01")
            try await sourceNIC.save(on: app.db)

            let snapshot = SandboxSnapshot(
                name: "fork-point",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.architecture = CPUArchitecture.current.rawValue
            snapshot.guestControlProtocolVersion =
                SandboxGuestControlProtocol.currentVersion
            snapshot.forkLayoutVersion = SandboxSnapshotForkLayout.currentVersion
            try await snapshot.save(on: app.db)

            var accepted: AcceptedSandbox?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "worker-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                    "networkId": try sourceNetwork.requireID().uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedSandbox.self)
            }

            let body = try #require(accepted)
            let forkID = body.resource.id!
            var fork = try #require(await Sandbox.find(forkID, on: app.db))
            #expect(fork.restoredFromSnapshotId == snapshot.id)
            #expect(fork.image == source.image)
            #expect(fork.imageDigest == source.imageDigest)
            #expect(fork.cpus == source.cpus)
            #expect(fork.memory == source.memory)
            #expect(fork.entrypoint == source.entrypoint)
            #expect(fork.cmd == source.cmd)
            #expect(fork.env == source.env)
            #expect(fork.workingDir == source.workingDir)
            #expect(fork.desiredStatus == .running)
            #expect(fork.generation == 1)

            for _ in 0..<100 where fork.hypervisorId == nil {
                try await Task.sleep(for: .milliseconds(20))
                fork = try #require(await Sandbox.find(forkID, on: app.db))
            }
            #expect(fork.hypervisorId == agentId)

            let desired = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let forkState = try #require(desired.sandboxes.first { $0.sandboxId == forkID })
            let expectedRef = SandboxSnapshotRef(
                snapshotId: snapshot.id!, sourceSandboxId: source.id!)
            #expect(forkState.restoreFrom == expectedRef)
            #expect(forkState.spec.restoreFrom == expectedRef)
            #expect(forkState.registryCredential == nil)

            let forkNIC = try #require(
                await SandboxNetworkInterface.query(on: app.db)
                    .filter(\.$sandbox.$id == forkID)
                    .first())
            #expect(forkNIC.macAddress != sourceNIC.macAddress)
            #expect(forkNIC.deviceName == "net0")
        }
    }

    @Test("Fork refuses machine overrides")
    func createFromSnapshotGuards() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agent = try await registerAgent(
                app: app,
                sandbox: source,
                named: "fork-agent",
                sandboxCapable: true)
            let snapshot = SandboxSnapshot(
                name: "fork-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: agent,
                createdByID: user.id!)
            snapshot.status = .ready
            try await snapshot.save(on: app.db)

            // A fork resumes the checkpointed machine, so a spec override the
            // restore cannot honor is refused outright.
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "invalid-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "image": "docker.io/library/alpine:latest",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Fork refuses a checkpoint whose guest predates re-identification")
    func createFromSnapshotRejectsLegacyGuest() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app,
                sandbox: source,
                named: "current-agent-with-legacy-guest",
                sandboxCapable: true)
            let snapshot = SandboxSnapshot(
                name: "legacy-guest-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.guestControlProtocolVersion =
                SandboxGuestControlProtocol.reidentifyMinimumVersion - 1
            snapshot.forkLayoutVersion = SandboxSnapshotForkLayout.currentVersion
            try await snapshot.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "unsafe-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("checkpointed guest is too old"))
            }
        }
    }

    /// A snapshot load can repoint a network device at a different host TAP,
    /// but it can neither add nor drop one (STR-104) — so a fork that
    /// disagrees with its source about having a NIC is unbootable, and the
    /// agent refuses it permanently. Saying so on the request that asked for
    /// it is the difference between a 409 and a degraded sandbox.
    @Test("Fork refuses a NIC the checkpoint has no device for")
    func createFromSnapshotRejectsNICOnNetworklessCheckpoint() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app, sandbox: source, named: "networkless-source-agent",
                sandboxCapable: true, sandboxNetworkingCapable: true)
            // `source` is created without a NIC.
            let network = try await self.projectNetwork(project: project, on: app.db)
            let snapshot = try await self.readySnapshot(
                named: "networkless-checkpoint", source: source, project: project, user: user,
                agentId: agentId, on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "grown-a-nic",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                    "networkId": try network.requireID().uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("cannot grow one on restore"))
            }
        }
    }

    /// The other side of the shape rule: the restore cannot *drop* the
    /// checkpoint's device either, so the NIC is part of what a fork inherits —
    /// like its image and machine shape — rather than something the caller has
    /// to remember to re-request. The fork still gets its own MAC and IPAM
    /// allocation; sharing those with a possibly-live source is exactly what
    /// re-identification exists to prevent.
    @Test("Fork inherits the source's network when it names none")
    func createFromSnapshotInheritsTheSourceNetwork() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app, sandbox: source, named: "networked-source-agent",
                sandboxCapable: true, sandboxNetworkingCapable: true,
                architecture: CPUArchitecture.current)
            let network = try await self.projectNetwork(project: project, on: app.db)
            let sourceNIC = SandboxNetworkInterface(
                sandboxID: source.id!,
                logicalNetworkID: try network.requireID(),
                macAddress: "52:54:00:00:00:11")
            try await sourceNIC.save(on: app.db)
            let snapshot = try await self.readySnapshot(
                named: "networked-checkpoint", source: source, project: project, user: user,
                agentId: agentId, on: app.db)

            var accepted: AcceptedSandbox?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "inherits-the-nic",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedSandbox.self)
            }

            let forkID = try #require(accepted).resource.id!
            let forkNIC = try #require(
                await SandboxNetworkInterface.query(on: app.db)
                    .filter(\.$sandbox.$id == forkID)
                    .first())
            #expect(forkNIC.logicalNetworkID == (try network.requireID()))
            #expect(forkNIC.macAddress != sourceNIC.macAddress)
        }
    }

    /// A v3 guest rotates its identity but drops `reidentify`'s `network`
    /// block, so it would come up holding the *source* sandbox's address —
    /// which generally still belongs to a live sandbox. A network-free fork of
    /// the same guest stays perfectly legal, which is why this gate is
    /// separate from the fork gate rather than a bump of it.
    @Test("Fork refuses a networked checkpoint whose guest cannot re-address its NIC")
    func createFromSnapshotRejectsNetworkedForkOnPreV4Guest() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app, sandbox: source, named: "pre-v4-guest-agent",
                sandboxCapable: true, sandboxNetworkingCapable: true)
            let network = try await self.projectNetwork(project: project, on: app.db)
            try await SandboxNetworkInterface(
                sandboxID: source.id!,
                logicalNetworkID: try network.requireID(),
                macAddress: "52:54:00:00:00:12"
            ).save(on: app.db)
            let snapshot = try await self.readySnapshot(
                named: "pre-v4-guest-checkpoint", source: source, project: project, user: user,
                agentId: agentId, on: app.db)
            snapshot.guestControlProtocolVersion =
                SandboxGuestControlProtocol.networkReconfigureMinimumVersion - 1
            try await snapshot.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "stale-address-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                    "networkId": try network.requireID().uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("cannot re-address its NIC"))
            }
        }
    }

    /// Capturing a networked checkpoint needs nothing special, but forking one
    /// needs `network_overrides` on the load — so a snapshot can sit on a host
    /// that cannot fork it. Without this gate the only signal is a permanent
    /// agent-side refusal the caller sees as a degraded sandbox.
    @Test("Fork refuses a networked snapshot pinned to a pre-1.12 Firecracker host")
    func createFromSnapshotRejectsNetworkedForkOnOldFirecracker() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app, sandbox: source, named: "pre-1-12-firecracker-agent",
                sandboxCapable: true, sandboxNetworkingCapable: true,
                firecrackerVersion: "1.11.0")
            let network = try await self.projectNetwork(project: project, on: app.db)
            try await SandboxNetworkInterface(
                sandboxID: source.id!,
                logicalNetworkID: try network.requireID(),
                macAddress: "52:54:00:00:00:13"
            ).save(on: app.db)
            let snapshot = try await self.readySnapshot(
                named: "old-vmm-checkpoint", source: source, project: project, user: user,
                agentId: agentId, on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "unremappable-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("cannot point a restored network device"))
            }
        }
    }

    /// The gate is scoped to the remap, not to forking: the same host forks a
    /// network-free checkpoint perfectly well, because nothing on that path
    /// touches `network_overrides`.
    @Test("A network-free fork is unaffected by the host's Firecracker version")
    func createFromSnapshotAllowsNetworkFreeForkOnOldFirecracker() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app, sandbox: source, named: "pre-1-12-firecracker-agent-networkless",
                sandboxCapable: true, firecrackerVersion: "1.11.0")
            let snapshot = try await self.readySnapshot(
                named: "old-vmm-networkless-checkpoint", source: source, project: project,
                user: user, agentId: agentId, on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "networkless-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
        }
    }

    @Test("Fork refuses a checkpoint captured without the jailed layout")
    func createFromSnapshotRejectsUnjailedLayout() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app,
                sandbox: source,
                named: "current-agent-with-unjailed-snapshot",
                sandboxCapable: true)
            let snapshot = SandboxSnapshot(
                name: "unjailed-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.guestControlProtocolVersion = SandboxGuestControlProtocol.currentVersion
            try await snapshot.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "unsafe-layout-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("fork-compatible jailed layout"))
            }
        }
    }

    @Test("Fork of an exported snapshot survives losing its owning agent")
    func createFromExportedSnapshotWithoutAgent() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            // No agent at all: the snapshot's export record is the only
            // viable restore source (issue #428). The create is accepted;
            // background placement then fails because no schedulable agent
            // exists, which is the scheduling contract, not the gate's.
            let snapshot = SandboxSnapshot(
                name: "durable-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: nil,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.guestControlProtocolVersion = SandboxGuestControlProtocol.currentVersion
            snapshot.forkLayoutVersion = SandboxSnapshotForkLayout.currentVersion
            snapshot.exportedArtifacts = SandboxSnapshotArtifactKind.allCases.map {
                SandboxSnapshotExportedArtifact(
                    kind: $0, sizeBytes: 16, sha256: String(repeating: "0", count: 64))
            }
            snapshot.exportedAt = Date()
            try await snapshot.save(on: app.db)

            var accepted: AcceptedSandbox?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "durable-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedSandbox.self)
            }
            let body = try #require(accepted)
            let fork = try #require(await Sandbox.find(body.resource.id!, on: app.db))
            #expect(fork.restoredFromSnapshotId == snapshot.id)
        }
    }

    @Test("Fork with neither an owning agent nor an export is refused")
    func createFromSnapshotRefusedWithoutAgentOrExport() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let snapshot = SandboxSnapshot(
                name: "stranded-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: nil,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.guestControlProtocolVersion = SandboxGuestControlProtocol.currentVersion
            snapshot.forkLayoutVersion = SandboxSnapshotForkLayout.currentVersion
            try await snapshot.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "stranded-fork",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("export"))
            }
        }
    }

    @Test("Create validates the CPU template and persists the normalized value")
    func createValidatesCPUTemplate() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "bogus-template",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                    "cpuTemplate": "SUPERFAST",
                ])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("cpuTemplate"))
            }

            var accepted: AcceptedSandbox?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "templated",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                    "cpuTemplate": "t2",
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedSandbox.self)
            }
            let body = try #require(accepted)
            let created = try #require(await Sandbox.find(body.resource.id!, on: app.db))
            #expect(created.cpuTemplate == "T2")

            // The template travels on the wire spec (issue #428).
            #expect(created.buildSpec().cpuTemplate == "T2")
        }
    }

    @Test("Fork transaction rechecks destructive source transitions")
    func createFromSnapshotRechecksLineage() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app,
                sandbox: source,
                named: "lineage-lock-agent",
                sandboxCapable: true)
            let snapshot = SandboxSnapshot(
                name: "lineage-lock-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.guestControlProtocolVersion =
                SandboxGuestControlProtocol.currentVersion
            snapshot.forkLayoutVersion = SandboxSnapshotForkLayout.currentVersion
            try await snapshot.save(on: app.db)

            source.desiredStatus = .absent
            try await source.save(on: app.db)
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "fork-during-source-delete",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("source sandbox is being deleted"))
            }

            source.desiredStatus = .running
            // An in-place restore in flight: `requestRestore` bumps both the
            // restore nonce and the generation, and the agent has not confirmed
            // the latter. That window is what used to be a pending `restore`
            // operation row (STR-152).
            source.requestFixtureRestore(snapshotID: snapshot.id!)
            try await source.save(on: app.db)
            _ = try await ResourceEvent.record(
                .restore, resourceKind: .sandbox, resourceID: source.requireID(),
                actor: .user(try user.requireID()), on: app.db)
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "fork-during-source-restore",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("being restored in place"))
            }
        }
    }

    /// A restore is not consumed by being superseded — the agent applies one
    /// only when the workload is wanted running, so a stop makes it *wait*
    /// (`Reconciliation.planWorkloadSteps`). The guard therefore has to key on
    /// the newest `.restore`, not on the newest mutation: keying on the latter
    /// would let a `.shutdown` issued after the restore hide it and admit a
    /// fork the retired operation row refused.
    @Test("A restore hidden behind a newer mutation still blocks a fork")
    func createFromSnapshotBlockedByRestoreBehindNewerMutation() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app,
                sandbox: source,
                named: "superseded-restore-agent",
                sandboxCapable: true)
            let snapshot = SandboxSnapshot(
                name: "superseded-restore-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.guestControlProtocolVersion =
                SandboxGuestControlProtocol.currentVersion
            snapshot.forkLayoutVersion = SandboxSnapshotForkLayout.currentVersion
            try await snapshot.save(on: app.db)

            let sourceID = try source.requireID()
            let userID = try user.requireID()

            // The restore is requested first...
            source.requestFixtureRestore(snapshotID: snapshot.id!)
            try await source.save(on: app.db)
            _ = try await ResourceEvent.record(
                .restore, resourceKind: .sandbox, resourceID: sourceID,
                actor: .user(userID), on: app.db)

            // ...then a stop lands on top of it, making `.shutdown` the newest
            // recorded mutation while the restore is still unapplied.
            source.setFixtureDesiredStatus(.stopped)
            try await source.save(on: app.db)
            _ = try await ResourceEvent.record(
                .shutdown, resourceKind: .sandbox, resourceID: sourceID,
                actor: .user(userID), on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "fork-behind-superseded-restore",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("being restored in place"))
            }
        }
    }

    /// The other half of the restore guard: it has to *close*. The operation
    /// row it used to read closed when an RPC returned; the nonce closes when
    /// the agent reports the generation, which is the only signal that the
    /// source's rootfs has stopped moving.
    @Test("A converged restore stops blocking forks of the source")
    func createFromSnapshotAllowedOnceRestoreConverges() async throws {
        try await withSandboxTestApp { app, user, project, source, token in
            let agentId = try await registerAgent(
                app: app,
                sandbox: source,
                named: "restore-converged-agent",
                sandboxCapable: true)
            let snapshot = SandboxSnapshot(
                name: "converged-restore-checkpoint",
                sandboxID: source.id!,
                projectID: project.id!,
                environment: source.environment,
                agentId: agentId,
                createdByID: user.id!)
            snapshot.status = .ready
            snapshot.guestControlProtocolVersion =
                SandboxGuestControlProtocol.currentVersion
            snapshot.forkLayoutVersion = SandboxSnapshotForkLayout.currentVersion
            try await snapshot.save(on: app.db)

            source.setStatus(.running)
            source.requestFixtureRestore(snapshotID: snapshot.id!)
            // The agent applied the nonce and reported the generation back.
            source.observedGeneration = source.generation
            try await source.save(on: app.db)
            _ = try await ResourceEvent.record(
                .restore, resourceKind: .sandbox, resourceID: source.requireID(),
                actor: .user(try user.requireID()), on: app.db)

            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "fork-after-source-restore",
                    "restoreFrom": snapshot.id!.uuidString,
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
        }
    }

    @Test("POST /api/sandboxes rejects an empty image reference")
    func createRejectsEmptyImage() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "worker",
                    "image": "   ",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Lifecycle: 202 + dispatch failure recording

    @Test("POST /api/sandboxes/:id/start returns 202 and fails fast without an agent")
    func startFailsFastWithoutAgent() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            var mutationId: UUID?

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                let body = try res.content.decode(AcceptedSandbox.self)
                #expect(body.resource.id == sandbox.id)
                #expect(!body.resource.conditions.converged)
                mutationId = body.mutationId
            }

            // No agent is mapped, so the background dispatch degrades the
            // sandbox and realigns desired state with observed.
            _ = mutationId

            for _ in 0..<100 {
                if let refreshed = try await Sandbox.find(sandbox.id, on: app.db),
                    refreshed.desiredStatus == .stopped
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.desiredStatus == .stopped)
            #expect(refreshed.conditions.degraded?.reason.isEmpty == false)
        }
    }

    @Test("POST start is rejected (400) while the sandbox is running")
    func startRejectedWhileRunning() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            sandbox.setStatus(.running)
            try await sandbox.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    /// `Error` means the agent could not confirm the sandbox, which very often
    /// means its guest is still running — a failed checkpoint used to land one
    /// there while the microVM kept serving. Refusing the stop left deletion as
    /// the only way out (STR-194); the start guard already made this exception.
    @Test("POST stop is accepted for a sandbox whose state could not be confirmed")
    func stopAcceptedWhileErrored() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            sandbox.setStatus(.error)
            try await sandbox.save(on: app.db)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/stop") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let shutdown = try await ResourceEvent.latest(
                .requested, resourceKind: .sandbox, resourceID: sandbox.id!, on: app.db)
            #expect(shutdown?.mutation == .shutdown)
        }
    }

    @Test("A pending snapshot operation no longer blocks a lifecycle mutation")
    func pendingOperationDoesNotBlockLifecycleMutation() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, token in
            // Running, so the stop below passes its state guard.
            sandbox.setStatus(.running)
            try await sandbox.save(on: app.db)

            // A mutation in flight: desired state moved and the agent has not
            // confirmed it, which is what the operation mutex used to key on.
            sandbox.setFixtureDesiredStatus(.running)
            sandbox.extendConvergenceDeadline(by: 600)
            try await sandbox.save(on: app.db)

            // The double-submit `409` went with the operation row (STR-147):
            // desired state is level-triggered, so the stop is accepted and the
            // agent converges on whichever write lands last.
            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/stop") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }

            let shutdown = try await ResourceEvent.latest(
                .requested, resourceKind: .sandbox, resourceID: sandbox.id!, on: app.db)
            #expect(shutdown?.mutation == .shutdown)
        }
    }

    @Test("DELETE without an agent removes the record and appends its terminal event")
    func deleteWithoutAgentRemovesRecord() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, token in
            let sandboxID = try sandbox.requireID()

            // The creator binding sandbox creation writes, plus a snapshot
            // whose row cascades away with the sandbox and so orphans its own
            // binding (STR-112).
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .sandbox, nodeID: sandboxID, createdBy: user.id!, on: app.db)
            let snapshot = SandboxSnapshot(
                name: "snap", sandboxID: sandboxID, projectID: sandbox.$project.id,
                environment: sandbox.environment, agentId: nil, createdByID: user.id!)
            try await snapshot.save(on: app.db)
            let snapshotID = try snapshot.requireID()
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .sandboxSnapshot, nodeID: snapshotID, createdBy: user.id!, on: app.db)

            var mutationId: UUID?
            try await app.test(.DELETE, "/api/sandboxes/\(sandboxID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
                mutationId = try res.content.decode(AcceptedSandbox.self).mutationId
            }

            try await self.pollSandboxRemoved(sandboxID, on: app.db)
            let gone = try await Sandbox.find(sandboxID, on: app.db)
            #expect(gone == nil)

            // The reap's terminal event is what lets the façade answer a delete
            // after the row it names is gone (STR-147).
            try await app.test(.GET, "/api/operations/\(mutationId!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operation = try res.content.decode(OperationResponse.self)
                #expect(operation.status == .succeeded)
                #expect(operation.kind == .delete)
            }

            let sandboxBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.sandbox.rawValue)
                .filter(\.$nodeID == sandboxID)
                .count()
            #expect(sandboxBindings == 0)
            let snapshotBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.sandboxSnapshot.rawValue)
                .filter(\.$nodeID == snapshotID)
                .count()
            #expect(snapshotBindings == 0)
        }
    }

    @Test("GET /api/operations/:id resolves sandbox operations")
    func operationVisibility() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, token in
            let event = try await ResourceEvent.record(
                .boot, resourceKind: .sandbox, resourceID: try sandbox.requireID(),
                actor: .user(try user.requireID()), on: app.db)

            try await app.test(.GET, "/api/operations/\(try event.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let decoded = try res.content.decode(OperationResponse.self)
                #expect(decoded.resourceKind == .sandbox)
                #expect(decoded.resourceId == sandbox.id)
            }
        }
    }

    @Test("GET /api/sandboxes/:id/operations lists newest first and honors limit")
    func listOperationsNewestFirst() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, token in
            let sandboxID = try sandbox.requireID()
            let userID = try user.requireID()
            // Recorded in order and never rewritten: `resource_events` is
            // append-only (its trigger rejects an `UPDATE`), so the insert
            // order is the only way to age one row relative to another.
            _ = try await ResourceEvent.record(
                .boot, resourceKind: .sandbox, resourceID: sandboxID, actor: .user(userID), on: app.db)
            let newer = try await ResourceEvent.record(
                .shutdown, resourceKind: .sandbox, resourceID: sandboxID, actor: .user(userID), on: app.db)

            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!)/operations?limit=1") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let operations = try res.content.decode([OperationResponse].self)
                #expect(operations.count == 1)
                #expect(operations.first?.id == newer.id)
            }

            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!)/operations?limit=abc") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("DELETE /api/projects/:id is rejected (409) while sandboxes exist")
    func projectDeleteBlockedBySandboxes() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            // The sandboxes table references projects, so without the
            // dependent-resource check this would surface as a raw database
            // constraint failure instead of a deterministic conflict.
            try await app.test(.DELETE, "/api/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("Environment removal is rejected (409) while sandboxes use it")
    func environmentRemovalBlockedBySandboxes() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, token in
            // Move the sandbox off the default environment so the requests
            // below reach the sandbox guard (the default is unremovable, and
            // no VMs exist to trip the VM guard first).
            sandbox.environment = "staging"
            try await sandbox.save(on: app.db)

            try await app.test(.DELETE, "/api/projects/\(project.id!)/environments/staging") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            struct UpdateProjectRequest: Content {
                let environments: [String]
            }
            try await app.test(.PUT, "/api/projects/\(project.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateProjectRequest(environments: ["development", "production"]))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    // MARK: - Authorization

    @Test("GET /api/sandboxes/:id is denied (403) when no binding grants read")
    func showDeniedWhenNoPermission() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let outsider = try await TestDataBuilder(db: app.db).createUser(
                username: "sandbox-outsider", email: "sandbox-outsider@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)

            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("POST /api/sandboxes/:id/start is denied (403) when no binding grants start")
    func startDeniedWhenNoPermission() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let outsider = try await TestDataBuilder(db: app.db).createUser(
                username: "sandbox-outsider2", email: "sandbox-outsider2@example.com")
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/sandboxes/\(sandbox.id!)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("GET /api/sandboxes/:id succeeds and carries the sandbox shape")
    func showAllowedWhenPermitted() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, token in
            try await app.test(.GET, "/api/sandboxes/\(sandbox.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(SandboxDetailResponse.self)
                #expect(detail.image == "ghcr.io/acme/worker:v1")
                #expect(detail.status == .stopped)
            }
        }
    }

    // MARK: - Desired-state sync assembly

    @Test("the desired-state assembly carries the agent's sandboxes")
    func assemblyIncludesSandboxes() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setFixtureDesiredStatus(.running)
            try await sandbox.save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(message.sandboxes.count == 1)
            let entry = try #require(message.sandboxes.first)
            #expect(entry.sandboxId == sandbox.id)
            #expect(entry.desiredStatus == .running)
            #expect(entry.generation == sandbox.generation)
            #expect(entry.spec.image == "ghcr.io/acme/worker:v1")
            #expect(entry.spec.cpus == 1)
            #expect(entry.registryCredential == nil)
        }
    }

    // MARK: - NIC + IPAM integration (issue #416)

    /// A network in the sandbox's project (`192.168.1.0/24`, gateway `.1`,
    /// v4-only), created on first use. Nothing provisions one with a project
    /// (issue #765), so a sandbox only gets a NIC when the caller names one.
    /// A ready, fork-eligible checkpoint of `source`: current guest control
    /// protocol, current fork layout, pinned to `agentId`. Tests that probe a
    /// single gate override the one field they are about.
    private func readySnapshot(
        named name: String, source: Sandbox, project: Project, user: User, agentId: String?,
        on db: any Database
    ) async throws -> SandboxSnapshot {
        let snapshot = SandboxSnapshot(
            name: name,
            sandboxID: source.id!,
            projectID: project.id!,
            environment: source.environment,
            agentId: agentId,
            createdByID: user.id!)
        snapshot.status = .ready
        snapshot.architecture = CPUArchitecture.current.rawValue
        snapshot.guestControlProtocolVersion = SandboxGuestControlProtocol.currentVersion
        snapshot.forkLayoutVersion = SandboxSnapshotForkLayout.currentVersion
        try await snapshot.save(on: db)
        return snapshot
    }

    private func projectNetwork(project: Project, on db: any Database) async throws -> LogicalNetwork {
        if let existing = try await LogicalNetwork.query(on: db)
            .filter(\.$project.$id == project.requireID())
            .filter(\.$name == "default")
            .first()
        {
            return existing
        }
        return try await TestDataBuilder(db: db).createNetwork(name: "default", project: project)
    }

    @Test("Creating a sandbox on a named network allocates one NIC with an IPv4 address")
    func createAllocatesNIC() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            let network = try await self.projectNetwork(project: project, on: app.db)

            var accepted: AcceptedSandbox?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "netbox",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                    "networkId": try network.requireID().uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedSandbox.self)
            }

            let sandboxID = try #require(accepted?.resource.id)
            let interfaces = try await SandboxNetworkInterface.query(on: app.db)
                .filter(\.$sandbox.$id == sandboxID)
                .with(\.$addresses)
                .all()
            #expect(interfaces.count == 1)
            let nic = try #require(interfaces.first)
            #expect(nic.logicalNetworkID == network.id)
            #expect(nic.deviceName == "net0")
            #expect(nic.macAddress.hasPrefix("00:0c:29:"))

            let v4 = try #require(nic.ipv4Address)
            #expect(v4.address == "192.168.1.2")  // .1 is the gateway
            #expect(v4.gateway == "192.168.1.1")
            #expect(v4.prefixLength == 24)
        }
    }

    @Test("Naming no network creates the sandbox with no NIC at all")
    func createWithoutNetworkAttachesNoNIC() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            // Sandbox guest networking does not exist yet, so a sandbox in a
            // project with no network — or one whose caller named none — is
            // created without a NIC rather than refused (issue #765). No
            // phantom address is reserved.
            var accepted: AcceptedSandbox?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "netless",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedSandbox.self)
            }

            let sandboxID = try #require(accepted?.resource.id)
            let interfaces = try await SandboxNetworkInterface.query(on: app.db)
                .filter(\.$sandbox.$id == sandboxID)
                .all()
            #expect(interfaces.isEmpty)
        }
    }

    @Test("IPAM's used set unions VM and sandbox addresses on the same network")
    func ipamUnionsVMAndSandboxAddresses() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, _ in
            let network = try await self.projectNetwork(project: project, on: app.db)

            // A VM holds .2 and a sandbox holds .3 on the same network. The next
            // allocation must skip both — proving the used set unions the two
            // address tables.
            let vm = try await TestDataBuilder(db: app.db).createVM(name: "peer-vm", project: project)
            let vmNIC = VMNetworkInterface(
                vmID: try vm.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: VMNetworkInterface.generateMACAddress())
            try await vmNIC.save(on: app.db)
            try await VMInterfaceAddress(
                interfaceID: try vmNIC.requireID(), logicalNetworkID: try network.requireID(), family: .ipv4,
                address: "192.168.1.2", prefixLength: 24, gateway: network.gateway
            ).save(on: app.db)

            let sbNIC = SandboxNetworkInterface(
                sandboxID: try sandbox.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: VMNetworkInterface.generateMACAddress())
            try await sbNIC.save(on: app.db)
            try await SandboxInterfaceAddress(
                interfaceID: try sbNIC.requireID(), logicalNetworkID: try network.requireID(), family: .ipv4,
                address: "192.168.1.3", prefixLength: 24, gateway: network.gateway
            ).save(on: app.db)

            let allocation = try await IPAMService.allocateIP(for: network, on: app.db)
            #expect(allocation.ipAddress == "192.168.1.4")
        }
    }

    @Test("the desired-state assembly puts a NIC on the wire for a sandbox-networking agent")
    func assemblyCarriesNICSpecForCapableAgent() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, _ in
            let network = try await self.projectNetwork(project: project, on: app.db)
            let agentId = try await self.registerAgent(
                app: app, sandbox: sandbox, sandboxCapable: true, sandboxNetworkingCapable: true)

            // Attach a NIC with an allocated address directly.
            let nic = SandboxNetworkInterface(
                sandboxID: try sandbox.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: "00:0c:29:ab:cd:ef")
            try await nic.save(on: app.db)
            try await SandboxInterfaceAddress(
                interfaceID: try nic.requireID(), logicalNetworkID: try network.requireID(), family: .ipv4,
                address: "192.168.1.7", prefixLength: 24, gateway: network.gateway
            ).save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(message.sandboxes.first)
            let spec = try #require(entry.spec.network)
            #expect(spec.macAddress == "00:0c:29:ab:cd:ef")
            #expect(spec.ipAddress == "192.168.1.7")
            #expect(spec.network == network.name)

            // The sandbox's network is realized on its host too.
            #expect(message.networks.contains { $0.name == network.name })
        }
    }

    /// The upgrade hazard STR-103 exists for. Sandbox NICs have been allocated
    /// control-plane-side since #416 while never reaching the wire, so a
    /// control plane that shipped them to every agent at once would hand a NIC
    /// to hosts whose guest image predates the config drive's `network` block —
    /// failing every sandbox create there, permanently.
    @Test("the assembly withholds the NIC from an agent that does not advertise sandbox networking")
    func assemblyWithholdsNICFromIncapableAgent() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, _ in
            let network = try await self.projectNetwork(project: project, on: app.db)
            let agentId = try await self.registerAgent(
                app: app, sandbox: sandbox, sandboxCapable: true, sandboxNetworkingCapable: nil)

            let nic = SandboxNetworkInterface(
                sandboxID: try sandbox.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: "00:0c:29:ab:cd:ee")
            try await nic.save(on: app.db)
            try await SandboxInterfaceAddress(
                interfaceID: try nic.requireID(), logicalNetworkID: try network.requireID(), family: .ipv4,
                address: "192.168.1.8", prefixLength: 24, gateway: network.gateway
            ).save(on: app.db)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(message.sandboxes.first)
            #expect(entry.spec.network == nil)
            // The sandbox itself is still desired state; only its NIC is held back.
            #expect(entry.sandboxId == sandbox.id)
        }
    }

    @Test("A freshly created sandbox converges with the NIC its create reserved")
    func createdSandboxWireSpecCarriesItsNetwork() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            let network = try await self.projectNetwork(project: project, on: app.db)
            var accepted: AcceptedSandbox?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "bootable",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                    "networkId": try network.requireID().uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedSandbox.self)
            }
            let sandboxID = try #require(accepted?.resource.id)
            // Drain the background placement attempt (it fails — no
            // sandbox-capable agent is registered yet) so its save cannot race
            // the manual placement below.
            try await self.pollSandboxDegraded(sandboxID, on: app.db)
            let created = try #require(await Sandbox.find(sandboxID, on: app.db))
            let agentId = try await self.registerAgent(
                app: app, sandbox: created, sandboxCapable: true, sandboxNetworkingCapable: true)

            let message = try await app.desiredStateAssembler.assemble(agentId: agentId)
            let entry = try #require(message.sandboxes.first { $0.sandboxId == sandboxID })
            let spec = try #require(entry.spec.network)

            let nic = try #require(
                await SandboxNetworkInterface.query(on: app.db)
                    .filter(\.$sandbox.$id == sandboxID)
                    .with(\.$addresses)
                    .first())
            #expect(spec.ipAddress == nic.ipv4Address?.address)
            // The default group the create transaction attached rides with it,
            // so the port is filtered from the moment it exists (STR-102).
            #expect(spec.securityGroupIds?.isEmpty == false)
        }
    }

    /// Both sides of the seam: the per-agent gate is the outermost check, and
    /// the mapping underneath it carries the security-group ids — otherwise a
    /// sandbox port would come up unmanaged, the one outcome STR-102 prevents.
    @Test("Security-group ids reach a sandbox NIC's wire spec, and the per-agent gate still withholds it")
    func sandboxNICSpecCarriesSecurityGroups() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, _ in
            let network = try await self.projectNetwork(project: project, on: app.db)
            let nic = SandboxNetworkInterface(
                sandboxID: try sandbox.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: "00:0c:29:ab:cd:11")
            try await nic.save(on: app.db)
            try await SandboxInterfaceAddress(
                interfaceID: try nic.requireID(), logicalNetworkID: try network.requireID(), family: .ipv4,
                address: "192.168.1.9", prefixLength: 24, gateway: network.gateway
            ).save(on: app.db)
            try await nic.$addresses.load(on: app.db)

            let groupIDs = [UUID(), UUID()]
            // The gate is the outermost check: ids or no ids.
            #expect(
                SandboxSpecBuilder.networkSpec(
                    from: nic, network: network, securityGroupIds: groupIDs,
                    agentRealizesSandboxNICs: false) == nil)

            let spec = try #require(
                SandboxSpecBuilder.networkSpec(
                    from: nic, network: network, securityGroupIds: groupIDs,
                    agentRealizesSandboxNICs: true))
            #expect(spec.securityGroupIds == groupIDs)
            #expect(spec.macAddress == nic.macAddress)
            #expect(spec.ipAddress == "192.168.1.9")
            // Nil stays nil: "unmanaged", never "no groups".
            #expect(
                SandboxSpecBuilder.networkSpec(
                    from: nic, network: network, agentRealizesSandboxNICs: true)?.securityGroupIds == nil)
        }
    }

    @Test("A sandbox's NIC response carries its network, addresses and groups")
    func sandboxDetailReportsNIC() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            let network = try await self.projectNetwork(project: project, on: app.db)
            var accepted: AcceptedSandbox?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "nic-detail",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                    "networkId": try network.requireID().uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .accepted)
                accepted = try res.content.decode(AcceptedSandbox.self)
            }
            let sandboxID = try #require(accepted?.resource.id)
            try await self.pollSandboxDegraded(sandboxID, on: app.db)

            try await app.test(.GET, "/api/sandboxes/\(sandboxID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(SandboxDetailResponse.self)
                let reported = try #require(detail.networkInterfaces.first)
                #expect(reported.networkId == (try network.requireID()))
                #expect(reported.network == network.name)
                #expect(reported.deviceName == "net0")
                #expect(reported.addresses.contains { $0.family == "ipv4" })
                // Create attached the project's default group, so this is
                // exactly one id — and non-nil, which is the load-bearing half:
                // nil would mean the handler forgot to eager-load membership.
                let ids = try #require(reported.securityGroupIds)
                #expect(ids.count == 1)
                #expect(detail.securityGroupIds == ids)
            }
        }
    }

    /// The flat `securityGroupIds` and the `networkInterfaces` list must agree
    /// about which interface is the sandbox's first. They are derived from one
    /// ordering, but nothing in the types enforces it, and v1's single NIC hides
    /// a disagreement — so pin it against a second interface whose insertion
    /// order is the reverse of its device name.
    @Test("The flat security-group ids come from the same NIC the list orders first")
    func sandboxDetailFlatIDsMatchFirstOrderedNIC() async throws {
        try await withSandboxTestApp { app, _, project, sandbox, _ in
            let network = try await self.projectNetwork(project: project, on: app.db)
            let defaultGroup = try await SecurityGroupService.ensureDefaultGroup(
                projectID: try project.requireID(), on: app.db)
            let other = SecurityGroup(
                projectID: try project.requireID(), name: "sbx-second", description: nil)
            try await other.save(on: app.db)

            // Saved net1 first, so insertion order and device-name order differ.
            for (deviceName, group) in [("net1", other), ("net0", defaultGroup)] {
                let nic = SandboxNetworkInterface(
                    sandboxID: try sandbox.requireID(), logicalNetworkID: try network.requireID(),
                    macAddress: VMNetworkInterface.generateMACAddress(), deviceName: deviceName)
                try await nic.save(on: app.db)
                try await SandboxInterfaceSecurityGroup(
                    interfaceID: try nic.requireID(), securityGroupID: try group.requireID()
                ).save(on: app.db)
            }

            try await sandbox.$networkInterfaces.load(on: app.db)
            for interface in sandbox.networkInterfaces {
                try await interface.$securityGroupMemberships.load(on: app.db)
            }
            let detail = SandboxDetailResponse(from: sandbox)
            #expect(detail.networkInterfaces.map(\.deviceName) == ["net0", "net1"])
            #expect(detail.securityGroupIds == [try defaultGroup.requireID()])
            #expect(detail.securityGroupIds == detail.networkInterfaces.first?.securityGroupIds)
        }
    }

    @Test("Deleting a sandbox cascades its NIC and address rows")
    func deleteCascadesNIC() async throws {
        try await withSandboxTestApp { app, _, project, _, token in
            let network = try await self.projectNetwork(project: project, on: app.db)
            var accepted: AcceptedSandbox?
            try await app.test(.POST, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode([
                    "name": "doomed",
                    "image": "ghcr.io/acme/worker:v3",
                    "projectId": project.id!.uuidString,
                    "networkId": try network.requireID().uuidString,
                ])
            } afterResponse: { res in
                accepted = try res.content.decode(AcceptedSandbox.self)
            }
            let sandboxID = try #require(accepted?.resource.id)

            // Sanity: rows exist before deletion.
            let nicIDs = try await SandboxNetworkInterface.query(on: app.db)
                .filter(\.$sandbox.$id == sandboxID).all().map { try $0.requireID() }
            #expect(nicIDs.count == 1)

            let sandbox = try #require(await Sandbox.find(sandboxID, on: app.db))
            try await sandbox.delete(on: app.db)

            let remainingNICs = try await SandboxNetworkInterface.query(on: app.db)
                .filter(\.$sandbox.$id == sandboxID).count()
            #expect(remainingNICs == 0)
            let remainingAddresses = try await SandboxInterfaceAddress.query(on: app.db)
                .filter(\.$interface.$id ~~ nicIDs).count()
            #expect(remainingAddresses == 0)
        }
    }

    // MARK: - Observed-state reports

    @Test("A converged observation completes the pending boot operation")
    func observedRunningCompletesBoot() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setFixtureDesiredStatus(.running)
            sandbox.extendConvergenceDeadline(by: 600)
            try await sandbox.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                sandboxes: [
                    ObservedSandboxState(
                        sandboxId: sandbox.id!, status: .running,
                        observedGeneration: sandbox.generation)
                ])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("sandbox-agent"))

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.status == .running)
            #expect(refreshed.observedGeneration == sandbox.generation)
            #expect(refreshed.conditions.converged)
            // Converged means nothing is outstanding, so there is no deadline
            // left for the stuck-convergence sweep to judge.
            #expect(refreshed.convergenceDeadline == nil)
        }
    }

    @Test("An exited observation satisfies desired running and records the exit code")
    func observedExitedSatisfiesRunning() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setFixtureDesiredStatus(.running)
            try await sandbox.save(on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                sandboxes: [
                    ObservedSandboxState(
                        sandboxId: sandbox.id!, status: .exited,
                        observedGeneration: sandbox.generation, exitCode: 0)
                ])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("sandbox-agent"))

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.status == .exited)
            #expect(refreshed.exitCode == 0)
            #expect(refreshed.conditions.converged)
        }
    }

    @Test("A failed convergence at the current generation degrades the sandbox and reverts desired")
    func observedFailureDegradesSandbox() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setFixtureDesiredStatus(.running)
            sandbox.extendConvergenceDeadline(by: 600)
            try await sandbox.save(on: app.db)
            let generation = sandbox.generation
            _ = try await ResourceEvent.record(
                .boot, resourceKind: .sandbox, resourceID: sandbox.id!,
                actor: .user(user.id!), on: app.db)

            let envelope = try self.report(
                agentId: agentId,
                sandboxes: [
                    ObservedSandboxState(
                        sandboxId: sandbox.id!, status: .stopped,
                        observedGeneration: 0,
                        lastError: "image pull failed",
                        failedGeneration: generation)
                ])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("sandbox-agent"))

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            let degraded = try #require(refreshed.conditions.degraded)
            #expect(degraded.reason == "image pull failed")
            #expect(degraded.sinceGeneration == generation)
            #expect(refreshed.desiredStatus == .stopped)
            #expect(refreshed.convergenceDeadline == nil)
        }
    }

    @Test("Absence from the report confirms a pending deletion and removes the row")
    func absenceConfirmsDeletion() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            ResourceFinalizerService.stampForDeletion(sandbox)
            sandbox.setFixtureDesiredStatus(.absent)
            try await sandbox.save(on: app.db)
            let request = try await ResourceEvent.record(
                .delete, resourceKind: .sandbox, resourceID: sandbox.id!,
                actor: .user(user.id!), on: app.db)

            // The creator binding sandbox creation writes, plus a snapshot
            // whose row cascades away with the sandbox: bindings have no FK to
            // either, so the confirmed deletion has to drop both (STR-112) —
            // and the snapshot's only if the revoke reads it before the delete.
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .sandbox, nodeID: sandbox.id!, createdBy: user.id!, on: app.db)
            let snapshot = SandboxSnapshot(
                name: "snap", sandboxID: sandbox.id!, projectID: sandbox.$project.id,
                environment: sandbox.environment, agentId: agentId, createdByID: user.id!)
            try await snapshot.save(on: app.db)
            let snapshotID = try snapshot.requireID()
            try await RoleBindingService.grant(
                principalType: .user, principalID: user.id!, role: .admin,
                nodeType: .sandboxSnapshot, nodeID: snapshotID, createdBy: user.id!, on: app.db)

            let envelope = try self.report(agentId: agentId, sandboxes: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("sandbox-agent"))

            let gone = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(gone == nil)

            // The reap appended the terminal event the operations façade — and
            // any client polling a delete — reads as "done" (STR-147).
            let terminal = try #require(
                await ResourceEvent.latest(
                    .completed, resourceKind: .sandbox, resourceID: sandbox.id!, on: app.db))
            #expect(terminal.mutation == .delete)
            #expect(terminal.id != request.id)

            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.sandbox.rawValue)
                .filter(\.$nodeID == sandbox.id!)
                .count()
            #expect(bindings == 0)
            let snapshotBindings = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.sandboxSnapshot.rawValue)
                .filter(\.$nodeID == snapshotID)
                .count()
            #expect(snapshotBindings == 0)
        }
    }

    @Test("Absence does not escalate a never-confirmed sandbox")
    func absenceToleratesUnconfirmedCreate() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            // Mid-create: desired stopped at generation 1, never confirmed.
            sandbox.setFixtureDesiredStatus(.stopped)
            try await sandbox.save(on: app.db)

            let envelope = try self.report(agentId: agentId, sandboxes: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("sandbox-agent"))

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.status == .stopped)
        }
    }

    @Test("Absence escalates an established sandbox to error")
    func absenceEscalatesEstablishedSandbox() async throws {
        try await withSandboxTestApp { app, _, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            sandbox.setFixtureDesiredStatus(.running)
            sandbox.setStatus(.running)
            sandbox.observedGeneration = sandbox.generation
            try await sandbox.save(on: app.db)

            let envelope = try self.report(agentId: agentId, sandboxes: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("sandbox-agent"))

            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.status == .error)
        }
    }

    // MARK: - Stuck-convergence sweep

    /// The stuck-*operation* sweep this section used to exercise — failing a
    /// row past its per-kind budget, and erroring a transitional sandbox with
    /// no pending row — went with the table (STR-152). The deadline every
    /// accepted mutation stamps says the same thing without a cluster lock.
    @Test("A timed-out sandbox delete keeps converging on absent instead of resurrecting it")
    func sweepLeavesStuckDeleteConvergingOnAbsent() async throws {
        try await withSandboxTestApp { app, user, _, sandbox, _ in
            let agentId = try await self.registerAgent(app: app, sandbox: sandbox)

            // A delete leaves `status` non-transitional: the user deleted a
            // running sandbox and the agent has not reported the absence yet.
            sandbox.setStatus(.running)
            sandbox.setFixtureDesiredStatus(.absent)
            sandbox.convergenceDeadline = Date(timeIntervalSinceNow: -100)
            try await sandbox.save(on: app.db)
            _ = try await ResourceEvent.record(
                .delete, resourceKind: .sandbox, resourceID: try sandbox.requireID(),
                actor: .user(try user.requireID()), on: app.db)

            await app.agentService.sweepStuckConvergence()

            // The timeout must not abandon the deletion (issue #734) — a live
            // desired state would have the agent recreate a blank sandbox.
            let refreshed = try #require(await Sandbox.find(sandbox.id, on: app.db))
            #expect(refreshed.conditions.degraded?.sinceGeneration == sandbox.generation)
            #expect(refreshed.desiredStatus == .absent)
            #expect(refreshed.generation == sandbox.generation)

            // The agent returns and reports absence: the delete still lands.
            let envelope = try self.report(agentId: agentId, sandboxes: [])
            await app.agentService.applyObservedStateReport(envelope, fromAgentKey: agentKey("sandbox-agent"))

            let gone = try await Sandbox.find(sandbox.id, on: app.db)
            #expect(gone == nil)
        }
    }
}
