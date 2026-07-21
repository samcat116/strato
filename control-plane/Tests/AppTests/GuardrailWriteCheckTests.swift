import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// IAM phase 7 (issue #484): the write-time ceiling check.
///
/// These run against a real cvc5 — a stubbed solver would only test the
/// plumbing, and the thing worth testing is whether the symbolic question we
/// ask is the question we meant. Point `IAM_SYMCC_SOLVER_PATH` or `CVC5` at
/// the binary, or put `cvc5` on `PATH`; CI installs one.
@Suite("IAM Guardrail Write Check", .serialized, .enabled(if: solverPath() != nil))
final class GuardrailWriteCheckTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            app.guardrailAnalyzer = SymCCGuardrailAnalyzer(solverPath: solverPath()!)
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
        var orgNode: IAMNode { IAMNode(type: .organization, id: org.id!) }
        var projectNode: IAMNode { IAMNode(type: .project, id: project.id!) }
    }

    private func buildTree(_ builder: TestDataBuilder, prefix: String) async throws -> Tree {
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let ou = try await builder.createOU(name: "\(prefix) OU", description: "d", organization: org)
        let project = try await builder.createProject(name: "\(prefix) Project", description: "d", ou: ou)
        return Tree(org: org, project: project)
    }

    private func violations(
        _ app: Application, _ binding: ProposedBinding
    ) async throws -> [GuardrailViolation] {
        try await GuardrailWriteCheck.violations(
            for: binding, analyzer: app.guardrailAnalyzer, on: app.db, logger: app.logger)
    }

    // MARK: - The check finds what it should

    @Test("A grant that reaches past a ceiling is refused, naming the ceiling")
    func breachIsNamed() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Breach")
            let user = try await builder.createUser(username: "breach", email: "breach@example.com")

            _ = try await GuardrailStore.create(
                name: "no-vm-changes",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["vm:*"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            let found = try await violations(
                app,
                ProposedBinding(
                    principalType: .user, principalID: user.id!, role: .editor,
                    node: tree.projectNode))

            #expect(found.count == 1)
            let violation = try #require(found.first)
            // The ceiling is named by its path, so the reader knows where to
            // go to change it — that is the whole difference from an
            // eval-time denial.
            #expect(violation.guardrail.contains("no-vm-changes"))
            #expect(violation.guardrail.contains("Breach Org"))
            #expect(violation.counterexample != nil)
            // Rendered as the design's 403 body.
            #expect(violation.status == .forbidden)
            #expect(violation.reason.contains("GuardrailViolation"))
        }
    }

    @Test("A ceiling on an unrelated action set does not block the grant")
    func nonOverlappingActionsAreClean() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Actions")
            let user = try await builder.createUser(username: "actions", email: "actions@example.com")

            // `viewer` carries no `iam:` action, so this ceiling cannot bite.
            _ = try await GuardrailStore.create(
                name: "no-policy-writes-for-them",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["iam:setPolicy"],
                principalMatch: .user(user.id!),
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            let found = try await violations(
                app,
                ProposedBinding(
                    principalType: .user, principalID: user.id!, role: .viewer,
                    node: tree.projectNode))
            #expect(found.isEmpty)
        }
    }

    @Test("A ceiling naming another principal does not block the grant")
    func otherPrincipalIsClean() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Principal")
            let alice = try await builder.createUser(username: "alice-p", email: "alice-p@example.com")
            let bob = try await builder.createUser(username: "bob-p", email: "bob-p@example.com")

            _ = try await GuardrailStore.create(
                name: "bob-may-not-edit",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["*"],
                principalMatch: .user(bob.id!),
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            // Resolved against the database, not symbolically: a solver told
            // nothing about who is who would have to assume alice might be
            // bob's group-mate and refuse a grant no ceiling touches.
            let found = try await violations(
                app,
                ProposedBinding(
                    principalType: .user, principalID: alice.id!, role: .admin,
                    node: tree.projectNode))
            #expect(found.isEmpty)
        }
    }

    @Test("A disabled ceiling is not in force")
    func disabledCeilingIsClean() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Disabled")
            let user = try await builder.createUser(username: "disabled", email: "disabled@example.com")

            _ = try await GuardrailStore.create(
                name: "switched-off",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                // Not `*`: an unconditional ceiling over every action would be
                // refused as self-locking before it could be disabled.
                actions: ["vm:*"],
                principalMatch: .any,
                resourceMatch: .any,
                enabled: false,
                createdBy: nil,
                on: app.db
            )

            let found = try await violations(
                app,
                ProposedBinding(
                    principalType: .user, principalID: user.id!, role: .admin,
                    node: tree.projectNode))
            #expect(found.isEmpty)
        }
    }

    @Test("An environment ceiling still bites a grant on the whole project")
    func environmentCeilingReachesProjectGrant() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Environment")
            let user = try await builder.createUser(username: "env", email: "env@example.com")

            _ = try await GuardrailStore.create(
                name: "no-prod-vm-changes",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["vm:*"],
                principalMatch: .any,
                resourceMatch: .environment("production"),
                createdBy: nil,
                on: app.db
            )

            // The project holds no production VM *today*. The grant is still a
            // breach, because it reaches every VM the project will ever hold —
            // which is the question only a symbolic check can answer.
            let found = try await violations(
                app,
                ProposedBinding(
                    principalType: .user, principalID: user.id!, role: .editor,
                    node: tree.projectNode))
            #expect(found.count == 1)
        }
    }

    // MARK: - Group grants

    @Test("A ceiling on a group catches a grant to that group")
    func groupCeilingCatchesGroupGrant() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Group")
            let group = Group(name: "contractors", description: "d", organizationID: tree.org.id!)
            try await group.save(on: app.db)

            _ = try await GuardrailStore.create(
                name: "no-prod-for-contractors",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["vm:*"],
                principalMatch: .group(group.id!),
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            let found = try await violations(
                app,
                ProposedBinding(
                    principalType: .group, principalID: group.id!, role: .editor,
                    node: tree.projectNode))
            #expect(found.count == 1)
        }
    }

    @Test("A ceiling on a group catches a grant to a group sharing a member")
    func groupCeilingCatchesOverlappingGroup() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Overlap")
            let contractors = Group(name: "overlap-contractors", description: "d", organizationID: tree.org.id!)
            try await contractors.save(on: app.db)
            let engineers = Group(name: "overlap-engineers", description: "d", organizationID: tree.org.id!)
            try await engineers.save(on: app.db)

            let shared = try await builder.createUser(username: "shared", email: "shared@example.com")
            try await UserGroup(userID: shared.id!, groupID: contractors.id!).save(on: app.db)
            try await UserGroup(userID: shared.id!, groupID: engineers.id!).save(on: app.db)

            _ = try await GuardrailStore.create(
                name: "contractors-no-vms",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["vm:*"],
                principalMatch: .group(contractors.id!),
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            // The grant is to engineers, but it reaches a contractor through
            // the shared member — which is exactly how the ceiling reaches
            // them at evaluation time too.
            let found = try await violations(
                app,
                ProposedBinding(
                    principalType: .group, principalID: engineers.id!, role: .editor,
                    node: tree.projectNode))
            #expect(found.count == 1)
        }
    }

    // MARK: - Fail closed

    @Test("Without a solver the write is refused, not accepted")
    func unavailableSolverFailsClosed() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "NoSolver")
            let user = try await builder.createUser(username: "nosolver", email: "nosolver@example.com")

            _ = try await GuardrailStore.create(
                name: "some-ceiling",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["vm:*"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            let binding = ProposedBinding(
                principalType: .user, principalID: user.id!, role: .editor,
                node: tree.projectNode)
            await #expect(throws: GuardrailCheckUnavailable.self) {
                _ = try await GuardrailWriteCheck.violations(
                    for: binding,
                    analyzer: UnavailableGuardrailAnalyzer(reason: "no solver in this test"),
                    on: app.db,
                    logger: app.logger
                )
            }
        }
    }

    @Test("With no ceiling in force the solver is never consulted")
    func noCeilingsMeansNoSolverCall() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "NoCeilings")
            let user = try await builder.createUser(username: "noceil", email: "noceil@example.com")

            // An analyzer that would fail if called: the check must not pay
            // for a solver process when nothing constrains the node.
            let found = try await GuardrailWriteCheck.violations(
                for: ProposedBinding(
                    principalType: .user, principalID: user.id!, role: .admin,
                    node: tree.projectNode),
                analyzer: UnavailableGuardrailAnalyzer(reason: "must not be consulted"),
                on: app.db,
                logger: app.logger
            )
            #expect(found.isEmpty)
        }
    }

    // MARK: - Guardrail writes

    @Test("A new ceiling reports the bindings it narrows rather than refusing")
    func guardrailWriteReportsShadowedBindings() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Shadow")
            let user = try await builder.createUser(username: "shadow", email: "shadow@example.com")

            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                role: .editor,
                nodeType: .project,
                nodeID: tree.project.id!,
                createdBy: nil,
                on: app.db
            )

            let guardrail = try await GuardrailStore.create(
                name: "freeze-vms",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["vm:*"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            let shadowed = try await GuardrailWriteCheck.shadowedBindings(
                by: guardrail, analyzer: app.guardrailAnalyzer, on: app.db, logger: app.logger)
            #expect(shadowed.count == 1)
            #expect(shadowed.first?.role == .editor)
            #expect(shadowed.first?.node == tree.projectNode)
        }
    }
}

/// The cvc5 the symbolic tests need, if this machine has one.
func solverPath() -> String? {
    let environment = ProcessInfo.processInfo.environment
    var candidates: [String] = []
    for key in ["IAM_SYMCC_SOLVER_PATH", "CVC5"] {
        if let configured = environment[key], !configured.isEmpty { candidates.append(configured) }
    }
    candidates += (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/cvc5" }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}
