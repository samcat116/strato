import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// IAM phase 4 (issue #481): shadow evaluation and the decision log. These
/// drive `IAMShadowEvaluator.shadow` directly (the decorator's background
/// spawn is a wrapper around it) against real trees, bindings, and the real
/// engine, then assert on the rows the burn-down will query.
@Suite("IAM Shadow Evaluator Tests", .serialized)
final class IAMShadowEvaluatorTests {

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            app.iamShadowConfig.enabled = true
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
    }

    private func buildTree(_ app: Application, prefix: String) async throws -> Tree {
        let builder = TestDataBuilder(db: app.db)
        let org = try await builder.createOrganization(name: "\(prefix) Org")
        let project = try await builder.createProject(
            name: "\(prefix) Project", description: "d", organization: org)
        let vm = try await builder.createVM(name: "\(prefix)-vm", project: project)
        let user = try await builder.createUser(
            username: "\(prefix)-user", email: "\(prefix)@example.com")
        try await builder.addUserToOrganization(user: user, organization: org, role: "member")
        return Tree(org: org, project: project, vm: vm, user: user)
    }

    private func check(
        _ tree: Tree, permission: String, resourceType: String, resourceID: String,
        spicedbAllowed: Bool, path: String = "/api/vms"
    ) -> IAMShadowCheck {
        IAMShadowCheck(
            subject: tree.user.id!.uuidString,
            permission: permission,
            resourceType: resourceType,
            resourceID: resourceID,
            spicedbAllowed: spicedbAllowed,
            path: path,
            method: "GET",
            requestID: "test-request"
        )
    }

    private func onlyEntry(_ app: Application) async throws -> IAMDecisionLog {
        let entries = try await IAMDecisionLog.query(on: app.db).all()
        #expect(entries.count == 1)
        return try #require(entries.first)
    }

    @Test("Agreeing verdicts record a matching decision with policy, tier, and version")
    func agreementRecorded() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "agree")
            try await RoleBindingService.grant(
                principalType: .user, principalID: tree.user.id!, role: .viewer,
                nodeType: .project, nodeID: tree.project.id!, createdBy: nil, on: app.db)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            await app.iamShadow.shadow(
                check(
                    tree, permission: "read", resourceType: "virtual_machine",
                    resourceID: tree.vm.id!.uuidString, spicedbAllowed: true))

            let entry = try await onlyEntry(app)
            #expect(entry.spicedbDecision == "allow")
            #expect(entry.cedarDecision == "allow")
            #expect(entry.decisionsMatch == true)
            #expect(entry.iamAction == "vm:read")
            #expect(entry.tier == "grant")
            #expect(entry.determiningPolicies == ["role-viewer"])
            #expect(entry.policyVersion == version)
            #expect(entry.organizationID == tree.org.id)
            #expect(entry.requestID == "test-request")
        }
    }

    @Test("A verdict mismatch is recorded with both verdicts and the default-deny tier")
    func mismatchRecorded() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "mismatch")
            // No binding: Cedar denies. SpiceDB (today's model) said allow —
            // exactly the org-member-visibility class of expected mismatch.
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            await app.iamShadow.shadow(
                check(
                    tree, permission: "view_project", resourceType: "project",
                    resourceID: tree.project.id!.uuidString, spicedbAllowed: true))

            let entry = try await onlyEntry(app)
            #expect(entry.spicedbDecision == "allow")
            #expect(entry.cedarDecision == "deny")
            #expect(entry.decisionsMatch == false)
            #expect(entry.iamAction == "project:read")
            #expect(entry.tier == "default-deny")
            #expect(entry.determiningPolicies.isEmpty)
        }
    }

    @Test("A guardrail denial names the ceiling in the decision row")
    func guardrailDenialNamed() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "ceiling")
            try await RoleBindingService.grant(
                principalType: .user, principalID: tree.user.id!, role: .admin,
                nodeType: .organization, nodeID: tree.org.id!, createdBy: nil, on: app.db)
            let guardrail = try await GuardrailStore.create(
                name: "no-vm-lifecycle", description: nil, effect: nil,
                node: IAMNode(type: .organization, id: tree.org.id!),
                actions: ["vm:*"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            await app.iamShadow.shadow(
                check(
                    tree, permission: "start", resourceType: "virtual_machine",
                    resourceID: tree.vm.id!.uuidString, spicedbAllowed: true))

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "deny")
            #expect(entry.decisionsMatch == false)
            #expect(entry.tier == "guardrail")
            #expect(entry.determiningPolicies == ["guardrail-\(guardrail.id!.uuidString.lowercased())"])
        }
    }

    @Test("An untranslatable check is recorded as a coverage gap, not dropped")
    func untranslatedRecorded() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "gap")
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            await app.iamShadow.shadow(
                check(
                    tree, permission: "frobnicate", resourceType: "virtual_machine",
                    resourceID: tree.vm.id!.uuidString, spicedbAllowed: false))

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "untranslated")
            #expect(entry.decisionsMatch == nil)
            #expect(entry.iamAction == nil)
            #expect(entry.spicedbDecision == "deny")
        }
    }

    @Test("With no compiled policy set the decision is recorded as skipped")
    func skippedWithoutCompiledSet() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "skip")
            // Deliberately no rebuild: the testing environment never
            // auto-starts the cache.
            await app.iamShadow.shadow(
                check(
                    tree, permission: "read", resourceType: "virtual_machine",
                    resourceID: tree.vm.id!.uuidString, spicedbAllowed: true))

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "skipped")
            #expect(entry.decisionsMatch == nil)
            #expect(entry.policyVersion == nil)
            // Translation still happened — the gap is the engine, not the map.
            #expect(entry.iamAction == "vm:read")
        }
    }

    @Test("The org-membership grant agrees with SpiceDB's view_organization")
    func membershipAgreement() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "member")
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            await app.iamShadow.shadow(
                check(
                    tree, permission: "view_organization", resourceType: "organization",
                    resourceID: tree.org.id!.uuidString, spicedbAllowed: true))

            let entry = try await onlyEntry(app)
            #expect(entry.cedarDecision == "allow")
            #expect(entry.decisionsMatch == true)
            #expect(entry.tier == "platform")
            #expect(entry.determiningPolicies == ["org-membership"])
        }
    }

    @Test("Request.spicedb wraps checks in the shadowing decorator only when enabled")
    func decoratorWiring() async throws {
        try await withApp { app in
            let request = Request(application: app, method: .GET, url: "/api/vms", on: app.eventLoopGroup.next())
            let shadowed = try request.spicedb
            #expect(shadowed is ShadowingSpiceDBService)

            app.iamShadowConfig.enabled = false
            let plain = try request.spicedb
            #expect(!(plain is ShadowingSpiceDBService))
        }
    }

    @Test("A checkPermission through the decorator lands a decision row")
    func decoratorEndToEnd() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "e2e")
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let request = Request(application: app, method: .GET, url: "/api/vms", on: app.eventLoopGroup.next())
            let allowed = try await request.spicedb.checkPermission(
                subject: tree.user.id!.uuidString,
                permission: "read",
                resource: "virtual_machine",
                resourceId: tree.vm.id!.uuidString)
            #expect(allowed)  // the testing mock allows by default

            // The shadow runs in a tracked background task; wait for the row.
            var entries: [IAMDecisionLog] = []
            for _ in 0..<100 {
                entries = try await IAMDecisionLog.query(on: app.db).all()
                if !entries.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(entries.count == 1)
            #expect(entries.first?.spicedbDecision == "allow")
            #expect(entries.first?.path == "/api/vms")
        }
    }

    @Test("The retention sweep prunes rows older than the window")
    func retentionSweep() async throws {
        try await withApp { app in
            let tree = try await buildTree(app, prefix: "sweep")
            await app.iamShadow.shadow(
                check(
                    tree, permission: "read", resourceType: "virtual_machine",
                    resourceID: tree.vm.id!.uuidString, spicedbAllowed: true))
            let entry = try await onlyEntry(app)

            // Age the row past the window, then sweep.
            let old = Date().addingTimeInterval(-Double(app.iamShadowConfig.retentionDays + 1) * 86_400)
            entry.createdAt = old
            try await entry.save(on: app.db)

            await app.iamShadow.sweepExpiredEntries()
            let remaining = try await IAMDecisionLog.query(on: app.db).count()
            #expect(remaining == 0)
        }
    }
}
