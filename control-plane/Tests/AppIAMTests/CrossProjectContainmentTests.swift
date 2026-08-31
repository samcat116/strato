import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Every endpoint that refuses "the two resources you named live in different
/// projects" answers the same way (issue #777).
///
/// The refusals were hand-written per site and had drifted across `400`, `403`,
/// and `409`, so no client could branch on status to recognize a containment
/// failure. They route through `ProjectContainment` now; these tests pin the
/// status and the shared wording at each site so the next one cannot quietly
/// pick a different answer.
///
/// Two sites deliberately answer something else, and are pinned here as such:
/// where nothing authorizes the caller against the resource the request body
/// names, the lookup is scoped to the caller's own project and a resource
/// elsewhere is reported as plain not-found — a containment message there would
/// itself be the disclosure the ordering rule exists to prevent.
///
/// Volume attach — the site that prompted the audit — is pinned in
/// `VolumeAttachProjectContainmentTests`.
@Suite("Cross-Project Containment Tests", .serialized)
final class CrossProjectContainmentTests {

    /// The wording every site shares: "<subject> belongs to a different project
    /// than <object>".
    private static let sharedReason = "belongs to a different project than"

    private struct Fixture {
        let app: Application
        let org: Organization
        /// Holds the security group / floating IP / DNS zone under test.
        let home: Project
        /// A second project the admin caller also has full rights in — the
        /// case the guard exists for: permission on both sides is not consent
        /// to join them.
        let other: Project
        let image: Image
        let adminToken: String
        /// Editor on `home` only. Clears the first authorization check and
        /// fails the one on `other`'s VM, which is how the ordering tests below
        /// tell "authorize, then contain" from "contain, then authorize".
        let homeEditorToken: String
    }

    private func withApp(_ test: (Fixture) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "containment-admin",
                email: "containment-admin@example.com",
                displayName: "Containment Admin",
                isSystemAdmin: true)
            let org = try await builder.createOrganization(name: "Containment Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            admin.currentOrganizationId = org.id
            try await admin.save(on: app.db)

            let home = try await builder.createProject(
                name: "Home Project", description: "Owns the resource under test", organization: org)
            let other = try await builder.createProject(
                name: "Other Project", description: "Owns the VM or network being named", organization: org)
            try await builder.createNetwork(name: "default", project: home)
            let image = try await builder.createImage(project: home, uploadedBy: admin)

            let editor = try await builder.createUser(
                username: "containment-editor",
                email: "containment-editor@example.com",
                displayName: "Containment Editor")
            try await builder.addUserToOrganization(user: editor, organization: org, role: "member")
            editor.currentOrganizationId = org.id
            try await editor.save(on: app.db)
            try await RoleBindingService.grant(
                principalType: .user, principalID: try editor.requireID(), role: .editor,
                nodeType: .project, nodeID: try home.requireID(), createdBy: nil, on: app.db)

            try await test(
                Fixture(
                    app: app, org: org, home: home, other: other, image: image,
                    adminToken: try await admin.generateAPIKey(on: app.db),
                    homeEditorToken: try await editor.generateAPIKey(on: app.db)))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Fixtures

    /// A refusal reduced to what a client can act on. Vapor's error body is
    /// JSON with no guaranteed key order, so the two answers a non-disclosure
    /// test compares have to be compared field by field, not as raw strings.
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

    /// Body mirroring `VMController`'s private `CreateVMRequest`.
    private struct CreateVMBody: Content {
        let name: String
        let imageId: UUID?
        let projectId: UUID?
        let environment: String?
        let cpu: Int?
        let memory: Int64?
        let disk: Int64?
        let networkName: String?
        var securityGroupIds: [UUID]? = nil
    }

    /// A VM in `project` with one NIC, written directly so the tests don't
    /// depend on scheduling. Every guard under test fires before placement is
    /// consulted.
    @discardableResult
    private func createVMWithNIC(
        app: Application, project: Project, network: LogicalNetwork, address: String? = nil
    ) async throws -> VM {
        let builder = TestDataBuilder(db: app.db)
        let vm = try await builder.createVM(
            name: "containment-vm-\(UUID().uuidString.prefix(8))", project: project)
        let networkID = try network.requireID()
        let nic = VMNetworkInterface(
            vmID: try vm.requireID(), logicalNetworkID: networkID,
            macAddress: MACAllocator.generateCandidate().description)
        try await nic.save(on: app.db)
        if let address {
            try await VMInterfaceAddress(
                interfaceID: try nic.requireID(), logicalNetworkID: networkID,
                family: .ipv4, address: address, prefixLength: 24, gateway: network.gateway
            ).save(on: app.db)
        }
        return vm
    }

    private func createGroup(
        app: Application, token: String, project: Project, name: String
    ) async throws -> SecurityGroupResponse {
        var created: SecurityGroupResponse?
        try await app.test(.POST, "/api/security-groups") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(
                CreateSecurityGroupRequest(name: name, projectId: try project.requireID()))
        } afterResponse: { res in
            #expect(res.status == .ok)
            created = try res.content.decode(SecurityGroupResponse.self)
        }
        return created!
    }

