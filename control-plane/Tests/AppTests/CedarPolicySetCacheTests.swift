import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// IAM phase 3 (issue #480): the per-replica compiled policy set and its
/// invalidation through the policy-set version watch (#479).
@Suite("Cedar Policy Set Cache Tests", .serialized)
final class CedarPolicySetCacheTests {

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

    @Test("A fresh database builds the static set at the current version")
    func freshBuild() async throws {
        try await withApp { app in
            let cache = CedarPolicySetCache(logger: app.logger)
            // Not 0: the boot-time registry sync bumps the version when it
            // first seeds `iam_roles`, and the build must reflect that.
            let expectedVersion = try await PolicySetVersionService.current(on: app.db)
            await cache.reconcile(version: expectedVersion, on: app.db)

            let built = await cache.current
            #expect(built != nil)
            #expect(built?.version == expectedVersion)
            #expect(built?.guardrailCount == 0)
            #expect(built?.policyText.contains("@id(\"platform-system-admin\")") == true)
            #expect(built?.schemaText.contains("entity Folder") == true)
            // The default engine is the real one: the artifact holds parsed,
            // schema-validated policies (issue #481).
            #expect(built?.artifact is SwiftCedarEngine.Compiled)

            // Idempotent: reconciling at the same version keeps the build
            // rather than redoing it — this runs on every periodic tick.
            await cache.reconcile(version: expectedVersion, on: app.db)
            let after = await cache.current
            #expect(after?.builtAt == built?.builtAt)
        }
    }

    @Test("Enabled guardrails compile into the set; disabled ones stay out")
    func guardrailsCompile() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Cache Org")
            let node = IAMNode(type: .organization, id: org.id!)

            let enabled = try await GuardrailStore.create(
                name: "no-vm-writes", description: nil, effect: nil, node: node,
                actions: ["vm:*"], principalMatch: .any, resourceMatch: .any,
                createdBy: nil, on: app.db)
            let disabled = try await GuardrailStore.create(
                name: "switched-off", description: nil, effect: nil, node: node,
                actions: ["volume:*"], principalMatch: .any, resourceMatch: .any,
                enabled: false, createdBy: nil, on: app.db)

            let cache = CedarPolicySetCache(logger: app.logger)
            await cache.rebuild(version: 1, on: app.db)

            let built = await cache.current
            #expect(built?.version == 1)
            #expect(built?.guardrailCount == 1)
            #expect(built?.policyText.contains("guardrail-\(enabled.id!.uuidString.lowercased())") == true)
            #expect(built?.policyText.contains("guardrail-\(disabled.id!.uuidString.lowercased())") == false)
            #expect(built?.policyText.contains("action in [Action::\"svc:vm\"]") == true)
        }
    }

    @Test("An external-principal guardrail resolves its attach node's org into the forbid")
    func externalGuardrailOrgResolution() async throws {
        try await withApp { app in
            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "External Org")
            let ou = try await builder.createOU(name: "External OU", description: "d", organization: org)
            let node = IAMNode(type: .organizationalUnit, id: ou.id!)

            _ = try await GuardrailStore.create(
                name: "no-external", description: nil, effect: nil, node: node,
                actions: [], principalMatch: .externalToOrganization, resourceMatch: .any,
                createdBy: nil, on: app.db)

            let cache = CedarPolicySetCache(logger: app.logger)
            await cache.rebuild(version: 1, on: app.db)

            let built = await cache.current
            #expect(built?.guardrailCount == 1)
            #expect(built?.skippedGuardrails.isEmpty == true)
            let expectedCondition =
                "!(principal.memberOfOrgs.contains(Organization::\"\(org.id!.uuidString.lowercased())\"))"
            #expect(built?.policyText.contains(expectedCondition) == true)
        }
    }

    @Test("A version change observed by the watch rebuilds the compiled set")
    func versionChangeRebuilds() async throws {
        try await withApp { app in
            // Wire the cache to the version watch the way boot does (the
            // .testing environment skips the auto-start on purpose). The
            // watch's initial refresh is what performs the boot-time build.
            await app.startCedarPolicySetCache()
            await app.policySetVersion.refresh(on: app.db)
            let initialVersion = try await PolicySetVersionService.current(on: app.db)
            let before = await app.cedarPolicySet.current
            #expect(before?.version == initialVersion)
            #expect(before?.guardrailCount == 0)

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Watch Org")
            let node = IAMNode(type: .organization, id: org.id!)
            let guardrail = try await PolicySetVersionService.withPolicySetChange(on: app.db) { transaction in
                let guardrail = try await GuardrailStore.create(
                    name: "watched", description: nil, effect: nil, node: node,
                    actions: ["sandbox:*"], principalMatch: .any, resourceMatch: .any,
                    createdBy: nil, on: transaction)
                try await PolicySetVersionService.bump(reason: "test guardrail", on: transaction)
                return guardrail
            }

            // The refresh is what the Valkey nudge and the periodic re-read
            // both funnel into.
            await app.policySetVersion.refresh(on: app.db)

            let after = await app.cedarPolicySet.current
            #expect(after?.version == initialVersion + 1)
            #expect(after?.guardrailCount == 1)
            #expect(after?.policyText.contains("guardrail-\(guardrail.id!.uuidString.lowercased())") == true)
        }
    }

    @Test("A failed rebuild keeps the previous set — stale beats broken")
    func failedRebuildKeepsPrevious() async throws {
        try await withApp { app in
            final class ToggleEngine: CedarEngine, @unchecked Sendable {
                struct Failure: Error {}
                struct Artifact: CedarCompiledPolicySet {
                    func authorize(
                        principal: CedarEntityUID, action: String, resource: CedarEntityUID,
                        context: CedarValue, entitiesJSON: String
                    ) throws -> CedarCheckDecision {
                        CedarCheckDecision(allowed: false, determiningPolicyIDs: [], evaluationErrors: [])
                    }
                }
                var failing = false
                func compile(schemaText: String, policies: [CedarPolicySource]) throws -> any CedarCompiledPolicySet {
                    if failing { throw Failure() }
                    return Artifact()
                }
            }

            let engine = ToggleEngine()
            let cache = CedarPolicySetCache(engine: engine, logger: app.logger)
            await cache.rebuild(version: 1, on: app.db)
            let first = await cache.current
            #expect(first?.version == 1)

            engine.failing = true
            await cache.rebuild(version: 2, on: app.db)
            let second = await cache.current
            // An empty set would deny everything (or drop the ceilings); the
            // stale one converges on the next nudge or periodic re-read.
            #expect(second?.version == 1)
            #expect(second?.builtAt == first?.builtAt)

            // The periodic reconcile is the retry path: the version cache
            // already advanced, so no further change event is coming — the
            // level-triggered tick has to keep re-driving the rebuild until
            // it lands.
            engine.failing = false
            await cache.reconcile(version: 2, on: app.db)
            let third = await cache.current
            #expect(third?.version == 2)
        }
    }
}
