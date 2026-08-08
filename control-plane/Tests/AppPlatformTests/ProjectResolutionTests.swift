import Fluent
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for `Request.authorizedProjectForCreate` (issue #1049), the one answer
/// to "which project does this create go in?" behind volume, network,
/// security-group, floating-IP and DNS-zone creation.
///
/// The five endpoints each carried their own copy of the resolution, and the
/// copies had drifted over whether the resolved project must exist: three
/// confirmed it, network create only when the request also pinned a site, and
/// `createVolume` left the row insert to trip the foreign key. These pin what
/// they now agree on — one refusal per endpoint for an id nothing backs, one
/// fallback that answers the same way twice, and one wording per verb.
@Suite("Project Resolution Tests", .serialized)
final class ProjectResolutionTests {

    /// A system admin whose current organization holds exactly one project — so
    /// the default-project fallback has a single unambiguous answer, and the
    /// evaluator permits every create, leaving project resolution as the only
    /// thing under test.
    private func withProjectResolutionApp(
        _ test: (Application, TestDataBuilder, User, Organization, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)
            try await app.autoMigrate()

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
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, builder, user, org, project, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    /// The five creates, each posted with whatever body carries a `projectId`.
    /// Everything else in the body is valid, so the only thing that can refuse
    /// the request is project resolution.
    private func postEachCreate(
        app: Application, token: String, projectId: UUID?, suffix: String,
        afterResponse: (String, TestingHTTPResponse) throws -> Void
    ) async throws {
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
                CreateNetworkRequest(name: "net-\(suffix)", subnet: "10.90.0.0/24", projectId: projectId))
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
            try req.content.encode(
                CreateDNSZoneRequest(name: "\(suffix).internal", projectId: projectId))
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

    /// The evaluator has the first word on an unknown id, and it is the same
    /// word at all five endpoints: a project with no row has a chain that never
    /// reaches an organization, and the evaluator denies a truncated chain
    /// outright — system admins included, since their reach is the tier-1 policy
    /// rather than a bypass. So the `400 "does not exist"` the inline copies
    /// wrote is not what a caller inventing a UUID sees.
    @Test("An unknown project id is refused by the evaluator, identically at every create")
    func unknownProjectIsForbiddenEverywhere() async throws {
        try await withProjectResolutionApp { app, _, _, _, _, token in
            try await postEachCreate(
                app: app, token: token, projectId: UUID(), suffix: "missing"
            ) { route, res in
                #expect(res.status == .forbidden, "\(route) answered \(res.status)")
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
        try await withProjectResolutionApp { app, builder, _, org, _, _ in
            let member = try await builder.createUser(
                username: "projresmember",
                email: "projresmember@example.com",
                displayName: "Project Resolution Member",
                isSystemAdmin: false
            )
            try await builder.addUserToOrganization(user: member, organization: org, role: "member")
            member.currentOrganizationId = org.id
            try await member.save(on: app.db)

            let ghostProject = UUID()
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: try member.requireID(),
                role: .admin,
                nodeType: .project,
                nodeID: ghostProject,
                createdBy: try member.requireID(),
                on: app.db
            )
            let memberToken = try await member.generateAPIKey(on: app.db)

            try await postEachCreate(
                app: app, token: memberToken, projectId: ghostProject, suffix: "ghost"
            ) { route, res in
                #expect(res.status == .forbidden, "\(route) answered \(res.status)")
            }
        }
    }

    @Test("Omitting the project falls back to the current organization's project")
    func omittedProjectFallsBackToTheOrganizationsProject() async throws {
        try await withProjectResolutionApp { app, _, _, org, project, token in
            try await app.test(.POST, "/api/networks") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateNetworkRequest(name: "fallback-net", subnet: "10.91.0.0/24"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let network = try res.content.decode(NetworkResponse.self)
                #expect(network.projectId == project.id)
            }

            try await app.test(.POST, "/api/security-groups") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateSecurityGroupRequest(name: "fallback-sg"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let group = try res.content.decode(SecurityGroupResponse.self)
                #expect(group.projectId == project.id)
            }

            try await app.test(.POST, "/api/dns-zones") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateDNSZoneRequest(name: "fallback.internal"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let zone = try res.content.decode(DNSZoneResponse.self)
                #expect(zone.projectId == project.id)
            }

            // Floating-IP allocation needs an address to hand out, so this one
            // brings a pool. Scoped to the org, which is what makes it serve
            // the project the fallback resolves to.
            let pool = FloatingIPPool(
                name: "fallback-pool", cidr: "203.0.113.0/29",
                organizationScope: .organization(try org.requireID()))
            try await pool.save(on: app.db)
            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(CreateFloatingIPRequest(poolId: try pool.requireID(), projectId: nil))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let floatingIP = try res.content.decode(FloatingIPResponse.self)
                #expect(floatingIP.projectId == project.id)
            }

            // Volume create is the endpoint that gained the existence
            // assertion, and with it a `Project.find` on the success path, so
            // the fallback landing in the right project is worth pinning here
            // rather than assumed from the other four. It answers `202` and
            // places asynchronously (STR-148); with no agents connected the
            // placement degrades, which the wait below settles so the detached
            // task cannot race application shutdown.
            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    CreateVolumeRequest(
                        name: "fallback-vol", description: nil, projectId: nil, environment: nil, sizeGB: 1,
                        format: nil,
                        volumeType: nil, sourceImageId: nil, iopsTotal: nil, bpsTotal: nil))
            } afterResponse: { res in
                #expect(res.status == .accepted)
                let accepted = try res.content.decode(AcceptedMutation<VolumeResponse>.self)
                #expect(accepted.resource.projectId == project.id)
            }
            var placed: Volume?
            for _ in 0..<100 {
                placed = try await Volume.query(on: app.db).first()
                if placed?.conditions.degraded != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(placed?.conditions.degraded != nil)
        }
    }

    /// The fallback's sort earns its keep only when the organization holds more
    /// than one project: unsorted, `.first()` is whatever row Postgres feels
    /// like returning, so two identical requests could land in different
    /// projects. This does not assert that the *oldest* project is the right
    /// default — that question is issue #1059 — only that the answer is the
    /// same one twice.
    @Test("With several projects the fallback is repeatable, not whatever Postgres returns")
    func fallbackIsStableAcrossSeveralProjects() async throws {
        try await withProjectResolutionApp { app, builder, _, org, project, token in
            for index in 0..<4 {
                _ = try await builder.createProject(
                    name: "Later Project \(index)",
                    description: "Created after the fallback's answer",
                    organization: org
                )
            }

            var landedIn: [UUID] = []
            for index in 0..<3 {
                try await app.test(.POST, "/api/security-groups") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    try req.content.encode(CreateSecurityGroupRequest(name: "stable-sg-\(index)"))
                } afterResponse: { res in
                    #expect(res.status == .ok)
                    landedIn.append(try res.content.decode(SecurityGroupResponse.self).projectId)
                }
            }

            #expect(landedIn == Array(repeating: try project.requireID(), count: 3))
        }
    }

    /// The `verb:` knob exists for exactly one endpoint, and nothing else would
    /// notice if a refactor collapsed it: floating IPs *allocate* where the
    /// other four *create*. Checked on a caller the evaluator denies — an
    /// organization member holding no role in the project — since the wording
    /// only ever reaches a `403`.
    @Test("The permission refusal keeps each endpoint's verb")
    func refusalWordingKeepsTheEndpointsVerb() async throws {
        try await withProjectResolutionApp { app, builder, _, org, project, _ in
            let outsider = try await builder.createUser(
                username: "projresoutsider",
                email: "projresoutsider@example.com",
                displayName: "Project Resolution Outsider",
                isSystemAdmin: false
            )
            try await builder.addUserToOrganization(user: outsider, organization: org, role: "member")
            outsider.currentOrganizationId = org.id
            try await outsider.save(on: app.db)
            let outsiderToken = try await outsider.generateAPIKey(on: app.db)

            try await app.test(.POST, "/api/floating-ips") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
                try req.content.encode(
                    CreateFloatingIPRequest(poolId: UUID(), projectId: try project.requireID()))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
                #expect(
                    res.body.string.contains("You don't have permission to allocate floating IPs"),
                    "\(res.body.string)")
            }

            // The default verb, for contrast — the two spellings have to stay
            // distinguishable for the parameter to be earning its keep.
            try await app.test(.POST, "/api/volumes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: outsiderToken)
                try req.content.encode(
                    CreateVolumeRequest(
                        name: "denied-vol", description: nil, projectId: try project.requireID(), environment: nil,
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

    @Test("A caller with no current organization and no project id is refused")
    func noCurrentOrganizationIsRefusedEverywhere() async throws {
        try await withProjectResolutionApp { app, _, user, _, _, token in
            user.currentOrganizationId = nil
            try await user.save(on: app.db)

            try await postEachCreate(
                app: app, token: token, projectId: nil, suffix: "noorg"
            ) { route, res in
                #expect(res.status == .badRequest, "\(route) answered \(res.status)")
                #expect(
                    res.body.string.contains("No project specified and user has no current organization"),
                    "\(route) answered \(res.body.string)")
            }
        }
    }

    @Test("A current organization with no projects is refused everywhere")
    func organizationWithoutProjectsIsRefusedEverywhere() async throws {
        try await withProjectResolutionApp { app, builder, user, _, _, token in
            let emptyOrg = try await builder.createOrganization(name: "Empty Resolution Org")
            try await builder.addUserToOrganization(user: user, organization: emptyOrg, role: "admin")
            user.currentOrganizationId = emptyOrg.id
            try await user.save(on: app.db)

            try await postEachCreate(
                app: app, token: token, projectId: nil, suffix: "emptyorg"
            ) { route, res in
                #expect(res.status == .badRequest, "\(route) answered \(res.status)")
                #expect(
                    res.body.string.contains("No project specified and no default project found"),
                    "\(route) answered \(res.body.string)")
            }
        }
    }
}
