import ControlPlanePostgres
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport

@testable import App

/// STR-203: a credential confined to a project subtree can *enumerate* what it
/// is allowed to manage, not just operate on ids it was handed out of band.
///
/// `/api/vms` and `/api/sandboxes` are the two route-prefix-guarded collections,
/// and their middleware check is a *substituted* one — `view_organization` on
/// the acting organization, standing in for the per-row `vm:read` the handler
/// goes on to do. A restriction is stated in the vocabulary of that per-row act,
/// so intersecting it with the substituted question denied it twice over: a
/// project never appears in an organization's ancestor chain, and `vm:read` does
/// not cover `org:read`. The same credential could read every one of those VMs
/// one id at a time.
///
/// These drive the real production routes with real bearer keys, because the
/// defect was in the route table's own gate and nothing below it.
@Suite("Restricted Credential Lists", .serialized)
final class RestrictedCredentialListTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            app.iamDecisionLogConfig.recordDecisions = true
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private struct Fixture {
        let org: Organization
        let otherOrg: Organization
        let projectA: Project
        let projectB: Project
        let emptyProject: Project
        let vmA: VM
        let vmB: VM
        let sandboxA: Sandbox
        let image: Image
        let user: User
        /// `["*"]`, confined to project A — the credential from the bug report:
        /// *every* action, one project.
        let scopedAllA: String
        /// `["vm:read"]`, confined to project A: both halves of the restriction
        /// in force at once.
        let vmReadA: String
        /// `["vm:read"]` with no node scope, which failed the substituted
        /// question on the action half alone.
        let actionOnly: String
        let scopedAllB: String
        let scopedEmpty: String
    }

    private func fixture(_ app: Application) async throws -> Fixture {
        let builder = TestDataBuilder(db: app.testPostgres)
        let org = try await builder.createOrganization(name: "Scoped Org")
        let otherOrg = try await builder.createOrganization(name: "Foreign Org")
        let projectA = try await builder.createProject(
            name: "Project A", description: "d", organization: org)
        let projectB = try await builder.createProject(
            name: "Project B", description: "d", organization: org)
        let emptyProject = try await builder.createProject(
            name: "Empty Project", description: "d", organization: org)
        let vmA = try await builder.createVM(name: "vm-a", project: projectA)
        let vmB = try await builder.createVM(name: "vm-b", project: projectB)
        let sandboxA = try await builder.createSandbox(name: "sandbox-a", project: projectA)

        let user = try await builder.createUser(username: "scoped-user", email: "scoped@example.com")
        // VM create refuses a body with no `imageId` before it authorizes
        // anything, so the create assertions need a real one. It lives in
        // project A, which the credential may read.
        let image = try await builder.createImage(project: projectA, uploadedBy: user)
        try await builder.addUserToOrganization(user: user, organization: org, role: "member")
        // Editor across the whole organization, so every assertion below is
        // about the *credential* and never about a missing binding.
        try await RoleBindingService.grant(
            principalType: .user, principalID: try user.requireID(), role: .editor,
            nodeType: .organization, nodeID: try org.requireID(), createdBy: nil, on: app.testPostgres)
        // `actingOrganizationID()` reads this, and the collection gate 403s
        // without it — membership alone does not set it.
        try await user.replacingCurrentOrganization(try org.requireID()).save(on: app.testPostgres)

        return Fixture(
            org: org,
            otherOrg: otherOrg,
            projectA: projectA,
            projectB: projectB,
            emptyProject: emptyProject,
            vmA: vmA,
            vmB: vmB,
            sandboxA: sandboxA,
            image: image,
            user: user,
            scopedAllA: try await user.generateAPIKey(
                on: app, name: "all-a", restriction: try restriction(["*"], node: projectA)),
            vmReadA: try await user.generateAPIKey(
                on: app, name: "vmread-a", restriction: try restriction(["vm:read"], node: projectA)),
            actionOnly: try await user.generateAPIKey(
                on: app, name: "vmread", restriction: try restriction(["vm:read"])),
            scopedAllB: try await user.generateAPIKey(
                on: app, name: "all-b", restriction: try restriction(["*"], node: projectB)),
            scopedEmpty: try await user.generateAPIKey(
                on: app, name: "all-empty", restriction: try restriction(["*"], node: emptyProject))
        )
    }

    private func restriction(_ actions: [String], node: Project? = nil) throws -> CredentialRestriction {
        try CredentialRestriction.validated(
            actions: actions,
            nodeType: node == nil ? nil : IAMNodeType.project.rawValue,
            nodeID: try node?.requireID())
    }

    /// The names on a list page, so an assertion reads as "which rows came
    /// back" rather than as a decode.
    private struct NamedPage: Content {
        struct Item: Content { let name: String }
        let items: [Item]
        let total: Int
    }

    private func names(_ res: TestingHTTPResponse) throws -> [String] {
        try res.content.decode(NamedPage.self).items.map(\.name).sorted()
    }

    // MARK: - The regression

    @Test("A project-scoped credential lists the VMs in its project")
    func projectScopedKeyListsVMs() async throws {
        try await withApp { app in
            let f = try await fixture(app)

            for (label, key) in [("all", f.scopedAllA), ("vm:read", f.vmReadA)] {
                try await app.test(.GET, "/api/vms") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: key)
                } afterResponse: { res async throws in
                    #expect(res.status == .ok, "\(label) key → \(res.status)")
                    #expect(try names(res) == ["vm-a"], "\(label) key")
                }
            }
        }
    }

    @Test("A project-scoped credential lists the sandboxes in its project")
    func projectScopedKeyListsSandboxes() async throws {
        try await withApp { app in
            let f = try await fixture(app)

            try await app.test(.GET, "/api/sandboxes") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.scopedAllA)
            } afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try names(res) == ["sandbox-a"])
            }
        }
    }

    /// The action half on its own. A `vm:read` credential with no node scope was
    /// denied too — `vm:read` does not cover `org:read` — so this is a second,
    /// independent 403 and needs its own assertion.
    @Test("An action-restricted credential with no node scope lists VMs")
    func actionOnlyKeyListsVMs() async throws {
        try await withApp { app in
            let f = try await fixture(app)

            try await app.test(.GET, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.actionOnly)
            } afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try names(res) == ["vm-a", "vm-b"])
            }
        }
    }

    /// The shape the two resource families disagreed about: a credential pointed
    /// somewhere the rows are not gets a *filtered page*, as `/api/volumes` has
    /// always given it, rather than a refusal.
    @Test("A credential scoped elsewhere is filtered, not forbidden")
    func keyScopedElsewhereIsFilteredNotForbidden() async throws {
        try await withApp { app in
            let f = try await fixture(app)

            try await app.test(.GET, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.scopedAllB)
            } afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try names(res) == ["vm-b"])
            }

            try await app.test(.GET, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.scopedEmpty)
            } afterResponse: { res async throws in
                #expect(res.status != .forbidden)
                #expect(res.status == .ok)
                #expect(try res.content.decode(NamedPage.self).total == 0)
            }
        }
    }

    // MARK: - What must not have moved

    /// The suspension is for the substituted question only. Object routes ask
    /// the real act on the real resource, so the ceiling still binds there.
    @Test("Object routes still enforce the credential's subtree")
    func objectRoutesAreUnchanged() async throws {
        try await withApp { app in
            let f = try await fixture(app)

            try await app.test(.GET, "/api/vms/\(try f.vmA.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.scopedAllA)
            } afterResponse: { res async in
                #expect(res.status == .ok)
            }

            try await app.test(.GET, "/api/vms/\(try f.vmB.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.scopedAllA)
            } afterResponse: { res async in
                #expect(res.status == .forbidden)
            }
        }
    }

    /// The load-bearing one: a probe suspends the *credential's ceiling*, never
    /// the bindings. A principal who is nobody in the organization is refused at
    /// the gate exactly as before — with an unrestricted key, so the refusal
    /// cannot be coming from a restriction.
    @Test("A non-member is still refused at the collection gate")
    func nonMemberIsStillForbidden() async throws {
        try await withApp { app in
            let f = try await fixture(app)
            let builder = TestDataBuilder(db: app.testPostgres)
            let outsider = try await builder.createUser(
                username: "outsider", email: "outsider@example.com")
            // Pointed at the organization but holding nothing in it, so the gate
            // is reached and answered rather than short-circuited by "no current
            // organization set".
            try await outsider.replacingCurrentOrganization(try f.org.requireID()).save(on: app.testPostgres)
            let key = try await outsider.generateAPIKey(on: app, name: "outsider")

            try await app.test(.GET, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: key)
            } afterResponse: { res async in
                #expect(res.status == .forbidden)
            }
        }
    }

    /// A create's gate is substituted the same way, and the real check is
    /// `create_resources` on the resolved project — which the restriction still
    /// binds. Asserted on the decision row rather than on a status, because a
    /// full create goes on to reach images, networks and the scheduler.
    @Test("Create still lands the real project-scoped check")
    func createStillLandsTheRealProjectCheck() async throws {
        try await withApp { app in
            let f = try await fixture(app)

            let imageID = try f.image.requireID().uuidString

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.scopedAllA)
                try req.content.encode([
                    "name": "outside-vm", "imageId": imageID,
                    "projectId": try f.projectB.requireID().uuidString,
                ])
            } afterResponse: { res async in
                #expect(res.status == .forbidden)
            }

            try await app.test(.POST, "/api/vms") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.scopedAllA)
                try req.content.encode([
                    "name": "inside-vm", "imageId": imageID,
                    "projectId": try f.projectA.requireID().uuidString,
                ])
            } afterResponse: { res async in
                #expect(res.status != .forbidden)
            }

            await app.iamDecisionRecorder.flush()
            let creates = try await app.decisionLogsPersistence.entries(
                matching: DecisionLogFilter(action: "vm:create"),
                limit: 500
            ).entries
            #expect(
                creates.contains { $0.nodeID == f.projectA.id && $0.decision == "allow" },
                "the create in the credential's own project was allowed on the project node")
            #expect(
                creates.contains { $0.nodeID == f.projectB.id && $0.decision != "allow" },
                "the create outside it was denied on the project node")
        }
    }

    // MARK: - The `?organization_id=` narrowing filter

    /// The same substituted question, one layer down: `organizationListFilter`
    /// narrows a list to one organization and every consumer then filters per
    /// row, so the parameter can only ever subtract. Without this a scoped key
    /// could list VMs but not say which organization it meant — the call shape
    /// the web client sends.
    @Test("A restricted credential can narrow its list by organization")
    func organizationIdNarrowingWorksForARestrictedKey() async throws {
        try await withApp { app in
            let f = try await fixture(app)

            try await app.test(.GET, "/api/vms?organization_id=\(try f.org.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.scopedAllA)
            } afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try names(res) == ["vm-a"])
            }

            // Membership is still decided, so naming an organization the
            // principal is nobody in is refused as it always was.
            try await app.test(.GET, "/api/vms?organization_id=\(try f.otherOrg.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: f.scopedAllA)
            } afterResponse: { res async in
                #expect(res.status == .forbidden)
            }
        }
    }
}
