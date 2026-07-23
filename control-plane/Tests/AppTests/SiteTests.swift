import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

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
            capabilities: ["qemu"],
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            ),
            networkCapability: networkCapability,
            protocolVersion: protocolVersion
        )
        let orgID = try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id
        let uuid = try await app.agentService.registerAgent(
            message, agentName: name, siteID: siteID,
            organizationScope: orgID.map { .organization($0) })
        return uuid.uuidString
    }

    /// A site owned by the harness's organization, so the site↔agent same-org
    /// invariant holds for agents registered via `registerAgent`.
    private func makeSite(app: Application, name: String) async throws -> Site {
        let orgID = try #require(try await Organization.query(on: app.db).sort(\.$createdAt).first()?.id)
        let site = Site(name: name, organizationScope: .organization(orgID))
        try await site.save(on: app.db)
        return site
    }

    private func placeVM(
        app: Application, project: Project, named name: String, onAgent agentId: String, network: String
    ) async throws {
        let builder = TestDataBuilder(db: app.db)
        let vm = try await builder.createVM(name: name, project: project)
        vm.hypervisorId = agentId
        try await vm.save(on: app.db)
        let nic = VMNetworkInterface(
            vmID: vm.id!, network: network, macAddress: VMNetworkInterface.generateMACAddress())
        try await nic.save(on: app.db)
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

            // Pre-v4 member: assembly keeps it on legacy per-node scoping, so
            // designating it would leave the site's topology authored nowhere.
            let oldId = try await self.registerAgent(
                app: app, named: "old-proto", siteID: site.id, protocolVersion: 3)
            try await app.test(.PUT, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSiteRequest(description: nil, networkControllerAgentId: UUID(uuidString: oldId)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

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

    @Test("Designating a pre-v12 controller is refused while floating IPs are attached")
    func controllerDesignationFloatingIPGate() async throws {
        try await withSiteTestApp { app, _, project, token in
            let site = try await self.makeSite(app: app, name: "fip-gate-site")
            let currentId = try await self.registerAgent(app: app, named: "fip-current", siteID: site.id)
            let oldId = try await self.registerAgent(
                app: app, named: "fip-old", siteID: site.id, protocolVersion: 11)
            try await self.placeVM(
                app: app, project: project, named: "fip-gate-vm", onAgent: currentId, network: "default")

            // An attached floating IP on the site's VM (rows built directly —
            // the attach API's own gates are covered elsewhere).
            let vm = try #require(try await VM.query(on: app.db).filter(\.$name == "fip-gate-vm").first())
            let nic = try #require(
                try await VMNetworkInterface.query(on: app.db).filter(\.$vm.$id == vm.id!).first())
            let pool = FloatingIPPool(name: "fip-gate-pool", cidr: "203.0.113.0/29")
            try await pool.save(on: app.db)
            let floatingIP = FloatingIP(
                poolID: pool.id!, address: "203.0.113.2", projectID: project.id!, interfaceID: nic.id!)
            try await floatingIP.save(on: app.db)

            // A pre-v12 controller would silently drop the attached NAT.
            try await app.test(.PUT, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSiteRequest(description: nil, networkControllerAgentId: UUID(uuidString: oldId)))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // A current-protocol controller is fine.
            try await app.test(.PUT, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSiteRequest(
                        description: nil, networkControllerAgentId: UUID(uuidString: currentId)))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // Detached, the old controller becomes designatable again.
            floatingIP.$interface.id = nil
            try await floatingIP.save(on: app.db)
            try await app.test(.PUT, "/api/sites/\(site.id!.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    UpdateSiteRequest(description: nil, networkControllerAgentId: UUID(uuidString: oldId)))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test("A site's network controller cannot be deregistered")
    func controllerDeregistrationGuard() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = try await self.makeSite(app: app, name: "dc-dereg")
            let controllerId = try await self.registerAgent(app: app, named: "dereg-ctl", siteID: site.id)
            site.$networkControllerAgent.id = UUID(uuidString: controllerId)
            try await site.save(on: app.db)

            // The controller reference has no FK, so deletion would leave the
            // site pointing at a vanished agent and reconciliation would stop.
            try await app.test(.DELETE, "/api/agents/\(controllerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
            #expect(try await Agent.find(UUID(uuidString: controllerId), on: app.db) != nil)
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

    @Test("The designated network controller cannot be removed from its site")
    func controllerRemovalGuard() async throws {
        try await withSiteTestApp { app, _, _, token in
            let site = try await self.makeSite(app: app, name: "dc-c")
            let controllerId = try await self.registerAgent(app: app, named: "ctl", siteID: site.id)
            site.$networkControllerAgent.id = UUID(uuidString: controllerId)
            try await site.save(on: app.db)

            try await app.test(.DELETE, "/api/sites/\(site.id!.uuidString)/agents/\(controllerId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }
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
                network: LogicalNetwork.defaultNetworkName)

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
                let sites = try res.content.decode([SiteResponse].self)
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
                let sites = try res.content.decode([SiteResponse].self)
                #expect(sites.count == 2)
            }

            // Filtered, the admin bypass must not widen the result back out.
            let orgID = try #require(admin.currentOrganizationId)
            try await app.test(.GET, "/api/sites?organization_id=\(orgID.uuidString)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let sites = try res.content.decode([SiteResponse].self)
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
                let sites = try res.content.decode([SiteResponse].self)
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
        wireProtocolVersion: Int = WireProtocol.currentVersion,
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
            siteID: siteID,
            wireProtocolVersion: wireProtocolVersion
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

    @Test("Site requirement excludes members on a pre-site-authority protocol")
    func schedulerSiteFilterExcludesOldProtocol() throws {
        let siteA = UUID()
        // A pre-v4 member is kept on legacy per-node network scoping, so a
        // pinned-network VM placed there would land in its private local NB.
        let oldMember = makeSchedulable(name: "old-member", siteID: siteA, wireProtocolVersion: 3)
        let newMember = makeSchedulable(name: "new-member", siteID: siteA)

        let scheduler = SchedulerService(logger: Logger(label: "test"))
        let requirements = VMPlacementRequirements(
            cpu: 1, memory: 1 << 30, disk: 1 << 30, siteID: siteA)

        let selected = try scheduler.selectAgent(
            requirements: requirements, from: [oldMember, newMember])
        #expect(selected == newMember.id)

        #expect(throws: SchedulerError.self) {
            try scheduler.selectAgent(requirements: requirements, from: [oldMember])
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
            let peerNet = LogicalNetwork(
                name: "peer-net", subnet: "10.30.0.0/24", gateway: "10.30.0.1",
                projectID: project.id)
            try await peerNet.save(on: app.db)
            let pinnedNet = LogicalNetwork(
                name: "pinned-net", subnet: "10.31.0.0/24", gateway: "10.31.0.1",
                projectID: project.id, siteID: site.id!)
            try await pinnedNet.save(on: app.db)
            try await self.placeVM(
                app: app, project: project, named: "peer-vm", onAgent: peerId, network: "peer-net")

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
            try await self.placeVM(
                app: app, project: project, named: "lone-vm", onAgent: agentId,
                network: LogicalNetwork.defaultNetworkName)

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(!sync.networksAuthoritative)
            #expect(sync.networks.isEmpty)
            // The VM still syncs — only topology is withheld.
            #expect(sync.vms.count == 1)
        }
    }

    @Test("A sited agent on a pre-v4 protocol keeps legacy scoping (rolling-upgrade safety)")
    func preSiteAuthorityAgentAssembly() async throws {
        try await withSiteTestApp { app, _, project, _ in
            let site = try await self.makeSite(app: app, name: "dc-skew")

            // A v3 binary predates `networksAuthoritative`: it would read the
            // non-authoritative shape (networks: [] + false) as an
            // authoritative teardown of all its L3. It must keep receiving its
            // own networks, authoritative, even though it's in a site.
            let oldAgentId = try await self.registerAgent(
                app: app, named: "old-binary", siteID: site.id, protocolVersion: 3)
            try await self.placeVM(
                app: app, project: project, named: "old-vm", onAgent: oldAgentId,
                network: LogicalNetwork.defaultNetworkName)

            let sync = try await app.desiredStateAssembler.assemble(agentId: oldAgentId)
            #expect(sync.networksAuthoritative)
            #expect(sync.networks.contains { $0.name == LogicalNetwork.defaultNetworkName })
        }
    }

    @Test("A site-less agent keeps the legacy model: own networks, authoritative")
    func sitelessAssembly() async throws {
        try await withSiteTestApp { app, _, project, _ in
            let agentId = try await self.registerAgent(app: app, named: "legacy-agent")
            try await self.placeVM(
                app: app, project: project, named: "legacy-vm", onAgent: agentId,
                network: LogicalNetwork.defaultNetworkName)

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentId)
            #expect(sync.networksAuthoritative)
            #expect(sync.networks.contains { $0.name == LogicalNetwork.defaultNetworkName })
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
}
