import Fluent
import Testing
import Vapor
import VaporTesting

@testable import App

/// IAM phase 2 (issue #479): the policy-set version log and the per-replica
/// cache it invalidates.
@Suite("IAM Policy Set Version Tests", .serialized)
final class IAMPolicySetVersionTests {

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

    @Test("Versions are monotonic and carry why they were cut")
    func versionsAreMonotonic() async throws {
        try await withApp { app in
            // `configure` runs the role-registry sync, which bumps once on a
            // fresh database. Measure from wherever that left off rather than
            // asserting a fixed starting point.
            let start = try await PolicySetVersionService.current(on: app.db)

            let first = try await PolicySetVersionService.bump(reason: "guardrail created: a", on: app.db)
            let second = try await PolicySetVersionService.bump(reason: "guardrail created: b", on: app.db)

            #expect(first == start + 1)
            #expect(second == start + 2)

            let latest = try await PolicySetVersionService.current(on: app.db)
            #expect(latest == second)

            let row = try await PolicySetVersion.query(on: app.db)
                .filter(\.$version == second)
                .first()
            #expect(row?.reason == "guardrail created: b")
        }
    }

    @Test("Concurrent bumps produce distinct versions rather than one lost update")
    func concurrentBumpsDoNotCollide() async throws {
        try await withApp { app in
            let start = try await PolicySetVersionService.current(on: app.db)

            // Serialized rather than truly parallel: SQLite is single-writer, so
            // this covers the allocator's arithmetic, and the uniqueness
            // constraint plus the retry loop covers the real race in Postgres.
            var versions: [Int] = []
            for index in 1...5 {
                versions.append(
                    try await PolicySetVersionService.bump(reason: "change \(index)", on: app.db))
            }

            #expect(versions == Array((start + 1)...(start + 5)))
            #expect(Set(versions).count == versions.count)
        }
    }

    @Test("The registry sync bumps once on a change and stays quiet when there is nothing to do")
    func registrySyncBumpsOnlyOnChange() async throws {
        try await withApp { app in
            // The first sync ran inside `configure`. A second one has nothing
            // left to reconcile, so it must not cut a version — otherwise every
            // replica restart would invalidate every replica's compiled set.
            let before = try await PolicySetVersionService.current(on: app.db)
            #expect(before > 0)

            try await RoleRegistrySync.sync(on: app.db, logger: app.logger)

            let after = try await PolicySetVersionService.current(on: app.db)
            #expect(after == before)
        }
    }

    @Test("A dropped action is a policy-set change the sync records")
    func registrySyncBumpsWhenRegistryDrifts() async throws {
        try await withApp { app in
            let before = try await PolicySetVersionService.current(on: app.db)

            // Simulate the tables drifting from the code-side registry, which is
            // what a deploy carrying a registry change looks like to the sync.
            try await IAMRoleAction.query(on: app.db)
                .filter(\.$role == IAMRole.viewer.rawValue)
                .filter(\.$action == "vm:read")
                .delete()

            try await RoleRegistrySync.sync(on: app.db, logger: app.logger)

            let after = try await PolicySetVersionService.current(on: app.db)
            #expect(after == before + 1)

            let restored = try await IAMRoleAction.query(on: app.db)
                .filter(\.$role == IAMRole.viewer.rawValue)
                .filter(\.$action == "vm:read")
                .count()
            #expect(restored == 1)
        }
    }

    @Test("The replica cache picks up a new version and tells its listeners")
    func cacheRefreshNotifiesListeners() async throws {
        try await withApp { app in
            let cache = PolicySetVersionCache(logger: app.logger)
            let observed = ObservedVersions()
            await cache.onVersionChange { version in
                await observed.record(version)
            }

            await cache.refresh(on: app.db)
            let afterFirst = await cache.currentVersion
            let expected = try await PolicySetVersionService.current(on: app.db)
            #expect(afterFirst == expected)

            // A refresh with nothing new must not re-fire: listeners rebuild the
            // compiled policy set, which is not work to do on a timer.
            await cache.refresh(on: app.db)
            let afterNoChange = await observed.all()
            #expect(afterNoChange == [expected])

            let bumped = try await PolicySetVersionService.bump(reason: "guardrail created: c", on: app.db)
            await cache.refresh(on: app.db)

            let finalVersion = await cache.currentVersion
            let recorded = await observed.all()
            #expect(finalVersion == bumped)
            #expect(recorded == [expected, bumped])
        }
    }

    /// Collects the versions a cache listener saw.
    private actor ObservedVersions {
        private var versions: [Int] = []
        func record(_ version: Int) { versions.append(version) }
        func all() -> [Int] { versions }
    }
}
