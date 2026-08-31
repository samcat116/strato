import Crypto
import Fluent
import Foundation
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

@Suite("External Ceph Storage Tests", .serialized)
final class CephStorageTests {
    private struct CreateVMBody: Content {
        let name: String
        let imageId: UUID
        let projectId: UUID
        let disk: Int64
        let poolId: UUID
        let networkName: String
        let hypervisorType: HypervisorType
    }

    private struct Fixture {
        let app: Application
        let builder: TestDataBuilder
        let user: User
        let organization: Organization
        let project: Project
        let site: Site
        let token: String
        let encryption: SecretsEncryptionService
    }

    private func withFixture(
        _ test: (Fixture) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            let encryption = SecretsEncryptionService(key: SymmetricKey(size: .bits256))
            app.secretsEncryption = encryption

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "ceph-admin", email: "ceph-admin@example.com",
                displayName: "Ceph Admin", isSystemAdmin: true)
            let organization = try await builder.createOrganization(name: "Ceph Org")
            user.currentOrganizationId = try organization.requireID()
            try await user.save(on: app.db)
            let project = try await builder.createProject(
                name: "Ceph Project", description: "External RBD", organization: organization)
            let site = try await builder.placementSite(for: project)
            let token = try await user.generateAPIKey(on: app.db)
            try await test(
                Fixture(
                    app: app, builder: builder, user: user, organization: organization,
                    project: project, site: site, token: token, encryption: encryption))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func clusterPath(_ fixture: Fixture) throws -> String {
        "/api/sites/\(try fixture.site.requireID())/ceph-cluster"
    }

    private func accessPath(_ fixture: Fixture, project: Project? = nil) throws -> String {
        "\(try clusterPath(fixture))/projects/\(try (project ?? fixture.project).requireID())"
    }

