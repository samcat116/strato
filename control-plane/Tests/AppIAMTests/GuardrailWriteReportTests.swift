import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// IAM phase 7 (issue #484): the write-time ceiling report.
///
/// These run against a real cvc5 — a stubbed solver would only test the
/// plumbing, and the thing worth testing is whether the symbolic question we
/// ask is the question we meant. Point `IAM_SYMCC_SOLVER_PATH` or `CVC5` at
/// the binary, or put `cvc5` on `PATH`; CI installs one.
@Suite("IAM Guardrail Write Report", .serialized, .enabled(if: solverPath() != nil))
final class GuardrailWriteReportTests {

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

    private func ceilings(
        _ app: Application, _ binding: ProposedBinding
    ) async throws -> [GuardrailWriteReport.GrantCeiling] {
        try await GuardrailWriteReport.ceilings(
            narrowing: binding, analyzer: app.guardrailAnalyzer, on: app.db, logger: app.logger)
    }

    // MARK: - The report finds what it should

    @Test("A grant a ceiling narrows is reported, naming the ceiling")
    func narrowingIsNamed() async throws {
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

            let found = try await ceilings(
                app,
                ProposedBinding(
                    principalType: .user, principalID: user.id!, role: .editor,
                    node: tree.projectNode))

            #expect(found.count == 1)
            let ceiling = try #require(found.first)
            // The ceiling is named by its path, so the reader knows where to
            // go to change it — that is the whole difference from an
            // eval-time denial.
            #expect(ceiling.guardrail.contains("no-vm-changes"))
            #expect(ceiling.guardrail.contains("Breach Org"))
            #expect(ceiling.counterexample != nil)
            // What it takes back, not "the grant": `vm:*` covers editor's vm
            // actions and leaves the rest of the role — volumes, images,
            // networks — standing.
            #expect(ceiling.ceilingedActions.contains("vm:create"))
            #expect(ceiling.ceilingedActions.allSatisfy { $0.hasPrefix("vm:") })
            #expect(!ceiling.ceilingedActions.contains("volume:create"))
        }
    }

    @Test("A one-action ceiling narrows a broad role by that one action")
    func narrowCeilingSubtractsOneAction() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Narrow")
            let user = try await builder.createUser(username: "narrow", email: "narrow@example.com")

            // The ceiling from STR-110: one reasonable action, org-wide. It
            // used to make `operator`, `editor` and `admin` ungrantable
            // everywhere beneath the org, because every one of them contains
            // `vm:stop`.
            _ = try await GuardrailStore.create(
                name: "no-vm-stop-org-wide",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["vm:stop"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            for role in [IAMRole.operator, .editor, .admin] {
                let found = try await ceilings(
                    app,
                    ProposedBinding(
                        principalType: .user, principalID: user.id!, role: role,
                        node: tree.projectNode))
                // Reported, not refused — and reported as the one action it
                // is. The other thirty-odd the role carries are untouched, at
                // write time exactly as at evaluation time.
                #expect(found.count == 1)
                #expect(found.first?.ceilingedActions == ["vm:stop"])
            }

            // `viewer` never carried `vm:stop`, so nothing to report there
            // either — the one role that survived the old behaviour.
            let viewer = try await ceilings(
                app,
                ProposedBinding(
                    principalType: .user, principalID: user.id!, role: .viewer,
                    node: tree.projectNode))
            #expect(viewer.isEmpty)
        }
    }

    @Test("A ceiling on an unrelated action set narrows nothing")
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

            let found = try await ceilings(
                app,
                ProposedBinding(
                    principalType: .user, principalID: user.id!, role: .viewer,
                    node: tree.projectNode))
            #expect(found.isEmpty)
        }
    }

    @Test("A ceiling naming another principal narrows nothing")
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
            // bob's group-mate and report a ceiling that does not touch her.
            let found = try await ceilings(
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

            let found = try await ceilings(
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

            // The project holds no production VM *today*. The ceiling still
            // narrows the grant, because it reaches every VM the project will
            // ever hold — the question only a symbolic check can answer.
            let found = try await ceilings(
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

            let found = try await ceilings(
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
            let found = try await ceilings(
                app,
                ProposedBinding(
                    principalType: .group, principalID: engineers.id!, role: .editor,
                    node: tree.projectNode))
            #expect(found.count == 1)
        }
    }

    // MARK: - Best effort

    @Test("Without a solver the write is accepted, with nothing to report")
    func unavailableSolverCostsOnlyTheExplanation() async throws {
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
            // The analyzer's failure reaches this overload; `report(for:req:)`
            // is what turns it into a written grant carrying
            // `analysisUnavailable` (pinned over HTTP in `ProjectMemberTests`).
            // Eval-time enforcement is exact and always in force, so a
            // deployment whose solver has gone missing loses the explanation,
            // not the ceiling — and not the ability to grant roles.
            await #expect(throws: GuardrailAnalyzerError.self) {
                _ = try await GuardrailWriteReport.ceilings(
                    narrowing: binding,
                    analyzer: UnavailableGuardrailAnalyzer(reason: "no solver in this test"),
                    on: app.db,
                    logger: app.logger
                )
            }
        }
    }

    @Test("An action the ceiling cannot reach is not reported as ceilinged")
    func unreachableActionsAreNotReported() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Reach")
            let user = try await builder.createUser(username: "reach", email: "reach@example.com")

            _ = try await GuardrailStore.create(
                name: "vms-and-images",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["vm:stop", "image:delete"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            // The solver's answers are stubbed *per resource type* so the
            // mapping under test is the only variable: `Image` and `Project`
            // come back provably disjoint, `VM` does not. The enumeration is
            // sorted, so `Image` is asked first — stopping at the first hit
            // would attribute VM's verdict to `image:delete`, which is the
            // over-broad claim this report exists not to make.
            let found = try await GuardrailWriteReport.ceilings(
                narrowing: ProposedBinding(
                    principalType: .user, principalID: user.id!, role: .editor,
                    node: tree.projectNode),
                analyzer: SelectiveGuardrailAnalyzer(nonDisjointResourceTypes: [CedarEntityType.vm.rawValue]),
                on: app.db,
                logger: app.logger
            )
            #expect(found.count == 1)
            #expect(found.first?.ceilingedActions == ["vm:stop"])
        }
    }

    @Test("With no ceiling in force the solver is never consulted")
    func noCeilingsMeansNoSolverCall() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "NoCeilings")
            let user = try await builder.createUser(username: "noceil", email: "noceil@example.com")

            // An analyzer that would fail if called: the report must not pay
            // for a solver process when nothing constrains the node.
            let found = try await GuardrailWriteReport.ceilings(
                narrowing: ProposedBinding(
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

            let shadowed = try await GuardrailWriteReport.shadowedBindings(
                by: guardrail, analyzer: app.guardrailAnalyzer, on: app.db, logger: app.logger)
            #expect(shadowed.count == 1)
            #expect(shadowed.first?.role == .editor)
            #expect(shadowed.first?.node == tree.projectNode)
        }
    }
}

/// An analyzer whose answers depend only on the request environment's resource
/// type, so a test can pin *which* types the report attributes to which
/// actions without depending on what cvc5 makes of a particular schema.
struct SelectiveGuardrailAnalyzer: GuardrailAnalyzer {
    let nonDisjointResourceTypes: Set<String>

    func disjoint(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        let overlaps = nonDisjointResourceTypes.contains(environment.resourceType.rawValue)
        return GuardrailAnalysis(
            holds: !overlaps,
            counterexample: overlaps
                ? "test analyzer: \(environment.action) on \(environment.resourceType.rawValue)" : nil)
    }

    func implies(
        schemaText: String,
        _ a: [CedarPolicySource],
        _ b: [CedarPolicySource],
        in environment: CedarRequestEnvironment
    ) async throws -> GuardrailAnalysis {
        GuardrailAnalysis(holds: true, counterexample: nil)
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
