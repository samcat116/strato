import Testing
import Vapor
import VaporTesting
import AppTestSupport

@testable import App

/// `GET /api/hierarchy/validate` and `POST /api/hierarchy/repair` over
/// materialized-path drift — the class of damage a partial path rewrite leaves
/// behind (issue #871).
@Suite("Hierarchy Maintenance Tests", .serialized)
final class HierarchyMaintenanceTests {

    private struct Fixture {
        let organization: Organization
        let engineering: OrganizationalUnit
        let platform: OrganizationalUnit
        let project: Project
        let sysadminToken: String
    }

    private func withApp(_ test: (Application, TestDataBuilder, Fixture) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let builder = TestDataBuilder(db: app.testPostgres)
            let organization = try await builder.createOrganization(name: "Hierarchy Maintenance Org")
            let sysadmin = try await builder.createUser(
                username: "hm-sysadmin", email: "hm-sysadmin@example.com", isSystemAdmin: true)
            let engineering = try await builder.createOU(
                name: "engineering", description: "", organization: organization)
            let platform = try await builder.createOU(
                name: "platform", description: "", organization: organization, parentOU: engineering)
            let project = try await builder.createProject(name: "infra", description: "", ou: platform)

            let fixture = Fixture(
                organization: organization,
                engineering: engineering,
                platform: platform,
                project: project,
                sysadminToken: try await sysadmin.generateAPIKey(on: app)
            )
            try await test(app, builder, fixture)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("A consistent hierarchy reports no issues")
    func consistentHierarchyIsValid() async throws {
        try await withApp { app, _, fx in
            try await app.test(.GET, "/api/hierarchy/validate") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.sysadminToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let report = try res.content.decode(HierarchyValidationResponse.self)
                #expect(report.isValid)
                #expect(report.issues.isEmpty)
            }
        }
    }

