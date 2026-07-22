import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

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
    }

    private func buildTree(_ app: Application, prefix: String) async throws -> Tree {
        let builder = TestDataBuilder(db: app.db)
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
            legacyEquivalent: nil,
            context: IAMCheckContext(path: "/test", method: "GET", requestID: "test"),
            state: nil,
            app: app,
            db: app.db
        ).allowed
    }

    // MARK: - Service accounts as principals

    @Test("A service account's project binding grants its role's actions and nothing more")
    func serviceAccountBinding() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sa-grant")
            let account = ServiceAccount(name: "deployer", projectID: try tree.project.requireID())
            try await account.save(on: app.db)
            let accountID = try account.requireID()

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
                on: app.db
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
            let registration = WorkloadRegistration(
                spiffeID: "spiffe://acme.example/payments/batcher",
                kind: .workload,
                organizationID: try tree.org.requireID()
            )
            try await registration.save(on: app.db)
            let registrationID = try registration.requireID()

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
                on: app.db
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
            let account = ServiceAccount(name: "auditor", projectID: try tree.project.requireID())
            try await account.save(on: app.db)
            let accountID = try account.requireID()

            _ = try await authorize(
                app, principal: .serviceAccount(accountID), action: "vm:read",
                node: IAMNode(type: .virtualMachine, id: tree.vm.requireID()))

            var entries: [IAMDecisionLog] = []
            for _ in 0..<200 {
                entries = try await IAMDecisionLog.query(on: app.db).all()
                if !entries.isEmpty { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            let entry = try #require(entries.first)
            #expect(entry.subject == "service_account:\(accountID.uuidString)")
        }
    }

    @Test("The slice loader files machine-principal bindings into their own grants sets")
    func sliceLoaderGrantsSets() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sa-slice")
            let account = ServiceAccount(name: "slicer", projectID: try tree.project.requireID())
            try await account.save(on: app.db)
            let accountID = try account.requireID()

            try await RoleBindingService.grant(
                principalType: .serviceAccount,
                principalID: accountID,
                role: .viewer,
                nodeType: .project,
                nodeID: tree.project.requireID(),
                createdBy: nil,
                on: app.db
            )

            let slice = try await EntitySliceLoader.load(
                principal: .serviceAccount(accountID),
                node: IAMNode(type: .virtualMachine, id: try tree.vm.requireID()),
                on: app.db
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
            let account = ServiceAccount(name: "selfie", projectID: try tree.project.requireID())
            try await account.save(on: app.db)
            let accountID = try account.requireID()

            let slice = try await EntitySliceLoader.load(
                principal: .serviceAccount(accountID),
                node: IAMNode(type: .serviceAccount, id: accountID),
                on: app.db
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
            let account = ServiceAccount(name: "watcher", projectID: try tree.project.requireID())
            try await account.save(on: app.db)
            let accountID = try account.requireID()

            try await RoleBindingService.grant(
                principalType: .serviceAccount,
                principalID: accountID,
                role: .viewer,
                nodeType: .project,
                nodeID: tree.project.requireID(),
                createdBy: nil,
                on: app.db
            )

            let vmNode = IAMNode(type: .virtualMachine, id: try tree.vm.requireID())
            let result = try await WhoCanService.whoCan(action: "vm:read", node: vmNode, on: app.db)
            let entry = try #require(
                result.principals.first {
                    $0.principal == WhoCanPrincipalRef(type: .serviceAccount, id: accountID)
                })
            #expect(entry.source == .binding)
            #expect(entry.role == "viewer")

            #expect(
                try await WhoCanService.can(
                    principalType: .serviceAccount, principalID: accountID,
                    action: "vm:read", node: vmNode, on: app.db))
            #expect(
                try await WhoCanService.can(
                    principalType: .serviceAccount, principalID: accountID,
                    action: "vm:start", node: vmNode, on: app.db) == false)
        }
    }

    @Test("An external-principal ceiling always covers machine principals")
    func externalCeilingCoversMachinePrincipals() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sa-ceiling")
            let orgID = try tree.org.requireID()
            for principalType in [IAMPrincipalType.serviceAccount, .workload] {
                let covered = try await GuardrailStore.principalMatches(
                    .externalToOrganization,
                    principalType: principalType,
                    principalID: UUID(),
                    organizationID: orgID,
                    on: app.db
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
            let account = ServiceAccount(name: "resolved", projectID: try tree.project.requireID())
            try await account.save(on: app.db)
            let accountID = try account.requireID()

            try await WorkloadRegistration(
                spiffeID: "spiffe://strato.local/sa/resolved", kind: .serviceAccount,
                serviceAccountID: accountID
            ).save(on: app.db)
            let workloadRow = WorkloadRegistration(
                spiffeID: "spiffe://strato.local/customer/thing", kind: .workload,
                organizationID: try tree.org.requireID())
            try await workloadRow.save(on: app.db)
            try await WorkloadRegistry.registerAgent(
                identity: AgentIdentity(trustDomain: "strato.local", name: "node-a"), on: app.db)

            #expect(
                try await WorkloadRegistry.resolve(
                    spiffeID: "spiffe://strato.local/sa/resolved", on: app.db)
                    == .serviceAccount(id: accountID))
            #expect(
                try await WorkloadRegistry.resolve(
                    spiffeID: "spiffe://strato.local/customer/thing", on: app.db)
                    == .workload(id: try workloadRow.requireID()))
            #expect(
                try await WorkloadRegistry.resolve(
                    spiffeID: "spiffe://strato.local/agent/node-a", on: app.db)
                    == .agent(name: "node-a"))
            #expect(
                try await WorkloadRegistry.resolve(
                    spiffeID: "spiffe://strato.local/agent/unknown", on: app.db) == nil)

            // The `.serviceAccount` resolution is what the machine principal
            // rides: it must line up with the IAM principal.
            let resolved = try await WorkloadRegistry.resolve(
                spiffeID: "spiffe://strato.local/sa/resolved", on: app.db)
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
            try await WorkloadRegistry.registerAgent(identity: nodeB, on: app.db)
            try await WorkloadRegistry.requireAgentRegistration(identity: nodeB, on: app.db)
            let rows = try await WorkloadRegistration.query(on: app.db)
                .filter(\.$spiffeID == nodeB.key)
                .count()
            #expect(rows == 1)

            // …but the same URI cannot become a second principal.
            await #expect(throws: (any Error).self) {
                try await WorkloadRegistration(
                    spiffeID: nodeB.key, kind: .workload,
                    organizationID: try tree.org.requireID()
                ).save(on: app.db)
            }

            // An agent-shaped URI already registered to a *different* kind of
            // principal must fail agent authentication outright.
            let claimed = AgentIdentity(trustDomain: "strato.local", name: "node-c")
            try await WorkloadRegistration(
                spiffeID: claimed.key, kind: .workload,
                organizationID: try tree.org.requireID()
            ).save(on: app.db)
            await #expect(throws: (any Error).self) {
                try await WorkloadRegistry.requireAgentRegistration(identity: claimed, on: app.db)
            }

            // Deregistering removes the agent's row.
            try await WorkloadRegistry.deregisterAgent(identity: nodeB, on: app.db)
            #expect(try await WorkloadRegistry.resolve(spiffeID: nodeB.key, on: app.db) == nil)
        }
    }
}
