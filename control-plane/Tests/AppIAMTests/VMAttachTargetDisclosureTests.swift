import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Every endpoint that takes a VM id in its *body* answers "the VM you named
/// isn't reachable by you" the same way, and that answer says nothing about
/// whether the VM exists (issue #881).
///
/// Volume attach, security-group attach and detach, and floating-IP attach all
/// take a VM id in the request body, look it up, and then check `update` on it.
/// They had drifted to three answers for the same condition — `404 "VM not
/// found"`, and two spellings of `400 "VM {id} does not exist"` — and each of
/// those answers arrived *before* any authorization check, so an unknown id and
/// a VM in another tenant's project were distinguishable to a caller who could
/// see neither: an existence oracle over VM ids.
///
/// The fix is `Request.reachableVM(_:action:)`: one `404` for both cases at
/// every site. These tests pin the status and the indistinguishability — the
/// reasons must match once the id is elided, not merely share a status — and
/// pin that the refusal is not unconditional, by checking that a caller who
/// *can* reach the VM gets past it to the containment guard behind it.
///
/// Not pinned here, because it is deliberately still split: the `sandboxId`
/// half of security-group attach/detach, which resolves through
/// `Request.authorizedSandbox` and answers `404` absent / `403` forbidden. The
/// scope of #881 was VMs; the sandbox oracle is the same shape and awaits
/// parity (see `docs/architecture/iam.md`).
///
/// The sibling refusal, "the two resources you named live in different
/// projects", is pinned in `CrossProjectContainmentTests`.
@Suite("VM Attach Target Disclosure Tests", .serialized)
struct VMAttachTargetDisclosureTests {

    /// The attachable resource, by id — one per endpoint under test.
    ///
    /// Security-group detach is its own case rather than a flag: it shares
    /// `resolveTargetNIC` with attach, which is exactly why it must be pinned
    /// separately — nothing but a test stops a refactor from splitting the two
    /// resolvers and leaving detach on a raw `VM.find`.
    private enum AttachEndpoint {
        case volume(UUID)
        case securityGroup(UUID)
        case securityGroupDetach(UUID)
        case floatingIP(UUID)
    }

    private struct Fixture {
        let app: Application
        /// Holds the volume, security group, and floating IP.
        let home: Project
        /// Holds the VM. The editor has no rights here.
        let other: Project
        let volumeId: UUID
        let groupId: UUID
        let floatingIpId: UUID
        /// A real VM in `other`: exists, and is forbidden to the editor.
        let foreignVMId: UUID
        let adminToken: String
        /// Editor on `home` only — clears the check on the attachable resource
        /// and fails the one on the VM, which is the case under test.
        let homeEditorToken: String
    }

    /// A refusal reduced to what a client can act on. Vapor's error body is
    /// JSON with no guaranteed key order, so two answers have to be compared
    /// field by field rather than as raw strings.
    private struct Refusal {
        let status: HTTPStatus
        let reason: String
    }

    private struct ErrorBody: Content {
        let reason: String
    }

    private static func refusal(from res: TestingHTTPResponse) -> Refusal {
        let reason = (try? res.content.decode(ErrorBody.self).reason) ?? res.body.string
        return Refusal(status: res.status, reason: reason)
    }