    @Test("A project path that does not extend its folder's is reported")
    func staleProjectPathIsReported() async throws {
        try await withApp { app, _, fx in
            // The drift a folder move used to leave behind: the project still
            // names an ancestor it no longer has.
            try await fx.project.replacingPath(
                "/\(fx.organization.id!)/\(UUID())/\(fx.project.id!)"
            ).save(on: app.testPostgres)

            try await app.test(.GET, "/api/hierarchy/validate") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.sysadminToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let report = try res.content.decode(HierarchyValidationResponse.self)
                #expect(!report.isValid)
                #expect(report.summary.totalIssues == 1)
                #expect(report.summary.warningIssues == 1)

                let issue = try #require(report.issues.first)
                #expect(issue.type == "broken_path")
                #expect(issue.entityType == "project")
                #expect(issue.entityId == fx.project.id)
                #expect(issue.id == fx.project.id)
                #expect(issue.autoRepairable)
            }
        }
    }

    @Test("A folder path that disagrees with its parent chain is reported")
    func staleFolderPathIsReported() async throws {
        try await withApp { app, _, fx in
            try await fx.platform.replacingPath(
                "/\(fx.organization.id!)/\(fx.platform.id!)", depth: 0
            ).save(on: app.testPostgres)

            let issues = try await HierarchyMaintenanceService.findHierarchyIssues(on: app.testPostgres)
            // The project beneath it is not reported: expected paths come from
            // the relational chain, not from what the folder happens to store,
            // and the project still extends the folder's derived path.
            #expect(issues.count == 1)
            let issue = try #require(issues.first)
            #expect(issue.entityType == "ou")
            #expect(issue.entityId == fx.platform.id)
            #expect(issue.type == "broken_path")
        }
    }

    @Test("Repair rebuilds drifted paths and reports the tree as healed")
    func repairRebuildsPaths() async throws {
        try await withApp { app, _, fx in
            let correctFolderPath = fx.platform.path
            let correctProjectPath = fx.project.path

            try await fx.platform.replacingPath(
                "/\(fx.organization.id!)/\(fx.platform.id!)", depth: 0
            ).save(on: app.testPostgres)
            try await fx.project.replacingPath(
                "/\(fx.organization.id!)/\(fx.project.id!)"
            ).save(on: app.testPostgres)

            try await app.test(.POST, "/api/hierarchy/repair") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.sysadminToken)
                try req.content.encode(
                    HierarchyRepairRequest(
                        repairAll: true,
                        repairOptions: .init(rebuildPaths: true)
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let report = try res.content.decode(HierarchyRepairResponse.self)
                #expect(report.success)
                #expect(report.remainingIssues.isEmpty)
                #expect(report.repairedIssues.count == 2)
            }

            let platform = try #require(try await OrganizationalUnit.find(fx.platform.id!, on: app.testPostgres))
            let project = try #require(try await Project.find(fx.project.id!, on: app.testPostgres))
            #expect(platform.path == correctFolderPath)
            #expect(platform.depth == 1)
            #expect(project.path == correctProjectPath)
        }
    }

    @Test("Repair leaves paths alone unless rebuildPaths is requested")
    func repairRespectsOptions() async throws {
        try await withApp { app, _, fx in
            let drifted = "/\(fx.organization.id!)/\(fx.project.id!)"
            try await fx.project.replacingPath(drifted).save(on: app.testPostgres)

            // A body naming only `repairAll` decodes: every option defaults off.
            try await app.test(.POST, "/api/hierarchy/repair") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.sysadminToken)
                try req.content.encode(["repairAll": true])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let report = try res.content.decode(HierarchyRepairResponse.self)
                #expect(report.repairedIssues.isEmpty)
                #expect(report.remainingIssues.count == 1)
                // A request that asked for nothing does not report a healthy
                // tree: `success` describes the tree, not the request.
                #expect(!report.success)
            }

            let project = try #require(try await Project.find(fx.project.id!, on: app.testPostgres))
            #expect(project.path == drifted)
        }
    }

    @Test("Repair honours specificIssues")
    func repairHonoursSpecificIssues() async throws {
        try await withApp { app, builder, fx in
            let other = try await builder.createProject(
                name: "other", description: "", ou: fx.engineering)
            let otherDrifted = "/\(fx.organization.id!)/\(other.id!)"
            try await other.replacingPath(otherDrifted).save(on: app.testPostgres)
            try await fx.project.replacingPath(
                "/\(fx.organization.id!)/\(fx.project.id!)"
            ).save(on: app.testPostgres)

            try await app.test(.POST, "/api/hierarchy/repair") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.sysadminToken)
                try req.content.encode(
                    HierarchyRepairRequest(
                        specificIssues: [fx.project.id!],
                        repairOptions: .init(rebuildPaths: true)
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let report = try res.content.decode(HierarchyRepairResponse.self)
                #expect(report.repairedIssues.map(\.issueId) == [fx.project.id!])
                #expect(report.remainingIssues.map(\.entityId) == [other.id!])
                // The unselected issue still stands, so the tree is not healthy.
                #expect(!report.success)
            }

            let untouched = try #require(try await Project.find(other.id!, on: app.testPostgres))
            #expect(untouched.path == otherDrifted)
        }
    }

    @Test("Repair that leaves an unrepairable issue standing does not report success")
    func repairWithUnrepairableIssueIsNotSuccess() async throws {
        try await withApp { app, builder, fx in
            // A cycle in one branch of the org, drift in another: the drift is
            // repairable, the cycle is not, and a caller polling `success` must
            // not see green while the cycle stands.
            let left = try await builder.createOU(name: "left", description: "", organization: fx.organization)
            let right = try await builder.createOU(
                name: "right", description: "", organization: fx.organization, parentOU: left)
            try await OrganizationalUnit(
                id: left.id, name: left.name, description: left.description,
                organizationID: left.organizationID, parentOUID: right.id,
                path: left.path, depth: left.depth,
                createdAt: left.createdAt, updatedAt: left.updatedAt
            ).save(on: app.testPostgres)

            let correct = fx.project.path
            try await fx.project.replacingPath(
                "/\(fx.organization.id!)/\(fx.project.id!)"
            ).save(on: app.testPostgres)

            try await app.test(.POST, "/api/hierarchy/repair") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: fx.sysadminToken)
                try req.content.encode(
                    HierarchyRepairRequest(repairAll: true, repairOptions: .init(rebuildPaths: true)))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let report = try res.content.decode(HierarchyRepairResponse.self)
                #expect(report.repairedIssues.map(\.issueId) == [fx.project.id!])
                #expect(!report.success)
                #expect(report.remainingIssues.allSatisfy { $0.type == "circular_reference" })
                #expect(Set(report.remainingIssues.map(\.entityId)) == Set([left.id!, right.id!]))
            }

            // The repairable half still got repaired.
            let project = try #require(try await Project.find(fx.project.id!, on: app.testPostgres))
            #expect(project.path == correct)
        }
    }

    @Test("A project attached to neither a folder nor an organization is reported as orphaned")
    func parentlessProjectIsReported() async throws {
        try await withApp { app, _, fx in
            // Reachable: both columns are nullable and no check constraint
            // forbids the pair, so only `Project.validate()` stands in the way.
            try await fx.project.replacingScope(
                organizationID: nil, organizationalUnitID: nil
            ).save(on: app.testPostgres)

            let issues = try await HierarchyMaintenanceService.findHierarchyIssues(on: app.testPostgres)
            #expect(issues.count == 1)
            let issue = try #require(issues.first)
            #expect(issue.type == "orphaned_resource")
            #expect(issue.severity == "critical")
            #expect(issue.entityType == "project")
            #expect(issue.entityId == fx.project.id)
            #expect(!issue.autoRepairable)

            // Nothing to derive a path from, so a full repair leaves it alone.
            let report = try await HierarchyMaintenanceService.performHierarchyRepair(
                repairRequest: .init(repairAll: true, repairOptions: .init(rebuildPaths: true)), on: app.testPostgres)
            #expect(report.repairedIssues.isEmpty)
            #expect(!report.success)
        }
    }

    @Test("A parent cycle is reported instead of hanging the derivation")
    func parentCycleIsReported() async throws {
        try await withApp { app, _, fx in
            // Nothing in the schema forbids this: the foreign key only requires
            // the parent row to exist, so engineering ⇄ platform is storable and
            // the path derivation has to terminate on it.
            try await OrganizationalUnit(
                id: fx.engineering.id, name: fx.engineering.name, description: fx.engineering.description,
                organizationID: fx.engineering.organizationID, parentOUID: fx.platform.id,
                path: fx.engineering.path, depth: fx.engineering.depth,
                createdAt: fx.engineering.createdAt, updatedAt: fx.engineering.updatedAt
            ).save(on: app.testPostgres)

            let issues = try await HierarchyMaintenanceService.findHierarchyIssues(on: app.testPostgres)
            #expect(issues.count == 2)
            #expect(issues.allSatisfy { $0.type == "circular_reference" })
            #expect(issues.allSatisfy { $0.severity == "critical" })
            #expect(issues.allSatisfy { !$0.autoRepairable })
            #expect(Set(issues.map(\.entityId)) == Set([fx.engineering.id!, fx.platform.id!]))
        }
    }

    @Test("The maintenance repair rebuilds drift and is idempotent")
    func maintenanceRepairRebuildsDrift() async throws {
        try await withApp { app, _, fx in
            let correct = fx.project.path
            try await fx.project.replacingPath(
                "/\(fx.organization.id!)/\(UUID())/\(fx.project.id!)"
            ).save(on: app.testPostgres)

            let request = HierarchyRepairRequest(
                repairAll: true, repairOptions: .init(rebuildPaths: true))
            let first = try await HierarchyMaintenanceService.performHierarchyRepair(
                repairRequest: request, on: app.testPostgres)
            let second = try await HierarchyMaintenanceService.performHierarchyRepair(
                repairRequest: request, on: app.testPostgres)
            #expect(first.repairedIssues.count == 1)
            #expect(second.repairedIssues.isEmpty)

            let project = try #require(try await Project.find(fx.project.id!, on: app.testPostgres))
            #expect(project.path == correct)
            #expect(try await HierarchyMaintenanceService.findHierarchyIssues(on: app.testPostgres).isEmpty)
        }
    }

    @Test("Validate and repair are system-admin only")
    func maintenanceIsSystemAdminOnly() async throws {
        try await withApp { app, builder, fx in
            let member = try await builder.createUser(username: "hm-member", email: "hm-member@example.com")
            try await builder.addUserToOrganization(user: member, organization: fx.organization, role: "admin")
            let token = try await member.generateAPIKey(on: app)

            try await app.test(.GET, "/api/hierarchy/validate") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            try await app.test(.POST, "/api/hierarchy/repair") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(HierarchyRepairRequest(repairAll: true))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }
}
