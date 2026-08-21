import ControlPlanePostgres
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Workload principals (issue #491): service accounts and registered
/// workloads as first-class Cedar principals. These drive the typed
/// `IAMAuthorizer.authorize(principal:...)` entry point against the real
/// engine — so they also prove the extended schema (three principal types,
/// four grants sets per role, `is`-guarded permits) survives strict
/// validation — plus the workload registry and the who-can surfaces.
@Suite("Workload Principal Tests", .serialized)
final class WorkloadPrincipalTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
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
    }

    private func buildTree(_ app: Application, prefix: String) async throws -> Tree {
        let builder = TestDataBuilder(db: app.testPostgres)
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let project = try await builder.createProject(
            name: "\(prefix) Project", description: "d", organization: org)
        let vm = try await builder.createVM(name: "\(prefix)-vm", project: project)
        return Tree(org: org, project: project, vm: vm)
    }

    private func authorize(
        _ app: Application, principal: IAMPrincipal, action: String, node: IAMNode
    ) async throws -> Bool {
        try await IAMAuthorizer.authorize(
            principal: principal,
            action: action,
            node: node,
            context: IAMCheckContext(path: "/test", method: "GET", requestID: "test"),
            state: .detached,
            app: app,
            db: app.testPostgres
        ).allowed
    }

    // MARK: - Service accounts as principals

    @Test("A service account's project binding grants its role's actions and nothing more")
    func serviceAccountBinding() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sa-grant")
            let account = try await LegacyServiceAccountStore.insert(
                ServiceAccountWrite(name: "deployer", projectID: try tree.project.requireID()),
                on: app.testPostgres)
            let accountID = account.id

            // Before any binding: nothing, including the membership-derived
            // actions users get from bare org membership — a machine
            // principal is a member of nothing.
            #expect(
                try await authorize(
                    app, principal: .serviceAccount(accountID), action: "vm:read",
                    node: IAMNode(type: .virtualMachine, id: tree.vm.requireID())) == false)
            #expect(
                try await authorize(
                    app, principal: .serviceAccount(accountID), action: "org:read",
                    node: IAMNode(type: .organization, id: tree.org.requireID())) == false)

            try await RoleBindingService.grant(
                principalType: .serviceAccount,
                principalID: accountID,
                role: .editor,
                nodeType: .project,
                nodeID: tree.project.requireID(),
                createdBy: nil,
                on: app.testPostgres
            )

            // Editor covers read and start (operator ⊂ editor)…
            #expect(
                try await authorize(
                    app, principal: .serviceAccount(accountID), action: "vm:read",
                    node: IAMNode(type: .virtualMachine, id: tree.vm.requireID())))
            #expect(
                try await authorize(
                    app, principal: .serviceAccount(accountID), action: "vm:start",
                    node: IAMNode(type: .virtualMachine, id: tree.vm.requireID())))
            // …but not the admin tier.
            #expect(
                try await authorize(
                    app, principal: .serviceAccount(accountID), action: "iam:setPolicy",
                    node: IAMNode(type: .project, id: tree.project.requireID())) == false)
        }
    }

    @Test("A registered workload's binding grants through the same path")
    func workloadBinding() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "wl-grant")
            let registration = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: "spiffe://acme.example/payments/batcher",
                    kind: WorkloadRegistrationKind.workload.rawValue,
                    organizationID: try tree.org.requireID()),
                on: app.testPostgres)
            let registrationID = registration.id

            let vmNode = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())
            #expect(
                try await authorize(
                    app, principal: .workload(registrationID), action: "vm:read", node: vmNode) == false)

            try await RoleBindingService.grant(
                principalType: .workload,
                principalID: registrationID,
                role: .viewer,
                nodeType: .project,
                nodeID: tree.project.requireID(),
                createdBy: nil,
                on: app.testPostgres
            )

            #expect(
                try await authorize(
                    app, principal: .workload(registrationID), action: "vm:read", node: vmNode))
            // Viewer stops at reads.
            #expect(
                try await authorize(
                    app, principal: .workload(registrationID), action: "vm:start", node: vmNode) == false)
        }
    }

    @Test("Machine-principal decisions record a type-prefixed subject")
    func machinePrincipalSubject() async throws {
        try await withApp { app in
            app.iamDecisionLogConfig.recordDecisions = true
            let tree = try await buildTree(app, prefix: "sa-subject")
            let account = try await LegacyServiceAccountStore.insert(
                ServiceAccountWrite(name: "auditor", projectID: try tree.project.requireID()),
                on: app.testPostgres)
            let accountID = account.id

            _ = try await authorize(
                app, principal: .serviceAccount(accountID), action: "vm:read",
                node: IAMNode(type: .virtualMachine, id: tree.vm.requireID()))

            await app.iamDecisionRecorder.flush()
            let entries = try await app.decisionLogsPersistence.entries(limit: 500).entries
            let entry = try #require(entries.first)
            #expect(entry.subject == "service_account:\(accountID.uuidString)")
        }
    }

    @Test("The slice loader files machine-principal bindings into their own grants sets")
    func sliceLoaderGrantsSets() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sa-slice")
            let account = try await LegacyServiceAccountStore.insert(
                ServiceAccountWrite(name: "slicer", projectID: try tree.project.requireID()),
                on: app.testPostgres)
            let accountID = account.id

            try await RoleBindingService.grant(
                principalType: .serviceAccount,
                principalID: accountID,
                role: .viewer,
                nodeType: .project,
                nodeID: tree.project.requireID(),
                createdBy: nil,
                on: app.testPostgres
            )

            let slice = try await EntitySliceLoader.load(
                principal: .serviceAccount(accountID),
                node: IAMNode(type: .virtualMachine, id: try tree.vm.requireID()),
                on: app.testPostgres
            )
            #expect(slice.principal == CedarEntityUID(type: .serviceAccount, id: accountID))
            #expect(slice.grants.serviceAccounts(for: IAMRole.viewer.seededID).contains(accountID))
            #expect(slice.grants.users(for: IAMRole.viewer.seededID).isEmpty)
            #expect(slice.chainComplete)
        }
    }

    @Test("A service account checked against its own node loads a single entity for it")
    func principalIsResource() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sa-self")
            let account = try await LegacyServiceAccountStore.insert(
                ServiceAccountWrite(name: "selfie", projectID: try tree.project.requireID()),
                on: app.testPostgres)
            let accountID = account.id

            let slice = try await EntitySliceLoader.load(
                principal: .serviceAccount(accountID),
                node: IAMNode(type: .serviceAccount, id: accountID),
                on: app.testPostgres
            )
            let uid = CedarEntityUID(type: .serviceAccount, id: accountID)
            #expect(slice.entities.filter { $0.uid == uid }.count == 1)
            #expect(slice.chainComplete)

            // And the engine evaluates it: a user holding admin on the
            // account can be asked about impersonation, and the account
            // itself holds nothing on itself.
            #expect(
                try await authorize(
                    app, principal: .serviceAccount(accountID), action: "serviceaccount:impersonate",
                    node: IAMNode(type: .serviceAccount, id: accountID)) == false)
        }
    }

    @Test("who-can reports machine-principal bindings; the forward check agrees")
    func whoCanMachinePrincipals() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sa-whocan")
            let account = try await LegacyServiceAccountStore.insert(
                ServiceAccountWrite(name: "watcher", projectID: try tree.project.requireID()),
                on: app.testPostgres)
            let accountID = account.id

            try await RoleBindingService.grant(
                principalType: .serviceAccount,
                principalID: accountID,
                role: .viewer,
                nodeType: .project,
                nodeID: tree.project.requireID(),
                createdBy: nil,
                on: app.testPostgres
            )

            let vmNode = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())
            let result = try await WhoCanService.whoCan(action: "vm:read", node: vmNode, app: app, on: app.testPostgres)
            let entry = try #require(
                result.principals.first {
                    $0.principal == WhoCanPrincipalRef(type: .serviceAccount, id: accountID)
                })
            #expect(entry.source == .binding)
            #expect(entry.role == IAMRole.viewer.seededID)

            #expect(
                try await WhoCanService.can(
                    principalType: .serviceAccount, principalID: accountID,
                    action: "vm:read", node: vmNode, app: app, on: app.testPostgres))
            #expect(
                try await WhoCanService.can(
                    principalType: .serviceAccount, principalID: accountID,
                    action: "vm:start", node: vmNode, app: app, on: app.testPostgres) == false)
        }
    }

    @Test("A populated user grant set never leaks to an ungranted machine principal")
    func principalTypeConfusionWithPopulatedGrants() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let tree = try await buildTree(app, prefix: "sa-confusion")
            let user = try await builder.createUser(
                username: "sa-confusion-user", email: "sa-confusion@example.com")
            try await builder.addUserToOrganization(user: user, organization: tree.org, role: "member")
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: user.id!,
                role: .viewer,
                nodeType: .project,
                nodeID: tree.project.requireID(),
                createdBy: nil,
                on: app.testPostgres
            )
            let account = try await LegacyServiceAccountStore.insert(
                ServiceAccountWrite(name: "bystander", projectID: try tree.project.requireID()),
                on: app.testPostgres)

            // The viewer role's Users set is now non-empty on this chain; the
            // `is User` guard is what keeps the service account out of it.
            let vmNode = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())
            #expect(try await authorize(app, principal: .user(user.id!), action: "vm:read", node: vmNode))
            #expect(
                try await authorize(
                    app, principal: .serviceAccount(account.id), action: "vm:read", node: vmNode)
                    == false)
        }
    }

    @Test("The compiled external-org forbid binds machine principals and spares org members")
    func externalCeilingEnforcedByEngine() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.testPostgres)
            let tree = try await buildTree(app, prefix: "sa-forbid")
            let projectID = try tree.project.requireID()

            // Both principals hold editor on the project…
            let member = try await builder.createUser(
                username: "sa-forbid-user", email: "sa-forbid@example.com")
            try await builder.addUserToOrganization(user: member, organization: tree.org, role: "member")
            let account = try await LegacyServiceAccountStore.insert(
                ServiceAccountWrite(name: "forbidden", projectID: projectID), on: app.testPostgres)
            for principal in [IAMPrincipal.user(member.id!), .serviceAccount(account.id)] {
                try await RoleBindingService.grant(
                    principalType: principal.type,
                    principalID: principal.id,
                    role: .editor,
                    nodeType: .project,
                    nodeID: projectID,
                    createdBy: nil,
                    on: app.testPostgres
                )
            }

            // …and an external-principal ceiling lands on the org. Compile it
            // into the live policy set the way boot does.
            _ = try await GuardrailStore.create(
                name: "no-external", description: nil, effect: nil,
                node: IAMNode(type: .organization, id: tree.org.requireID()),
                actions: [], principalMatch: .externalToOrganization, resourceMatch: .any,
                createdBy: nil, on: app.testPostgres)
            _ = try await PolicySetVersionService.bump(reason: "test guardrail", on: app.testPostgres)
            await app.startCedarPolicySetCache()
            await app.policySetVersion.refresh()

            // The org member's grant still works; the machine principal —
            // external by definition — is stopped by the compiled forbid, not
            // just the Swift-side predicate.
            let vmNode = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())
            #expect(try await authorize(app, principal: .user(member.id!), action: "vm:read", node: vmNode))
            #expect(
                try await authorize(
                    app, principal: .serviceAccount(account.id), action: "vm:read", node: vmNode)
                    == false)
        }
    }

    @Test("An external-principal ceiling always covers machine principals")
    func externalCeilingCoversMachinePrincipals() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sa-ceiling")
            let orgID = try tree.org.requireID()
            for principalType in [IAMPrincipalType.serviceAccount, .workload] {
                let covered = try await GuardrailRendering.covers(
                    .externalToOrganization,
                    principalType: principalType,
                    principalID: UUID(),
                    organizationID: orgID,
                    on: app.testPostgres
                )
                #expect(covered, "\(principalType) should be external to every org")
            }
        }
    }

    // MARK: - The registry

    @Test("The registry resolves each kind to its principal")
    func registryResolution() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "registry")
            let account = try await LegacyServiceAccountStore.insert(
                ServiceAccountWrite(name: "resolved", projectID: try tree.project.requireID()),
                on: app.testPostgres)
            let accountID = account.id

            _ = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: "spiffe://strato.local/sa/resolved",
                    kind: WorkloadRegistrationKind.serviceAccount.rawValue,
                    serviceAccountID: accountID),
                on: app.testPostgres)
            let workloadRow = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: "spiffe://strato.local/customer/thing",
                    kind: WorkloadRegistrationKind.workload.rawValue,
                    organizationID: try tree.org.requireID()),
                on: app.testPostgres)
            try await WorkloadRegistry.registerAgent(
                identity: AgentIdentity(trustDomain: "strato.local", name: "node-a"), on: app.testPostgres)

            #expect(
                try await WorkloadRegistry.resolve(
                    spiffeID: "spiffe://strato.local/sa/resolved", on: app.testPostgres)
                    == .serviceAccount(id: accountID))
            #expect(
                try await WorkloadRegistry.resolve(
                    spiffeID: "spiffe://strato.local/customer/thing", on: app.testPostgres)
                    == .workload(id: workloadRow.id))
            #expect(
                try await WorkloadRegistry.resolve(
                    spiffeID: "spiffe://strato.local/agent/node-a", on: app.testPostgres)
                    == .agent(name: "node-a"))
            #expect(
                try await WorkloadRegistry.resolve(
                    spiffeID: "spiffe://strato.local/agent/unknown", on: app.testPostgres) == nil)

            // The `.serviceAccount` resolution is what the machine principal
            // rides: it must line up with the IAM principal.
            let resolved = try await WorkloadRegistry.resolve(
                spiffeID: "spiffe://strato.local/sa/resolved", on: app.testPostgres)
            #expect(resolved?.principal == IAMPrincipal.serviceAccount(accountID))
        }
    }

    @Test("One SPIFFE ID registers to exactly one principal")
    func registryUniqueness() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "registry-unique")
            let nodeB = AgentIdentity(trustDomain: "strato.local", name: "node-b")

            // Registering (and re-requiring) the same agent identity is
            // idempotent…
            try await WorkloadRegistry.registerAgent(identity: nodeB, on: app.testPostgres)
            try await WorkloadRegistry.requireAgentRegistration(identity: nodeB, on: app.testPostgres)
            #expect(
                try await LegacyWorkloadRegistrationStore.registration(
                    spiffeID: nodeB.key, on: app.testPostgres) != nil)

            // …but the same URI cannot become a second principal.
            await #expect(throws: (any Error).self) {
                _ = try await LegacyWorkloadRegistrationStore.insert(
                    WorkloadRegistrationWrite(
                        spiffeID: nodeB.key,
                        kind: WorkloadRegistrationKind.workload.rawValue,
                        organizationID: try tree.org.requireID()),
                    on: app.testPostgres)
            }

            // An agent-shaped URI already registered to a *different* kind of
            // principal must fail agent authentication outright.
            let claimed = AgentIdentity(trustDomain: "strato.local", name: "node-c")
            _ = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: claimed.key,
                    kind: WorkloadRegistrationKind.workload.rawValue,
                    organizationID: try tree.org.requireID()),
                on: app.testPostgres)
            await #expect(throws: (any Error).self) {
                try await WorkloadRegistry.requireAgentRegistration(identity: claimed, on: app.testPostgres)
            }

            // Deregistering removes the agent's row.
            try await WorkloadRegistry.deregisterAgent(identity: nodeB, on: app.testPostgres)
            #expect(try await WorkloadRegistry.resolve(spiffeID: nodeB.key, on: app.testPostgres) == nil)
        }
    }

    @Test("Corrupted registry rows resolve to no principal, never to a guess")
    func corruptedRegistryRows() async throws {
        try await withApp { app in
            // An agent row whose stored name diverges from its URI (only
            // reachable by row surgery — registration derives one from the
            // other) must fail agent authentication rather than answer with
            // either name.
            let nodeZ = AgentIdentity(trustDomain: "strato.local", name: "node-z")
            _ = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: nodeZ.key,
                    kind: WorkloadRegistrationKind.agent.rawValue,
                    agentName: "someone-else"),
                on: app.testPostgres)
            await #expect(throws: (any Error).self) {
                try await WorkloadRegistry.requireAgentRegistration(identity: nodeZ, on: app.testPostgres)
            }

            // A kind row missing its reference resolves to nil.
            _ = try await LegacyWorkloadRegistrationStore.insert(
                WorkloadRegistrationWrite(
                    spiffeID: "spiffe://strato.local/sa/dangling",
                    kind: WorkloadRegistrationKind.serviceAccount.rawValue),
                on: app.testPostgres)
            #expect(
                try await WorkloadRegistry.resolve(
                    spiffeID: "spiffe://strato.local/sa/dangling", on: app.testPostgres) == nil)
        }
    }

    @Test("Platform-owned SPIFFE namespaces cannot be registered through the API surface")
    func reservedNamespaceRejected() async throws {
        let reserved = [
            (
                "spiffe://strato.local/agent/node-a",
                "The /agent/ SPIFFE namespace is reserved for hypervisor agents, which register automatically when they first connect"
            ),
            (
                "spiffe://org-0123456789abcdef.strato.local/vm/00000000-0000-0000-0000-000000000001",
                "The /vm/ SPIFFE namespace is reserved for guest virtual machines, which register automatically when they are created"
            ),
            (
                "spiffe://org-0123456789abcdef.strato.local/sandbox/00000000-0000-0000-0000-000000000002",
                "The /sandbox/ SPIFFE namespace is reserved for guest sandboxes, which register automatically when they are created"
            ),
        ]

        for (spiffeID, expectedReason) in reserved {
            do {
                _ = try WorkloadRegistry.validateRegistrable(spiffeID: spiffeID)
                Issue.record("Expected \(spiffeID) to be rejected")
            } catch let abort as Abort {
                #expect(abort.status == .badRequest)
                #expect(abort.reason == expectedReason)
            }
        }

        #expect(throws: (any Error).self) {
            try WorkloadRegistry.validateRegistrable(spiffeID: "not-a-spiffe-uri")
        }

        for registrable in [
            "spiffe://strato.local/sa/fine",
            "spiffe://strato.local/vmware/fine",
            "spiffe://strato.local/sandboxed/fine",
        ] {
            #expect(try WorkloadRegistry.validateRegistrable(spiffeID: registrable) == registrable)
        }
    }
}
