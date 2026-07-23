import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// IAM #610: `who-can` and `WhoCanService.can` reflect ceilings exactly.
///
/// A grant is not the last word — a guardrail forbid or an authored forbid
/// policy can take it back. These drive real trees, grants, and the real engine
/// to prove the reverse lookup marks a neutralised grant `ceilinged`, names the
/// ceiling, and agrees with `can` — for matcher guardrails, hand-authored
/// guardrails, and authored forbid policies alike.
@Suite("IAM who-can Ceiling Tests", .serialized)
final class WhoCanCeilingTests {

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
        let user: User
        var orgNode: IAMNode { IAMNode(type: .organization, id: org.id!) }
        var projectNode: IAMNode { IAMNode(type: .project, id: project.id!) }
        var vmNode: IAMNode { IAMNode(type: .virtualMachine, id: vm.id!) }
    }

    /// Org → project → VM, with `user` an org admin (so it holds every VM
    /// action a ceiling might take back).
    private func buildTree(_ app: Application, prefix: String) async throws -> Tree {
        let builder = TestDataBuilder(db: app.db)
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let project = try await builder.createProject(
            name: "\(prefix) Project", description: "d", organization: org)
        let vm = try await builder.createVM(name: "\(prefix)-vm", project: project)
        let user = try await builder.createUser(
            username: "\(prefix)-user", email: "\(prefix)@example.com")
        try await builder.addUserToOrganization(user: user, organization: org, role: "member")
        try await RoleBindingService.grant(
            principalType: .user, principalID: user.id!, role: .admin,
            nodeType: .organization, nodeID: org.id!, createdBy: nil, on: app.db)
        return Tree(org: org, project: project, vm: vm, user: user)
    }

    /// Recompile the policy set against the current database — the store writes
    /// here do not bump the version, so drive the rebuild directly.
    private func rebuild(_ app: Application) async throws {
        let version = try await PolicySetVersionService.current(on: app.db)
        await app.cedarPolicySet.rebuild(version: version, on: app.db)
    }

    private func entry(_ result: WhoCanResult, for user: User) -> WhoCanEntry? {
        result.principals.first { $0.principal.type == .user && $0.principal.id == user.id }
    }

    @Test("who-can marks a grant a matcher guardrail forbids, and can() agrees")
    func matcherCeiling() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "MatcherCeil")
            _ = try await GuardrailStore.create(
                name: "no-vm-delete", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            try await rebuild(app)

            let deleteResult = try await WhoCanService.whoCan(
                action: "vm:delete", node: tree.vmNode, app: app, on: app.db)
            #expect(entry(deleteResult, for: tree.user)?.ceilinged == true)
            #expect(deleteResult.ceilings.contains { $0.kind == .guardrail })
            let canDelete = try await WhoCanService.can(
                principalType: .user, principalID: tree.user.id!, action: "vm:delete",
                node: tree.vmNode, app: app, on: app.db)
            #expect(!canDelete)

            // An action the ceiling does not cover is not ceilinged.
            let startResult = try await WhoCanService.whoCan(
                action: "vm:start", node: tree.vmNode, app: app, on: app.db)
            #expect(entry(startResult, for: tree.user)?.ceilinged == false)
            let canStart = try await WhoCanService.can(
                principalType: .user, principalID: tree.user.id!, action: "vm:start",
                node: tree.vmNode, app: app, on: app.db)
            #expect(canStart)
        }
    }

    @Test("who-can reflects a hand-authored guardrail forbid exactly")
    func authoredGuardrailCeiling() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "AuthoredCeil")
            let text =
                "forbid(principal, action in [Action::\"vm:delete\"], resource in \(tree.projectNode.cedarUID.cedarLiteral));"
            _ = try await GuardrailStore.createAuthored(
                name: "authored-no-delete", description: nil, node: tree.projectNode,
                cedarText: text, createdBy: nil, engine: app.cedarEngine, on: app.db)
            try await rebuild(app)

            let result = try await WhoCanService.whoCan(
                action: "vm:delete", node: tree.vmNode, app: app, on: app.db)
            #expect(entry(result, for: tree.user)?.ceilinged == true)
            #expect(result.ceilings.contains { $0.kind == .guardrail })
            let canDelete = try await WhoCanService.can(
                principalType: .user, principalID: tree.user.id!, action: "vm:delete",
                node: tree.vmNode, app: app, on: app.db)
            #expect(!canDelete)
        }
    }

    @Test("who-can reflects an authored forbid policy as a ceiling, not a caveat")
    func authoredForbidPolicyCeiling() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "ForbidPolicy")
            let id = UUID()
            let text =
                "forbid(principal, action in [Action::\"vm:delete\"], resource in \(tree.projectNode.cedarUID.cedarLiteral));"
            let prepared = try await PolicyStore.prepare(
                id: id, cedarText: text, ownerType: .project, ownerID: tree.project.id!,
                engine: app.cedarEngine, on: app.db)
            _ = try await PolicyStore.create(
                id: id, name: "forbid-delete", description: nil, ownerType: .project,
                ownerID: tree.project.id!, prepared: prepared, createdBy: nil, enabled: true,
                on: app.db)
            try await rebuild(app)

            let result = try await WhoCanService.whoCan(
                action: "vm:delete", node: tree.vmNode, app: app, on: app.db)
            #expect(entry(result, for: tree.user)?.ceilinged == true)
            #expect(result.ceilings.contains { $0.kind == .policy })
            // A forbid is reflected exactly, so it is not a best-effort caveat.
            #expect(result.authoredPolicyCaveat == false)
            let canDelete = try await WhoCanService.can(
                principalType: .user, principalID: tree.user.id!, action: "vm:delete",
                node: tree.vmNode, app: app, on: app.db)
            #expect(!canDelete)
        }
    }

    @Test("A guardrail with a null cedar_text (a pre-#610 row) still compiles and enforces")
    func nullCedarTextFallback() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "NullText")
            let guardrail = try await GuardrailStore.create(
                name: "no-vm-delete", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            // Simulate a row written before the migration: clear the stored
            // text so the cache must regenerate it from the matchers.
            guardrail.cedarText = nil
            try await guardrail.save(on: app.db)
            try await rebuild(app)

            let decision = try await IAMAuthorizer.authorize(
                userID: tree.user.id!, action: "vm:delete", node: tree.vmNode,
                legacyEquivalent: nil,
                context: IAMCheckContext(path: "/test", method: "GET", requestID: nil),
                state: nil, app: app, db: app.db)
            #expect(!decision.allowed)
            #expect(decision.tier == "guardrail")
        }
    }

    @Test("who-can and can agree with the authorizer across a matcher ceiling")
    func agreesWithAuthorizer() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "Agree")
            _ = try await GuardrailStore.create(
                name: "no-vm-delete", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            try await rebuild(app)

            for action in ["vm:delete", "vm:start", "vm:read"] {
                let can = try await WhoCanService.can(
                    principalType: .user, principalID: tree.user.id!, action: action,
                    node: tree.vmNode, app: app, on: app.db)
                let decision = try await IAMAuthorizer.authorize(
                    userID: tree.user.id!, action: action, node: tree.vmNode,
                    legacyEquivalent: nil,
                    context: IAMCheckContext(path: "/test", method: "GET", requestID: nil),
                    state: nil, app: app, db: app.db)
                #expect(can == decision.allowed, "disagreement on \(action)")
            }
        }
    }
}
