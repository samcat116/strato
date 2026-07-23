import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// The forward check *is* the enforcement decision.
///
/// `WhoCanService.can` answers through `IAMDecisionEngine` — the same
/// evaluator, over the same compiled policy set, that `IAMAuthorizer` enforces
/// with — so agreement is by construction. These tests pin the places where
/// the old hand-walked bindings model used to *disagree* with enforcement
/// (authored permits, conditioned bindings, platform permits for machine
/// principals), plus the two seams that deliberately sit outside the
/// evaluator: principals that could never reach it, and group principals.
@Suite("IAM who-can Evaluator Agreement Tests", .serialized)
final class WhoCanEvaluatorAgreementTests {

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

    private struct Tree {
        let org: Organization
        let project: Project
        let vm: VM
        var orgNode: IAMNode { IAMNode(type: .organization, id: org.id!) }
        var projectNode: IAMNode { IAMNode(type: .project, id: project.id!) }
        var vmNode: IAMNode { IAMNode(type: .virtualMachine, id: vm.id!) }
    }

    private func buildTree(_ app: Application, prefix: String) async throws -> Tree {
        let builder = TestDataBuilder(db: app.db)
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let project = try await builder.createProject(
            name: "\(prefix) Project", description: "d", organization: org)
        let vm = try await builder.createVM(name: "\(prefix)-vm", project: project)
        return Tree(org: org, project: project, vm: vm)
    }

    /// Recompile the policy set against the current database (store writes in
    /// these tests do not bump the version, so drive the rebuild directly).
    private func rebuild(_ app: Application) async throws {
        let version = try await PolicySetVersionService.current(on: app.db)
        await app.cedarPolicySet.rebuild(version: version, on: app.db)
    }

    private func authorizerAllows(
        _ app: Application, principal: IAMPrincipal, action: String, node: IAMNode
    ) async throws -> Bool {
        let decision = try await IAMAuthorizer.authorize(
            principal: principal, action: action, node: node,
            legacyEquivalent: nil,
            context: IAMCheckContext(path: "/test", method: "GET", requestID: nil),
            state: nil, app: app, db: app.db)
        return decision.allowed
    }

