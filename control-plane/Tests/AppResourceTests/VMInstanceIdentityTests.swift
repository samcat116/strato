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
            // An operator-facing label snapshotted at create, not a second name
            // for the identity: the id in the path is the identity.
            #expect(row.displayName == "identified-vm")
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

            // The `202` a create answers with.
            #expect(created.spiffeId == expected)

            try await app.test(.GET, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let detail = try res.content.decode(VMBody.self)
                #expect(detail.spiffeId == expected)
            }

            try await app.test(.GET, "/api/vms/\(vmID)/status") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let status = try res.content.decode(VMBody.self)
                #expect(status.spiffeId == expected)
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
            }
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
                vmID: vmID, organizationID: try org.requireID(), displayName: vm.name,
                createdBy: user.id, on: app.db)
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

            vm.setDesiredStatus(.absent)
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
        try await withIdentityTestApp { app, user, org, project, _ in
            let admin = try await TestDataBuilder(db: app.db).createUser(
                username: "identityadmin", email: "identityadmin@example.com",
                displayName: "Identity Admin", isSystemAdmin: true)
            let adminToken = try await admin.generateAPIKey(on: app.db)

            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "revoked-vm", project: project)
            let vmID = try vm.requireID()
            let row = try await GuestIdentity.register(
                vmID: vmID, organizationID: try org.requireID(), displayName: vm.name,
                createdBy: user.id, on: app.db)

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
        }
    }
}
