import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport

@testable import App

/// Per-VM instance identity (STR-55): every VM is a first-class IAM principal,
/// named by a `workload_registrations` row created in its create transaction and
/// destroyed with it.
///
/// The identity is deliberately *not* opt-in. That is safe because of the
/// invariant these tests also pin: the registration carries no grants, so until
/// an operator writes a role binding against the principal it authenticates and
/// authorizes nothing.
@Suite("VM Instance Identity Tests", .serialized)
final class VMInstanceIdentityTests {

    private func withIdentityTestApp(
        _ test: (Application, User, Organization, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "identityuser",
                email: "identity@example.com",
                displayName: "Identity User",
                isSystemAdmin: false
            )
            let org = try await builder.createOrganization(name: "Identity Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Identity Project",
                description: "Project for instance identity tests",
                organization: org
            )
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, user, org, project, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private struct CreateVMBody: Content {
        let name: String
        let imageId: UUID?
        let projectId: UUID?
        let cpu: Int?
        let memory: Int64?
        let disk: Int64?
        let networkId: UUID?
    }

    /// The `202` envelope every accepted VM mutation answers with.
    private struct AcceptedBody: Content {
        let resource: VMBody
    }

    /// The paged envelope the list endpoint answers with.
    private struct PagedBody: Content {
        let items: [VMBody]
    }

    /// The subset of `VMDetailResponse` these tests read back.
    private struct VMBody: Content {
        let id: UUID?
        let name: String
        let spiffeId: String?
        let instanceIdentityPrincipalId: UUID?
        let instanceIdentityStatus: InstanceIdentityStatus?
    }

    private struct RoleBody: Content {
        let role: String
    }

    private func createVM(
        _ app: Application, project: Project, user: User, token: String, name: String,
        suffix: String
    ) async throws -> VMBody {
        let builder = TestDataBuilder(db: app.db)
        let image = try await builder.createImage(project: project, uploadedBy: user)
        let network = try await builder.createNetwork(name: "identity-net-\(suffix)", project: project)
        let gb = Int64(1) << 30

        var body: VMBody?
        try await app.test(.POST, "/api/vms") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(
                CreateVMBody(
                    name: name, imageId: image.id, projectId: project.id,
                    cpu: 1, memory: gb, disk: 10 * gb, networkId: try network.requireID()))
        } afterResponse: { res in
            #expect(res.status == .accepted)
            body = try res.content.decode(AcceptedBody.self).resource
        }
        return try #require(body)
    }

    private func registration(
        forVM vmID: UUID, on db: any Database
    ) async throws -> WorkloadRegistration? {
        try await WorkloadRegistration.query(on: db).filter(\.$vm.$id == vmID).first()
    }

    // MARK: - Create

