import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// The service-account and workload-registry APIs (issue #491).
@Suite("Service Account API Tests", .serialized)
final class ServiceAccountAPITests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private struct Env {
        let org: Organization
        let project: Project
        /// Org admin (holds an admin binding on the org).
        let adminToken: String
        /// A bare org member: no bindings, no project access.
        let memberToken: String
    }

    private func makeEnv(_ app: Application, prefix: String) async throws -> Env {
        let builder = TestDataBuilder(db: app.db)
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let project = try await builder.createProject(
            name: "\(prefix) Project", description: "d", organization: org)

        let admin = try await builder.createUser(
            username: "\(prefix)-admin", email: "\(prefix)-admin@example.com")
        try await builder.addUserToOrganization(user: admin, organization: org, role: "admin")

        let member = try await builder.createUser(
            username: "\(prefix)-member", email: "\(prefix)-member@example.com")
        try await builder.addUserToOrganization(user: member, organization: org, role: "member")

        return Env(
            org: org,
            project: project,
            adminToken: try await admin.generateAPIKey(on: app.db),
            memberToken: try await member.generateAPIKey(on: app.db)
        )
    }

    private struct CreateBody: Content {
        let name: String
        var description: String? = nil
    }

    private struct RoleBody: Content {
        let role: String
    }

    private struct SpiffeBody: Content {
        let spiffeId: String
    }

    private struct RegisterWorkloadBody: Content {
        let spiffeId: String
        let organizationId: UUID
        var displayName: String? = nil
    }

    // MARK: - CRUD

    @Test("Service account CRUD round-trips, with the creator binding written")
    func crud() async throws {
        try await withApp { app in
            let env = try await makeEnv(app, prefix: "crud")
            let projectID = try env.project.requireID()
            var accountID: UUID!

            try await app.test(.POST, "/api/projects/\(projectID)/service-accounts") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(CreateBody(name: "ci-deployer", description: "deploys"))
            } afterResponse: { res in
                #expect(res.status == .created)
                let account = try res.content.decode(
                    ServiceAccountController.ServiceAccountResponse.self)
                #expect(account.name == "ci-deployer")
                #expect(account.description == "deploys")
                #expect(account.projectId == projectID)
                #expect(account.projectRoles.isEmpty)
                accountID = account.id
            }

            // The creator's explicit admin binding on the account.
            let creatorBindings = try await RoleBindingService.activeBindings(
                nodeType: .serviceAccount, nodeID: accountID, on: app.db)
            #expect(creatorBindings.count == 1)
            #expect(creatorBindings.first?.principalType == IAMPrincipalType.user.rawValue)

            // A duplicate name in the same project conflicts.
            try await app.test(.POST, "/api/projects/\(projectID)/service-accounts") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(CreateBody(name: "ci-deployer"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            try await app.test(.GET, "/api/projects/\(projectID)/service-accounts") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let accounts = try res.content.decode(
                    [ServiceAccountController.ServiceAccountResponse].self)
                #expect(accounts.map(\.name) == ["ci-deployer"])
            }

            try await app.test(.PATCH, "/api/service-accounts/\(accountID!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(["description": "still deploys"])
            } afterResponse: { res in
                #expect(res.status == .ok)
                let account = try res.content.decode(
                    ServiceAccountController.ServiceAccountResponse.self)
                #expect(account.description == "still deploys")
            }

            try await app.test(.DELETE, "/api/service-accounts/\(accountID!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            #expect(try await ServiceAccount.find(accountID, on: app.db) == nil)
            // Both binding directions were cleaned up.
            let leftover = try await RoleBindingService.activeBindings(
                nodeType: .serviceAccount, nodeID: accountID, on: app.db)
            #expect(leftover.isEmpty)
        }
    }

    @Test("A bare member can neither create nor read service accounts")
    func memberDenied() async throws {
        try await withApp { app in
            let env = try await makeEnv(app, prefix: "denied")
            let projectID = try env.project.requireID()
            let account = ServiceAccount(name: "hidden", projectID: projectID)
            try await account.save(on: app.db)

            try await app.test(.POST, "/api/projects/\(projectID)/service-accounts") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.memberToken)
                try req.content.encode(CreateBody(name: "nope"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.GET, "/api/service-accounts/\(try account.requireID())") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.memberToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Project role

    @Test("Setting the project role writes a guardrail-checked binding the evaluator honors")
    func projectRole() async throws {
        try await withApp { app in
            let env = try await makeEnv(app, prefix: "role")
            let projectID = try env.project.requireID()
            let account = ServiceAccount(name: "roled", projectID: projectID)
            try await account.save(on: app.db)
            let accountID = try account.requireID()

            try await app.test(.PUT, "/api/service-accounts/\(accountID)/project-role") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(RoleBody(role: "editor"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let projectNode = IAMNode(type: .project, id: projectID)
            #expect(
                try await WhoCanService.can(
                    principalType: .serviceAccount, principalID: accountID,
                    action: "vm:create", node: projectNode, on: app.db))

            // Replacing narrows: editor → viewer leaves exactly one binding.
            try await app.test(.PUT, "/api/service-accounts/\(accountID)/project-role") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(RoleBody(role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            let bindings = try await RoleBindingService.activeBindings(
                principalType: .serviceAccount, principalID: accountID, on: app.db)
            #expect(bindings.count == 1)
            #expect(
                try await WhoCanService.can(
                    principalType: .serviceAccount, principalID: accountID,
                    action: "vm:create", node: projectNode, on: app.db) == false)

            // An unknown role is a 400, and a bare member may not grant.
            try await app.test(.PUT, "/api/service-accounts/\(accountID)/project-role") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(RoleBody(role: "owner"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            try await app.test(.PUT, "/api/service-accounts/\(accountID)/project-role") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.memberToken)
                try req.content.encode(RoleBody(role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            try await app.test(.DELETE, "/api/service-accounts/\(accountID)/project-role") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            #expect(
                try await RoleBindingService.activeBindings(
                    principalType: .serviceAccount, principalID: accountID, on: app.db
                ).isEmpty)
        }
    }

    // MARK: - Registrations

    @Test("SPIFFE registrations attach to the account and enforce registry uniqueness")
    func registrations() async throws {
        try await withApp { app in
            let env = try await makeEnv(app, prefix: "spiffe")
            let projectID = try env.project.requireID()
            let account = ServiceAccount(name: "registered", projectID: projectID)
            try await account.save(on: app.db)
            let accountID = try account.requireID()
            var registrationID: UUID!

            try await app.test(.POST, "/api/service-accounts/\(accountID)/registrations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(SpiffeBody(spiffeId: "spiffe://strato.local/sa/registered"))
            } afterResponse: { res in
                #expect(res.status == .created)
                let registration = try res.content.decode(
                    ServiceAccountController.WorkloadRegistrationResponse.self)
                #expect(registration.kind == "service_account")
                #expect(registration.serviceAccountId == accountID)
                registrationID = registration.id
            }

            // The registry resolves the identity to the account's principal.
            let resolved = try await WorkloadRegistry.resolve(
                spiffeID: "spiffe://strato.local/sa/registered", on: app.db)
            #expect(resolved == .serviceAccount(id: accountID))

            // Not a SPIFFE URI → 400; an already-registered URI → 409; the
            // reserved agent namespace → 400 (identity squatting on an
            // enrolled-but-unconnected node would deny it onboarding).
            try await app.test(.POST, "/api/service-accounts/\(accountID)/registrations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(SpiffeBody(spiffeId: "https://not-spiffe.example"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
            try await app.test(.POST, "/api/service-accounts/\(accountID)/registrations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(SpiffeBody(spiffeId: "spiffe://strato.local/agent/node-a"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // Attaching an identity is grant-shaped: a project *editor* can
            // update the account but may not register identities to it.
            let builder = TestDataBuilder(db: app.db)
            let editor = try await builder.createUser(
                username: "spiffe-editor", email: "spiffe-editor@example.com")
            try await builder.addUserToOrganization(user: editor, organization: env.org, role: "member")
            try await RoleBindingService.grant(
                principalType: .user, principalID: editor.id!, role: .editor,
                nodeType: .project, nodeID: projectID, createdBy: nil, on: app.db)
            let editorToken = try await editor.generateAPIKey(on: app.db)
            try await app.test(.PATCH, "/api/service-accounts/\(accountID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: editorToken)
                try req.content.encode(["description": "editors may edit"])
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            try await app.test(.POST, "/api/service-accounts/\(accountID)/registrations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: editorToken)
                try req.content.encode(SpiffeBody(spiffeId: "spiffe://strato.local/sa/editor-try"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
            try await app.test(.POST, "/api/service-accounts/\(accountID)/registrations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(SpiffeBody(spiffeId: "spiffe://strato.local/sa/registered"))
            } afterResponse: { res in
                #expect(res.status == .conflict)
            }

            try await app.test(.GET, "/api/service-accounts/\(accountID)/registrations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let registrations = try res.content.decode(
                    [ServiceAccountController.WorkloadRegistrationResponse].self)
                #expect(registrations.count == 1)
            }

            try await app.test(
                .DELETE, "/api/service-accounts/\(accountID)/registrations/\(registrationID!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            #expect(
                try await WorkloadRegistry.resolve(
                    spiffeID: "spiffe://strato.local/sa/registered", on: app.db) == nil)
        }
    }

    @Test("Deleting a project sweeps its service accounts' bindings on both sides")
    func projectDeleteSweepsServiceAccountBindings() async throws {
        try await withApp { app in
            let env = try await makeEnv(app, prefix: "prjdel")
            let projectID = try env.project.requireID()
            var accountID: UUID!

            // Created via the API so the creator binding exists, then granted
            // a project role so a held binding exists too.
            try await app.test(.POST, "/api/projects/\(projectID)/service-accounts") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(CreateBody(name: "doomed"))
            } afterResponse: { res in
                #expect(res.status == .created)
                accountID = try res.content.decode(
                    ServiceAccountController.ServiceAccountResponse.self
                ).id
            }
            try await app.test(.PUT, "/api/service-accounts/\(accountID!)/project-role") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(RoleBody(role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            try await app.test(.DELETE, "/api/projects/\(projectID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent || res.status == .ok)
            }

            // The account cascaded away with the project — and neither the
            // creator binding on its node nor the binding it held survived.
            #expect(try await ServiceAccount.find(accountID, on: app.db) == nil)
            let onNode = try await RoleBinding.query(on: app.db)
                .filter(\.$nodeType == IAMNodeType.serviceAccount.rawValue)
                .filter(\.$nodeID == accountID)
                .count()
            let held = try await RoleBinding.query(on: app.db)
                .filter(\.$principalType == IAMPrincipalType.serviceAccount.rawValue)
                .filter(\.$principalID == accountID)
                .count()
            #expect(onNode == 0)
            #expect(held == 0)
        }
    }

    // MARK: - Registry admin surface + workload grants

    @Test("The registry surface is system-admin only; workload grants ride the project gate")
    func workloadRegistryAndGrants() async throws {
        try await withApp { app in
            let env = try await makeEnv(app, prefix: "wlreg")
            let orgID = try env.org.requireID()
            let projectID = try env.project.requireID()

            let builder = TestDataBuilder(db: app.db)
            let sysAdmin = try await builder.createUser(
                username: "wlreg-root", email: "wlreg-root@example.com", isSystemAdmin: true)
            let sysAdminToken = try await sysAdmin.generateAPIKey(on: app.db)

            // Org admin is not enough for the registry surface.
            try await app.test(.GET, "/api/workload-registrations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }

            var registrationID: UUID!
            try await app.test(.POST, "/api/workload-registrations") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: sysAdminToken)
                try req.content.encode(
                    RegisterWorkloadBody(
                        spiffeId: "spiffe://acme.example/batch/uploader",
                        organizationId: orgID,
                        displayName: "Uploader"))
            } afterResponse: { res in
                #expect(res.status == .created)
                let registration = try res.content.decode(
                    ServiceAccountController.WorkloadRegistrationResponse.self)
                #expect(registration.kind == "workload")
                #expect(registration.organizationId == orgID)
                registrationID = registration.id
            }

            // Grant it viewer on the project (org admin holds iam:setPolicy).
            try await app.test(
                .PUT, "/api/projects/\(projectID)/workload-grants/\(registrationID!)"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: env.adminToken)
                try req.content.encode(RoleBody(role: "viewer"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            let projectNode = IAMNode(type: .project, id: projectID)
            #expect(
                try await WhoCanService.can(
                    principalType: .workload, principalID: registrationID,
                    action: "project:read", node: projectNode, on: app.db))

            // Deleting the registration deletes the principal and its grants.
            try await app.test(.DELETE, "/api/workload-registrations/\(registrationID!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: sysAdminToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }
            #expect(
                try await RoleBindingService.activeBindings(
                    principalType: .workload, principalID: registrationID, on: app.db
                ).isEmpty)
        }
    }
}