    private func withApp(_ test: (Fixture) async throws -> Void) async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "disclosure-admin",
                email: "disclosure-admin@example.com",
                displayName: "Disclosure Admin",
                isSystemAdmin: true)
            let org = try await builder.createOrganization(name: "Disclosure Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            admin.currentOrganizationId = org.id
            try await admin.save(on: app.db)

            let home = try await builder.createProject(
                name: "Home Project", description: "Owns the attachable resources", organization: org)
            let other = try await builder.createProject(
                name: "Other Project", description: "Owns the VM being named", organization: org)
            let site = try await builder.placementSite(for: home)

            let editor = try await builder.createUser(
                username: "disclosure-editor",
                email: "disclosure-editor@example.com",
                displayName: "Disclosure Editor")
            try await builder.addUserToOrganization(user: editor, organization: org, role: "member")
            editor.currentOrganizationId = org.id
            try await editor.save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: try editor.requireID(), role: .editor,
                nodeType: .project, nodeID: try home.requireID(), createdBy: nil, on: app.db)

            // The attachable resources, written directly: every guard under
            // test fires before any of them is realized. The volume must be
            // `available` to clear `canAttach`, which precedes the VM lookup.
            let volume = Volume(
                name: "disclosure-volume",
                description: "volume whose attach names a foreign VM",
                projectID: try home.requireID(), environment: "development",
                size: 10 * 1024 * 1024 * 1024,
                status: .available,
                createdByID: try admin.requireID())
            try await volume.save(on: app.db)
            try await placeVolume(
                volume,
                on: "agent-that-is-not-connected",
                at: "/var/lib/strato/volumes/disclosure/volume.qcow2",
                using: app.db
            )

            let group = SecurityGroup(projectID: try home.requireID(), name: "disclosure-group")
            try await group.save(on: app.db)

            let pool = FloatingIPPool(
                name: "disclosure-edge", cidr: "203.0.113.0/29", gateway: "203.0.113.1",
                siteID: try site.requireID(),
                organizationScope: .organization(try org.requireID()))
            try await pool.save(on: app.db)
            let floatingIP = FloatingIP(
                poolID: try pool.requireID(), address: "203.0.113.2",
                projectID: try home.requireID(), createdByID: try admin.requireID())
            try await floatingIP.save(on: app.db)

            // A VM the editor cannot touch, with a NIC so that nothing behind
            // the check under test could fail first for want of one.
            let network = try await builder.createNetwork(
                name: "disclosure-net", project: other, subnet: "10.95.0.0/24",
                gateway: "10.95.0.1", site: site)
            let vm = try await builder.createVM(name: "disclosure-vm", project: other)
            let nic = VMNetworkInterface(
                vmID: try vm.requireID(), logicalNetworkID: try network.requireID(),
                macAddress: MACAllocator.generateCandidate().description)
            try await nic.save(on: app.db)
            try await VMInterfaceAddress(
                interfaceID: try nic.requireID(), logicalNetworkID: try network.requireID(),
                family: .ipv4, address: "10.95.0.5", prefixLength: 24, gateway: network.gateway
            ).save(on: app.db)

            try await test(
                Fixture(
                    app: app, home: home, other: other,
                    volumeId: try volume.requireID(),
                    groupId: try group.requireID(),
                    floatingIpId: try floatingIP.requireID(),
                    foreignVMId: try vm.requireID(),
                    adminToken: try await admin.generateAPIKey(on: app.db),
                    homeEditorToken: try await editor.generateAPIKey(on: app.db)))
        }
    }

    /// POSTs the endpoint's attach — or detach — with `vmId` in the body and
    /// reports what came back.
    private func attach(
        _ endpoint: AttachEndpoint, vmId: UUID, as token: String, on app: Application
    ) async throws -> Refusal {
        var result = Refusal(status: .ok, reason: "")
        switch endpoint {
        case .volume(let volumeId):
            try await app.test(.POST, "/api/volumes/\(volumeId)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    AttachVolumeRequest(vmId: vmId, deviceName: nil, bootOrder: nil, readonly: nil))
            } afterResponse: { res in
                result = Self.refusal(from: res)
            }
        case .securityGroup(let groupId):
            try await app.test(.POST, "/api/security-groups/\(groupId)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vmId))
            } afterResponse: { res in
                result = Self.refusal(from: res)
            }
        case .securityGroupDetach(let groupId):
            try await app.test(.POST, "/api/security-groups/\(groupId)/detach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(AttachSecurityGroupRequest(vmId: vmId))
            } afterResponse: { res in
                result = Self.refusal(from: res)
            }
        case .floatingIP(let floatingIpId):
            try await app.test(.POST, "/api/floating-ips/\(floatingIpId)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(["vmId": vmId.uuidString])
            } afterResponse: { res in
                result = Self.refusal(from: res)
            }
        }
        return result
    }

    /// The shared assertion: an unknown id and a VM the caller may not touch
    /// are answered `404`, identically once the id is elided.
    private func expectIndistinguishable(
        _ endpoint: AttachEndpoint, fixture: Fixture, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let unknownId = UUID()
        let unknown = try await attach(
            endpoint, vmId: unknownId, as: fixture.homeEditorToken, on: fixture.app)
        let forbidden = try await attach(
            endpoint, vmId: fixture.foreignVMId, as: fixture.homeEditorToken, on: fixture.app)

        #expect(unknown.status == .notFound, sourceLocation: sourceLocation)
        #expect(forbidden.status == .notFound, sourceLocation: sourceLocation)
        #expect(
            unknown.reason.replacingOccurrences(of: unknownId.uuidString, with: "")
                == forbidden.reason.replacingOccurrences(
                    of: fixture.foreignVMId.uuidString, with: ""),
            sourceLocation: sourceLocation)
    }

    // MARK: - One answer per site

    @Test("Volume attach cannot tell a missing VM from a forbidden one")
    func volumeAttachHidesExistence() async throws {
        try await withApp { fixture in
            // Was `404 "VM not found"` for the missing one and `403` for the
            // forbidden one.
            try await self.expectIndistinguishable(.volume(fixture.volumeId), fixture: fixture)

            // Nothing was bound on the way to the refusal.
            let volume = try #require(try await Volume.find(fixture.volumeId, on: fixture.app.db))
            #expect(volume.$vm.id == nil)
            #expect(volume.status == .available)
        }
    }

    @Test("Security-group attach cannot tell a missing VM from a forbidden one")
    func securityGroupAttachHidesExistence() async throws {
        try await withApp { fixture in
            // Was `400 "VM {id} does not exist"` ahead of any check at all.
            try await self.expectIndistinguishable(.securityGroup(fixture.groupId), fixture: fixture)

            let memberships = try await VMInterfaceSecurityGroup.query(on: fixture.app.db).count()
            #expect(memberships == 0)
        }
    }

    @Test("Security-group detach cannot tell a missing VM from a forbidden one")
    func securityGroupDetachHidesExistence() async throws {
        try await withApp { fixture in
            // Detach resolves its target through the same `resolveTargetNIC`,
            // so it moved off `400 "VM {id} does not exist"` with attach. The
            // group need not be attached to anything: the target resolution
            // refuses before the membership read.
            try await self.expectIndistinguishable(
                .securityGroupDetach(fixture.groupId), fixture: fixture)
        }
    }

    @Test("Floating-IP attach cannot tell a missing VM from a forbidden one")
    func floatingIPAttachHidesExistence() async throws {
        try await withApp { fixture in
            // Was `400 "VM {id} does not exist"` ahead of any check at all.
            try await self.expectIndistinguishable(.floatingIP(fixture.floatingIpId), fixture: fixture)

            let floatingIP = try #require(
                try await FloatingIP.find(fixture.floatingIpId, on: fixture.app.db))
            #expect(floatingIP.$interface.id == nil)
        }
    }

    // MARK: - The same status at every site, and not unconditionally

    /// Every site that takes a body-supplied `vmId`.
    private static func allEndpoints(_ fixture: Fixture) -> [AttachEndpoint] {
        [
            .volume(fixture.volumeId),
            .securityGroup(fixture.groupId),
            .securityGroupDetach(fixture.groupId),
            .floatingIP(fixture.floatingIpId),
        ]
    }

    @Test("Every endpoint taking a body vmId answers one status for an unknown id")
    func allSitesAgreeOnUnknownVM() async throws {
        try await withApp { fixture in
            for endpoint in Self.allEndpoints(fixture) {
                let refusal = try await self.attach(
                    endpoint, vmId: UUID(), as: fixture.adminToken, on: fixture.app)
                // Even for a system admin: the id names nothing, so there is
                // nothing to authorize and nothing to disclose.
                #expect(refusal.status == .notFound)
            }
        }
    }

    @Test("A caller who can reach the VM gets the refusal behind the check, not 404")
    func reachableVMFallsThroughToContainment() async throws {
        try await withApp { fixture in
            // The admin holds rights in both projects — the case the
            // containment guard exists for. Reaching a `400` proves the `404`
            // above is the VM check answering, not a blanket not-found.
            for endpoint in Self.allEndpoints(fixture) {
                let refusal = try await self.attach(
                    endpoint, vmId: fixture.foreignVMId, as: fixture.adminToken, on: fixture.app)
                #expect(refusal.status == .badRequest)
                #expect(refusal.reason.contains("belongs to a different project than"))
            }
        }
    }
}
