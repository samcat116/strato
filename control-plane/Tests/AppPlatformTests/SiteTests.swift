import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for sites (availability zones, issue #343): the sites API and its
/// topology-safety guards, site assignment at agent registration, the
/// scheduler's site hard constraint, and site-aware desired-state assembly
/// (network-controller authority and site-wide network scoping).
@Suite("Site Tests", .serialized)
final class SiteTests {

    private func withSiteTestApp(
        _ test: (Application, User, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            // Site topology endpoints are system-admin only.
            let admin = try await builder.createUser(
                username: "siteadmin",
                email: "siteadmin@example.com",
                displayName: "Site Admin",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "Site Org")
            try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")
            admin.currentOrganizationId = org.id
            try await admin.save(on: app.db)

            let project = try await builder.createProject(
                name: "Site Project",
                description: "Project for site tests",
                organization: org
            )
            let token = try await admin.generateAPIKey(on: app.db)

            try await test(app, admin, project, token)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// Registers an in-memory agent, optionally into a site (as its
    /// registration token would). New agents require an org scope; default to
    /// the harness's organization (the oldest one). Returns the agent's UUID
    /// string.
    private func registerAgent(
        app: Application, named name: String, siteID: UUID? = nil,
        protocolVersion: Int = WireProtocol.currentVersion,
        networkCapability: NetworkCapability = .overlay
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: "host-\(name)",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            hypervisors: [
                HypervisorSupport(type: .qemu, available: true, accelerated: true, capabilities: .qemu)
            ],
            networkCapability: networkCapability,
            protocolVersion: protocolVersion
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let uuid = try await app.agentService.registerAgent(
            message, agentName: name, siteID: siteID,
            organizationScope: orgID.map { .organization($0) })
        return uuid.uuidString
    }

    /// Backdates an agent's heartbeat, the state a node that crashed or is
    /// rebooting reaches. `registerAgent` stamps a fresh heartbeat, so this is
    /// how a test lands inside or past
    /// `SiteNetworkAuthority.controllerOfflineGrace` deterministically —
    /// without touching the environment the grace window is read from.
    @discardableResult
    private func backdateHeartbeat(
        app: Application, agentId: String, bySeconds seconds: TimeInterval
    ) async throws -> Agent {
        let agent = try #require(try await Agent.find(UUID(uuidString: agentId), on: app.db))
        agent.lastHeartbeat = Date().addingTimeInterval(-seconds)
        try await agent.save(on: app.db)
        return agent
    }

    /// Comfortably past `SiteNetworkAuthority.controllerOfflineGrace` at any
    /// plausible configured value the suite runs under.
    private var wellPastGrace: TimeInterval { SiteNetworkAuthority.controllerOfflineGrace + 600 }

    /// A site owned by the harness's organization, so the site↔agent same-org
    /// invariant holds for agents registered via `registerAgent`.
    private func makeSite(app: Application, name: String) async throws -> Site {
        let orgID = try #require(try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id)
        let site = Site(name: name, organizationScope: .organization(orgID))
        try await site.save(on: app.db)
        return site
    }

    private func placeVM(
        app: Application, project: Project, named name: String, onAgent agentId: String,
        network: LogicalNetwork
    ) async throws {
        let builder = TestDataBuilder(db: app.db)
        let vm = try await builder.createVM(name: name, project: project)
        vm.hypervisorId = agentId
        try await vm.save(on: app.db)
        let nic = VMNetworkInterface(
            vmID: vm.id!, logicalNetworkID: try network.requireID(),
            macAddress: VMNetworkInterface.generateMACAddress())
        try await nic.save(on: app.db)
    }

    /// The project's network of that name, created on first use. Nothing
    /// provisions one with a project (issue #765), and these tests only care
    /// that VMs share or don't share a network — not which one.
    private func network(
        app: Application, project: Project, named name: String = "default",
        subnet: String = "192.168.1.0/24", gateway: String = "192.168.1.1"
    ) async throws -> LogicalNetwork {
        if let existing = try await LogicalNetwork.query(on: app.db)
            .filter(\.$project.$id == project.requireID())
            .filter(\.$name == name)
            .first()
        {
            return existing
        }
        return try await TestDataBuilder(db: app.db).createNetwork(
            name: name, project: project, subnet: subnet, gateway: gateway)
    }

    // MARK: - Sites API

    @Test("Site CRUD round-trips and rejects duplicate names")
    func siteCRUD() async throws {
        try await withSiteTestApp { app, _, project, token in
            let orgId = project.$organization.id
            var siteId: UUID?
            try await app.test(.POST, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSiteRequest(
                        name: "dc-east", description: "rack 1",
                        organizationId: orgId, organizationalUnitId: nil))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let site = try res.content.decode(SiteResponse.self)
                #expect(site.name == "dc-east")
                #expect(site.networkControllerAgentId == nil)
                #expect(site.organizationId == orgId)
                siteId = site.id
            }

            // A site without an owning scope is refused outright.
            try await app.test(.POST, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSiteRequest(
                        name: "dc-unowned", description: nil,
                        organizationId: nil, organizationalUnitId: nil))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            try await app.test(.POST, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSiteRequest(
                        name: "dc-east", description: nil,
                        organizationId: orgId, organizationalUnitId: nil))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            try await app.test(.GET, "/api/sites/\(siteId!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let site = try res.content.decode(SiteResponse.self)
                #expect(site.id == siteId)
            }
        }
    }

    @Test("Site metadata round-trips; status stays put unless explicitly changed")
    func siteMetadataRoundTrips() async throws {
        try await withSiteTestApp { app, _, project, token in
            let orgId = project.$organization.id
            var siteId: UUID?

            // Create with a full metadata payload.
            try await app.test(.POST, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSiteRequest(
                        name: "meta-dc", description: "primary",
                        organizationId: orgId, organizationalUnitId: nil,
                        status: .draining, latitude: 38.9445, longitude: -77.4558,
                        locationLabel: "  Equinix DC1  ", regionCode: "us-east-1",
                        labels: ["tier": "production", "provider": "equinix"]))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let site = try res.content.decode(SiteResponse.self)
                #expect(site.status == .draining)
                #expect(site.latitude == 38.9445)
                #expect(site.longitude == -77.4558)
                // Location label is trimmed on the way in.
                #expect(site.locationLabel == "Equinix DC1")
                #expect(site.regionCode == "us-east-1")
                #expect(site.labels == ["tier": "production", "provider": "equinix"])
                #expect(site.updatedAt != nil)
                siteId = site.id
            }
            let id = try #require(siteId)

            // A PUT that omits status leaves the lifecycle untouched, but
            // full-replaces the descriptive fields (labels omitted → empty).
            try await app.test(.PUT, "/api/sites/\(id.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSiteRequest(description: "primary", regionCode: "us-east-2"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let site = try res.content.decode(SiteResponse.self)
                #expect(site.status == .draining)  // unchanged
                #expect(site.regionCode == "us-east-2")
                #expect(site.latitude == nil)  // cleared by full-replace
                #expect(site.labels.isEmpty)  // cleared by full-replace
            }

            // Sending status explicitly changes it.
            try await app.test(.PUT, "/api/sites/\(id.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateSiteRequest(status: .active))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let site = try res.content.decode(SiteResponse.self)
                #expect(site.status == .active)
            }
        }
    }

    @Test("Label keys and values are trimmed on the way in")
    func siteLabelsAreTrimmed() async throws {
        try await withSiteTestApp { app, _, project, token in
            let orgId = project.$organization.id
            try await app.test(.POST, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSiteRequest(
                        name: "labels-trim", organizationId: orgId,
                        labels: ["  tier  ": "  production  "]))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let site = try res.content.decode(SiteResponse.self)
                #expect(site.labels == ["tier": "production"])
            }
        }
    }

    @Test("Invalid site metadata is rejected")
    func siteMetadataValidation() async throws {
        try await withSiteTestApp { app, _, project, token in
            let orgId = project.$organization.id

            // Latitude out of range.
            try await app.test(.POST, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSiteRequest(
                        name: "bad-lat", organizationId: orgId, latitude: 91, longitude: 0))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // A lone coordinate (latitude without longitude).
            try await app.test(.POST, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateSiteRequest(name: "lone-coord", organizationId: orgId, latitude: 10))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Designating a network controller requires site membership")
    func controllerMustBeMember() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = try await self.makeSite(app: app, name: "dc-a")
            let outsiderId = try await self.registerAgent(app: app, named: "outsider")

            try await app.test(.PUT, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSiteRequest(description: nil, networkControllerAgentId: UUID(uuidString: outsiderId)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Once the agent is a member, designation succeeds.
            let memberId = try await self.registerAgent(app: app, named: "member", siteID: site.id)
            try await app.test(.PUT, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSiteRequest(description: nil, networkControllerAgentId: UUID(uuidString: memberId)))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let updated = try res.content.decode(SiteResponse.self)
                #expect(updated.networkControllerAgentId?.uuidString == memberId)
            }
        }
    }

    @Test("A controller the sync path won't honor cannot be designated")
    func controllerCapabilityValidation() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = try await self.makeSite(app: app, name: "dc-caps")

            // Non-overlay (user-mode/SLIRP) member: no OVN network service to
            // reconcile topology with.
            let slirpId = try await self.registerAgent(
                app: app, named: "slirp-node", siteID: site.id, networkCapability: .userMode)
            try await app.test(.PUT, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSiteRequest(description: nil, networkControllerAgentId: UUID(uuidString: slirpId)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("A site's network controller cannot be deregistered while the site has other members")
    func controllerDeregistrationGuard() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = try await self.makeSite(app: app, name: "dc-dereg")
            let controllerId = try await self.registerAgent(app: app, named: "dereg-ctl", siteID: site.id)
            let peerId = try await self.registerAgent(app: app, named: "dereg-peer", siteID: site.id)
            site.$networkControllerAgent.id = UUID(uuidString: controllerId)
            try await site.save(on: app.db)

            // The controller reference has no FK, so deletion would leave the
            // site pointing at a vanished agent and reconciliation would stop
            // for the peer that is still there.
            try await app.test(.DELETE, "/api/agents/\(controllerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            let survivor = try await Agent.find(UUID(uuidString: controllerId), on: app.db)
            #expect(survivor != nil)

            // Once it is the last member there is no topology left to author,
            // so it deregisters and gives its designation up — otherwise a
            // single-node site's auto-designated agent (issue #743) could
            // never be retired.
            try await app.test(.DELETE, "/api/agents/\(peerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            try await app.test(.DELETE, "/api/agents/\(controllerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            #expect(try await Agent.find(UUID(uuidString: controllerId), on: app.db) == nil)
            let emptied = try #require(try await Site.find(site.id, on: app.db))
            #expect(emptied.$networkControllerAgent.id == nil)
        }
    }

    @Test("A site with members or pinned networks refuses deletion")
    func deleteGuards() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = try await self.makeSite(app: app, name: "dc-b")
            _ = try await self.registerAgent(app: app, named: "occupant", siteID: site.id)

            try await app.test(.DELETE, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
        }
    }

    @Test("The designated network controller cannot be removed while the site has other members")
    func controllerRemovalGuard() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = try await self.makeSite(app: app, name: "dc-c")
            let siteID = try #require(site.id)
            let controllerId = try await self.registerAgent(app: app, named: "ctl", siteID: siteID)
            let peerId = try await self.registerAgent(app: app, named: "ctl-peer", siteID: siteID)
            site.$networkControllerAgent.id = UUID(uuidString: controllerId)
            try await site.save(on: app.db)

            try await app.test(.DELETE, "/api/sites/\(siteID.uuidString)/agents/\(controllerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // Emptying the site is allowed: with no members left there is no
            // topology to author, so the last one out clears the designation
            // rather than being trapped in the site (issue #743).
            try await app.test(.DELETE, "/api/sites/\(siteID.uuidString)/agents/\(peerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            try await app.test(.DELETE, "/api/sites/\(siteID.uuidString)/agents/\(controllerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            let emptied = try #require(try await Site.find(siteID, on: app.db))
            #expect(emptied.$networkControllerAgent.id == nil)
        }
    }

    @Test("Assigning an agent that controls another site is refused")
    func controllerMoveGuard() async throws {
        try await withSiteTestApp { app, _, _, token in
            let oldSite = try await self.makeSite(app: app, name: "dc-old")
            let newSite = try await self.makeSite(app: app, name: "dc-new")

            let controllerId = try await self.registerAgent(app: app, named: "moving-ctl", siteID: oldSite.id)
            oldSite.$networkControllerAgent.id = UUID(uuidString: controllerId)
            try await oldSite.save(on: app.db)

            // Moving the old site's controller would leave that site pointing
            // at a non-member and stop its network reconciliation.
            try await app.test(.POST, "/api/sites/\(newSite.id!.uuidString)/agents/\(controllerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            let agent = try #require(try await Agent.find(UUID(uuidString: controllerId), on: app.db))
            #expect(agent.$site.id == oldSite.id)

            // A registration token targeting the new site must not move it
            // either — the assignment is ignored, not applied.
            _ = try await self.registerAgent(app: app, named: "moving-ctl", siteID: newSite.id)
            let after = try #require(try await Agent.find(UUID(uuidString: controllerId), on: app.db))
            #expect(after.$site.id == oldSite.id)
        }
    }

    @Test("An agent hosting VMs cannot change site (API and token paths)")
    func hostedVMMoveGuard() async throws {
        try await withSiteTestApp { app, _, project, token in
            let oldSite = try await self.makeSite(app: app, name: "dc-vm-old")
            let newSite = try await self.makeSite(app: app, name: "dc-vm-new")

            let agentId = try await self.registerAgent(app: app, named: "loaded", siteID: oldSite.id)
            try await self.placeVM(
                app: app, project: project, named: "resident-vm", onAgent: agentId,
                network: try await self.network(app: app, project: project))

            // Moving it would drop its VMs' networks out of the old site's
            // shared NB while the VMs keep running.
            try await app.test(.POST, "/api/sites/\(newSite.id!.uuidString)/agents/\(agentId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            // The token path refuses the same move (logged, not fatal).
            _ = try await self.registerAgent(app: app, named: "loaded", siteID: newSite.id)
            let agent = try #require(try await Agent.find(UUID(uuidString: agentId), on: app.db))
            #expect(agent.$site.id == oldSite.id)

            // Re-registering into the SAME site is a no-op, not a refusal.
            _ = try await self.registerAgent(app: app, named: "loaded", siteID: oldSite.id)
            let unchanged = try #require(try await Agent.find(UUID(uuidString: agentId), on: app.db))
            #expect(unchanged.$site.id == oldSite.id)
        }
    }

    @Test("Site listing is scoped: a user with no site access sees nothing")
    func sitesListScoped() async throws {
        try await withSiteTestApp { app, _, _, _ in
            _ = try await self.makeSite(app: app, name: "dc-scoped")

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "plainuser", email: "plain@example.com",
                displayName: "Plain", isSystemAdmin: false)
            let token = try await user.generateAPIKey(on: app.db)

            // The user holds no binding anywhere, so site view resolves to
            // nothing — the list is empty rather than forbidden, since sites
            // are org-delegated now.
            try await app.test(.GET, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let sites = try res.content.decode(PagedResponse<SiteResponse>.self).items
                #expect(sites.isEmpty)
            }
        }
    }

    @Test("organization_id narrows the site list, including for system admins")
    func sitesListFilteredByOrganization() async throws {
        try await withSiteTestApp { app, admin, _, token in
            let ownSite = try await self.makeSite(app: app, name: "dc-own")

            // A site in an organization the admin is not looking at.
            let builder = TestDataBuilder(db: app.db)
            let otherOrg = try await builder.createOrganization(name: "Other Org")
            let otherSite = Site(name: "dc-other", organizationScope: .organization(otherOrg.id!))
            try await otherSite.save(on: app.db)

            // Unfiltered, a system admin still sees the whole fleet.
            try await app.test(.GET, "/api/sites") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let sites = try res.content.decode(PagedResponse<SiteResponse>.self).items
                #expect(sites.count == 2)
            }

            // Filtered, the admin bypass must not widen the result back out.
            let orgID = try #require(admin.currentOrganizationId)
            try await app.test(.GET, "/api/sites?organization_id=\(orgID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let sites = try res.content.decode(PagedResponse<SiteResponse>.self).items
                let names = sites.map(\.name)
                #expect(names == [ownSite.name])
            }
        }
    }

    @Test("Filtering by an organization includes its OU-scoped sites")
    func sitesListFilterIncludesOUScoped() async throws {
        try await withSiteTestApp { app, admin, _, token in
            let orgID = try #require(admin.currentOrganizationId)
            let org = try #require(try await Organization.find(orgID, on: app.db))

            let builder = TestDataBuilder(db: app.db)
            let ou = try await builder.createOU(
                name: "Nested OU", description: "delegated capacity", organization: org)
            let ouSite = Site(name: "dc-ou", organizationScope: .organizationalUnit(ou.id!))
            try await ouSite.save(on: app.db)
            _ = try await self.makeSite(app: app, name: "dc-org")

            // An organization contains every scope rooted in it, so a site
            // delegated to one of its OUs is still the org's site.
            try await app.test(.GET, "/api/sites?organization_id=\(orgID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let sites = try res.content.decode(PagedResponse<SiteResponse>.self).items
                let names = Set(sites.map(\.name))
                #expect(names == Set(["dc-org", "dc-ou"]))
            }
        }
    }

    @Test("A malformed organization_id is rejected rather than silently ignored")
    func sitesListFilterRejectsMalformedOrganization() async throws {
        try await withSiteTestApp { app, _, _, token in
            _ = try await self.makeSite(app: app, name: "dc-guard")

            // Falling through to an unfiltered fleet is the failure this filter exists
            // to prevent, so a bad id must fail loudly.
            try await app.test(.GET, "/api/sites?organization_id=not-a-uuid") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Filtering by an organization the caller can't view is forbidden")
    func sitesListFilterRequiresOrganizationAccess() async throws {
        try await withSiteTestApp { app, admin, _, _ in
            _ = try await self.makeSite(app: app, name: "dc-private")
            let orgID = try #require(admin.currentOrganizationId)

            let builder = TestDataBuilder(db: app.db)
            let outsider = try await builder.createUser(
                username: "outsider", email: "outsider@example.com",
                displayName: "Outsider", isSystemAdmin: false)
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)

            // The outsider holds no binding on the organization, so the
            // org-scoped filter is refused.
            try await app.test(.GET, "/api/sites?organization_id=\(orgID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Registration site assignment

    @Test("Registration assigns the token's site; re-registration without one preserves it")
    func registrationSiteAssignment() async throws {
        try await withSiteTestApp { app, _, _, _ in
            let site = try await self.makeSite(app: app, name: "dc-d")

            let agentId = try await self.registerAgent(app: app, named: "node-1", siteID: site.id)
            var agent = try #require(try await Agent.find(UUID(uuidString: agentId), on: app.db))
            #expect(agent.$site.id == site.id)

            // Reconnect with a rotated token that carries no site: the
            // assignment is durable on the agent row.
            _ = try await self.registerAgent(app: app, named: "node-1", siteID: nil)
            agent = try #require(try await Agent.find(UUID(uuidString: agentId), on: app.db))
            #expect(agent.$site.id == site.id)
        }
    }

    // MARK: - Scheduler site constraint

    private func makeSchedulable(
        id: String = UUID().uuidString, name: String, siteID: UUID? = nil,
        supportsInterVMNetworking: Bool = true
    ) -> SchedulableAgent {
        SchedulableAgent(
            id: id, name: name,
            totalCPU: 16, availableCPU: 16,
            totalMemory: 1 << 34, availableMemory: 1 << 34,
            totalDisk: 1 << 40, availableDisk: 1 << 40,
            status: .online, runningVMCount: 0,
            supportedHypervisors: [.qemu],
            supportsInterVMNetworking: supportsInterVMNetworking,
            siteID: siteID
        )
    }

    @Test("Site requirement filters placement to the site's agents")
    func schedulerSiteFilter() throws {
        let siteA = UUID()
        let siteB = UUID()
        let inSite = makeSchedulable(name: "in-site", siteID: siteA)
        let elsewhere = makeSchedulable(name: "elsewhere", siteID: siteB)
        let siteless = makeSchedulable(name: "siteless")

        let scheduler = SchedulerService(logger: Logger(label: "test"))
        let requirements = VMPlacementRequirements(
            cpu: 1, memory: 1 << 30, disk: 1 << 30, siteID: siteA)

        let selected = try scheduler.selectAgent(
            requirements: requirements, from: [elsewhere, siteless, inSite])
        #expect(selected == inSite.id)
    }

    @Test("Site requirement with no member agents fails with the site error")
    func schedulerSiteUnsatisfied() {
        let scheduler = SchedulerService(logger: Logger(label: "test"))
        let requirements = VMPlacementRequirements(
            cpu: 1, memory: 1 << 30, disk: 1 << 30, siteID: UUID())

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(
                requirements: requirements,
                from: [self.makeSchedulable(name: "siteless"), self.makeSchedulable(name: "other", siteID: UUID())]
            )
        }
    }

    @Test("Site requirement excludes members without overlay networking")
    func schedulerSiteFilterExcludesNonOverlay() throws {
        let siteA = UUID()
        // A user-mode (SLIRP) member never attaches to the site's OVN fabric,
        // so a pinned-network VM placed there would have no site overlay.
        let slirpMember = makeSchedulable(
            name: "slirp-member", siteID: siteA, supportsInterVMNetworking: false)
        let overlayMember = makeSchedulable(name: "overlay-member", siteID: siteA)

        let scheduler = SchedulerService(logger: Logger(label: "test"))
        let requirements = VMPlacementRequirements(
            cpu: 1, memory: 1 << 30, disk: 1 << 30, siteID: siteA)

        let selected = try scheduler.selectAgent(
            requirements: requirements, from: [slirpMember, overlayMember])
        #expect(selected == overlayMember.id)

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(requirements: requirements, from: [slirpMember])
        }
    }

    @Test("Unconstrained VMs still place on sited and site-less agents alike")
    func schedulerNoSiteRequirement() throws {
        let scheduler = SchedulerService(logger: Logger(label: "test"))
        let requirements = VMPlacementRequirements(cpu: 1, memory: 1 << 30, disk: 1 << 30)
        let agents = [makeSchedulable(name: "sited", siteID: UUID())]
        let selected = try scheduler.selectAgent(requirements: requirements, from: agents)
        #expect(selected == agents[0].id)
    }

    // MARK: - Site-aware desired-state assembly

    @Test("The site's network controller gets the whole site's networks, authoritative")
    func controllerAssembly() async throws {
        try await withSiteTestApp { app, _, project, _ in
            let site = try await self.makeSite(app: app, name: "dc-e")

            let controllerId = try await self.registerAgent(app: app, named: "ctl-agent", siteID: site.id)
            let peerId = try await self.registerAgent(app: app, named: "peer-agent", siteID: site.id)
            site.$networkControllerAgent.id = UUID(uuidString: controllerId)
            try await site.save(on: app.db)

            // One network referenced only by a VM on the peer, one pinned to
            // the site with no VMs at all.
            let peerNet = try await self.network(
                app: app, project: project, named: "peer-net", subnet: "10.30.0.0/24",
                gateway: "10.30.0.1")
            let pinnedNet = LogicalNetwork(
                name: "pinned-net", subnet: "10.31.0.0/24", gateway: "10.31.0.1",
                projectID: try project.requireID(), siteID: site.id!)
            try await pinnedNet.save(on: app.db)
            try await self.placeVM(
                app: app, project: project, named: "peer-vm", onAgent: peerId, network: peerNet)

            // Controller: authoritative, sees the peer's network and the
            // pinned-but-unused one — even with no VMs of its own.
            let controllerSync = try await app.desiredStateAssembler.assemble(agentId: controllerId)
            #expect(controllerSync.networksAuthoritative)
            let names = Set(controllerSync.networks.map(\.name))
            #expect(names.contains("peer-net"))
            #expect(names.contains("pinned-net"))

            // Peer: hosts the VM (so the VM itself syncs to it), but topology
            // belongs to the controller.
            let peerSync = try await app.desiredStateAssembler.assemble(agentId: peerId)
            #expect(!peerSync.networksAuthoritative)
            #expect(peerSync.networks.isEmpty)
            #expect(peerSync.vms.count == 1)
        }
    }

    @Test("A site with no designated controller gives no agent authority")
    func noControllerAssembly() async throws {
        try await withSiteTestApp { app, _, project, _ in
            let site = try await self.makeSite(app: app, name: "dc-f")
            let agentId = try await self.registerAgent(app: app, named: "lone-agent", siteID: site.id)
            // Registration designates the first eligible member (issue #743);
            // clear it to exercise the undesignated state, which an operator
            // can still reach with a `PUT /api/sites/:id` that omits the field.
            site.$networkControllerAgent.id = nil
            try await site.save(on: app.db)
            try await self.placeVM(
                app: app, project: project, named: "lone-vm", onAgent: agentId,
                network: try await self.network(app: app, project: project))

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(!sync.networksAuthoritative)
            #expect(sync.networks.isEmpty)
            // The VM still syncs — only topology is withheld.
            #expect(sync.vms.count == 1)
        }
    }

    @Test("A site-less agent keeps the legacy model: own networks, authoritative")
    func sitelessAssembly() async throws {
        try await withSiteTestApp { app, _, project, _ in
            let agentId = try await self.registerAgent(app: app, named: "legacy-agent")
            try await self.placeVM(
                app: app, project: project, named: "legacy-vm", onAgent: agentId,
                network: try await self.network(app: app, project: project))

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(sync.networksAuthoritative)
            #expect(sync.networks.contains { $0.name == "default" })
        }
    }

    // MARK: - Automatic controller designation (issue #743)

    @Test("The first topology-capable node to join a site becomes its controller")
    func firstMemberBecomesController() async throws {
        try await withSiteTestApp { app, _, _, _ in
            let site = try await self.makeSite(app: app, name: "dc-auto")
            let siteID = try #require(site.id)
            let firstId = try await self.registerAgent(app: app, named: "auto-first", siteID: siteID)

            var reloaded = try #require(try await Site.find(siteID, on: app.db))
            #expect(reloaded.$networkControllerAgent.id?.uuidString == firstId)

            // A second member joining changes nothing: an existing
            // designation is never displaced.
            _ = try await self.registerAgent(app: app, named: "auto-second", siteID: siteID)
            reloaded = try #require(try await Site.find(siteID, on: app.db))
            #expect(reloaded.$networkControllerAgent.id?.uuidString == firstId)

            // Nor does the controller itself re-registering after a restart.
            _ = try await self.registerAgent(app: app, named: "auto-first", siteID: siteID)
            reloaded = try #require(try await Site.find(siteID, on: app.db))
            #expect(reloaded.$networkControllerAgent.id?.uuidString == firstId)
        }
    }

    @Test("A node the sync path would ignore is never auto-designated")
    func ineligibleMembersAreNotDesignated() async throws {
        try await withSiteTestApp { app, _, _, _ in
            let site = try await self.makeSite(app: app, name: "dc-auto-caps")
            let siteID = try #require(site.id)

            // User-mode (SLIRP): no OVN network service to reconcile topology
            // with.
            _ = try await self.registerAgent(
                app: app, named: "auto-slirp", siteID: siteID, networkCapability: .userMode)
            var reloaded = try #require(try await Site.find(siteID, on: app.db))
            #expect(reloaded.$networkControllerAgent.id == nil)

            // An overlay member enrolled later takes the job.
            let overlayId = try await self.registerAgent(
                app: app, named: "auto-overlay", siteID: siteID)
            reloaded = try #require(try await Site.find(siteID, on: app.db))
            #expect(reloaded.$networkControllerAgent.id?.uuidString == overlayId)
        }
    }

    @Test("Assigning the first agent through the sites API designates it too")
    func assignEndpointDesignatesController() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = try await self.makeSite(app: app, name: "dc-assign")
            let siteID = try #require(site.id)
            // Registered site-less, then moved in through the sites API —
            // the other way an agent joins a site.
            let agentId = try await self.registerAgent(app: app, named: "assign-node")

            try await app.test(.POST, "/api/sites/\(siteID.uuidString)/agents/\(agentId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let reloaded = try #require(try await Site.find(siteID, on: app.db))
            #expect(reloaded.$networkControllerAgent.id?.uuidString == agentId)
        }
    }

    // MARK: - Loud preconditions when a site has no controller (issue #743)

    @Test("Starting a VM in a controllerless site is refused, not accepted and stalled")
    func startRefusedWithoutController() async throws {
        try await withSiteTestApp { app, _, project, token in
            let site = try await self.makeSite(app: app, name: "dc-start-guard")
            let siteID = try #require(site.id)
            let agentId = try await self.registerAgent(app: app, named: "start-guard-node", siteID: siteID)
            // Undo the automatic designation: this is the state an operator
            // reaches by clearing the field on a `PUT /api/sites/:id`.
            site.$networkControllerAgent.id = nil
            try await site.save(on: app.db)

            try await self.placeVM(
                app: app, project: project, named: "stalled-vm", onAgent: agentId,
                network: try await self.network(app: app, project: project))
            let vm = try #require(try await VM.query(on: app.db).filter(\.$name == "stalled-vm").first())
            let vmID = try #require(vm.id)

            try await app.test(.POST, "/api/vms/\(vmID.uuidString)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("no network controller"))
            }

            // Designating one makes the same boot acceptable.
            site.$networkControllerAgent.id = UUID(uuidString: agentId)
            try await site.save(on: app.db)
            try await app.test(.POST, "/api/vms/\(vmID.uuidString)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
        }
    }

    @Test("Pinning a network to a populated site with no controller is refused")
    func networkPinRefusedWithoutController() async throws {
        try await withSiteTestApp { app, _, project, token in
            let site = try await self.makeSite(app: app, name: "dc-pin-guard")
            let siteID = try #require(site.id)

            struct Body: Content {
                let name: String
                let subnet: String
                let projectId: UUID?
                let siteId: UUID?
            }

            // An empty site is fine: pre-provisioning a network for capacity
            // that hasn't been enrolled yet is legitimate, and the first node
            // to join becomes the controller.
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(
                        name: "pre-provisioned-net", subnet: "10.60.0.0/24", projectId: project.id,
                        siteId: siteID))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // A site that has members but designates none of them realizes no
            // topology at all, so a network pinned there would be created and
            // reconciled nowhere.
            _ = try await self.registerAgent(app: app, named: "pin-guard-node", siteID: siteID)
            site.$networkControllerAgent.id = nil
            try await site.save(on: app.db)

            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(
                        name: "orphaned-net", subnet: "10.61.0.0/24", projectId: project.id,
                        siteId: siteID))
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("no network controller"))
            }
        }
    }

    @Test("Placement onto a controllerless site fails the operation instead of hanging")
    func placementRefusedWithoutController() async throws {
        try await withSiteTestApp { app, _, project, _ in
            let site = try await self.makeSite(app: app, name: "dc-place-guard")
            let siteID = try #require(site.id)
            let agentId = try await self.registerAgent(app: app, named: "place-guard-node", siteID: siteID)
            site.$networkControllerAgent.id = nil
            try await site.save(on: app.db)

            // A network pinned to the site confines placement to its agents,
            // so the scheduler can only land on the controllerless host.
            let builder = TestDataBuilder(db: app.db)
            let pinned = try await builder.createNetwork(
                name: "place-guard-net", project: project, subnet: "10.62.0.0/24",
                gateway: "10.62.0.1", site: site)
            let vm = try await builder.createVM(name: "unplaceable-vm", project: project)
            let nic = VMNetworkInterface(
                vmID: try vm.requireID(), logicalNetworkID: try pinned.requireID(),
                macAddress: VMNetworkInterface.generateMACAddress())
            try await nic.save(on: app.db)

            await #expect(throws: AgentServiceError.self) {
                try await app.agentService.createVM(vm: vm, db: app.db)
            }
            let unplaced = try #require(try await VM.find(vm.id, on: app.db))
            #expect(unplaced.hypervisorId == nil)

            // With a controller designated the same placement succeeds.
            site.$networkControllerAgent.id = UUID(uuidString: agentId)
            try await site.save(on: app.db)
            try await app.agentService.createVM(vm: vm, db: app.db)
            let placed = try #require(try await VM.find(vm.id, on: app.db))
            #expect(placed.hypervisorId == agentId)
        }
    }

    // MARK: - Controller liveness and capability regression (issue #833)

    @Test("resolve reports a controller that is offline past the grace window")
    func resolveOfflineController() async throws {
        try await withSiteTestApp { app, _, _, _ in
            let site = try await self.makeSite(app: app, name: "dc-liveness")
            let siteID = try #require(site.id)
            let controllerId = try await self.registerAgent(
                app: app, named: "live-ctl", siteID: siteID)
            let peerId = try await self.registerAgent(app: app, named: "live-peer", siteID: siteID)
            let peer = try #require(try await Agent.find(UUID(uuidString: peerId), on: app.db))

            // Healthy to begin with: registration designated the first member.
            let healthy = try await SiteNetworkAuthority.resolve(forAgent: peer, on: app.db)
            guard case .controller(let designated) = healthy else {
                Issue.record("expected .controller, got \(healthy)")
                return
            }
            #expect(designated.id?.uuidString == controllerId)

            // A blip inside the grace window keeps converging: syncs are
            // level-triggered, so refusing here would be worse than waiting.
            try await self.backdateHeartbeat(
                app: app, agentId: controllerId,
                bySeconds: SiteNetworkAuthority.controllerOfflineGrace / 2)
            let blip = try await SiteNetworkAuthority.resolve(forAgent: peer, on: app.db)
            guard case .controller = blip else {
                Issue.record("a controller inside the grace window must still resolve, got \(blip)")
                return
            }

            // Past it, the peer's workloads would park forever.
            try await self.backdateHeartbeat(
                app: app, agentId: controllerId, bySeconds: self.wellPastGrace)
            let gone = try await SiteNetworkAuthority.resolve(forAgent: peer, on: app.db)
            guard case .controllerUnavailable(_, let offline, let fault) = gone else {
                Issue.record("expected .controllerUnavailable, got \(gone)")
                return
            }
            #expect(offline.id?.uuidString == controllerId)
            guard case .offline = fault else {
                Issue.record("expected an offline fault, got \(fault)")
                return
            }
        }
    }

    @Test("resolve re-applies the designation bar to a standing controller")
    func resolveRegressedController() async throws {
        try await withSiteTestApp { app, _, _, _ in
            for (name, capability, version, expected) in [
                (
                    "slirp", NetworkCapability.userMode, WireProtocol.currentVersion,
                    SiteNetworkAuthority.ControllerFault.noOverlayNetworking
                )
            ] as [(String, NetworkCapability, Int, SiteNetworkAuthority.ControllerFault)] {
                let site = try await self.makeSite(app: app, name: "dc-regress-\(name)")
                let siteID = try #require(site.id)
                // Designated while healthy, then re-registered with the
                // regression — the state an agent reaches by coming back on a
                // different config or a rolled-back binary.
                let controllerId = try await self.registerAgent(
                    app: app, named: "regress-ctl-\(name)", siteID: siteID)
                let peerId = try await self.registerAgent(
                    app: app, named: "regress-peer-\(name)", siteID: siteID)
                _ = try await self.registerAgent(
                    app: app, named: "regress-ctl-\(name)", siteID: siteID,
                    protocolVersion: version, networkCapability: capability)
                // Re-validation hands the job to an eligible peer, so pin the
                // regressed agent back to isolate what `resolve` reports.
                let reloaded = try #require(try await Site.find(siteID, on: app.db))
                reloaded.$networkControllerAgent.id = UUID(uuidString: controllerId)
                try await reloaded.save(on: app.db)

                let peer = try #require(try await Agent.find(UUID(uuidString: peerId), on: app.db))
                let authority = try await SiteNetworkAuthority.resolve(forAgent: peer, on: app.db)
                guard case .controllerUnavailable(_, _, let fault) = authority else {
                    Issue.record("expected .controllerUnavailable for \(name), got \(authority)")
                    continue
                }
                #expect(fault == expected)
            }
        }
    }

    @Test("An offline controller changes nothing about assembly")
    func offlineControllerAssemblyUnchanged() async throws {
        try await withSiteTestApp { app, _, project, _ in
            // The fix belongs at the precondition and reporting layers: a peer
            // must keep getting `networks: [], authoritative: false`, because
            // letting it author topology behind a dead controller's back is the
            // dual-writer failure the single-author rule exists to prevent.
            let site = try await self.makeSite(app: app, name: "dc-assembly-offline")
            let siteID = try #require(site.id)
            let controllerId = try await self.registerAgent(
                app: app, named: "asm-ctl", siteID: siteID)
            let peerId = try await self.registerAgent(app: app, named: "asm-peer", siteID: siteID)
            try await self.placeVM(
                app: app, project: project, named: "asm-vm", onAgent: peerId,
                network: try await self.network(app: app, project: project))
            try await self.backdateHeartbeat(
                app: app, agentId: controllerId, bySeconds: self.wellPastGrace)

            let peerSync = try await app.desiredStateAssembler.assemble(agentId: peerId)
            #expect(!peerSync.networksAuthoritative)
            #expect(peerSync.networks.isEmpty)
            #expect(peerSync.vms.count == 1)

            // And the controller still gets its authoritative view, so it
            // converges the moment it comes back.
            let controllerSync = try await app.desiredStateAssembler.assemble(agentId: controllerId)
            #expect(controllerSync.networksAuthoritative)
        }
    }

    @Test("An offline controller refuses new work on its peers instead of stalling it")
    func offlineControllerRefusesPeerWork() async throws {
        try await withSiteTestApp { app, _, project, token in
            let site = try await self.makeSite(app: app, name: "dc-offline-guard")
            let siteID = try #require(site.id)
            let controllerId = try await self.registerAgent(
                app: app, named: "guard-ctl", siteID: siteID)
            let peerId = try await self.registerAgent(app: app, named: "guard-peer", siteID: siteID)
            try await self.backdateHeartbeat(
                app: app, agentId: controllerId, bySeconds: self.wellPastGrace)

            // Boot of an already-placed VM on the healthy peer.
            try await self.placeVM(
                app: app, project: project, named: "guard-vm", onAgent: peerId,
                network: try await self.network(app: app, project: project))
            let vm = try #require(try await VM.query(on: app.db).filter(\.$name == "guard-vm").first())
            try await app.test(.POST, "/api/vms/\(try vm.requireID().uuidString)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("guard-ctl"))
                #expect(res.body.string.contains("is offline"))
            }

            // Pinning a network to the site.
            struct Body: Content {
                let name: String
                let subnet: String
                let projectId: UUID?
                let siteId: UUID?
            }
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    Body(
                        name: "guard-net", subnet: "10.63.0.0/24", projectId: project.id,
                        siteId: siteID))
            } afterResponse: { res in
                #expect(res.status == .conflict)
                #expect(res.body.string.contains("guard-ctl"))
            }

            // Placement of a new VM onto the site.
            let builder = TestDataBuilder(db: app.db)
            let pinned = try await builder.createNetwork(
                name: "guard-pinned-net", project: project, subnet: "10.64.0.0/24",
                gateway: "10.64.0.1", site: site)
            let pending = try await builder.createVM(name: "guard-unplaceable", project: project)
            try await VMNetworkInterface(
                vmID: try pending.requireID(), logicalNetworkID: try pinned.requireID(),
                macAddress: VMNetworkInterface.generateMACAddress()
            ).save(on: app.db)
            await #expect(throws: AgentServiceError.self) {
                try await app.agentService.createVM(vm: pending, db: app.db)
            }

            // A fresh heartbeat from the controller unblocks all of it.
            try await self.backdateHeartbeat(app: app, agentId: controllerId, bySeconds: 0)
            try await app.agentService.createVM(vm: pending, db: app.db)
            #expect(try await VM.find(pending.id, on: app.db)?.hypervisorId != nil)
        }
    }

    @Test("A single-node site still accepts a boot while its own node is down")
    func offlineSelfControllerIsNotRefused() async throws {
        try await withSiteTestApp { app, _, project, token in
            // The workload and its topology author are the same node here, so
            // the boot is simply waiting on that node to come back — which is
            // what desired state is for. Refusing would turn every reboot of a
            // single-node deployment into a wall of 409s.
            let site = try await self.makeSite(app: app, name: "dc-solo")
            let siteID = try #require(site.id)
            let agentId = try await self.registerAgent(app: app, named: "solo-node", siteID: siteID)
            let designated = try #require(try await Site.find(siteID, on: app.db))
            #expect(designated.$networkControllerAgent.id?.uuidString == agentId)

            try await self.placeVM(
                app: app, project: project, named: "solo-vm", onAgent: agentId,
                network: try await self.network(app: app, project: project))
            try await self.backdateHeartbeat(
                app: app, agentId: agentId, bySeconds: self.wellPastGrace)

            let vm = try #require(try await VM.query(on: app.db).filter(\.$name == "solo-vm").first())
            try await app.test(.POST, "/api/vms/\(try vm.requireID().uuidString)/start") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .accepted)
            }
        }
    }

    @Test("A controller re-registering unable to author hands the job to an eligible peer")
    func regressedControllerHandsOverWhenItCan() async throws {
        try await withSiteTestApp { app, _, _, _ in
            let site = try await self.makeSite(app: app, name: "dc-handover")
            let siteID = try #require(site.id)
            let controllerId = try await self.registerAgent(
                app: app, named: "handover-ctl", siteID: siteID)
            let peerId = try await self.registerAgent(
                app: app, named: "handover-peer", siteID: siteID)
            #expect(try await Site.find(siteID, on: app.db)?.$networkControllerAgent.id?.uuidString == controllerId)

            // Comes back in user-mode: it has no OVN service to reconcile with.
            _ = try await self.registerAgent(
                app: app, named: "handover-ctl", siteID: siteID, networkCapability: .userMode)
            #expect(try await Site.find(siteID, on: app.db)?.$networkControllerAgent.id == nil)

            // The eligible peer claims it on its own next registration, which
            // is the existing `designateIfUnset` path.
            _ = try await self.registerAgent(app: app, named: "handover-peer", siteID: siteID)
            #expect(try await Site.find(siteID, on: app.db)?.$networkControllerAgent.id?.uuidString == peerId)
        }
    }

    @Test("An irreplaceable regressed controller keeps the designation")
    func regressedControllerKeepsDesignationWithNoPeer() async throws {
        try await withSiteTestApp { app, _, _, _ in
            // Clearing here would trade one silent failure for another: nothing
            // could claim the job, and the refusal would stop naming the node
            // the operator actually has to fix.
            let site = try await self.makeSite(app: app, name: "dc-nohandover")
            let siteID = try #require(site.id)
            let controllerId = try await self.registerAgent(
                app: app, named: "lonely-ctl", siteID: siteID)

            _ = try await self.registerAgent(
                app: app, named: "lonely-ctl", siteID: siteID, networkCapability: .userMode)
            #expect(
                try await Site.find(siteID, on: app.db)?.$networkControllerAgent.id?.uuidString
                    == controllerId)
        }
    }

    @Test("The sites API reports controller health")
    func siteResponseCarriesControllerHealth() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = try await self.makeSite(app: app, name: "dc-health")
            let siteID = try #require(site.id)
            let controllerId = try await self.registerAgent(
                app: app, named: "health-ctl", siteID: siteID)
            _ = try await self.registerAgent(app: app, named: "health-peer", siteID: siteID)

            func fetchSite() async throws -> SiteResponse {
                var found: SiteResponse?
                try await app.test(.GET, "/api/sites/\(siteID.uuidString)") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                } afterResponse: { res in
                    #expect(res.status == .ok)
                    found = try res.content.decode(SiteResponse.self)
                }
                return try #require(found)
            }

            let healthy = try await fetchSite()
            #expect(healthy.networkControllerStatus == .online)
            #expect(healthy.networkControllerIssue == nil)

            // Status flips as soon as the heartbeat lapses — before the grace
            // window makes it a refusal — so the outage is visible first.
            try await self.backdateHeartbeat(app: app, agentId: controllerId, bySeconds: 120)
            let quiet = try await fetchSite()
            #expect(quiet.networkControllerStatus == .offline)
            #expect(quiet.networkControllerIssue == nil)

            try await self.backdateHeartbeat(
                app: app, agentId: controllerId, bySeconds: self.wellPastGrace)
            let refusing = try await fetchSite()
            #expect(refusing.networkControllerStatus == .offline)
            #expect(refusing.networkControllerIssue?.contains("health-ctl") == true)
        }
    }

    @Test("BackfillDefaultSites gives site-less orgs a default and leaves others alone")
    func backfillDefaultSites() async throws {
        try await withSiteTestApp { app, _, _, _ in
            let builder = TestDataBuilder(db: app.db)
            // One org with no site of its own, one that already manages a site.
            let bareOrg = try await builder.createOrganization(name: "Backfill Bare Org")
            let stockedOrg = try await builder.createOrganization(name: "Backfill Stocked Org")
            let existingSite = Site(
                name: "hand-made-dc", organizationScope: .organization(stockedOrg.id!))
            try await existingSite.save(on: app.db)

            try await BackfillDefaultSites().prepare(on: app.db)

            // The bare org gained exactly one default site.
            let bareSites = try await Site.query(on: app.db)
                .filter(\.$organization.$id == bareOrg.id!)
                .all()
            #expect(bareSites.count == 1)
            #expect(bareSites.first?.name == Site.defaultName(forOrganizationNamed: "Backfill Bare Org"))

            // The stocked org was untouched: still just its hand-made site.
            let stockedSites = try await Site.query(on: app.db)
                .filter(\.$organization.$id == stockedOrg.id!)
                .all()
            #expect(stockedSites.count == 1)
            #expect(stockedSites.first?.id == existingSite.id)

            // Idempotent: a second run adds nothing (the default now exists).
            try await BackfillDefaultSites().prepare(on: app.db)
            let bareSitesAgain = try await Site.query(on: app.db)
                .filter(\.$organization.$id == bareOrg.id!)
                .count()
            #expect(bareSitesAgain == 1)
        }
    }

    @Test("Required placement creates a default alongside an existing custom site")
    func requiredPlacementFallbackSite() async throws {
        try await withSiteTestApp { app, _, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Placement Fallback Org")
            let custom = Site(
                name: "placement-custom-dc", organizationScope: .organization(try org.requireID()))
            try await custom.save(on: app.db)

            try await RequireSitePlacement().prepare(on: app.db)

            let sites = try await Site.query(on: app.db)
                .filter(\.$organization.$id == org.id!)
                .all()
            #expect(sites.count == 2)
            #expect(sites.contains { $0.id == custom.id })
            #expect(
                sites.contains {
                    $0.name == Site.defaultName(forOrganizationNamed: "Placement Fallback Org")
                })

            // The fallback creation and the constraints are both idempotent.
            try await RequireSitePlacement().prepare(on: app.db)
            let count = try await Site.query(on: app.db)
                .filter(\.$organization.$id == org.id!)
                .count()
            #expect(count == 2)
        }
    }

    @Test("Required placement uses an owned fallback when the default name is taken")
    func requiredPlacementFallbackNameCollision() async throws {
        try await withSiteTestApp { app, _, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let owner = try await builder.createOrganization(name: "Fallback Collision Owner")
            let target = try await builder.createOrganization(name: "Fallback Collision Target")
            let collision = Site(
                name: Site.defaultName(forOrganizationNamed: target.name),
                organizationScope: .organization(try owner.requireID()))
            try await collision.save(on: app.db)

            try await RequireSitePlacement().prepare(on: app.db)

            let fallback = try #require(
                try await Site.query(on: app.db)
                    .filter(\.$organization.$id == target.id!)
                    .first())
            #expect(fallback.name == "Default Site \(try target.requireID().uuidString)")
            #expect(collision.$organization.id == owner.id)
        }
    }
}
