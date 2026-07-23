import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// IAM phase 2 (issue #479): the tier-2 guardrail store.
///
/// Two properties carry most of the weight here and both are easy to lose in a
/// refactor: guardrails are structurally forbid-only, and they **intersect**
/// down the tree rather than the nearest one winning.
@Suite("IAM Guardrail Tests", .serialized)
final class IAMGuardrailTests {

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

    /// Org → OU → project → VM, the chain a ceiling inherits down.
    private struct Tree {
        let org: Organization
        let ou: OrganizationalUnit
        let project: Project
        let vm: VM
        var orgNode: IAMNode { IAMNode(type: .organization, id: org.id!) }
        var ouNode: IAMNode { IAMNode(type: .organizationalUnit, id: ou.id!) }
        var projectNode: IAMNode { IAMNode(type: .project, id: project.id!) }
        var vmNode: IAMNode { IAMNode(type: .virtualMachine, id: vm.id!) }
    }

    private func buildTree(
        _ builder: TestDataBuilder, prefix: String, environment: String = "production"
    ) async throws -> Tree {
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let ou = try await builder.createOU(name: "\(prefix) OU", description: "d", organization: org)
        let project = try await builder.createProject(name: "\(prefix) Project", description: "d", ou: ou)
        let vm = try await builder.createVM(name: "\(prefix)-vm", project: project, environment: environment)
        return Tree(org: org, ou: ou, project: project, vm: vm)
    }

    // MARK: - Forbid-only