    private func createNetwork(
        app: Application, project: Project, name: String, subnet: String, gateway: String
    ) async throws -> LogicalNetwork {
        let builder = TestDataBuilder(db: app.db)
        return try await builder.createNetwork(
            name: name, project: project, subnet: subnet, gateway: gateway)
    }

    /// Allocates a floating IP in `project` from a fresh org-scoped pool.
    private func createFloatingIP(
        app: Application, org: Organization, token: String, project: Project
    ) async throws -> UUID {
        var poolId: UUID?
        try await app.test(.POST, "/api/floating-ip-pools") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode([
                "name": "containment-edge", "cidr": "203.0.113.0/29", "gateway": "203.0.113.1",
                "organizationId": try org.requireID().uuidString,
            ])
        } afterResponse: { res in
            #expect(res.status == .ok)
            poolId = try res.content.decode(FloatingIPPoolResponse.self).id
        }
        var floatingIpId: UUID?
        try await app.test(.POST, "/api/floating-ips") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode([
                "poolId": poolId!.uuidString, "projectId": try project.requireID().uuidString,
            ])
        } afterResponse: { res in
            #expect(res.status == .ok)
            floatingIpId = try res.content.decode(FloatingIPResponse.self).id
        }
        return floatingIpId!
    }

    private func createZone(
        app: Application, token: String, project: Project, name: String
    ) async throws -> UUID {
        var zoneId: UUID?
        try await app.test(.POST, "/api/dns-zones") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(["name": name, "projectId": try project.requireID().uuidString])
        } afterResponse: { res in
            #expect(res.status == .ok)
            zoneId = try res.content.decode(DNSZoneResponse.self).id
        }
        return zoneId!
    }

    // MARK: - The status at each site

    /// The two sites where nothing authorizes the caller against the resource
    /// the body names. They don't get the shared containment refusal at all —
    /// the lookup is scoped to the caller's project, so a group elsewhere is
    /// indistinguishable from one that doesn't exist. A containment message
    /// here would confirm that an opaque id names a real group in the fleet,
    /// which is the disclosure the ordering rule prevents at the sites that do
    /// authorize.

    @Test("VM create naming a security group from another project cannot tell it from a missing one")
    func vmCreateForeignSecurityGroupIsIndistinguishableFromMissing() async throws {
        try await withApp { fixture in
            let group = try await self.createGroup(
                app: fixture.app, token: fixture.adminToken, project: fixture.other,
                name: "other-project-group")

            func create(name: String, securityGroupIds: [UUID]) async throws -> Refusal {
                var refusal = Refusal(status: .ok, reason: "")
                try await fixture.app.test(.POST, "/api/vms") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.adminToken)
                    try req.content.encode(
                        CreateVMBody(
                            name: name, imageId: fixture.image.id,
                            projectId: fixture.home.id, environment: "development",
                            cpu: 1, memory: 1 << 30, disk: 10 << 30, networkName: "default",
                            securityGroupIds: securityGroupIds))
                } afterResponse: { res in
                    refusal = Self.refusal(from: res)
                }
                return refusal
            }

            // Matches how the same handler resolves the NIC's network (#765):
            // scoped to the project, reported as not found.
            let foreign = try await create(
                name: "containment-create-vm", securityGroupIds: [group.id])
            #expect(foreign.status == .notFound)
            #expect(foreign.reason == "Security group \(group.id) not found in this project")
            #expect(!foreign.reason.contains(Self.sharedReason))

            // A wholly unknown id is answered identically but for the id, so
            // the response distinguishes nothing.
            let unknownId = UUID()
            let unknown = try await create(
                name: "containment-create-vm-2", securityGroupIds: [unknownId])
            #expect(unknown.status == foreign.status)
            #expect(
                unknown.reason.replacingOccurrences(of: unknownId.uuidString, with: "")
                    == foreign.reason.replacingOccurrences(of: group.id.uuidString, with: ""))

            let created = try await VM.query(on: fixture.app.db)
                .filter(\.$name ~~ ["containment-create-vm", "containment-create-vm-2"])
                .count()
            #expect(created == 0)
        }
    }

    @Test("Attaching a security group to a VM in another project is refused with 400")
    func securityGroupAttachCrossProject() async throws {
        try await withApp { fixture in
            let group = try await self.createGroup(
                app: fixture.app, token: fixture.adminToken, project: fixture.home,
                name: "home-project-group")
            let network = try await self.createNetwork(
                app: fixture.app, project: fixture.other, name: "sg-other-net",
                subnet: "10.60.0.0/24", gateway: "10.60.0.1")
            let vm = try await self.createVMWithNIC(
                app: fixture.app, project: fixture.other, network: network)

            // Was 409 — nothing is in conflict and no retry resolves it.
            try await fixture.app.test(.POST, "/api/security-groups/\(group.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.adminToken)
                try req.content.encode(AttachSecurityGroupRequest(vmId: try vm.requireID()))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("VM \(Self.sharedReason) the security group"))
            }

            let memberships = try await VMInterfaceSecurityGroup.query(on: fixture.app.db).all()
            #expect(memberships.isEmpty)
        }
    }

    @Test("Attaching a floating IP to a VM in another project is refused with 400")
    func floatingIPAttachCrossProject() async throws {
        try await withApp { fixture in
            let floatingIpId = try await self.createFloatingIP(
                app: fixture.app, org: fixture.org, token: fixture.adminToken, project: fixture.home)
            let network = try await self.createNetwork(
                app: fixture.app, project: fixture.other, name: "fip-other-net",
                subnet: "10.70.0.0/24", gateway: "10.70.0.1")
            let vm = try await self.createVMWithNIC(
                app: fixture.app, project: fixture.other, network: network, address: "10.70.0.5")

            // Was 409.
            try await fixture.app.test(.POST, "/api/floating-ips/\(floatingIpId)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.adminToken)
                try req.content.encode(["vmId": try vm.requireID().uuidString])
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("VM \(Self.sharedReason) the floating IP"))
            }

            let floatingIP = try #require(try await FloatingIP.find(floatingIpId, on: fixture.app.db))
            #expect(floatingIP.$interface.id == nil)
        }
    }

    @Test("Attaching a DNS zone to a network in another project is refused with 400")
    func dnsZoneAttachCrossProject() async throws {
        try await withApp { fixture in
            let zoneId = try await self.createZone(
                app: fixture.app, token: fixture.adminToken, project: fixture.home,
                name: "containment.internal")
            let network = try await self.createNetwork(
                app: fixture.app, project: fixture.other, name: "dns-other-net",
                subnet: "10.80.0.0/24", gateway: "10.80.0.1")

            // Was 409.
            try await fixture.app.test(.POST, "/api/dns-zones/\(zoneId)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.adminToken)
                try req.content.encode(AttachDNSZoneRequest(networkId: try network.requireID()))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("Network \(Self.sharedReason) the DNS zone"))
            }

            let attachments = try await DNSZoneNetwork.query(on: fixture.app.db).all()
            #expect(attachments.isEmpty)
        }
    }

    @Test("Detaching a DNS zone from a network in another project is refused with 400")
    func dnsZoneDetachCrossProject() async throws {
        try await withApp { fixture in
            // `authorizedNetwork` serves both halves of the attachment API, so
            // detach moved off 409 with attach and is pinned here too.
            let zoneId = try await self.createZone(
                app: fixture.app, token: fixture.adminToken, project: fixture.home,
                name: "detach.internal")
            let network = try await self.createNetwork(
                app: fixture.app, project: fixture.other, name: "dns-detach-net",
                subnet: "10.82.0.0/24", gateway: "10.82.0.1")

            let networkID = try network.requireID()
            try await fixture.app.test(.DELETE, "/api/dns-zones/\(zoneId)/networks/\(networkID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.adminToken)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(res.body.string.contains("Network \(Self.sharedReason) the DNS zone"))
            }
        }
    }

    @Test("A rule's remote group in another project cannot be told from a missing one")
    func securityGroupRuleForeignRemoteIsIndistinguishableFromMissing() async throws {
        try await withApp { fixture in
            let group = try await self.createGroup(
                app: fixture.app, token: fixture.adminToken, project: fixture.home,
                name: "rule-home-group")
            let remote = try await self.createGroup(
                app: fixture.app, token: fixture.adminToken, project: fixture.other,
                name: "rule-remote-group")

            func addRule(remoteGroupId: UUID) async throws -> Refusal {
                var refusal = Refusal(status: .ok, reason: "")
                try await fixture.app.test(.POST, "/api/security-groups/\(group.id)/rules") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.adminToken)
                    try req.content.encode(
                        CreateSecurityGroupRuleRequest(
                            direction: .ingress, ethertype: .ipv4, protocolName: "tcp",
                            portRangeMin: 443, portRangeMax: 443, remoteGroupId: remoteGroupId))
                } afterResponse: { res in
                    refusal = Self.refusal(from: res)
                }
                return refusal
            }

            // The caller holds rights on this rule's group, not on the one the
            // body names — so the two answers must be identical.
            let foreign = try await addRule(remoteGroupId: remote.id)
            let unknown = try await addRule(remoteGroupId: UUID())
            #expect(foreign.status == .badRequest)
            #expect(foreign.reason == "Referenced security group not found")
            #expect(!foreign.reason.contains(Self.sharedReason))
            #expect(unknown.status == foreign.status)
            #expect(unknown.reason == foreign.reason)

            let rules = try await SecurityGroupRule.query(on: fixture.app.db)
                .filter(\.$securityGroup.$id == group.id)
                .count()
            #expect(rules == 0)
        }
    }

    // MARK: - Authorize, then contain

    /// The refusal must never reach a caller who could not otherwise see the
    /// other resource: answering "that lives in another project" before the
    /// authorization check turns the endpoint into a project-membership oracle.
    /// Security groups and floating IPs compared projects first until #777.

    @Test("Security-group attach checks VM permission before it compares projects")
    func securityGroupAttachAuthorizesFirst() async throws {
        try await withApp { fixture in
            let group = try await self.createGroup(
                app: fixture.app, token: fixture.adminToken, project: fixture.home,
                name: "ordering-home-group")
            let network = try await self.createNetwork(
                app: fixture.app, project: fixture.other, name: "sg-ordering-net",
                subnet: "10.61.0.0/24", gateway: "10.61.0.1")
            let vm = try await self.createVMWithNIC(
                app: fixture.app, project: fixture.other, network: network)

            try await fixture.app.test(.POST, "/api/security-groups/\(group.id)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.homeEditorToken)
                try req.content.encode(AttachSecurityGroupRequest(vmId: try vm.requireID()))
            } afterResponse: { res in
                // The VM check, not an earlier one on the group: the editor
                // holds `securitygroup:attach` on `home`. Its refusal is the
                // not-found one an absent VM gets (#881), so what this pins is
                // that the containment message never appears.
                #expect(res.status == .notFound)
                #expect(!res.body.string.contains(Self.sharedReason))
            }
        }
    }

    @Test("Floating-IP attach checks VM permission before it compares projects")
    func floatingIPAttachAuthorizesFirst() async throws {
        try await withApp { fixture in
            let floatingIpId = try await self.createFloatingIP(
                app: fixture.app, org: fixture.org, token: fixture.adminToken, project: fixture.home)
            let network = try await self.createNetwork(
                app: fixture.app, project: fixture.other, name: "fip-ordering-net",
                subnet: "10.71.0.0/24", gateway: "10.71.0.1")
            let vm = try await self.createVMWithNIC(
                app: fixture.app, project: fixture.other, network: network, address: "10.71.0.5")

            try await fixture.app.test(.POST, "/api/floating-ips/\(floatingIpId)/attach") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.homeEditorToken)
                try req.content.encode(["vmId": try vm.requireID().uuidString])
            } afterResponse: { res in
                // The VM check, not an earlier one on the floating IP: the
                // editor holds `floatingip:attach` on `home`. Not-found rather
                // than forbidden since #881 — see the security-group twin.
                #expect(res.status == .notFound)
                #expect(!res.body.string.contains(Self.sharedReason))
            }
        }
    }

    @Test("DNS zone attach checks network permission before it compares projects")
    func dnsZoneAttachAuthorizesFirst() async throws {
        try await withApp { fixture in
            let zoneId = try await self.createZone(
                app: fixture.app, token: fixture.homeEditorToken, project: fixture.home,
                name: "ordering.internal")
            let network = try await self.createNetwork(
                app: fixture.app, project: fixture.other, name: "dns-ordering-net",
                subnet: "10.81.0.0/24", gateway: "10.81.0.1")

            try await fixture.app.test(.POST, "/api/dns-zones/\(zoneId)/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.homeEditorToken)
                try req.content.encode(AttachDNSZoneRequest(networkId: try network.requireID()))
            } afterResponse: { res in
                // The network check, not an earlier one on the zone: the
                // editor authored the zone itself.
                #expect(res.status == .forbidden)
                #expect(res.body.string.contains("You don't have permission to modify this network"))
                #expect(!res.body.string.contains(Self.sharedReason))
            }
        }
    }
}