    @Test("Creating a VM registers exactly one workload principal naming it")
    func createRegistersTheVM() async throws {
        try await withIdentityTestApp { app, user, org, project, token in
            let created = try await self.createVM(
                app, project: project, user: user, token: token, name: "identified-vm",
                suffix: "create")
            let vmID = try #require(created.id)

            let rows = try await WorkloadRegistration.query(on: app.db)
                .filter(\.$vm.$id == vmID)
                .all()
            #expect(rows.count == 1)
            let row = try #require(rows.first)

            #expect(row.kind == .workload)
            #expect(row.$organization.id == org.id)
            #expect(row.createdBy == user.id)
            // No stored label: the id in the SPIFFE path is the identity, and a
            // copy of `vm.name` would only decay. The registry hydrates it.
            #expect(row.displayName == nil)
            #expect(
                row.spiffeID
                    == GuestIdentity.spiffeID(forVM: vmID, trustDomain: PlatformTrustDomain.current))

            // The registration is a principal, and it holds nothing. This is
            // what makes always-on registration safe.
            let registrationID = try row.requireID()
            let bindings = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.workload.rawValue)
                .filter(\.$principalID == registrationID)
                .count()
            #expect(bindings == 0)
            #expect(created.instanceIdentityStatus == .enabled)
        }
    }

    @Test("The 202 body, the detail, the status and the list all report the same identity")
    func everyReadSurfaceReportsTheIdentity() async throws {
        try await withIdentityTestApp { app, user, org, project, token in
            let created = try await self.createVM(
                app, project: project, user: user, token: token, name: "surfaced-vm",
                suffix: "surfaces")
            let vmID = try #require(created.id)
            let expected = try #require(
                try await self.registration(forVM: vmID, on: app.db)?.spiffeID)
            let expectedPrincipalID = try #require(
                try await self.registration(forVM: vmID, on: app.db)?.id)

            // The `202` a create answers with.
            #expect(created.spiffeId == expected)
            #expect(created.instanceIdentityPrincipalId == expectedPrincipalID)
            #expect(created.instanceIdentityStatus == .enabled)

            try await app.test(.GET, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(VMBody.self)
                #expect(detail.spiffeId == expected)
                #expect(detail.instanceIdentityPrincipalId == expectedPrincipalID)
                #expect(detail.instanceIdentityStatus == .enabled)
            }

            try await app.test(.GET, "/api/vms/\(vmID)/status") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let status = try res.content.decode(VMBody.self)
                #expect(status.spiffeId == expected)
                #expect(status.instanceIdentityPrincipalId == expectedPrincipalID)
                #expect(status.instanceIdentityStatus == .enabled)
            }

            // The list is the one surface that could have gone N+1; it resolves
            // the whole page in one query.
            try await app.test(.GET, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let listed = try res.content.decode(PagedBody.self)
                let mine = try #require(listed.items.first { $0.id == vmID })
                #expect(mine.spiffeId == expected)
                #expect(mine.instanceIdentityPrincipalId == expectedPrincipalID)
                #expect(mine.instanceIdentityStatus == .enabled)
            }
        }
    }

    @Test("Project IAM lists its complete lightweight VM principal inventory")
    func projectVMPrincipalsAreScopedAndLightweight() async throws {
        try await withIdentityTestApp { app, user, org, project, token in
            let otherProject = try await TestDataBuilder(db: app.db).createProject(
                name: "Other Identity Project", description: "not requested", organization: org)
            let expected = try await self.createVM(
                app, project: project, user: user, token: token, name: "requested-project-vm",
                suffix: "requested-project")
            _ = try await self.createVM(
                app, project: otherProject, user: user, token: token, name: "other-project-vm",
                suffix: "other-project")

            try await app.test(
                .GET, "/api/projects/\(try project.requireID())/vm-principals"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let listed = try res.content.decode(
                    [ProjectMemberController.ProjectVMPrincipalResponse].self)
                let principal = try #require(listed.first)
                #expect(listed.count == 1)
                #expect(principal.id == expected.id)
                #expect(principal.name == expected.name)
                #expect(principal.spiffeId == expected.spiffeId)
                #expect(
                    principal.instanceIdentityPrincipalId
                        == expected.instanceIdentityPrincipalId)
                #expect(principal.instanceIdentityStatus == .enabled)
            }
        }
    }

    @Test("A VM's project role is assignable and listed with its identity")
    func projectRoleIsAssignableAndListed() async throws {
        try await withIdentityTestApp { app, user, org, project, token in
            let created = try await self.createVM(
                app, project: project, user: user, token: token, name: "role-bearing-vm",
                suffix: "role")
            let vmID = try #require(created.id)
            let principalID = try #require(created.instanceIdentityPrincipalId)
            let projectID = try project.requireID()
            let roleID = IAMRole.viewer.seededID

            try await app.test(
                .PUT, "/api/projects/\(projectID)/workload-grants/\(principalID)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(RoleBody(role: roleID.uuidString))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            try await app.test(.GET, "/api/projects/\(projectID)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let members = try res.content.decode(
                    ProjectMemberController.ProjectMembersResponse.self)
                let grant = try #require(
                    members.workloads.first { $0.registrationId == principalID })
                #expect(grant.vmId == vmID)
                #expect(grant.displayName == created.name)
                #expect(grant.spiffeId == created.spiffeId)
                #expect(grant.role == roleID)
                #expect(grant.roleDisplayName == IAMRole.viewer.rawValue)
            }
        }
    }

    @Test("A VM reader can fetch only that VM identity's project grant")
    func vmReaderCanFetchTheVMProjectGrant() async throws {
        try await withIdentityTestApp { app, user, _, project, token in
            let created = try await self.createVM(
                app, project: project, user: user, token: token, name: "directly-readable-vm",
                suffix: "direct-reader")
            let vmID = try #require(created.id)
            let principalID = try #require(created.instanceIdentityPrincipalId)
            let projectID = try project.requireID()

            let reader = try await TestDataBuilder(db: app.db).createUser(
                username: "directvmreader",
                email: "directvmreader@example.com",
                displayName: "Direct VM Reader",
                isSystemAdmin: false)
            let readerID = try reader.requireID()
            let readerToken = try await reader.generateAPIKey(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: readerID,
                role: .viewer,
                nodeType: .virtualMachine,
                nodeID: vmID,
                createdBy: user.id,
                on: app.db)

            // A direct VM grant is deliberately not project membership.
            try await app.test(.GET, "/api/projects/\(projectID)/members") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: readerToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            try await app.test(.GET, "/api/vms/\(vmID)/project-grant") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: readerToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(VMController.VMProjectGrantResponse.self)
                #expect(response.grant == nil)
            }

            try await RoleBindingService.grant(
                principalType: .workload,
                principalID: principalID,
                role: .viewer,
                nodeType: .project,
                nodeID: projectID,
                createdBy: user.id,
                on: app.db)

            try await app.test(.GET, "/api/vms/\(vmID)/project-grant") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: readerToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(VMController.VMProjectGrantResponse.self)
                let grant = try #require(response.grant)
                #expect(grant.registrationId == principalID)
                #expect(grant.vmId == vmID)
                #expect(grant.displayName == created.name)
                #expect(grant.spiffeId == created.spiffeId)
                #expect(grant.role == IAMRole.viewer.seededID)
                #expect(grant.roleDisplayName == IAMRole.viewer.rawValue)
            }
        }
    }

    @Test("The registry shows the VM's current name, not the one it had at create")
    func registryLabelTracksRenames() async throws {
        try await withIdentityTestApp { app, user, org, project, token in
            let admin = try await TestDataBuilder(db: app.db).createUser(
                username: "registryadmin", email: "registryadmin@example.com",
                displayName: "Registry Admin", isSystemAdmin: true)
            let adminToken = try await admin.generateAPIKey(on: app.db)

            let created = try await self.createVM(
                app, project: project, user: user, token: token, name: "before-rename",
                suffix: "rename")
            let vmID = try #require(created.id)
            let spiffeID = try #require(
                try await self.registration(forVM: vmID, on: app.db)?.spiffeID)

            let vm = try #require(try await VM.find(vmID, on: app.db))
            vm.name = "after-rename"
            try await vm.save(on: app.db)

            struct RegistrationBody: Content {
                let spiffeId: String
                let vmId: UUID?
                let displayName: String?
            }
            struct PagedRegistrations: Content {
                let items: [RegistrationBody]
                let total: Int
            }

            // Percent-encoded: a SPIFFE URI carries `:` and `//`, so a raw
            // value would not survive the query string intact.
            let encoded = try #require(
                spiffeID.addingPercentEncoding(withAllowedCharacters: .alphanumerics))

            // Filtered to the one row, which is also the diagnostic path the
            // create-conflict and backfill messages send an operator down.
            try await app.test(
                .GET, "/api/workload-registrations?spiffeId=\(encoded)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let paged = try res.content.decode(PagedRegistrations.self)
                #expect(paged.total == 1)
                let row = try #require(paged.items.first)
                #expect(row.vmId == vmID)
                // Hydrated from the VM, so it cannot show a name a rename has
                // already invalidated — which is the whole reason it is not
                // stored.
                #expect(row.displayName == "after-rename")
            }
        }
    }

    @Test("The registry filters by kind and by whether a row is VM-owned")
    func registryFilters() async throws {
        try await withIdentityTestApp { app, user, org, project, token in
            let admin = try await TestDataBuilder(db: app.db).createUser(
                username: "filteradmin", email: "filteradmin@example.com",
                displayName: "Filter Admin", isSystemAdmin: true)
            let adminToken = try await admin.generateAPIKey(on: app.db)

            let created = try await self.createVM(
                app, project: project, user: user, token: token, name: "filtered-vm",
                suffix: "filter")
            let vmID = try #require(created.id)

            // A workload row with no VM behind it, so `vmOwned` has something to
            // exclude rather than trivially matching everything.
            try await WorkloadRegistration(
                spiffeID: "spiffe://\(PlatformTrustDomain.current)/sa/filter-bystander",
                kind: .workload, organizationID: try org.requireID()
            ).save(on: app.db)

            struct RegistrationBody: Content {
                let spiffeId: String
                let vmId: UUID?
            }
            struct PagedRegistrations: Content {
                let items: [RegistrationBody]
                let total: Int
            }

            func list(_ query: String) async throws -> PagedRegistrations {
                var decoded: PagedRegistrations?
                try await app.test(.GET, "/api/workload-registrations?\(query)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                } afterResponse: { res in
                    #expect(res.status == .ok)
                    decoded = try res.content.decode(PagedRegistrations.self)
                }
                return try #require(decoded)
            }

            // The unfiltered listing must contain *both*. This is the case that
            // caught `query[Bool.self, at:]` decoding a missing key as `false`:
            // the endpoint silently answered "every registration with no VM",
            // which is the minority of the table and looked like an empty
            // registry.
            let unfiltered = try await list("")
            #expect(unfiltered.items.contains { $0.vmId == vmID })
            #expect(unfiltered.items.contains { $0.spiffeId.hasSuffix("/sa/filter-bystander") })

            let vmOwned = try await list("vmOwned=true")
            #expect(vmOwned.items.allSatisfy { $0.vmId != nil })
            #expect(vmOwned.items.contains { $0.vmId == vmID })

            let notVMOwned = try await list("vmOwned=false")
            #expect(notVMOwned.items.allSatisfy { $0.vmId == nil })
            #expect(notVMOwned.items.contains { $0.spiffeId.hasSuffix("/sa/filter-bystander") })

            let agents = try await list("kind=agent")
            #expect(agents.items.isEmpty)

            // A bad value is a 400, not a silently narrowed page — the same rule
            // `intQuery` follows, and the reason `boolQuery` exists.
            for bad in ["kind=nonsense", "vmOwned=maybe"] {
                try await app.test(.GET, "/api/workload-registrations?\(bad)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
                } afterResponse: { res in
                    #expect(res.status == .badRequest, "\(bad)")
                }
            }
        }
    }

    // MARK: - Squatting

    @Test("A squatted SPIFFE ID fails registration, and a redrawn VM id escapes it")
    func squattedIdentityIsEscapedByRedrawingTheID() async throws {
        try await withIdentityTestApp { app, user, org, project, _ in
            let orgID = try org.requireID()
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "squatted-vm", project: project)
            let vmID = try vm.requireID()

            // Simulate a legacy or directly inserted row that bypassed the
            // `/vm/` reservation and claimed the URI a VM would be minted into.
            try await WorkloadRegistration(
                spiffeID: GuestIdentity.spiffeID(
                    forVM: vmID, trustDomain: PlatformTrustDomain.current),
                kind: .workload, organizationID: orgID
            ).save(on: app.db)

            // The `spiffe_id` unique index is the interim guard, and this is the
            // failure the create path's retry wrapper catches.
            await #expect(throws: (any Error).self) {
                try await GuestIdentity.register(
                    vmID: vmID, organizationID: orgID, createdBy: user.id, on: app.db)
            }

            // And this is why the retry is the answer: `retryingOnConstraintFailure`
            // resets `vm.id` between attempts, so the next attempt composes a
            // different URI and the squat no longer applies. A migration cannot
            // do this, which is why the backfill skips and warns instead.
            let redrawn = try await builder.createVM(name: "redrawn-vm", project: project)
            let redrawnID = try redrawn.requireID()
            #expect(redrawnID != vmID)
            let registration = try await GuestIdentity.register(
                vmID: redrawnID, organizationID: orgID, createdBy: user.id, on: app.db)
            #expect(
                registration.spiffeID
                    == GuestIdentity.spiffeID(
                        forVM: redrawnID, trustDomain: PlatformTrustDomain.current))
        }
    }

    // MARK: - Delete

    @Test("Reaping a VM removes its identity and the grants that principal held")
    func reapRemovesTheIdentityAndItsBindings() async throws {
        try await withIdentityTestApp { app, user, org, project, token in
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "doomed-vm", project: project)
            let vmID = try vm.requireID()

            let row = try await GuestIdentity.register(
                vmID: vmID, organizationID: try org.requireID(), createdBy: user.id, on: app.db)
            let registrationID = try row.requireID()

            // A grant the identity holds somewhere else entirely — the kind the
            // VM's own cascade would otherwise strand.
            try await RoleBindingService.grant(
                principalType: .workload, principalID: registrationID, role: .viewer,
                nodeType: .project, nodeID: try project.requireID(), createdBy: user.id,
                on: app.db)

            // A bystander workload, to prove the sweep is scoped rather than
            // a blanket delete of every workload principal.
            let bystander = WorkloadRegistration(
                spiffeID: "spiffe://\(PlatformTrustDomain.current)/sa/bystander",
                kind: .workload, organizationID: try org.requireID())
            try await bystander.save(on: app.db)
            let bystanderID = try bystander.requireID()
            try await RoleBindingService.grant(
                principalType: .workload, principalID: bystanderID, role: .viewer,
                nodeType: .project, nodeID: try project.requireID(), createdBy: user.id,
                on: app.db)

            vm.setFixtureDesiredStatus(.absent)
            try await vm.save(on: app.db)
            let reaped = try await VM.reap(vm, on: app.db, app: app)
            #expect(reaped)

            #expect(try await self.registration(forVM: vmID, on: app.db) == nil)
            #expect(try await WorkloadRegistration.find(registrationID, on: app.db) == nil)

            func bindingCount(_ principalID: UUID) async throws -> Int {
                try await RoleBinding.query(on: app.db)
                    .filter(\.$principalType == IAMPrincipalType.workload.rawValue)
                    .filter(\.$principalID == principalID)
                    .count()
            }
            #expect(try await bindingCount(registrationID) == 0)
            #expect(try await bindingCount(bystanderID) == 1)
        }
    }

    // MARK: - Revocation

    @Test("Revoking a VM's registration leaves the VM running with no identity")
    func revocationLeavesTheVMWithoutAnIdentity() async throws {
        try await withIdentityTestApp { app, user, org, project, token in
            let admin = try await TestDataBuilder(db: app.db).createUser(
                username: "identityadmin", email: "identityadmin@example.com",
                displayName: "Identity Admin", isSystemAdmin: true)
            let adminToken = try await admin.generateAPIKey(on: app.db)

            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "revoked-vm", project: project)
            let vmID = try vm.requireID()
            let row = try await GuestIdentity.register(
                vmID: vmID, organizationID: try org.requireID(), createdBy: user.id, on: app.db)

            try await app.test(.DELETE, "/api/workload-registrations/\(try row.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // One-way on purpose: the VM survives, and nothing re-creates the
            // row. A self-heal would undo the only revocation lever there is.
            #expect(try await VM.find(vmID, on: app.db) != nil)
            #expect(try await self.registration(forVM: vmID, on: app.db) == nil)
            #expect(try await GuestIdentity.spiffeID(forVM: vmID, on: app.db) == nil)

            try await app.test(.GET, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(VMBody.self)
                #expect(detail.spiffeId == nil)
                #expect(detail.instanceIdentityPrincipalId == nil)
                #expect(detail.instanceIdentityStatus == .revoked)
            }
        }
    }
}