    @discardableResult
    private func registerCluster(_ fixture: Fixture) async throws -> CephClusterResponse {
        var created: CephClusterResponse?
        try await fixture.app.test(.POST, try clusterPath(fixture)) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            try req.content.encode(
                CreateExternalCephClusterRequest(
                    fsid: "8E77B2A2-C81F-42B6-8F88-5D5FDF54A62A",
                    monEndpoints: [
                        "v2:mon-a.example:3300", "v2:mon-a.example:3300",
                        "v2:[2001:db8::10]:3300",
                    ],
                    clientName: "client.strato-observer",
                    keyring: "[client.strato-observer]\nkey = observer-secret\n"))
        } afterResponse: { response in
            #expect(response.status == .created)
            #expect(!response.body.string.contains("observer-secret"))
            #expect(!response.body.string.contains("keyringSecretRef"))
            created = try response.content.decode(CephClusterResponse.self)
        }
        return try #require(created)
    }

    @discardableResult
    private func configureAccess(
        _ fixture: Fixture,
        project: Project? = nil,
        clientName: String = "client.project-a",
        keyring: String? = """
            [client.project-a]
            key = project-secret
            caps mon = "profile rbd"
            caps mgr = "profile rbd pool=rbd namespace=project-a"
            caps osd = "profile rbd pool=rbd namespace=project-a"
        """,
        poolName: String = "project-a-rbd",
        namespace: String = "project-a",
        cephxRevoked: Bool? = nil
    ) async throws -> CephProjectAccessResponse {
        var configured: CephProjectAccessResponse?
        try await fixture.app.test(.PUT, try accessPath(fixture, project: project)) { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            try req.content.encode(
                UpsertCephProjectAccessRequest(
                    clientName: clientName, keyring: keyring,
                    storagePoolName: poolName, cephPoolName: "rbd", namespace: namespace,
                    cephxRevoked: cephxRevoked))
        } afterResponse: { response in
            #expect(response.status == .ok)
            #expect(!response.body.string.contains("project-secret"))
            #expect(!response.body.string.contains("keyringSecretRef"))
            configured = try response.content.decode(CephProjectAccessResponse.self)
        }
        return try #require(configured)
    }

    private func runtimeCredentialID(
        _ access: CephProjectAccessResponse, fixture: Fixture
    ) async throws -> UUID {
        let accessID = try #require(access.id)
        return try #require(
            await CephProjectAccess.find(accessID, on: fixture.app.db)
        )
        .$keyringSecret.id
    }

    private func registerCephAgent(
        _ fixture: Fixture, name: String,
        hypervisorType: HypervisorType = .qemu,
        architecture: CPUArchitecture? = nil,
        cephCapable: Bool = true,
        availableDisk: Int64 = 1 << 40
    ) async throws -> String {
        let now = Date()
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: "\(name).example",
            version: "test",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: availableDisk),
            architecture: architecture,
            hypervisors: [
                HypervisorSupport(
                    type: hypervisorType, available: true, accelerated: true,
                    capabilities: HypervisorCapabilities.capabilities(for: hypervisorType))
            ],
            networkCapability: hypervisorType == .firecracker ? .overlay : .userMode,
            protocolVersion: WireProtocol.currentVersion,
            metadataServiceCapable: hypervisorType == .firecracker,
            dependencyObservations: (cephCapable
                ? [
                    NodeDependencyObservation(
                        id: .cephClient, role: .storage, desiredState: .required,
                        ownership: .observeOnly, supervisorState: .notApplicable,
                        compatibility: .compatible, functionalState: .healthy,
                        checkedAt: now, affectedCapabilities: [.cephVolumes])
                ] : [])
                + (hypervisorType == .qemu
                    ? [
                        NodeDependencyObservation(
                            id: .libvirt, role: .compute, desiredState: .required,
                            ownership: .observeOnly, supervisorState: .notApplicable,
                            compatibility: .compatible, functionalState: .healthy,
                            checkedAt: now, affectedCapabilities: [.qemuPlacement])
                    ] : [])
                + (hypervisorType == .firecracker
                    ? [
                        NodeDependencyObservation(
                            id: .ovnOvs, role: .networking, desiredState: .required,
                            ownership: .observeOnly, supervisorState: .active,
                            compatibility: .compatible, functionalState: .healthy,
                            checkedAt: now, affectedCapabilities: [.overlayNetworking])
                    ] : []))
        return try await fixture.app.agentService.registerAgent(
            message, agentName: name,
            siteID: try fixture.site.requireID(),
            organizationScope: .organization(try fixture.organization.requireID())
        ).uuidString
    }

    private func report(
        agentId: String, volumes: [ObservedVolumeState]?
    ) -> ObservedStateReport {
        ObservedStateReport(
            agentId: agentId, vms: [],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40),
            volumes: volumes)
    }

    @Test("Ceph credentials are encrypted, atomically rotated, and redacted from reads")
    func credentialsAreEncryptedAndRedacted() async throws {
        try await withFixture { fixture in
            let response = try await registerCluster(fixture)
            #expect(response.managed == false)
            #expect(response.hasCredential)
            #expect(response.monEndpoints == ["v2:mon-a.example:3300", "v2:[2001:db8::10]:3300"])

            let clusterID = try #require(response.id)
            let cluster = try #require(await CephCluster.find(clusterID, on: fixture.app.db))
            let observerSecretID = cluster.$keyringSecret.id
            let observerSecret = try #require(
                await StoredSecret.find(observerSecretID, on: fixture.app.db))
            #expect(observerSecret.encryptedValue.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            #expect(try fixture.encryption.decrypt(observerSecret.encryptedValue).contains("observer-secret"))

            try await fixture.app.test(.GET, try clusterPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { read in
                #expect(read.status == .ok)
                #expect(!read.body.string.contains("observer-secret"))
                #expect(!read.body.string.contains(observerSecretID.uuidString))
            }

            try await fixture.app.test(.PUT, try clusterPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    UpdateExternalCephClusterRequest(
                        monEndpoints: ["v2:mon-b.example:3300"],
                        clientName: "client.strato-observer",
                        keyring: "[client.strato-observer]\nkey = rotated-observer\n"))
            } afterResponse: { update in
                #expect(update.status == .ok)
                #expect(!update.body.string.contains("rotated-observer"))
            }
            let rotatedObserver = try #require(
                await StoredSecret.find(observerSecretID, on: fixture.app.db))
            #expect(try fixture.encryption.decrypt(rotatedObserver.encryptedValue).contains("rotated-observer"))

            let access = try await configureAccess(fixture)
            #expect(access.hasCredential)
            let accessID = try #require(access.id)
            let storedAccess = try #require(
                await CephProjectAccess.find(accessID, on: fixture.app.db))
            let projectSecretID = storedAccess.$keyringSecret.id
            let projectSecret = try #require(
                await StoredSecret.find(projectSecretID, on: fixture.app.db))
            #expect(projectSecret.encryptedValue.hasPrefix(SecretsEncryptionService.encryptedPrefix))
            #expect(try fixture.encryption.decrypt(projectSecret.encryptedValue).contains("project-secret"))

            fixture.app.secretsEncryption = .disabled
            try await fixture.app.test(.PUT, try accessPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    UpsertCephProjectAccessRequest(
                        clientName: "client.project-a",
                        keyring: """
                            [client.project-a]
                            key = plaintext-must-not-be-stored
                            caps mon = "profile rbd"
                            caps mgr = "profile rbd pool=rbd namespace=project-a"
                            caps osd = "profile rbd pool=rbd namespace=project-a"
                            """,
                        storagePoolName: "project-a-rbd", cephPoolName: "rbd",
                        namespace: "project-a"))
            } afterResponse: { rejected in
                #expect(rejected.status == .serviceUnavailable)
            }
            fixture.app.secretsEncryption = fixture.encryption
            let unrotatedProjectSecret = try #require(
                await StoredSecret.find(projectSecretID, on: fixture.app.db))
            #expect(
                try fixture.encryption.decrypt(unrotatedProjectSecret.encryptedValue)
                    .contains("project-secret"))

            // Metadata-only updates retain the exact credential indirection.
            let updated = try await configureAccess(
                fixture, keyring: nil, poolName: "project-a-rbd-renamed")
            #expect(updated.storagePool.name == "project-a-rbd-renamed")
            let reloadedAccess = try #require(
                await CephProjectAccess.find(accessID, on: fixture.app.db))
            #expect(reloadedAccess.$keyringSecret.id == projectSecretID)

            let rotatedProjectKeyring = """
                [client.project-a]
                key = rotated-project-secret
                caps mon = "profile rbd"
                caps mgr = "profile rbd pool=rbd namespace=project-a"
                caps osd = "profile rbd pool=rbd namespace=project-a"
                """
            try await fixture.app.test(.PUT, try accessPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    UpsertCephProjectAccessRequest(
                        clientName: "client.project-a", keyring: rotatedProjectKeyring,
                        storagePoolName: "project-a-rbd-renamed", cephPoolName: "rbd",
                        namespace: "project-a"))
            } afterResponse: { rejected in
                #expect(rejected.status == .badRequest)
                #expect(rejected.body.string.contains("cephxRevoked"))
            }
            #expect(try await CephCredentialRevocation.query(on: fixture.app.db).count() == 0)

            let agentID = try await registerCephAgent(fixture, name: "credential-cleanup-client")
            _ = try await configureAccess(
                fixture, keyring: rotatedProjectKeyring,
                poolName: "project-a-rbd-renamed", cephxRevoked: true)
            let rotatedAccess = try #require(
                await CephProjectAccess.find(accessID, on: fixture.app.db))
            let rotatedSecretID = rotatedAccess.$keyringSecret.id
            #expect(rotatedSecretID != projectSecretID)
            let removedProjectSecret = try await StoredSecret.find(
                projectSecretID, on: fixture.app.db)
            #expect(removedProjectSecret == nil)
            let rotatedSecret = try #require(
                await StoredSecret.find(rotatedSecretID, on: fixture.app.db))
            #expect(
                try fixture.encryption.decrypt(rotatedSecret.encryptedValue)
                    .contains("rotated-project-secret"))
            let revocation = try #require(
                await CephCredentialRevocation.query(on: fixture.app.db).first())
            #expect(revocation.clusterID == clusterID)
            #expect(revocation.credentialID == projectSecretID)
            let desired = try await fixture.app.desiredStateAssembler.assemble(agentId: agentID)
            #expect(
                desired.cephCredentialRevocations
                    == [
                        DesiredCephCredentialRevocation(
                            clusterId: clusterID, credentialId: projectSecretID)
                    ])

            try await fixture.app.test(.GET, try accessPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { read in
                #expect(read.status == .ok)
                #expect(!read.body.string.contains("project-secret"))
                #expect(!read.body.string.contains(projectSecretID.uuidString))
                #expect(!read.body.string.contains(rotatedSecretID.uuidString))
            }

            try await fixture.app.test(
                .GET, "/api/projects/\(try fixture.project.requireID())/storage-pools"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { listed in
                #expect(listed.status == .ok)
                let pools = try listed.content.decode([StoragePoolResponse].self)
                #expect(pools.map(\.mode) == [.local, .ceph])
            }
        }
    }

    @Test("Ceph access deletion requires upstream revocation and tombstones survive until site deletion")
    func credentialRevocationLifecycle() async throws {
        try await withFixture { fixture in
            let cluster = try await registerCluster(fixture)
            let access = try await configureAccess(fixture)
            let clusterID = try #require(cluster.id)
            let credentialID = try await runtimeCredentialID(access, fixture: fixture)

            try await fixture.app.test(.DELETE, try accessPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { response in
                #expect(response.status == .badRequest)
                #expect(response.body.string.contains("cephxRevoked=true"))
            }
            let accessBeforeConfirmedRevocation = try await CephProjectAccess.find(
                access.id, on: fixture.app.db)
            let secretBeforeConfirmedRevocation = try await StoredSecret.find(
                credentialID, on: fixture.app.db)
            #expect(accessBeforeConfirmedRevocation != nil)
            #expect(secretBeforeConfirmedRevocation != nil)

            try await fixture.app.test(
                .DELETE, "\(try accessPath(fixture))?cephxRevoked=true"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { response in
                #expect(response.status == .noContent)
            }
            let removedAccess = try await CephProjectAccess.find(access.id, on: fixture.app.db)
            let removedPool = try await StoragePool.find(
                access.storagePool.id, on: fixture.app.db)
            let removedCredential = try await StoredSecret.find(
                credentialID, on: fixture.app.db)
            #expect(removedAccess == nil)
            #expect(removedPool == nil)
            #expect(removedCredential == nil)
            let tombstone = try #require(
                await CephCredentialRevocation.query(on: fixture.app.db).first())
            #expect(tombstone.clusterID == clusterID)
            #expect(tombstone.credentialID == credentialID)

            try await fixture.app.test(.DELETE, try clusterPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { response in
                #expect(response.status == .noContent)
            }
            #expect(try await CephCredentialRevocation.query(on: fixture.app.db).count() == 1)

            try await fixture.app.test(
                .DELETE, "/api/sites/\(try fixture.site.requireID())"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { response in
                #expect(response.status == .noContent)
            }
            #expect(try await CephCredentialRevocation.query(on: fixture.app.db).count() == 0)
        }
    }

    @Test("Ceph input validation and tenant identities fail closed")
    func tenantValidationAndUniqueness() async throws {
        try await withFixture { fixture in
            fixture.app.secretsEncryption = .disabled
            try await fixture.app.test(.POST, try clusterPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    CreateExternalCephClusterRequest(
                        fsid: UUID().uuidString,
                        monEndpoints: ["v2:mon.example:3300"],
                        clientName: "client.observer",
                        keyring: "[client.observer]\nkey = plaintext-must-not-be-stored\n"))
            } afterResponse: { response in
                #expect(response.status == .serviceUnavailable)
                #expect(response.body.string.contains("STRATO_SECRET_ENCRYPTION_KEY"))
            }
            #expect(try await CephCluster.query(on: fixture.app.db).count() == 0)
            #expect(try await StoredSecret.query(on: fixture.app.db).count() == 0)
            fixture.app.secretsEncryption = fixture.encryption

            for endpoint in ["v2:<bad>:3300", "v2:[not-an-ipv6]:3300", "v2:[2001:db8::1]3300"] {
                try await fixture.app.test(.POST, try clusterPath(fixture)) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        CreateExternalCephClusterRequest(
                            fsid: UUID().uuidString, monEndpoints: [endpoint],
                            clientName: "client.observer",
                            keyring: "[client.observer]\nkey = secret\n"))
                } afterResponse: { response in
                    #expect(response.status == .badRequest)
                }
            }

            _ = try await registerCluster(fixture)

            for unsafeKeyring in [
                "[client.project-a]\nkey = missing-cap\n",
                """
                [client.project-a]
                key = broad-cap
                caps mon = "allow *"
                caps mgr = "profile rbd pool=rbd namespace=project-a"
                caps osd = "profile rbd pool=rbd namespace=project-a"
                """,
                """
                [client.project-a]
                key = multiple-caps
                caps mon = "profile rbd"
                caps mgr = "profile rbd pool=rbd namespace=project-a"
                caps osd = "profile rbd pool=rbd namespace=project-a"
                caps osd = "profile rbd pool=rbd namespace=another-project"
                """,
                """
                [client.project-a]
                key = extra-service-cap
                caps mon = "profile rbd"
                caps mgr = "profile rbd pool=rbd namespace=project-a"
                caps osd = "profile rbd pool=rbd namespace=project-a"
                caps mds = "allow *"
                """,
            ] {
                try await fixture.app.test(.PUT, try accessPath(fixture)) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        UpsertCephProjectAccessRequest(
                            clientName: "client.project-a", keyring: unsafeKeyring,
                            storagePoolName: "unsafe", cephPoolName: "rbd",
                            namespace: "project-a"))
                } afterResponse: { response in
                    #expect(response.status == .badRequest)
                }
            }

            _ = try await configureAccess(fixture)
            try await fixture.app.test(.PUT, try accessPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    UpsertCephProjectAccessRequest(
                        clientName: "client.project-a", keyring: nil,
                        storagePoolName: "project-a-rbd", cephPoolName: "rbd",
                        namespace: "project-a-moved"))
            } afterResponse: { response in
                #expect(response.status == .badRequest)
            }
            let otherProject = try await fixture.builder.createProject(
                name: "Other Ceph Project", description: "tenant B",
                organization: fixture.organization)

            for attempt in [
                ("client.project-a", "project-b"),
                ("client.strato-observer", "project-c"),
            ] {
                try await fixture.app.test(
                    .PUT, try accessPath(fixture, project: otherProject)
                ) { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        UpsertCephProjectAccessRequest(
                            clientName: attempt.0,
                            keyring: """
                                [\(attempt.0)]
                                key = other-secret
                                caps mon = "profile rbd"
                                caps mgr = "profile rbd pool=rbd namespace=\(attempt.1)"
                                caps osd = "profile rbd pool=rbd namespace=\(attempt.1)"
                                """,
                            storagePoolName: "other-\(attempt.1)", cephPoolName: "rbd",
                            namespace: attempt.1))
                } afterResponse: { response in
                    #expect(response.status == .conflict)
                }
            }

            try await fixture.app.test(
                .PUT, try accessPath(fixture, project: otherProject)
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    UpsertCephProjectAccessRequest(
                        clientName: "client.project-b",
                        keyring: "[client.someone-else]\nkey = other-secret\n",
                        storagePoolName: "other", cephPoolName: "rbd", namespace: "project-b"))
            } afterResponse: { response in
                #expect(response.status == .badRequest)
            }

            try await fixture.app.test(
                .PUT, try accessPath(fixture, project: otherProject)
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    UpsertCephProjectAccessRequest(
                        clientName: "client.project-b",
                        keyring: """
                            [client.project-b]
                            key = other-secret
                            caps mon = "profile rbd"
                            caps mgr = "profile rbd pool=rbd namespace=project-a"
                            caps osd = "profile rbd pool=rbd namespace=project-a"
                            """,
                        storagePoolName: "other", cephPoolName: "rbd", namespace: "project-a"))
            } afterResponse: { response in
                #expect(response.status == .conflict)
            }

            // Failed validation and uniqueness checks must not strand secrets.
            #expect(try await StoredSecret.query(on: fixture.app.db).count() == 2)
        }
    }

    @Test("Projects with Ceph access cannot be transferred or deleted")
    func projectLifecycleIsGuarded() async throws {
        try await withFixture { fixture in
            _ = try await registerCluster(fixture)
            _ = try await configureAccess(fixture)
            let destination = try await fixture.builder.createOrganization(name: "Ceph Destination")

            try await fixture.app.test(
                .POST, "/api/projects/\(try fixture.project.requireID())/transfer"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    TransferProjectRequest(
                        organizationId: try destination.requireID(),
                        organizationalUnitId: nil))
            } afterResponse: { response in
                #expect(response.status == .conflict)
                #expect(response.body.string.contains("Ceph storage access"))
            }

            let retained = try #require(
                await Project.find(try fixture.project.requireID(), on: fixture.app.db))
            #expect(retained.$organization.id == fixture.organization.id)

            try await fixture.app.test(
                .DELETE, "/api/projects/\(try fixture.project.requireID())"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { response in
                #expect(response.status == .conflict)
                #expect(response.body.string.contains("Ceph storage access"))
            }
            #expect(
                try await Project.find(try fixture.project.requireID(), on: fixture.app.db)
                    != nil)

            try await fixture.app.test(
                .DELETE, "/api/organizations/\(try fixture.organization.requireID())"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { response in
                #expect(response.status == .conflict)
                #expect(response.body.string.contains("external Ceph storage access"))
                #expect(response.body.string.contains(fixture.project.name))
            }
        }
    }

    @Test("Firecracker Ceph boot placement uses a capable site client and no replica")
    func firecrackerCephBootVolume() async throws {
        try await withFixture { fixture in
            let cluster = try await registerCluster(fixture)
            let access = try await configureAccess(fixture)
            let poolID = try #require(access.storagePool.id)
            _ = try await fixture.builder.createNetwork(
                name: "ceph-vm-network", project: fixture.project, site: fixture.site)

            let image = Image(
                name: "firecracker-ceph-image", description: "kernel and rootfs",
                projectID: try fixture.project.requireID(), architecture: .arm64,
                status: .ready, uploadedByID: try fixture.user.requireID())
            try await image.save(on: fixture.app.db)
            let imageID = try image.requireID()
            let checksum = String(repeating: "c", count: 64)
            try await ImageArtifact(
                imageID: imageID, kind: .kernel, format: nil, architecture: .arm64,
                filename: "vmlinux", size: 1, checksum: checksum,
                storagePath: "images/\(imageID)/kernel/vmlinux"
            ).save(on: fixture.app.db)
            try await ImageArtifact(
                imageID: imageID, kind: .rootfs, format: .raw, architecture: .arm64,
                filename: "rootfs.raw", size: 1, checksum: checksum,
                storagePath: "images/\(imageID)/rootfs/rootfs.raw"
            ).save(on: fixture.app.db)

            let incapable = try await registerCephAgent(
                fixture, name: "firecracker-no-ceph", hypervisorType: .firecracker,
                architecture: .arm64, cephCapable: false)
            let capable = try await registerCephAgent(
                fixture, name: "firecracker-ceph", hypervisorType: .firecracker,
                architecture: .arm64, availableDisk: 0)

            try await fixture.app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    CreateVMBody(
                        name: "firecracker-rbd", imageId: imageID,
                        projectId: try fixture.project.requireID(),
                        disk: 10 * 1024 * 1024 * 1024, poolId: poolID,
                        networkName: "ceph-vm-network", hypervisorType: .firecracker))
            } afterResponse: { response in
                #expect(response.status == .accepted)
            }

            var placedVM: VM?
            for _ in 0..<150 {
                placedVM = try await VM.query(on: fixture.app.db)
                    .filter(\.$name == "firecracker-rbd").first()
                if placedVM?.hypervisorId != nil || placedVM?.conditions.degraded != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let vm = try #require(placedVM)
            let vmID = try vm.requireID()
            #expect(vm.hypervisorId == capable)
            #expect(vm.hypervisorId != incapable)
            let reservation = await fixture.app.coordination.activeReservations(
                agentIds: [capable])[capable]
            #expect(reservation?.disk == 0)

            let boot = try #require(
                await Volume.query(on: fixture.app.db)
                    .filter(\.$vm.$id == vmID)
                    .filter(\.$volumeType == .boot)
                    .first())
            let bootID = try boot.requireID()
            #expect(boot.$pool.id == poolID)
            #expect(boot.format == .raw)
            #expect(boot.reconcilerAgentId == capable)
            #expect(
                try await VolumeReplica.query(on: fixture.app.db)
                    .filter(\.$volume.$id == bootID).count() == 0)

            let clusterID = try #require(cluster.id)
            let credentialID = try await runtimeCredentialID(access, fixture: fixture)
            let attachment = DiskAttachment.rbd(
                pool: "rbd", image: "strato-volume-\(bootID.uuidString.lowercased())",
                namespace: "project-a", user: "project-a",
                monEndpoints: cluster.monEndpoints,
                clusterId: clusterID, credentialId: credentialID,
                configPath:
                    "/var/lib/strato/ceph/\(clusterID.uuidString.lowercased())/\(credentialID.uuidString.lowercased())/ceph.conf"
            )
            _ = try await fixture.app.observedStateApplier.apply(
                report(
                    agentId: capable,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: bootID, present: true, attachment: attachment,
                            observedGeneration: boot.generation)
                    ]))

            let desired = try await fixture.app.desiredStateAssembler.assemble(agentId: capable)
            let desiredBoot = try #require(desired.volumes.first { $0.volumeId == bootID })
            guard case .ceph(let storage) = desiredBoot.storage else {
                Issue.record("Firecracker boot volume was not assembled as Ceph storage")
                return
            }
            #expect(storage.clusterId == clusterID)
            #expect(desiredBoot.attachment?.vmId == vmID)
            let desiredVM = try #require(desired.vms.first { $0.vmId == vmID })
            #expect(desiredVM.spec.volumes.first?.attachment == attachment)
        }
    }

    @Test("Firecracker-only Ceph clients capture snapshots and reassign deletion")
    func firecrackerCephSnapshotLifecycle() async throws {
        try await withFixture { fixture in
            let cluster = try await registerCluster(fixture)
            let access = try await configureAccess(fixture)
            let poolID = try #require(access.storagePool.id)
            let clusterID = try #require(cluster.id)
            let credentialID = try await runtimeCredentialID(access, fixture: fixture)
            let original = try await registerCephAgent(
                fixture, name: "firecracker-rbd-original", hypervisorType: .firecracker,
                architecture: .arm64)

            var volumeID: UUID?
            try await fixture.app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    CreateVolumeRequest(
                        name: "firecracker-rbd-data", description: nil,
                        projectId: try fixture.project.requireID(), environment: nil,
                        sizeGB: 1, format: "raw", volumeType: "data", sourceImageId: nil,
                        iopsTotal: nil, bpsTotal: nil, poolId: poolID))
            } afterResponse: { response in
                #expect(response.status == .accepted)
                volumeID = try response.content.decode(
                    AcceptedMutation<VolumeResponse>.self
                ).resource.id
            }
            let id = try #require(volumeID)
            var placed: Volume?
            for _ in 0..<100 {
                placed = try await Volume.find(id, on: fixture.app.db)
                if placed?.reconcilerAgentId != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let volume = try #require(placed)
            #expect(volume.reconcilerAgentId == original)
            let attachment = DiskAttachment.rbd(
                pool: "rbd", image: "firecracker-snapshot-source", namespace: "project-a",
                user: "project-a", monEndpoints: cluster.monEndpoints,
                clusterId: clusterID, credentialId: credentialID,
                configPath:
                    "/var/lib/strato/ceph/\(clusterID.uuidString.lowercased())/\(credentialID.uuidString.lowercased())/ceph.conf"
            )
            _ = try await fixture.app.observedStateApplier.apply(
                report(
                    agentId: original,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: id, present: true, attachment: attachment,
                            observedGeneration: volume.generation)
                    ]))

            try await fixture.app.test(.POST, "/api/volumes/\(id)/snapshot") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    CreateSnapshotRequest(
                        name: "native-rbd", description: nil, ttlSeconds: nil))
            } afterResponse: { response in
                #expect(response.status == .accepted)
            }
            let snapshot = try #require(
                await VolumeSnapshot.query(on: fixture.app.db)
                    .filter(\.$volume.$id == id).first())
            #expect(snapshot.agentId == original)
            let expired = VolumeSnapshot(
                name: "expired-native-rbd", description: "retention reassignment",
                volumeID: id, projectID: try fixture.project.requireID(),
                environment: volume.environment, size: volume.size,
                agentId: original, expiresAt: Date().addingTimeInterval(-1),
                createdByID: try fixture.user.requireID())
            try await expired.save(on: fixture.app.db)

            guard let originalID = UUID(uuidString: original),
                let originalAgent = try await Agent.find(originalID, on: fixture.app.db)
            else { Issue.record("Missing original Firecracker Ceph client"); return }
            originalAgent.status = .offline
            originalAgent.lastHeartbeat = Date().addingTimeInterval(-120)
            try await originalAgent.save(on: fixture.app.db)
            let replacement = try await registerCephAgent(
                fixture, name: "firecracker-rbd-replacement", hypervisorType: .firecracker,
                architecture: .arm64)

            try await fixture.app.test(
                .DELETE, "/api/volumes/\(id)/snapshots/\(try snapshot.requireID())"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { response in
                #expect(response.status == .accepted)
            }
            let terminating = try #require(
                await VolumeSnapshot.find(try snapshot.requireID(), on: fixture.app.db))
            #expect(terminating.desiredStatus == .absent)
            #expect(terminating.agentId == replacement)
            await SnapshotRetentionSweep.run(app: fixture.app)
            let expiredTerminating = try #require(
                await VolumeSnapshot.find(try expired.requireID(), on: fixture.app.db))
            #expect(expiredTerminating.desiredStatus == .absent)
            #expect(expiredTerminating.agentId == replacement)
            #expect(
                try await VolumeReplica.query(on: fixture.app.db)
                    .filter(\.$volume.$id == id).count() == 0)
        }
    }

    @Test("Ceph volume convergence has no replicas and moves only its reconciler between VM hosts")
    func cephVolumeLifecycleHasNoReplicas() async throws {
        try await withFixture { fixture in
            let clusterResponse = try await registerCluster(fixture)
            let accessResponse = try await configureAccess(fixture)
            let poolID = try #require(accessResponse.storagePool.id)
            let accessID = try #require(accessResponse.id)
            let credentialID = try await runtimeCredentialID(accessResponse, fixture: fixture)
            let clusterID = try #require(clusterResponse.id)
            let agentA = try await registerCephAgent(fixture, name: "ceph-agent-a")
            let agentB = try await registerCephAgent(fixture, name: "ceph-agent-b")

            var createdID: UUID?
            try await fixture.app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    CreateVolumeRequest(
                        name: "ceph-data", description: "shared RBD",
                        projectId: try fixture.project.requireID(), environment: nil,
                        sizeGB: 10, format: nil, volumeType: "data", sourceImageId: nil,
                        iopsTotal: nil, bpsTotal: nil, poolId: poolID))
            } afterResponse: { response in
                #expect(response.status == .accepted)
                let accepted = try response.content.decode(AcceptedMutation<VolumeResponse>.self)
                createdID = accepted.resource.id
                #expect(accepted.resource.format == .raw)
            }
            let volumeID = try #require(createdID)

            var volume: Volume?
            for _ in 0..<100 {
                volume = try await Volume.find(volumeID, on: fixture.app.db)
                if volume?.reconcilerAgentId != nil { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let placed = try #require(volume)
            #expect(placed.reconcilerAgentId != nil)
            #expect(
                try await VolumeReplica.query(on: fixture.app.db)
                    .filter(\.$volume.$id == volumeID).count() == 0)

            // Make A the explicit execution owner for the mobility sequence.
            placed.reconcilerAgentId = agentA
            try await placed.save(on: fixture.app.db)

            // Exercise the actual producer/consumer contract: the assembler
            // must name the StoredSecret UUID (not the access-row UUID), and
            // the attachment echo derived from that desired storage must pass
            // observed-state validation unchanged.
            let initialDesired = try await fixture.app.desiredStateAssembler.assemble(
                agentId: agentA)
            let desiredVolume = try #require(
                initialDesired.volumes.first { $0.volumeId == volumeID })
            guard case .ceph(let desiredStorage) = desiredVolume.storage else {
                Issue.record("Ceph volume was not assembled with Ceph storage")
                return
            }
            #expect(desiredStorage.credentialId == credentialID)
            #expect(desiredStorage.credentialId != accessID)

            // Presence without a valid canonical RBD attachment cannot settle
            // the create: there is nothing safe for a VM spec to consume yet.
            _ = try await fixture.app.observedStateApplier.apply(
                report(
                    agentId: agentA,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true, attachment: nil,
                            observedGeneration: 1)
                    ]))
            let attachmentless = try #require(await Volume.find(volumeID, on: fixture.app.db))
            #expect(attachmentless.status == .creating)
            #expect(attachmentless.diskAttachment == nil)
            #expect(!attachmentless.conditions.converged)

            // RBD/libvirt uses the cephx user without the `client.` prefix.
            let attachment = DiskAttachment.rbd(
                pool: desiredStorage.pool, image: volumeID.uuidString,
                namespace: desiredStorage.namespace,
                user: String(desiredStorage.clientName.dropFirst("client.".count)),
                monEndpoints: desiredStorage.monEndpoints,
                clusterId: desiredStorage.clusterId,
                credentialId: desiredStorage.credentialId,
                configPath:
                    "/var/lib/strato/ceph/\(desiredStorage.clusterId.uuidString.lowercased())/\(desiredStorage.credentialId.uuidString.lowercased())/ceph.conf"
            )
            _ = try await fixture.app.observedStateApplier.apply(
                report(
                    agentId: agentA,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true, attachment: attachment,
                            observedGeneration: 1)
                    ]))
            let settled = try #require(await Volume.find(volumeID, on: fixture.app.db))
            #expect(settled.status == .available)
            #expect(settled.diskAttachment == attachment)
            #expect(settled.conditions.converged)
            #expect(
                try await VolumeReplica.query(on: fixture.app.db)
                    .filter(\.$volume.$id == volumeID).count() == 0)

            try await fixture.app.test(.PUT, try accessPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    UpsertCephProjectAccessRequest(
                        clientName: "client.project-a-renamed",
                        keyring: """
                            [client.project-a-renamed]
                            key = replacement
                            caps mon = "profile rbd"
                            caps mgr = "profile rbd pool=rbd namespace=project-a"
                            caps osd = "profile rbd pool=rbd namespace=project-a"
                            """,
                        storagePoolName: accessResponse.storagePool.name,
                        cephPoolName: "rbd", namespace: "project-a"))
            } afterResponse: { response in
                #expect(response.status == .conflict)
            }
            let immutableAccess = try #require(
                await CephProjectAccess.find(accessID, on: fixture.app.db))
            #expect(immutableAccess.clientName == "client.project-a")

            try await fixture.app.test(.PUT, try accessPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    UpsertCephProjectAccessRequest(
                        clientName: "client.project-a",
                        keyring: """
                            [client.project-a]
                            key = rotated-after-use
                            caps mon = "profile rbd"
                            caps mgr = "profile rbd pool=rbd namespace=project-a"
                            caps osd = "profile rbd pool=rbd namespace=project-a"
                            """,
                        storagePoolName: accessResponse.storagePool.name,
                        cephPoolName: "rbd", namespace: "project-a",
                        cephxRevoked: true))
            } afterResponse: { response in
                #expect(response.status == .conflict)
            }
            try await fixture.app.test(.PUT, try clusterPath(fixture)) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    UpdateExternalCephClusterRequest(
                        monEndpoints: ["v2:replacement-mon.example:3300"],
                        clientName: "client.strato-observer", keyring: nil))
            } afterResponse: { response in
                #expect(response.status == .conflict)
            }

            let unplacedVM = try await fixture.builder.createVM(
                name: "unplaced-vm", project: fixture.project)
            #expect(unplacedVM.hypervisorId == nil)
            try await fixture.app.test(.POST, "/api/volumes/\(volumeID)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    AttachVolumeRequest(
                        vmId: try unplacedVM.requireID(), deviceName: nil,
                        bootOrder: nil, readonly: nil))
            } afterResponse: { response in
                #expect(response.status == .conflict)
                #expect(response.body.string.contains("placed VM"))
            }

            let vmA = try await fixture.builder.createVM(name: "vm-a", project: fixture.project)
            vmA.hypervisorId = agentA
            try await vmA.save(on: fixture.app.db)
            let vmB = try await fixture.builder.createVM(name: "vm-b", project: fixture.project)
            vmB.hypervisorId = agentB
            try await vmB.save(on: fixture.app.db)

            func attach(to vm: VM) async throws {
                try await fixture.app.test(.POST, "/api/volumes/\(volumeID)/attach") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        AttachVolumeRequest(
                            vmId: try vm.requireID(), deviceName: nil,
                            bootOrder: nil, readonly: nil))
                } afterResponse: { response in
                    #expect(response.status == .accepted)
                }
            }
            func detach() async throws {
                try await fixture.app.test(.POST, "/api/volumes/\(volumeID)/detach") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                } afterResponse: { response in
                    #expect(response.status == .accepted)
                }
            }

            try await attach(to: vmA)
            var moved = try #require(await Volume.find(volumeID, on: fixture.app.db))
            #expect(moved.reconcilerAgentId == agentA)
            #expect(moved.diskAttachment == attachment)
            try await detach()
            moved = try #require(await Volume.find(volumeID, on: fixture.app.db))
            #expect(moved.reconcilerAgentId == agentA)

            try await fixture.app.test(.POST, "/api/volumes/\(volumeID)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    AttachVolumeRequest(
                        vmId: try vmB.requireID(), deviceName: nil,
                        bootOrder: nil, readonly: nil))
            } afterResponse: { response in
                #expect(response.status == .conflict)
                #expect(response.body.string.contains("previous Ceph detach"))
            }
            let detachGeneration = moved.generation

            guard let agentAID = UUID(uuidString: agentA),
                let detachingAgent = try await Agent.find(agentAID, on: fixture.app.db)
            else { Issue.record("Missing detaching Ceph agent A"); return }
            detachingAgent.status = .offline
            detachingAgent.lastHeartbeat = Date().addingTimeInterval(-120)
            try await detachingAgent.save(on: fixture.app.db)
            try await fixture.app.test(.DELETE, "/api/volumes/\(volumeID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
            } afterResponse: { response in
                #expect(response.status == .conflict)
            }
            let retainedForDetach = try #require(
                await Volume.find(volumeID, on: fixture.app.db))
            #expect(retainedForDetach.desiredStatus == .present)
            #expect(retainedForDetach.reconcilerAgentId == agentA)
            detachingAgent.status = .online
            detachingAgent.lastHeartbeat = Date()
            detachingAgent.dependencyObservationsReceivedAt = Date()
            try await detachingAgent.save(on: fixture.app.db)

            _ = try await fixture.app.observedStateApplier.apply(
                report(
                    agentId: agentA,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true, attachment: attachment,
                            attachedVMId: try vmA.requireID(),
                            observedGeneration: detachGeneration,
                            lastError: "detach refused", failedGeneration: detachGeneration)
                    ]))
            try await fixture.app.test(.POST, "/api/volumes/\(volumeID)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    AttachVolumeRequest(
                        vmId: try vmB.requireID(), deviceName: nil,
                        bootOrder: nil, readonly: nil))
            } afterResponse: { response in
                #expect(response.status == .conflict)
                #expect(response.body.string.contains("previous Ceph detach"))
            }
            _ = try await fixture.app.observedStateApplier.apply(
                report(
                    agentId: agentA,
                    volumes: [
                        ObservedVolumeState(
                            volumeId: volumeID, present: true, attachment: attachment,
                            attachedVMId: nil, observedGeneration: detachGeneration)
                    ]))

            try await attach(to: vmB)
            moved = try #require(await Volume.find(volumeID, on: fixture.app.db))
            #expect(moved.reconcilerAgentId == agentB)
            #expect(moved.diskAttachment == attachment)
            #expect(
                try await VolumeReplica.query(on: fixture.app.db)
                    .filter(\.$volume.$id == volumeID).count() == 0)

            try await detach()
            moved = try #require(await Volume.find(volumeID, on: fixture.app.db))
            moved.observedGeneration = moved.generation
            moved.status = .available
            try await moved.save(on: fixture.app.db)
            guard let agentBID = UUID(uuidString: agentB),
                let staleAgent = try await Agent.find(agentBID, on: fixture.app.db)
            else { Issue.record("Missing Ceph agent B"); return }
            staleAgent.dependencyObservationsReceivedAt =
                Date().addingTimeInterval(-Agent.dependencyObservationStaleAfter - 1)
            try await staleAgent.save(on: fixture.app.db)

            // Resolve failover from a deliberately stale request model after
            // an observed-state writer advanced the row. The resolver must
            // update only execution ownership, never write the old generation
            // or attachment back over the committed report.
            let staleRequest = try #require(await Volume.find(volumeID, on: fixture.app.db))
            let concurrent = try #require(await Volume.find(volumeID, on: fixture.app.db))
            concurrent.generation += 2
            concurrent.observedGeneration = concurrent.generation
            let concurrentAttachment = DiskAttachment.rbd(
                pool: "rbd", image: "reported-after-request", namespace: "project-a",
                user: "project-a", monEndpoints: clusterResponse.monEndpoints,
                clusterId: clusterID, credentialId: credentialID,
                configPath:
                    "/var/lib/strato/ceph/\(clusterID.uuidString.lowercased())/\(credentialID.uuidString.lowercased())/ceph.conf"
            )
            concurrent.diskAttachment = concurrentAttachment
            try await concurrent.save(on: fixture.app.db)
            let failover = try await VolumeService.resolveAgentHolding(
                staleRequest, on: fixture.app.db)
            #expect(failover.agentID == agentA)
            let preserved = try #require(await Volume.find(volumeID, on: fixture.app.db))
            #expect(preserved.generation == concurrent.generation)
            #expect(preserved.observedGeneration == concurrent.observedGeneration)
            #expect(preserved.diskAttachment == concurrentAttachment)

            try await fixture.app.test(.POST, "/api/volumes/\(volumeID)/resize") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(ResizeVolumeRequest(sizeGB: 20))
            } afterResponse: { response in
                #expect(response.status == .accepted)
            }
            moved = try #require(await Volume.find(volumeID, on: fixture.app.db))
            #expect(moved.reconcilerAgentId == agentA)
            moved.observedGeneration = moved.generation
            moved.status = .available
            moved.convergencePhase = nil
            moved.errorMessage = nil
            moved.failedGeneration = nil
            moved.reconcilerAgentId = agentB
            try await moved.save(on: fixture.app.db)

            try await fixture.app.test(.POST, "/api/volumes/\(volumeID)/snapshot") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    CreateSnapshotRequest(name: "failed-over", description: nil, ttlSeconds: nil))
            } afterResponse: { response in
                #expect(response.status == .accepted)
            }
            let snapshot = try #require(
                await VolumeSnapshot.query(on: fixture.app.db).first())
            #expect(snapshot.agentId == agentA)
            moved = try #require(await Volume.find(volumeID, on: fixture.app.db))
            moved.reconcilerAgentId = agentB
            try await moved.save(on: fixture.app.db)
            vmA.hypervisorId = nil
            try await vmA.save(on: fixture.app.db)
            let snapshotSync = try await fixture.app.desiredStateAssembler.assemble(agentId: agentA)
            let snapshotID = try snapshot.requireID()
            let desiredSnapshot = try #require(
                snapshotSync.snapshots.first { $0.snapshotId == snapshotID })
            guard case .ceph(let snapshotStorage) = desiredSnapshot.volumeStorage else {
                Issue.record("Ceph volume snapshot did not carry its parent storage configuration")
                return
            }
            #expect(snapshotStorage.pool == "rbd")
            #expect(snapshotStorage.namespace == "project-a")
            #expect(snapshotStorage.clientName == "client.project-a")

            try await fixture.app.test(.POST, "/api/volumes/\(volumeID)/clone") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(CloneVolumeRequest(name: "failed-over-clone", description: nil))
            } afterResponse: { response in
                #expect(response.status == .accepted)
            }
            #expect(try await Volume.query(on: fixture.app.db).count() == 2)
            #expect(try await VolumeSnapshot.query(on: fixture.app.db).count() == 1)
            let clone = try #require(
                await Volume.query(on: fixture.app.db)
                    .filter(\.$name == "failed-over-clone").first())
            #expect(clone.reconcilerAgentId == agentA)
            #expect(
                try await VolumeReplica.query(on: fixture.app.db)
                    .filter(\.$volume.$id == clone.requireID()).count() == 0)

            // The asynchronous create placement claim must lose cleanly when
            // deletion commits first; it cannot restore Present or generation
            // 1 with a whole-model save.
            let deleteWon = Volume(
                name: "delete-won", description: "placement race",
                projectID: try fixture.project.requireID(), environment: "default",
                size: 1 << 30, format: .raw, volumeType: .data, status: .creating,
                createdByID: try fixture.user.requireID(), poolID: poolID)
            deleteWon.desiredStatus = .absent
            deleteWon.generation = 2
            try await deleteWon.save(on: fixture.app.db)
            let claimed = try await VolumeService.assignInitialCephReconciler(
                volumeID: try deleteWon.requireID(), expectedGeneration: 1,
                agentID: agentA, on: fixture.app.db)
            #expect(!claimed)
            let stillAbsent = try #require(
                await Volume.find(try deleteWon.requireID(), on: fixture.app.db))
            #expect(stillAbsent.desiredStatus == .absent)
            #expect(stillAbsent.generation == 2)
            #expect(stillAbsent.reconcilerAgentId == nil)
        }
    }
}