    @Test("A permit-shaped guardrail is rejected at write time")
    func permitRejected() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "Permit")

            await #expect(throws: GuardrailError.permitRejected("permit")) {
                _ = try await GuardrailStore.create(
                    name: "should-not-exist",
                    description: nil,
                    effect: "permit",
                    node: tree.orgNode,
                    actions: ["vm:delete"],
                    principalMatch: .any,
                    resourceMatch: .any,
                    createdBy: nil,
                    on: app.db
                )
            }

            let stored = try await Guardrail.query(on: app.db).count()
            #expect(stored == 0)
        }
    }

    @Test("An omitted effect means forbid, and the stored row says so")
    func omittedEffectIsForbid() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "Omitted")

            let guardrail = try await GuardrailStore.create(
                name: "no-vm-delete",
                description: nil,
                effect: nil,
                node: tree.orgNode,
                actions: ["vm:delete"],
                principalMatch: .any,
                resourceMatch: .any,
                createdBy: nil,
                on: app.db
            )

            #expect(guardrail.effect == GuardrailEffect.forbid.rawValue)
        }
    }

    @Test("Guardrails attach to containers, not to individual resources")
    func leafNodeRejected() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "Leaf")

            await #expect(throws: GuardrailError.unattachableNode("virtual_machine")) {
                _ = try await GuardrailStore.create(
                    name: "on-a-vm",
                    description: nil,
                    effect: nil,
                    node: tree.vmNode,
                    actions: ["vm:delete"],
                    principalMatch: .any,
                    resourceMatch: .any,
                    createdBy: nil,
                    on: app.db
                )
            }
        }
    }

    /// The lockout guard is about `iam:setPolicy` reachability, not about the
    /// literal `*`: `iam:*` and a bare `iam:setPolicy` bolt exactly the same
    /// door, and an unconditional ceiling over any of them can outlaw its own
    /// removal.
    @Test(
        "An unconditional ceiling over iam:setPolicy is refused, however it is spelled",
        arguments: [["*"], ["iam:*"], ["iam:setPolicy"], ["vm:delete", "iam:setPolicy"]])
    func selfLockingGuardrailRefused(actions: [String]) async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "SelfLock")

            await #expect(throws: GuardrailError.locksOutPolicyAdministration) {
                _ = try await GuardrailStore.create(
                    name: "lock-everyone-out",
                    description: nil,
                    effect: nil,
                    node: tree.orgNode,
                    actions: actions,
                    principalMatch: .any,
                    resourceMatch: .any,
                    createdBy: nil,
                    on: app.db
                )
            }
        }
    }

    @Test("A conditioned ceiling over iam:setPolicy is allowed — someone outside it can still undo it")
    func conditionedPolicyCeilingAllowed() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "CondLock")
            let contractors = try await builder.createGroup(
                name: "cl-contractors", description: "d", organization: tree.org)

            let principalScoped = try await GuardrailStore.create(
                name: "contractors-cannot-set-policy", description: nil, effect: nil, node: tree.orgNode,
                actions: ["iam:setPolicy"], principalMatch: .group(contractors.id!), resourceMatch: .any,
                createdBy: nil, on: app.db)
            let resourceScoped = try await GuardrailStore.create(
                name: "no-policy-writes-in-prod", description: nil, effect: nil, node: tree.orgNode,
                actions: ["iam:*"], principalMatch: .any, resourceMatch: .environment("production"),
                createdBy: nil, on: app.db)

            #expect(principalScoped.id != nil)
            #expect(resourceScoped.id != nil)
        }
    }

    @Test("An unconditional ceiling that misses iam:setPolicy is allowed")
    func unconditionalNonPolicyCeilingAllowed() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "NonPolicy")

            let guardrail = try await GuardrailStore.create(
                name: "nobody-deletes-vms", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:*"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)

            #expect(guardrail.actions == ["vm:*"])
        }
    }

    @Test("Two guardrails on one node cannot share a name")
    func duplicateNameRejected() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "Dup")

            _ = try await GuardrailStore.create(
                name: "no-deletes", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)

            await #expect(throws: GuardrailError.duplicateName("no-deletes")) {
                _ = try await GuardrailStore.create(
                    name: "no-deletes", description: nil, effect: nil, node: tree.orgNode,
                    actions: ["volume:delete"], principalMatch: .any, resourceMatch: .any,
                    createdBy: nil, on: app.db)
            }
        }
    }

    // MARK: - Action patterns

    @Test("An empty action list means every action")
    func emptyActionsMeansWildcard() throws {
        let empty = try GuardrailActions.canonicalize([])
        let withWildcard = try GuardrailActions.canonicalize(["vm:delete", "*"])
        #expect(empty == ["*"])
        #expect(withWildcard == ["*"])
    }

    @Test("Unknown actions and services are rejected, so a typo can't create a no-op ceiling")
    func unknownActionsRejected() throws {
        #expect(throws: GuardrailError.unknownAction("vm:selfDestruct")) {
            _ = try GuardrailActions.canonicalize(["vm:selfDestruct"])
        }
        #expect(throws: GuardrailError.unknownActionService("spaceship")) {
            _ = try GuardrailActions.canonicalize(["spaceship:*"])
        }
        let deduped = try GuardrailActions.canonicalize(["vm:*", "vm:*"])
        #expect(deduped == ["vm:*"])
    }

    @Test("A service wildcard covers actions in that service, including ones not shipped yet")
    func serviceWildcardMatches() {
        #expect(GuardrailActions.matches(["vm:*"], action: "vm:delete"))
        #expect(GuardrailActions.matches(["vm:*"], action: "vm:migrate"))
        #expect(!GuardrailActions.matches(["vm:*"], action: "volume:delete"))
        #expect(GuardrailActions.matches(["*"], action: "anything:at:all"))
        #expect(GuardrailActions.matches(["vm:delete"], action: "vm:delete"))
        #expect(!GuardrailActions.matches(["vm:delete"], action: "vm:deleteSnapshot"))
    }

    // MARK: - Inheritance and intersection

    @Test("Ceilings inherit downward and intersect — a nearer one never cancels a farther one")
    func ceilingsIntersect() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "Intersect")

            _ = try await GuardrailStore.create(
                name: "org-no-vm-delete", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            _ = try await GuardrailStore.create(
                name: "project-no-volume-delete", description: nil, effect: nil, node: tree.projectNode,
                actions: ["volume:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)

            let effective = try await GuardrailStore.effective(at: tree.vmNode, on: app.db)

            #expect(effective.map(\.name) == ["org-no-vm-delete", "project-no-volume-delete"])
        }
    }

    @Test("A disabled guardrail stops applying but stays on the record")
    func disabledGuardrailExcluded() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "Disabled")

            let guardrail = try await GuardrailStore.create(
                name: "paused-ceiling", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            _ = try await GuardrailStore.update(
                guardrail, description: nil, actions: nil, principalMatch: nil, resourceMatch: nil,
                cedarText: nil, enabled: false, engine: app.cedarEngine, on: app.db)

            let effective = try await GuardrailStore.effective(at: tree.vmNode, on: app.db)
            #expect(effective.isEmpty)

            let attached = try await GuardrailStore.attached(to: tree.orgNode, on: app.db)
            #expect(attached.map(\.name) == ["paused-ceiling"])
        }
    }

    @Test("A guardrail on a sibling subtree does not reach this one")
    func siblingSubtreeUnaffected() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Sibling")
            let otherProject = try await builder.createProject(
                name: "Sibling Other Project", description: "d", ou: tree.ou)
            let otherVM = try await builder.createVM(name: "sibling-other-vm", project: otherProject)

            _ = try await GuardrailStore.create(
                name: "only-here", description: nil, effect: nil, node: tree.projectNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)

            let here = try await GuardrailStore.effective(at: tree.vmNode, on: app.db)
            let there = try await GuardrailStore.effective(
                at: IAMNode(type: .virtualMachine, id: otherVM.id!), on: app.db)

            #expect(here.map(\.name) == ["only-here"])
            #expect(there.isEmpty)
        }
    }

    // MARK: - Evaluation: principal side

    @Test("A group ceiling forbids the group's members, and nobody else")
    func groupCeilingCoversMembers() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "GroupCeiling")

            let contractors = try await builder.createGroup(
                name: "contractors", description: "d", organization: tree.org)
            let contractor = try await builder.createUser(
                username: "gc-contractor", email: "gc-contractor@example.com")
            let staff = try await builder.createUser(username: "gc-staff", email: "gc-staff@example.com")
            try await UserGroup(userID: contractor.id!, groupID: contractors.id!).save(on: app.db)

            _ = try await GuardrailStore.create(
                name: "no-prod-for-contractors", description: nil, effect: nil, node: tree.ouNode,
                actions: ["vm:delete"], principalMatch: .group(contractors.id!), resourceMatch: .any,
                createdBy: nil, on: app.db)

            let againstContractor = try await GuardrailStore.forbidding(
                action: "vm:delete", principalType: .user, principalID: contractor.id!,
                node: tree.vmNode, on: app.db)
            let againstStaff = try await GuardrailStore.forbidding(
                action: "vm:delete", principalType: .user, principalID: staff.id!,
                node: tree.vmNode, on: app.db)
            let againstGroupItself = try await GuardrailStore.forbidding(
                action: "vm:delete", principalType: .group, principalID: contractors.id!,
                node: tree.vmNode, on: app.db)

            #expect(againstContractor.map(\.name) == ["no-prod-for-contractors"])
            #expect(againstStaff.isEmpty)
            #expect(againstGroupItself.map(\.name) == ["no-prod-for-contractors"])
        }
    }

    @Test("A ceiling on an action the guardrail doesn't name leaves it alone")
    func unnamedActionUnaffected() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Unnamed")
            let user = try await builder.createUser(username: "un-user", email: "un-user@example.com")

            _ = try await GuardrailStore.create(
                name: "no-deletes", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)

            let onDelete = try await GuardrailStore.forbidding(
                action: "vm:delete", principalType: .user, principalID: user.id!,
                node: tree.vmNode, on: app.db)
            let onStart = try await GuardrailStore.forbidding(
                action: "vm:start", principalType: .user, principalID: user.id!,
                node: tree.vmNode, on: app.db)

            #expect(onDelete.count == 1)
            #expect(onStart.isEmpty)
        }
    }

    @Test("The cross-org ceiling matches principals outside the resource's org")
    func externalPrincipalCeiling() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "External")

            let insider = try await builder.createUser(username: "ex-insider", email: "ex-insider@example.com")
            try await builder.addUserToOrganization(user: insider, organization: tree.org)
            let outsider = try await builder.createUser(
                username: "ex-outsider", email: "ex-outsider@example.com")

            _ = try await GuardrailStore.create(
                name: "no-external-access", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:*"], principalMatch: .externalToOrganization, resourceMatch: .any,
                createdBy: nil, on: app.db)

            let againstOutsider = try await GuardrailStore.forbidding(
                action: "vm:read", principalType: .user, principalID: outsider.id!,
                node: tree.vmNode, on: app.db)
            let againstInsider = try await GuardrailStore.forbidding(
                action: "vm:read", principalType: .user, principalID: insider.id!,
                node: tree.vmNode, on: app.db)

            #expect(againstOutsider.map(\.name) == ["no-external-access"])
            #expect(againstInsider.isEmpty)
        }
    }

    @Test("A group from another org is external; a group from this one is not")
    func externalGroupCeiling() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "ExternalGroup")
            let otherOrg = try await builder.createOrganization(name: "ExternalGroup Other Org")

            let localGroup = try await builder.createGroup(
                name: "local", description: "d", organization: tree.org)
            let foreignGroup = try await builder.createGroup(
                name: "foreign", description: "d", organization: otherOrg)

            _ = try await GuardrailStore.create(
                name: "no-external-groups", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:*"], principalMatch: .externalToOrganization, resourceMatch: .any,
                createdBy: nil, on: app.db)

            let againstForeign = try await GuardrailStore.forbidding(
                action: "vm:read", principalType: .group, principalID: foreignGroup.id!,
                node: tree.vmNode, on: app.db)
            let againstLocal = try await GuardrailStore.forbidding(
                action: "vm:read", principalType: .group, principalID: localGroup.id!,
                node: tree.vmNode, on: app.db)

            #expect(againstForeign.map(\.name) == ["no-external-groups"])
            #expect(againstLocal.isEmpty)
        }
    }

    // MARK: - Evaluation: resource side

    @Test("An environment ceiling matches only resources in that environment")
    func environmentCeiling() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "Env", environment: "production")
            let stagingVM = try await builder.createVM(
                name: "env-staging-vm", project: tree.project, environment: "staging")
            let user = try await builder.createUser(username: "env-user", email: "env-user@example.com")

            _ = try await GuardrailStore.create(
                name: "no-prod-writes", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .environment("production"),
                createdBy: nil, on: app.db)

            let againstProd = try await GuardrailStore.forbidding(
                action: "vm:delete", principalType: .user, principalID: user.id!,
                node: tree.vmNode, on: app.db)
            let againstStaging = try await GuardrailStore.forbidding(
                action: "vm:delete", principalType: .user, principalID: user.id!,
                node: IAMNode(type: .virtualMachine, id: stagingVM.id!), on: app.db)

            #expect(againstProd.map(\.name) == ["no-prod-writes"])
            #expect(againstStaging.isEmpty)
        }
    }

    @Test("An environment ceiling reaches a snapshot of a production sandbox")
    func environmentCeilingCoversSandboxSnapshots() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "SnapEnv")
            let user = try await builder.createUser(
                username: "snapenv-user", email: "snapenv-user@example.com")
            let sandbox = try await builder.createSandbox(
                name: "snapenv-sandbox", project: tree.project, environment: "production")

            // A snapshot of a production sandbox is itself a production
            // resource: the ceiling has to follow the data.
            let snapshot = SandboxSnapshot(
                name: "snapenv-snapshot",
                sandboxID: sandbox.id!,
                projectID: tree.project.id!,
                environment: "production",
                agentId: nil,
                createdByID: user.id!
            )
            try await snapshot.save(on: app.db)

            _ = try await GuardrailStore.create(
                name: "no-prod-sandbox-writes", description: nil, effect: nil, node: tree.orgNode,
                actions: ["sandbox:*"], principalMatch: .any, resourceMatch: .environment("production"),
                createdBy: nil, on: app.db)

            let violations = try await GuardrailStore.forbidding(
                action: "sandbox:restore", principalType: .user, principalID: user.id!,
                node: IAMNode(type: .sandboxSnapshot, id: snapshot.id!), on: app.db)

            #expect(violations.map(\.name) == ["no-prod-sandbox-writes"])
        }
    }

    @Test("An environment ceiling does not reach a resource type that has no environment")
    func environmentCeilingSkipsContainers() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "EnvContainer")
            let user = try await builder.createUser(
                username: "envc-user", email: "envc-user@example.com")

            _ = try await GuardrailStore.create(
                name: "prod-only", description: nil, effect: nil, node: tree.orgNode,
                actions: ["project:update"], principalMatch: .any,
                resourceMatch: .environment("production"), createdBy: nil, on: app.db)

            let againstProject = try await GuardrailStore.forbidding(
                action: "project:update", principalType: .user, principalID: user.id!,
                node: tree.projectNode, on: app.db)

            #expect(againstProject.isEmpty)
        }
    }

    @Test("Every ceiling in the way is reported, not just the first")
    func allViolationsReported() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "AllViolations")
            let user = try await builder.createUser(username: "av-user", email: "av-user@example.com")

            _ = try await GuardrailStore.create(
                name: "a-org-ceiling", description: nil, effect: nil, node: tree.orgNode,
                actions: ["vm:*"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            _ = try await GuardrailStore.create(
                name: "b-project-ceiling", description: nil, effect: nil, node: tree.projectNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .environment("production"),
                createdBy: nil, on: app.db)

            let violations = try await GuardrailStore.forbidding(
                action: "vm:delete", principalType: .user, principalID: user.id!,
                node: tree.vmNode, on: app.db)

            #expect(violations.map(\.name) == ["a-org-ceiling", "b-project-ceiling"])
        }
    }

    // MARK: - Authored guardrails (#610)

    /// A forbid scoped to `node`, forbidding `vm:delete` — the authored
    /// equivalent of a `{actions: ["vm:delete"]}` matcher guardrail.
    private func authoredForbid(on node: IAMNode) -> String {
        "forbid(principal, action in [Action::\"vm:delete\"], resource in \(node.cedarUID.cedarLiteral));"
    }

    @Test("A matcher-built guardrail stores the Cedar forbid it assembles to")
    func matcherStoresCedarText() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "MatcherText")
            let guardrail = try await GuardrailStore.create(
                name: "no-vm-delete", description: nil, effect: nil, node: tree.projectNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            #expect(guardrail.authored == false)
            let stored = guardrail.cedarText
            #expect(stored?.contains("forbid") == true)
            #expect(stored?.contains(tree.projectNode.cedarUID.cedarLiteral) == true)
        }
    }

    @Test("A hand-authored forbid is stored, flagged authored, and compiles")
    func authoredForbidStored() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "Authored")
            let text = authoredForbid(on: tree.projectNode)
            let guardrail = try await GuardrailStore.createAuthored(
                name: "authored-no-delete", description: nil, node: tree.projectNode,
                cedarText: text, createdBy: nil, engine: app.cedarEngine, on: app.db)
            #expect(guardrail.authored == true)
            #expect(guardrail.cedarText == text)
            #expect(guardrail.effect == GuardrailEffect.forbid.rawValue)
        }
    }

    @Test("An authored permit is rejected — guardrails are forbid-only")
    func authoredMustForbid() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "AuthoredPermit")
            let text =
                "permit(principal, action in [Action::\"vm:delete\"], resource in \(tree.projectNode.cedarUID.cedarLiteral));"
            await #expect(throws: GuardrailError.authoredMustForbid("permit")) {
                _ = try await GuardrailStore.createAuthored(
                    name: "nope", description: nil, node: tree.projectNode,
                    cedarText: text, createdBy: nil, engine: app.cedarEngine, on: app.db)
            }
            let count = try await Guardrail.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test("An authored forbid scoped outside the attach node is refused")
    func authoredContainment() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "AuthoredScope")
            // Attached to the project, but scoped to the org above it.
            let text = authoredForbid(on: tree.orgNode)
            await #expect(throws: GuardrailError.self) {
                _ = try await GuardrailStore.createAuthored(
                    name: "out-of-scope", description: nil, node: tree.projectNode,
                    cedarText: text, createdBy: nil, engine: app.cedarEngine, on: app.db)
            }
        }
    }

    @Test("An authored forbid with an unscoped resource is refused")
    func authoredUnscoped() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "AuthoredUnscoped")
            let text = "forbid(principal, action in [Action::\"vm:delete\"], resource);"
            await #expect(throws: GuardrailError.authoredUnscopedResource) {
                _ = try await GuardrailStore.createAuthored(
                    name: "unscoped", description: nil, node: tree.projectNode,
                    cedarText: text, createdBy: nil, engine: app.cedarEngine, on: app.db)
            }
        }
    }

    @Test("An unconditional authored forbid over iam:setPolicy is refused as self-locking")
    func authoredSelfLock() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "AuthoredLock")
            // Unconstrained principal, no conditions, unconstrained action ⇒ reaches iam:setPolicy.
            let text = "forbid(principal, action, resource in \(tree.orgNode.cedarUID.cedarLiteral));"
            await #expect(throws: GuardrailError.locksOutPolicyAdministration) {
                _ = try await GuardrailStore.createAuthored(
                    name: "locked", description: nil, node: tree.orgNode,
                    cedarText: text, createdBy: nil, engine: app.cedarEngine, on: app.db)
            }
        }
    }

    @Test("Editing a matcher guardrail with cedarText is a mode mismatch")
    func updateModeMismatch() async throws {
        try await withApp { app in
            let tree = try await buildTree(TestDataBuilder(db: app.db), prefix: "ModeMismatch")
            let guardrail = try await GuardrailStore.create(
                name: "matcher", description: nil, effect: nil, node: tree.projectNode,
                actions: ["vm:delete"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            await #expect(throws: GuardrailError.self) {
                _ = try await GuardrailStore.update(
                    guardrail, description: nil, actions: nil, principalMatch: nil, resourceMatch: nil,
                    cedarText: self.authoredForbid(on: tree.projectNode), enabled: nil,
                    engine: app.cedarEngine, on: app.db)
            }
        }
    }

    @Test("The structured evaluation skips authored rows")
    func forbiddingSkipsAuthored() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "SkipAuthored")
            let user = try await builder.createUser(username: "sa-user", email: "sa-user@example.com")
            _ = try await GuardrailStore.createAuthored(
                name: "authored-ceiling", description: nil, node: tree.projectNode,
                cedarText: authoredForbid(on: tree.projectNode), createdBy: nil,
                engine: app.cedarEngine, on: app.db)
            // `forbidding` reads structured matchers, which an authored row does
            // not carry — it must not match on the placeholder `.any`.
            let forbidding = try await GuardrailStore.forbidding(
                action: "vm:delete", principalType: .user, principalID: user.id!,
                node: tree.vmNode, on: app.db)
            #expect(forbidding.isEmpty)
        }
    }

    @Test("An authored guardrail is skipped by the write-time check; the solver is never consulted")
    func authoredSkippedInWriteCheck() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let tree = try await buildTree(builder, prefix: "AuthoredWriteCheck")
            let user = try await builder.createUser(username: "awc-user", email: "awc-user@example.com")
            _ = try await GuardrailStore.createAuthored(
                name: "authored-ceiling", description: nil, node: tree.projectNode,
                cedarText: authoredForbid(on: tree.projectNode), createdBy: nil,
                engine: app.cedarEngine, on: app.db)
            let binding = ProposedBinding(
                principalType: .user, principalID: user.id!, role: .editor, node: tree.projectNode)
            // An unavailable analyzer would `503` if consulted; a matcher ceiling
            // here would. That it stays empty proves authored rows are skipped.
            let violations = try await GuardrailWriteCheck.violations(
                for: binding, analyzer: UnavailableGuardrailAnalyzer(reason: "test"),
                on: app.db, logger: app.logger)
            #expect(violations.isEmpty)
        }
    }
}
