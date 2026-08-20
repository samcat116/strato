import ControlPlanePostgres
import Fluent
import SQLKit
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// STR-112: deleting a resource has to take its role bindings with it, because
/// `role_bindings` has no foreign key to the node it names.
///
/// The delete paths themselves are covered where they live (`VMOperationTests`,
/// `SandboxTests`, `DesiredStateReconciliationTests`, `ImageControllerTests`).
/// What these tests guard is the part no call site can assert: that
/// `ResourceBindingCleanup` still knows about every child the database quietly
/// deletes along with a VM or a sandbox.
@Suite("Resource Binding Cleanup", .serialized)
struct ResourceBindingCleanupTests {

    /// Delete actions Postgres records in `pg_constraint.confdeltype`. Only
    /// `c` — CASCADE — removes the child row, and so orphans its bindings.
    private static let cascadeDeleteAction = "c"

    @Test("Every cascading descendant of a declared parent is a node type the cleanup revokes")
    func cascadingChildrenAreCovered() async throws {
        try await withTestApp { app in
            let sql = try #require(app.db as? any SQLDatabase)

            /// The tables a delete of `table` removes, transitively — one
            /// cascade feeds the next, so `dns_records` go with a project
            /// through `dns_zones` even though no foreign key joins them.
            func cascadingTables(from table: String) async throws -> Set<String> {
                var seen: Set<String> = []
                var pending = [table]
                while let next = pending.popLast() {
                    let rows = try await sql.raw(
                        """
                        SELECT child.relname AS child_table
                        FROM pg_constraint AS fk
                        JOIN pg_class AS child ON child.oid = fk.conrelid
                        JOIN pg_class AS parent ON parent.oid = fk.confrelid
                        WHERE fk.contype = 'f'
                          AND fk.confdeltype = \(bind: Self.cascadeDeleteAction)
                          AND parent.relname = \(bind: next)
                        """
                    ).all()
                    for row in rows {
                        let child = try row.decode(column: "child_table", as: String.self)
                        // A self-referencing cascade (nested folders) would
                        // otherwise loop forever.
                        if seen.insert(child).inserted { pending.append(child) }
                    }
                }
                return seen
            }

            // The declared map names direct children only, and a parent
            // inherits its children's entries the same way the database
            // inherits their cascades.
            func declaredDescendants(of parent: IAMNodeType) -> Set<IAMNodeType> {
                var seen: Set<IAMNodeType> = []
                var pending = ResourceBindingCleanup.cascadingChildren[parent] ?? []
                while let next = pending.popLast() {
                    guard seen.insert(next).inserted else { continue }
                    pending.append(contentsOf: ResourceBindingCleanup.cascadingChildren[next] ?? [])
                }
                return seen
            }

            // Principals inherit down the same chain: a project's accounts are
            // an organization's too, because its projects are.
            func declaredPrincipals(of parent: IAMNodeType) -> Set<IAMPrincipalType> {
                var principals = Set(ResourceBindingCleanup.cascadingPrincipals[parent] ?? [])
                for node in declaredDescendants(of: parent) {
                    principals.formUnion(ResourceBindingCleanup.cascadingPrincipals[node] ?? [])
                }
                return principals
            }

            // The set the helper declares is inert on its own; hold it against
            // the schema the database actually enforces. A new child table
            // added with ON DELETE CASCADE would otherwise compile and pass
            // while leaking its bindings on every parent delete — the exact
            // failure STR-112 and STR-137 were.
            let parents = Set(ResourceBindingCleanup.cascadingChildren.keys)
                .union(ResourceBindingCleanup.cascadingPrincipals.keys)
            for parent in parents {
                let declared = declaredDescendants(of: parent)
                let tables = try await cascadingTables(from: parent.table)

                // Only cascading children that are themselves bindable matter:
                // a NIC or an interface-address row carries no bindings, so its
                // removal orphans nothing.
                let bindableChildren = IAMNodeType.allCases.filter { tables.contains($0.table) }
                for child in bindableChildren {
                    #expect(
                        declared.contains(child),
                        """
                        \(child.rawValue) rows cascade away with \(parent.rawValue) rows, \
                        so their bindings orphan on every \(parent.rawValue) delete. \
                        Add it to ResourceBindingCleanup.cascadingChildren and revoke it.
                        """)
                }

                // The principal half. A cascading principal table strands the
                // bindings its rows *hold*, which the node-keyed check above
                // cannot see: nothing binds to a group or a registration, so
                // neither is an IAMNodeType at all.
                let declaredHolders = declaredPrincipals(of: parent)
                let cascadingPrincipals = IAMPrincipalType.allCases.filter { tables.contains($0.table) }
                for principal in cascadingPrincipals {
                    #expect(
                        declaredHolders.contains(principal),
                        """
                        \(principal.rawValue) rows cascade away with \(parent.rawValue) rows, \
                        so the bindings they hold orphan on every \(parent.rawValue) delete. \
                        Add it to ResourceBindingCleanup.cascadingPrincipals and revoke it.
                        """)
                }
            }
        }
    }

    @Test("Revoking for a deleted VM clears the VM's bindings and its checkpoints'")
    func revokesVMAndCheckpoints() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(username: "cleanup", email: "cleanup@example.com")
            let org = try await builder.createOrganization(name: "Cleanup Org")
            let project = try await builder.createProject(
                name: "Cleanup Project", description: "binding cleanup", organization: org)
            let vm = try await builder.createVM(name: "cleanup-vm", project: project)
            let vmID = try vm.requireID()

            let snapshot = VMSnapshot(
                name: "checkpoint", vmID: vmID, projectID: project.id!,
                environment: vm.environment, agentId: nil, createdByID: user.id!)
            try await snapshot.save(on: app.db)
            let snapshotID = try snapshot.requireID()

            // A sibling VM's binding stands in for every binding the sweep must
            // not touch.
            let bystander = try await builder.createVM(name: "bystander-vm", project: project)
            let bystanderID = try bystander.requireID()

            for (nodeType, nodeID) in [
                (IAMNodeType.virtualMachine, vmID),
                (.vmSnapshot, snapshotID),
                (.virtualMachine, bystanderID),
            ] {
                try await RoleBindingService.grant(
                    principalType: .user, principalID: user.id!, role: .admin,
                    nodeType: nodeType, nodeID: nodeID, createdBy: user.id!, on: app.db)
            }

            try await ResourceBindingCleanup.revokeBindings(forDeletedVM: vmID, on: app.db)

            func count(_ nodeType: IAMNodeType, _ nodeID: UUID) async throws -> Int {
                try await LegacyRoleBindingStore.bindings(
                    nodeType: nodeType.rawValue,
                    nodeID: nodeID,
                    on: app.db
                ).count
            }
            let vmBindings = try await count(.virtualMachine, vmID)
            let snapshotBindings = try await count(.vmSnapshot, snapshotID)
            let bystanderBindings = try await count(.virtualMachine, bystanderID)
            #expect(vmBindings == 0)
            #expect(snapshotBindings == 0)
            #expect(bystanderBindings == 1)
        }
    }

    @Test("Revoking for a deleted VM clears the grants its instance identity held")
    func revokesVMInstanceIdentityGrants() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(
                username: "identitycleanup", email: "identitycleanup@example.com")
            let org = try await builder.createOrganization(name: "Identity Cleanup Org")
            let orgID = try org.requireID()
            let project = try await builder.createProject(
                name: "Identity Cleanup Project", description: "identity cleanup", organization: org)
            let projectID = try project.requireID()
            let vm = try await builder.createVM(name: "identified-vm", project: project)
            let vmID = try vm.requireID()

            // The VM's own principal (STR-55), holding a grant somewhere the
            // VM's delete does not reach — this is the row the `vm_id` cascade
            // would strand.
            let identity = try await GuestIdentity.register(
                vmID: vmID, organizationID: orgID, createdBy: user.id, on: app.db)
            let identityID = identity.id

            // A workload principal with no VM behind it, standing in for every
            // registration the sweep must not touch.
            let bystander = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: "spiffe://strato.local/sa/bystander",
                    kind: WorkloadRegistrationKind.workload.rawValue,
                    organizationID: orgID),
                on: app.db)
            let bystanderID = bystander.id

            for principalID in [identityID, bystanderID] {
                try await RoleBindingService.grant(
                    principalType: .workload, principalID: principalID, role: .viewer,
                    nodeType: .project, nodeID: projectID, createdBy: user.id!, on: app.db)
            }

            try await ResourceBindingCleanup.revokeBindings(forDeletedVM: vmID, on: app.db)

            func count(_ principalID: UUID) async throws -> Int {
                try await LegacyRoleBindingStore.bindings(
                    principalType: IAMPrincipalType.workload.rawValue,
                    principalID: principalID,
                    on: app.db
                ).count
            }
            let identityBindings = try await count(identityID)
            let bystanderBindings = try await count(bystanderID)
            #expect(identityBindings == 0)
            #expect(bystanderBindings == 1)
        }
    }

    @Test("Revoking for a deleted project clears every node that cascades away with it")
    func revokesProjectAndCascadingChildren() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(username: "proj", email: "proj@example.com")
            let org = try await builder.createOrganization(name: "Project Cleanup Org")
            let project = try await builder.createProject(
                name: "Doomed", description: "cascades away", organization: org)
            let nodes = try await Self.populate(project: project, owner: user, app: app)

            // A project that shares nothing but the organization: its bindings
            // stand in for every binding the sweep must not touch.
            let bystander = try await builder.createProject(
                name: "Bystander", description: "stays", organization: org)
            let bystanderNodes = try await Self.populate(project: bystander, owner: user, app: app)

            for (nodeType, nodeID) in nodes + bystanderNodes {
                try await RoleBindingService.grant(
                    principalType: .user, principalID: user.id!, role: .admin,
                    nodeType: nodeType, nodeID: nodeID, createdBy: user.id!, on: app.db)
            }
            // The doomed project's service account also holds a grant of its
            // own, on a node outside the project entirely — the principal
            // direction, which a node-keyed sweep alone would miss.
            let serviceAccountID = try #require(nodes.first { $0.0 == .serviceAccount }?.1)
            try await RoleBindingService.grant(
                principalType: .serviceAccount, principalID: serviceAccountID, role: .viewer,
                nodeType: .organization, nodeID: org.id!, createdBy: user.id!, on: app.db)

            try await ResourceBindingCleanup.revokeBindings(
                forDeletedProject: try project.requireID(), on: app.db)

            for (nodeType, nodeID) in nodes {
                let remaining = try await Self.bindingCount(nodeType, nodeID, on: app.db)
                #expect(remaining == 0, "\(nodeType.rawValue) bindings survived the project delete")
            }
            for (nodeType, nodeID) in bystanderNodes {
                let remaining = try await Self.bindingCount(nodeType, nodeID, on: app.db)
                #expect(remaining == 1, "\(nodeType.rawValue) bindings of an unrelated project were swept")
            }
            let heldByAccount = try await LegacyRoleBindingStore.bindings(
                principalType: IAMPrincipalType.serviceAccount.rawValue,
                principalID: serviceAccountID,
                on: app.db
            ).count
            #expect(heldByAccount == 0)
        }
    }

    @Test("Revoking for a deleted DNS zone clears its authored records' bindings")
    func revokesZoneAndRecords() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(username: "dns", email: "dns@example.com")
            let org = try await builder.createOrganization(name: "DNS Cleanup Org")
            let project = try await builder.createProject(
                name: "DNS", description: "", organization: org)
            let projectID = try project.requireID()

            let zone = try await LegacyDNSZoneStore.insert(
                name: "acme.internal", projectID: projectID, on: app.db)
            let record = try await LegacyDNSRecordStore.insert(
                zoneID: zone.id, name: "www", type: .a,
                value: "192.0.2.1", on: app.db)

            // A record in a second zone: it cascades with *its* zone, not this
            // one, so the sweep must key on the zone rather than the project.
            let otherZone = try await LegacyDNSZoneStore.insert(
                name: "other.internal", projectID: projectID, on: app.db)
            let otherRecord = try await LegacyDNSRecordStore.insert(
                zoneID: otherZone.id, name: "www", type: .a,
                value: "192.0.2.2", on: app.db)

            for (nodeType, nodeID) in [
                (IAMNodeType.dnsZone, zone.id),
                (.dnsRecord, record.id),
                (.dnsZone, otherZone.id),
                (.dnsRecord, otherRecord.id),
            ] {
                try await RoleBindingService.grant(
                    principalType: .user, principalID: user.id!, role: .admin,
                    nodeType: nodeType, nodeID: nodeID, createdBy: user.id!, on: app.db)
            }

            try await ResourceBindingCleanup.revokeBindings(
                forDeletedDNSZone: zone.id, on: app.db)

            let zoneBindings = try await Self.bindingCount(.dnsZone, zone.id, on: app.db)
            let recordBindings = try await Self.bindingCount(.dnsRecord, record.id, on: app.db)
            let otherZoneBindings = try await Self.bindingCount(
                .dnsZone, otherZone.id, on: app.db)
            let otherRecordBindings = try await Self.bindingCount(
                .dnsRecord, otherRecord.id, on: app.db)
            #expect(zoneBindings == 0)
            #expect(recordBindings == 0)
            #expect(otherZoneBindings == 1)
            #expect(otherRecordBindings == 1)
        }
    }

    @Test("Revoking for a deleted folder clears the subtree it cascades")
    func revokesFolderSubtree() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(username: "folder", email: "folder@example.com")
            let org = try await builder.createOrganization(name: "Folder Cleanup Org")
            let folder = try await builder.createOU(name: "team", description: "", organization: org)
            let nested = try await builder.createOU(
                name: "sub", description: "", organization: org, parentOU: folder)
            let project = try await builder.createProject(
                name: "Nested", description: "cascades away", ou: nested)
            var nodes = try await Self.populate(project: project, owner: user, app: app)
            nodes.append((.organizationalUnit, try folder.requireID()))
            nodes.append((.organizationalUnit, try nested.requireID()))

            let sibling = try await builder.createOU(name: "other", description: "", organization: org)
            let siblingID = try sibling.requireID()

            for (nodeType, nodeID) in nodes + [(.organizationalUnit, siblingID)] {
                try await RoleBindingService.grant(
                    principalType: .user, principalID: user.id!, role: .admin,
                    nodeType: nodeType, nodeID: nodeID, createdBy: user.id!, on: app.db)
            }

            try await ResourceBindingCleanup.revokeBindings(forDeletedFolder: folder, on: app.db)

            for (nodeType, nodeID) in nodes {
                let remaining = try await Self.bindingCount(nodeType, nodeID, on: app.db)
                #expect(remaining == 0, "\(nodeType.rawValue) bindings survived the folder delete")
            }
            let siblingBindings = try await Self.bindingCount(.organizationalUnit, siblingID, on: app.db)
            #expect(siblingBindings == 1)
        }
    }

    @Test("Revoking for a deleted organization clears its folders, projects, and their children")
    func revokesOrganizationSubtree() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(username: "orgdel", email: "orgdel@example.com")
            let org = try await builder.createOrganization(name: "Org Cleanup Org")
            let organizationID = try org.requireID()
            let folder = try await builder.createOU(name: "team", description: "", organization: org)
            let folderProject = try await builder.createProject(
                name: "In Folder", description: "", ou: folder)
            let orgProject = try await builder.createProject(
                name: "In Org", description: "", organization: org)

            var nodes: [(IAMNodeType, UUID)] = [
                (.organization, organizationID),
                (.organizationalUnit, try folder.requireID()),
            ]
            nodes += try await Self.populate(project: folderProject, owner: user, app: app)
            nodes += try await Self.populate(project: orgProject, owner: user, app: app)

            // Groups and workload registrations cascade on `organization_id`
            // and are binding principals, never nodes, so only the principal
            // direction reclaims their grants.
            let group = try await builder.createGroup(name: "team", description: "", organization: org)
            let groupID = try group.requireID()
            let workload = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: "spiffe://example.org/workload/ci",
                    kind: WorkloadRegistrationKind.workload.rawValue,
                    organizationID: organizationID,
                    displayName: "ci"),
                on: app.db)
            let workloadID = workload.id

            let other = try await builder.createOrganization(name: "Untouched Org")
            let otherID = try other.requireID()

            for (nodeType, nodeID) in nodes + [(.organization, otherID)] {
                try await RoleBindingService.grant(
                    principalType: .user, principalID: user.id!, role: .admin,
                    nodeType: nodeType, nodeID: nodeID, createdBy: user.id!, on: app.db)
            }
            for (principalType, principalID) in [
                (IAMPrincipalType.group, groupID), (.workload, workloadID),
            ] {
                try await RoleBindingService.grant(
                    principalType: principalType, principalID: principalID, role: .viewer,
                    nodeType: .organization, nodeID: otherID, createdBy: user.id!, on: app.db)
            }

            try await ResourceBindingCleanup.revokeBindings(
                forDeletedOrganization: organizationID, on: app.db)

            for (nodeType, nodeID) in nodes {
                let remaining = try await Self.bindingCount(nodeType, nodeID, on: app.db)
                #expect(remaining == 0, "\(nodeType.rawValue) bindings survived the organization delete")
            }
            for (principalType, principalID) in [
                (IAMPrincipalType.group, groupID), (.workload, workloadID),
            ] {
                let held = try await LegacyRoleBindingStore.bindings(
                    principalType: principalType.rawValue,
                    principalID: principalID,
                    on: app.db
                ).count
                #expect(held == 0, "\(principalType.rawValue) grants survived the organization delete")
            }
            // The other org's own node binding is those former grants'
            // neighbour: sweeping the principal must not take the node with it.
            let otherBindings = try await Self.bindingCount(.organization, otherID, on: app.db)
            #expect(otherBindings == 1)
        }
    }

    // MARK: - The endpoints, not just the helper

    // The tests above prove the sweeps do what they say. These prove the four
    // container delete endpoints actually call them: without one, deleting the
    // helper's call site from a controller leaves the whole suite green and the
    // leak comes back unnoticed.

    @Test("Deleting a project through the API takes its children's bindings with it")
    func projectEndpointRevokesCascadingBindings() async throws {
        try await withContainerDeleteApp { app, user, org, token in
            let builder = TestDataBuilder(app: app)
            let project = try await builder.createProject(
                name: "Doomed", description: "", organization: org)
            let nodes = try await Self.populate(project: project, owner: user, app: app)
            try await Self.grantAll(nodes, to: user, on: app.db)

            try await app.test(.DELETE, "/api/projects/\(try project.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            try await Self.expectNoBindings(nodes, on: app.db)
        }
    }

    @Test("A project delete refused for its workloads leaves every binding in place")
    func refusedProjectDeleteKeepsBindings() async throws {
        try await withContainerDeleteApp { app, user, org, token in
            let builder = TestDataBuilder(app: app)
            let project = try await builder.createProject(
                name: "Occupied", description: "", organization: org)
            let nodes = try await Self.populate(project: project, owner: user, app: app)
            try await Self.grantAll(nodes, to: user, on: app.db)
            _ = try await builder.createVM(name: "resident", project: project)

            try await app.test(.DELETE, "/api/projects/\(try project.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // The sweep now spans the whole project subtree rather than just
            // its service accounts, so a refusal has that much more to put
            // back. This exercises the endpoint's pre-check; the other refusal
            // path — a VM committed after the check, caught by the RESTRICT
            // foreign key — rolls back the same transaction but cannot be
            // provoked without interleaving a commit mid-request.
            for (nodeType, nodeID) in nodes {
                let remaining = try await Self.bindingCount(nodeType, nodeID, on: app.db)
                #expect(remaining == 1, "\(nodeType.rawValue) bindings were swept by a refused delete")
            }
        }
    }

    @Test("Deleting a folder through the API takes its own bindings with it")
    func folderEndpointRevokesBindings() async throws {
        try await withContainerDeleteApp { app, user, org, token in
            let builder = TestDataBuilder(app: app)
            let folder = try await builder.createOU(name: "team", description: "", organization: org)
            let folderID = try folder.requireID()
            try await Self.grantAll([(.organizationalUnit, folderID)], to: user, on: app.db)

            try await app.test(
                .DELETE, "/api/organizations/\(try org.requireID())/ous/\(folderID)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            try await Self.expectNoBindings([(.organizationalUnit, folderID)], on: app.db)
        }
    }

    @Test("Deleting an organization through the API takes its whole subtree's bindings")
    func organizationEndpointRevokesSubtreeBindings() async throws {
        try await withContainerDeleteApp { app, user, org, token in
            let builder = TestDataBuilder(app: app)
            let organizationID = try org.requireID()
            let folder = try await builder.createOU(name: "team", description: "", organization: org)
            let project = try await builder.createProject(name: "In Folder", description: "", ou: folder)
            var nodes: [(IAMNodeType, UUID)] = [
                (.organization, organizationID), (.organizationalUnit, try folder.requireID()),
            ]
            nodes += try await Self.populate(project: project, owner: user, app: app)
            try await Self.grantAll(nodes, to: user, on: app.db)

            try await app.test(.DELETE, "/api/organizations/\(organizationID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            try await Self.expectNoBindings(nodes, on: app.db)
        }
    }

    /// An app with an org admin holding an API key — the caller every container
    /// delete endpoint demands.
    private func withContainerDeleteApp(
        _ test: (Application, User, Organization, String) async throws -> Void
    ) async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(username: "container", email: "container@example.com")
            let org = try await builder.createOrganization(name: "Container Delete Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            let token = try await user.generateAPIKey(on: app)
            try await test(app, user, org, token)
        }
    }

    private static func grantAll(
        _ nodes: [(IAMNodeType, UUID)], to user: User, on db: any Database
    ) async throws {
        for (nodeType, nodeID) in nodes {
            try await RoleBindingService.grant(
                principalType: .user, principalID: try user.requireID(), role: .admin,
                nodeType: nodeType, nodeID: nodeID, createdBy: user.id!, on: db)
        }
    }

    private static func expectNoBindings(
        _ nodes: [(IAMNodeType, UUID)], on db: any Database
    ) async throws {
        for (nodeType, nodeID) in nodes {
            let remaining = try await bindingCount(nodeType, nodeID, on: db)
            #expect(remaining == 0, "\(nodeType.rawValue) bindings survived the delete endpoint")
        }
    }

    /// One row of every node type that cascades away with a project, returned
    /// as the (type, id) pairs a binding sweep has to reach.
    private static func populate(
        project: Project, owner: User, app: Application
    ) async throws -> [(IAMNodeType, UUID)] {
        let db = app.db
        let projectID = try project.requireID()
        let ownerID = try owner.requireID()
        let suffix = projectID.uuidString.prefix(8)
        // This suite deletes the project or organization under test. Keep the
        // required network/pool site outside that ownership tree because site
        // deletion has its own guarded lifecycle and a RESTRICT owner FK.
        let site = Site(name: "cleanup-site-\(suffix)")
        try await site.save(on: db)
        let siteID = try site.requireID()

        let image = Image(
            name: "image-\(suffix)", description: "", projectID: projectID,
            status: .ready, uploadedByID: ownerID)
        try await image.save(on: db)

        let network = LogicalNetwork(
            name: "default", subnet: "192.168.1.0/24", gateway: "192.168.1.1",
            projectID: projectID, siteID: siteID)
        try await network.save(on: db)

        let securityGroup = try await LegacySecurityGroupStore.insert(
            projectID: projectID, name: "default", on: db)

        // Pools are org-scoped, not project-scoped, so each project needs its
        // own only to keep the (pool, address) unique index happy.
        let pool = try await TestDataBuilder(app: app).createFloatingIPPool(
            name: "pool-\(suffix)", cidr: "203.0.113.0/24", siteID: siteID,
            organizationID: project.organizationID,
            organizationalUnitID: project.organizationalUnitID)
        let floatingIP = try await LegacyFloatingIPStore.insert(
            poolID: pool.id, address: "203.0.113.5", projectID: projectID, on: db)

        let zone = try await LegacyDNSZoneStore.insert(
            name: "acme.internal", projectID: projectID, on: db)
        let record = try await LegacyDNSRecordStore.insert(
            zoneID: zone.id, name: "www", type: .a,
            value: "192.0.2.1", on: db)

        let volume = Volume(
            name: "data", description: "", projectID: projectID, environment: "development", size: 1024,
            createdByID: ownerID)
        try await volume.save(on: db)
        let volumeSnapshot = VolumeSnapshot(
            name: "snap", description: "", volumeID: try volume.requireID(), projectID: projectID,
            environment: "development",
            size: 1024, createdByID: ownerID)
        try await volumeSnapshot.save(on: db)

        let serviceAccount = try await LegacyServiceAccountStore.insert(
            ServiceAccountWrite(name: "runner", projectID: projectID), on: db)

        return [
            (.project, projectID),
            (.image, try image.requireID()),
            (.network, try network.requireID()),
            (.securityGroup, securityGroup.id),
            (.floatingIP, floatingIP.id),
            (.dnsZone, zone.id),
            (.dnsRecord, record.id),
            (.volume, try volume.requireID()),
            (.volumeSnapshot, try volumeSnapshot.requireID()),
            (.serviceAccount, serviceAccount.id),
        ]
    }

    private static func bindingCount(
        _ nodeType: IAMNodeType, _ nodeID: UUID, on db: any Database
    ) async throws -> Int {
        try await LegacyRoleBindingStore.bindings(
            nodeType: nodeType.rawValue,
            nodeID: nodeID,
            on: db
        ).count
    }
}
