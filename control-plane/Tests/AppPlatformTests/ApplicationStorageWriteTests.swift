import Testing
import Vapor

@testable import App

/// `Application.storage` is a struct behind a lock box, so `storage[K] = v` is a
/// read-modify-write of the whole container and concurrent writes to *different*
/// keys silently drop one another. `setStorageValue(_:to:)` is what makes those
/// writes atomic; these tests pin that down. A lost write here is what produced
/// the `AgentAutoUpdateTests.staleTargetIsReset` CI flake.
@Suite("Application Storage Write Tests")
struct ApplicationStorageWriteTests {

    private struct SeamKey: StorageKey { typealias Value = String }
    private struct OtherKey: StorageKey { typealias Value = String }
    private struct LazyProbeKey: StorageKey, LockKey { typealias Value = String }

    /// Rounds per race test. The lost update is a narrow window — measured at
    /// roughly 1 in 500 unsynchronized attempts on an idle machine, and far
    /// likelier on the starved CI runner where it first showed up — so the count
    /// is high enough that a regression is overwhelmingly likely to trip it. It
    /// cannot fail the other way: with the writes synchronized, no interleaving
    /// loses a key.
    private static let rounds = 4000

    /// These exercise storage alone: no database, no `configure`.
    private func withBareApp(_ test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await test(app)
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("concurrent writes to different storage keys do not clobber each other")
    func concurrentWritesToDifferentKeysBothSurvive() async throws {
        try await withBareApp { app in
            var lostSeam = 0
            var lostOther = 0

            for _ in 0..<Self.rounds {
                app.setStorageValue(SeamKey.self, to: nil)
                app.setStorageValue(OtherKey.self, to: nil)

                await withTaskGroup(of: Void.self) { group in
                    group.addTask { app.setStorageValue(SeamKey.self, to: "seam") }
                    group.addTask { app.setStorageValue(OtherKey.self, to: "other") }
                }

                if app.storage[SeamKey.self] == nil { lostSeam += 1 }
                if app.storage[OtherKey.self] == nil { lostOther += 1 }
            }

            #expect(lostSeam == 0, "\(lostSeam)/\(Self.rounds) writes were discarded by a concurrent write")
            #expect(lostOther == 0, "\(lostOther)/\(Self.rounds) writes were discarded by a concurrent write")
        }
    }

    /// The shape of the original flake: a background task creating a lazy
    /// service, racing a seam the test assigns on the very next line.
    @Test("a lazily created service does not discard a seam assigned concurrently")
    func lazyServiceCreationDoesNotDiscardAConcurrentAssignment() async throws {
        try await withBareApp { app in
            var lost = 0

            for _ in 0..<Self.rounds {
                app.setStorageValue(SeamKey.self, to: nil)
                app.setStorageValue(LazyProbeKey.self, to: nil)

                await withTaskGroup(of: Void.self) { group in
                    group.addTask { _ = app.lazyService(LazyProbeKey.self) { "probe" } }
                    group.addTask { app.setStorageValue(SeamKey.self, to: "seam") }
                }

                if app.storage[SeamKey.self] == nil { lost += 1 }
            }

            #expect(lost == 0, "\(lost)/\(Self.rounds) seam assignments were discarded by a lazy service creation")
        }
    }
}