    @Test("An authored permit reaches can() — a grant no binding row carries")
    func authoredPermitAgreement() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "PermitAgree")
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "permit-agree", email: "permit-agree@example.com")

            let id = UUID()
            let text = """
                permit (
                    principal == User::"\(user.id!.uuidString.lowercased())",
                    action == Action::"vm:delete",
                    resource in Project::"\(tree.project.id!.uuidString.lowercased())"
                );
                """
            let prepared = try await PolicyStore.prepare(
                id: id, cedarText: text, ownerType: .project, ownerID: tree.project.id!,
                engine: app.cedarEngine, on: app.db)
            _ = try await PolicyStore.create(
                id: id, name: "permit-delete", description: nil, ownerType: .project,
                ownerID: tree.project.id!, prepared: prepared, createdBy: nil, enabled: true,
                on: app.db)
            try await rebuild(app)

            let can = try await WhoCanService.can(
                principalType: .user, principalID: user.id!, action: "vm:delete",
                node: tree.vmNode, app: app, on: app.db)
            #expect(can)
            let enforced = try await authorizerAllows(
                app, principal: .user(user.id!), action: "vm:delete", node: tree.vmNode)
            #expect(enforced)

            // The reverse lookup still cannot *enumerate* the permit's
            // principals — the caveat is how it stays honest about that.
            let result = try await WhoCanService.whoCan(
                action: "vm:delete", node: tree.vmNode, app: app, on: app.db)
            #expect(result.authoredPolicyCaveat)
            #expect(!result.principals.contains { $0.principal.id == user.id })
        }
    }

    @Test("A conditioned binding is no unconditional grant: can() denies, like enforcement")
    func conditionedBindingAgreement() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "CondAgree")
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "cond-agree", email: "cond-agree@example.com")
            try await RoleBinding(
                principalType: .user, principalID: user.id!, role: .editor,
                nodeType: .project, nodeID: tree.project.id!, condition: "mfa"
            ).save(on: app.db)

            let can = try await WhoCanService.can(
                principalType: .user, principalID: user.id!, action: "vm:start",
                node: tree.vmNode, app: app, on: app.db)
            let enforced = try await authorizerAllows(
                app, principal: .user(user.id!), action: "vm:start", node: tree.vmNode)
            #expect(!enforced, "the slice skips conditioned bindings (under-grant)")
            #expect(can == enforced)

            // The reverse lookup still *enumerates* the binding — it is a real
            // row an admin may want to revoke — and does not mark it ceilinged
            // (nothing forbids it; the grant just is not unconditional).
            let result = try await WhoCanService.whoCan(
                action: "vm:start", node: tree.vmNode, app: app, on: app.db)
            let entry = result.principals.first { $0.principal.id == user.id }
            #expect(entry != nil)
            #expect(entry?.ceilinged == false)
        }
    }

    @Test("A machine principal reaches a platform permit: open network read")
    func machinePrincipalOpenNetworkAgreement() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "MachineNet")
            let account = ServiceAccount(name: "net-reader", projectID: tree.project.id!)
            try await account.save(on: app.db)
            let network = LogicalNetwork(name: "agree-global", subnet: "10.95.0.0/24", gateway: "10.95.0.1")
            try await network.save(on: app.db)
            let node = IAMNode(type: .network, id: network.id!)

            // No binding anywhere — the platform-open-network-read permit is
            // principal-unscoped, and the old bindings model missed that.
            let can = try await WhoCanService.can(
                principalType: .serviceAccount, principalID: account.id!, action: "network:read",
                node: node, app: app, on: app.db)
            let enforced = try await authorizerAllows(
                app, principal: .serviceAccount(account.id!), action: "network:read", node: node)
            #expect(enforced)
            #expect(can == enforced)
        }
    }

    @Test("A principal that cannot reach the evaluator answers false")
    func unreachablePrincipalsAnswerFalse() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let network = LogicalNetwork(name: "nobody-net", subnet: "10.96.0.0/24", gateway: "10.96.0.1")
            try await network.save(on: app.db)
            let node = IAMNode(type: .network, id: network.id!)

            // Unknown ids: the open-network permit covers *any* principal, but
            // nobody can authenticate as a row that does not exist.
            for type in [IAMPrincipalType.user, .serviceAccount, .workload] {
                let can = try await WhoCanService.can(
                    principalType: type, principalID: UUID(), action: "network:read",
                    node: node, app: app, on: app.db)
                #expect(!can, "unknown \(type.rawValue) must answer false")
            }

            // A disabled user cannot act on anything it still holds.
            let disabled = try await builder.createUser(
                username: "agree-disabled", email: "agree-disabled@example.com")
            disabled.disabledAt = Date()
            try await disabled.save(on: app.db)
            let can = try await WhoCanService.can(
                principalType: .user, principalID: disabled.id!, action: "network:read",
                node: node, app: app, on: app.db)
            #expect(!can)
        }
    }

    @Test("An action the schema does not apply to the node answers false instead of erroring")
    func inapplicableActionAnswersFalse() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "Inapplicable")
            let builder = TestDataBuilder(db: app.db)
            let member = try await builder.createUser(
                username: "inapp-member", email: "inapp-member@example.com")
            try await builder.addUserToOrganization(user: member, organization: tree.org)

            // org:read applies to organizations, not VMs. No real request can
            // pose this pair, so the query surfaces answer the fail-closed
            // "no" — before the applicability gate this was a
            // request-validation 500 out of the who-can ceiling pass.
            let can = try await WhoCanService.can(
                principalType: .user, principalID: member.id!, action: "org:read",
                node: tree.vmNode, app: app, on: app.db)
            #expect(!can)

            // The reverse lookup still enumerates membership along the chain
            // without erroring, and marks nothing ceilinged (nothing forbids).
            let result = try await WhoCanService.whoCan(
                action: "org:read", node: tree.vmNode, app: app, on: app.db)
            let entry = result.principals.first {
                $0.principal.id == member.id && $0.source == .orgMembership
            }
            #expect(entry != nil)
            #expect(entry?.ceilinged == false)
        }
    }

    @Test("A group principal answers from its bindings, minus matcher guardrails")
    func groupPrincipalPath() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "GroupPath")
            let builder = TestDataBuilder(db: app.db)
            let group = try await builder.createGroup(
                name: "group-path", description: "d", organization: tree.org)
            try await RoleBindingService.grant(
                principalType: .group, principalID: group.id!, role: .editor,
                nodeType: .organization, nodeID: tree.org.id!, createdBy: nil, on: app.db)

            let canStart = try await WhoCanService.can(
                principalType: .group, principalID: group.id!, action: "vm:start",
                node: tree.vmNode, app: app, on: app.db)
            #expect(canStart)
            let canSetPolicy = try await WhoCanService.can(
                principalType: .group, principalID: group.id!, action: "iam:setPolicy",
                node: tree.vmNode, app: app, on: app.db)
            #expect(!canSetPolicy, "editor does not grant iam:setPolicy")

            _ = try await GuardrailStore.create(
                name: "group-no-start", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:start"], principalMatch: .group(group.id!), resourceMatch: .any,
                createdBy: nil, on: app.db)
            try await rebuild(app)

            let ceilinged = try await WhoCanService.can(
                principalType: .group, principalID: group.id!, action: "vm:start",
                node: tree.vmNode, app: app, on: app.db)
            #expect(!ceilinged)
        }
    }
}
