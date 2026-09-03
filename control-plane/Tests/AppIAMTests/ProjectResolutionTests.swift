import Fluent
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for the create-side project resolution (issues #1049, #1059) — the one
/// answer to "which project does this create go in?" behind all seven
/// project-scoped creates: VM, sandbox, volume, network, security group,
/// floating IP and DNS zone.
///
/// **The answer is "the one you named."** Two of the seven used to guess when a
/// request named none, and they guessed differently: VM and sandbox creation
/// took the project literally *named* "Default Project", the other five took the
/// organization's oldest. Neither answer was one anybody chose, so the question
/// was withdrawn rather than settled. These pin what the seven now agree on: one
/// refusal for an omitted project, one refusal for an id nothing backs, and one
/// wording per verb.
///
/// The suite deliberately reaches all seven endpoints through one helper. The
/// old five-endpoint version could not have caught the divergence it was written
/// beside, because the two endpoints that diverged were the two it did not post
/// to.
@Suite("Project Resolution Tests", .serialized)
final class ProjectResolutionTests {

    /// What every test needs to reach project resolution at all seven endpoints.
    private struct Fixture {
        let app: Application
        let builder: TestDataBuilder
        let user: User
        let org: Organization
        let project: Project
        let siteID: UUID
        /// A `.ready` image, because `VMController.create` validates the image
        /// and checks `read` on it *before* it resolves the project. Without a
        /// real image — and permission to read it for non-admin callers — a
        /// VM-create test refuses for the wrong reason and passes vacuously.
        let image: Image
        let token: String
    }

    /// A system admin whose current organization holds one project, so the
    /// evaluator permits every create and project resolution is the only thing
    /// under test.
    private func withProjectResolutionApp(
        _ test: (Fixture) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "projresuser",
                email: "projres@example.com",
                displayName: "Project Resolution User",
                isSystemAdmin: true
            )
            let org = try await builder.createOrganization(name: "Project Resolution Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)

            let project = try await builder.createProject(
                name: "Project Resolution Project",
                description: "Project for project-resolution tests",
                organization: org
            )
            let image = try await builder.createImage(
                name: "Project Resolution Image", project: project, uploadedBy: user)
            let siteID = try await builder.placementSite(for: project).requireID()
            let token = try await user.generateAPIKey(on: app.db)

            try await test(
                Fixture(
                    app: app, builder: builder, user: user, org: org, project: project,
                    siteID: siteID, image: image, token: token))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// All seven creates, each posted with whatever body carries a `projectId`.
    /// Everything else in every body is valid, so the only thing that can refuse
    /// a request is project resolution.
    ///
    /// VM and sandbox encode dictionaries rather than the DTO: their
    /// `CreateVMRequest` / `CreateSandboxRequest` are private structs nested
    /// inside their controllers' `create`, so a test cannot name them. The other
    /// five use the real request types.
    private func postEachCreate(
        _ fixture: Fixture, projectId: UUID?, suffix: String, as token: String? = nil,
        afterResponse: (String, TestingHTTPResponse) throws -> Void
    ) async throws {
        let app = fixture.app
        let token = token ?? fixture.token

        try await app.test(.POST, "/api/vms") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            var body: [String: String] = [
                "name": "vm-\(suffix)", "imageId": try fixture.image.requireID().uuidString,
            ]
            if let projectId { body["projectId"] = projectId.uuidString }
            try req.content.encode(body)
        } afterResponse: { res in
            try afterResponse("/api/vms", res)
        }

        try await app.test(.POST, "/api/sandboxes") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            var body: [String: String] = [
                "name": "sb-\(suffix)", "image": "ghcr.io/acme/worker:v1",
            ]
            if let projectId { body["projectId"] = projectId.uuidString }
            try req.content.encode(body)
        } afterResponse: { res in
            try afterResponse("/api/sandboxes", res)
        }

        try await app.test(.POST, "/api/volumes") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(
                CreateVolumeRequest(
                    name: "vol-\(suffix)", description: nil, projectId: projectId, environment: nil, sizeGB: 1,
                    format: nil, volumeType: nil, sourceImageId: nil, iopsTotal: nil, bpsTotal: nil))
        } afterResponse: { res in
            try afterResponse("/api/volumes", res)
        }

        try await app.test(.POST, "/api/networks") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(
                CreateNetworkRequest(
                    name: "net-\(suffix)", subnet: "10.90.0.0/24", projectId: projectId,
                    siteId: fixture.siteID))
        } afterResponse: { res in
            try afterResponse("/api/networks", res)
        }

        try await app.test(.POST, "/api/security-groups") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(
                CreateSecurityGroupRequest(name: "sg-\(suffix)", projectId: projectId))
        } afterResponse: { res in
            try afterResponse("/api/security-groups", res)
        }

        try await app.test(.POST, "/api/dns-zones") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(CreateDNSZoneRequest(name: "\(suffix).internal", projectId: projectId))
        } afterResponse: { res in
            try afterResponse("/api/dns-zones", res)
        }

        // The pool is deliberately unknown: floating-IP allocation resolves and
        // authorizes the project before it looks the pool up, so every one of
        // these answers for the project and never reaches the pool.
        try await app.test(.POST, "/api/floating-ips") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: token)
            try req.content.encode(CreateFloatingIPRequest(poolId: UUID(), projectId: projectId))
        } afterResponse: { res in
            try afterResponse("/api/floating-ips", res)
        }
    }

    /// The headline: naming no project is refused, everywhere, in the same
    /// words. Asserted for a caller who *has* a current organization and admin
    /// on a project in it — the shape that used to succeed at all seven, landing
    /// in two different projects depending on which endpoint was asked. Having
    /// somewhere obvious to put the resource is exactly what no longer helps.
    @Test("Naming no project is refused at every create, identically")
    func omittedProjectIsRefusedAtEveryCreate() async throws {
        try await withProjectResolutionApp { fixture in
            try await postEachCreate(fixture, projectId: nil, suffix: "noproject") { route, res in
                #expect(res.status == .badRequest, "\(route) answered \(res.status)")
                #expect(
                    res.body.string.contains("projectId is required"),
                    "\(route) answered \(res.body.string)")
            }
        }
    }

    /// The refusal above is not a symptom of the organization being empty or
    /// ambiguous — nothing counts its projects any more. This is the scenario
    /// the deleted `fallbackIsStableAcrossSeveralProjects` set up (an
    /// organization with several projects, where the old fallback had to pick
    /// one and be able to pick the same one twice); the answer is now that the
    /// question is not asked.
    @Test("Several projects in the organization are not chosen between")
    func severalProjectsAreNotGuessedBetween() async throws {
        try await withProjectResolutionApp { fixture in
            for index in 0..<4 {
                _ = try await fixture.builder.createProject(
                    name: "Later Project \(index)",
                    description: "A project the old fallback would have had to rank",
                    organization: fixture.org
                )
            }

            try await postEachCreate(fixture, projectId: nil, suffix: "several") { route, res in
                #expect(res.status == .badRequest, "\(route) answered \(res.status)")
                #expect(
                    res.body.string.contains("projectId is required"),
                    "\(route) answered \(res.body.string)")
            }
        }
    }

    /// The positive half: a named project is where the resource actually lands,
    /// and it is the one named rather than whichever the old fallback would have
    /// ranked first. Without this the suite would only prove refusals, and a
    /// resolver returning the wrong row would pass everything above.
    @Test("A named project is the one the resource lands in")
    func namedProjectIsWhereTheResourceLands() async throws {
        try await withProjectResolutionApp { fixture in
            // Created after — and sorting after — the fixture's project, so
            // neither of the two retired fallbacks would have chosen it.
            let target = try await fixture.builder.createProject(
                name: "Zulu Target Project",
                description: "Neither the oldest project nor one named Default Project",
                organization: fixture.org
            )
            let targetID = try target.requireID()

            try await fixture.app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "named-net", subnet: "10.92.0.0/24", projectId: targetID,
                        siteId: fixture.siteID))
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.body.string)")
                let network = try res.content.decode(NetworkResponse.self)
                #expect(network.projectId == targetID)
            }

            try await fixture.app.test(.POST, "/api/security-groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(CreateSecurityGroupRequest(name: "named-sg", projectId: targetID))
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.body.string)")
                let securityGroup = try res.content.decode(SecurityGroupResponse.self)
                #expect(securityGroup.projectId == targetID)
            }

            try await fixture.app.test(.POST, "/api/dns-zones") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(CreateDNSZoneRequest(name: "named.internal", projectId: targetID))
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.body.string)")
                let dNSZone = try res.content.decode(DNSZoneResponse.self)
                #expect(dNSZone.projectId == targetID)
            }
        }
    }

    /// Infrastructure creates authorize their explicit project directly. VM
    /// and sandbox collection middleware separately requires a current organization.
    @Test("An explicitly named project needs no current organization")
    func explicitProjectNeedsNoCurrentOrganization() async throws {
        try await withProjectResolutionApp { fixture in
            fixture.user.currentOrganizationId = nil
            try await fixture.user.save(on: fixture.app.db)
            let projectID = try fixture.project.requireID()

            try await fixture.app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    CreateNetworkRequest(
                        name: "no-org-net", subnet: "10.93.0.0/24", projectId: projectID,
                        siteId: fixture.siteID))
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.body.string)")
                let network = try res.content.decode(NetworkResponse.self)
                #expect(network.projectId == projectID)
            }

            try await fixture.app.test(.POST, "/api/security-groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(CreateSecurityGroupRequest(name: "no-org-sg", projectId: projectID))
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.body.string)")
                let securityGroup = try res.content.decode(SecurityGroupResponse.self)
                #expect(securityGroup.projectId == projectID)
            }

            try await fixture.app.test(.POST, "/api/dns-zones") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(CreateDNSZoneRequest(name: "no-org.internal", projectId: projectID))
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.body.string)")
                let dNSZone = try res.content.decode(DNSZoneResponse.self)
                #expect(dNSZone.projectId == projectID)
            }
        }
    }

    /// VM and sandbox creation keeps a check the other five do not: the target
    /// project's root organization must be the caller's *current* one. Dropping
    /// it would have made the seven identical, but by *widening* — a principal
    /// holding `create_resources` in organization B could create there while
    /// the middleware admitted the request on behalf of organization A. That is
    /// its own decision, so the asymmetry is deliberate, and this is the test
    /// that says so before someone collapses it.
    @Test("Current-organization scope still narrows VM create, and only VM create")
    func currentOrganizationStillScopesVMCreate() async throws {
        try await withProjectResolutionApp { fixture in
            let otherOrg = try await fixture.builder.createOrganization(name: "Other Resolution Org")
            try await fixture.builder.addUserToOrganization(
                user: fixture.user, organization: otherOrg, role: "admin")
            let otherProject = try await fixture.builder.createProject(
                name: "Other Org Project",
                description: "Reachable by permission, outside the current organization",
                organization: otherOrg
            )
            let otherProjectID = try otherProject.requireID()
            // The caller stays pointed at the *first* organization.

            try await fixture.app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode([
                    "name": "cross-org-vm",
                    "imageId": try fixture.image.requireID().uuidString,
                    "projectId": otherProjectID.uuidString,
                ])
            } afterResponse: { res in
                #expect(res.status == .forbidden, "\(res.body.string)")
                #expect(res.body.string.contains("Access denied to project"), "\(res.body.string)")
            }

            // The same project, same caller, at an endpoint that leaves the
            // whole question to the evaluator.
            try await fixture.app.test(.POST, "/api/security-groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    CreateSecurityGroupRequest(name: "cross-org-sg", projectId: otherProjectID))
            } afterResponse: { res in
                #expect(res.status == .ok, "\(res.body.string)")
                let securityGroup = try res.content.decode(SecurityGroupResponse.self)
                #expect(securityGroup.projectId == otherProjectID)
            }
        }
    }

    /// The evaluator has the first word on an unknown id, and it is the same
    /// word at all seven endpoints: a project with no row has a chain that never
    /// reaches an organization, and the evaluator denies a truncated chain
    /// outright — system admins included, since their reach is the tier-1 policy
    /// rather than a bypass. So the `400 "does not exist"` the inline copies
    /// wrote is not what a caller inventing a UUID sees.
    ///
    /// VM and sandbox only joined this list with #1059. They used to look the
    /// project up *first* and answer `400 "Project not found"`, distinguishable
    /// from the `403` a real-but-unreachable project got — an existence oracle
    /// over other tenants' projects, at the two endpoints the rule documented in
    /// `docs/architecture/iam.md` was written for the other five.
    @Test("An unknown project id is refused by the evaluator, identically at every create")
    func unknownProjectIsForbiddenEverywhere() async throws {
        try await withProjectResolutionApp { fixture in
            try await postEachCreate(fixture, projectId: UUID(), suffix: "missing") { route, res in
                #expect(res.status == .forbidden, "\(route) answered \(res.status): \(res.body.string)")
            }
        }
    }

    /// The nearest thing to a case that could reach the existence assertion: a
    /// role binding pinned straight at a project id with no row behind it — a
    /// binding that outlived its project, say. It is refused too: the chain is
    /// still truncated, so the grant never gets evaluated. That is what makes
    /// the `400` a backstop rather than an answer anyone sees.
    @Test("A grant pinned to a project with no row does not get past the evaluator either")
    func grantOnMissingProjectIsStillForbidden() async throws {
        try await withProjectResolutionApp { fixture in
            let member = try await fixture.builder.createUser(
                username: "projresmember",
                email: "projresmember@example.com",
                displayName: "Project Resolution Member",
                isSystemAdmin: false
            )
            try await fixture.builder.addUserToOrganization(
                user: member, organization: fixture.org, role: "member")
            member.currentOrganizationId = fixture.org.id
            try await member.save(on: fixture.app.db)

            // VM create checks image readability before project resolution.
            // Let this caller pass that gate so the VM row exercises the ghost
            // project just like the other six rows do.
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: try member.requireID(),
                role: .viewer,
                nodeType: .project,
                nodeID: try fixture.project.requireID(),
                createdBy: try member.requireID(),
                on: fixture.app.db
            )

            let ghostProject = UUID()
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: try member.requireID(),
                role: .admin,
                nodeType: .project,
                nodeID: ghostProject,
                createdBy: try member.requireID(),
                on: fixture.app.db
            )
            let memberToken = try await member.generateAPIKey(on: fixture.app.db)

            try await postEachCreate(
                fixture, projectId: ghostProject, suffix: "ghost", as: memberToken
            ) { route, res in
                #expect(res.status == .forbidden, "\(route) answered \(res.status): \(res.body.string)")
                #expect(
                    res.body.string.contains("this project"),
                    "\(route) refused before ghost-project authorization: \(res.body.string)")
            }
        }
    }

    /// The `verb:` knob exists for exactly one endpoint, and nothing else would
    /// notice if a refactor collapsed it: floating IPs *allocate* where the
    /// others *create*. Checked on a caller the evaluator denies — an
    /// organization member holding no role in the project — since the wording
    /// only ever reaches a `403`.
    @Test("The permission refusal keeps each endpoint's verb")
    func refusalWordingKeepsTheEndpointsVerb() async throws {
        try await withProjectResolutionApp { fixture in
            let outsider = try await fixture.builder.createUser(
                username: "projresoutsider",
                email: "projresoutsider@example.com",
                displayName: "Project Resolution Outsider",
                isSystemAdmin: false
            )
            try await fixture.builder.addUserToOrganization(
                user: outsider, organization: fixture.org, role: "member")
            outsider.currentOrganizationId = fixture.org.id
            try await outsider.save(on: fixture.app.db)
            let outsiderToken = try await outsider.generateAPIKey(on: fixture.app.db)
            let projectID = try fixture.project.requireID()

            try await fixture.app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
                try req.content.encode(CreateFloatingIPRequest(poolId: UUID(), projectId: projectID))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(
                    res.body.string.contains("You don't have permission to allocate floating IPs"),
                    "\(res.body.string)")
            }

            // The default verb, for contrast — the two spellings have to stay
            // distinguishable for the parameter to be earning its keep.
            try await fixture.app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
                try req.content.encode(
                    CreateVolumeRequest(
                        name: "denied-vol", description: nil, projectId: projectID, environment: nil,
                        sizeGB: 1,
                        format: nil, volumeType: nil, sourceImageId: nil, iopsTotal: nil, bpsTotal: nil))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(
                    res.body.string.contains("You don't have permission to create volumes"),
                    "\(res.body.string)")
            }
        }
    }

    /// The missing-project refusal carries the endpoint's verb too, for the same
    /// reason the permission refusal does — and it is the one place a caller
    /// meets that wording without already having been denied.
    @Test("The missing-project refusal keeps each endpoint's verb")
    func missingProjectWordingKeepsTheEndpointsVerb() async throws {
        try await withProjectResolutionApp { fixture in
            try await fixture.app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(CreateFloatingIPRequest(poolId: UUID(), projectId: nil))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(
                    res.body.string.contains("name the project to allocate floating IPs in"),
                    "\(res.body.string)")
            }

            try await fixture.app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                try req.content.encode(
                    CreateVolumeRequest(
                        name: "verbless-vol", description: nil, projectId: nil, environment: nil, sizeGB: 1,
                        format: nil, volumeType: nil, sourceImageId: nil, iopsTotal: nil, bpsTotal: nil))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
                #expect(
                    res.body.string.contains("name the project to create volumes in"),
                    "\(res.body.string)")
            }
        }
    }
}
