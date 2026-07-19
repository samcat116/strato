import Fluent
import Testing
import Vapor

@testable import App

/// Tests for the `SeedDefaultNetworkDNS` migration (issue #518): the seeded
/// "default" network must ship with usable resolvers, without ever clobbering
/// resolvers an operator chose.
@Suite("SeedDefaultNetworkDNS migration", .serialized)
struct SeedDefaultNetworkDNSTests {

    private func defaultNetwork(on db: any Database) async throws -> LogicalNetwork {
        let network = try await LogicalNetwork.query(on: db)
            .filter(\.$name == LogicalNetwork.defaultNetworkName)
            .first()
        return try #require(network)
    }

    @Test("Seeded default network comes up with resolvers")
    func seedsResolversOnFreshInstall() async throws {
        try await withTestApp { app in
            let network = try await defaultNetwork(on: app.db)
            #expect(network.dnsServers == SeedDefaultNetworkDNS.fallbackResolvers)
        }
    }

    @Test("Backfills a default network that has no resolvers")
    func backfillsEmptyResolvers() async throws {
        try await withTestApp { app in
            // Reproduce the pre-fix state: the column exists but was never populated.
            let network = try await defaultNetwork(on: app.db)
            network.dnsServersRaw = nil
            try await network.save(on: app.db)

            try await SeedDefaultNetworkDNS().prepare(on: app.db)

            let seeded = try await defaultNetwork(on: app.db)
            #expect(seeded.dnsServers == SeedDefaultNetworkDNS.fallbackResolvers)
        }
    }

    @Test("Leaves operator-chosen resolvers alone")
    func preservesOperatorResolvers() async throws {
        try await withTestApp { app in
            let network = try await defaultNetwork(on: app.db)
            network.dnsServers = ["10.0.0.53"]
            try await network.save(on: app.db)

            try await SeedDefaultNetworkDNS().prepare(on: app.db)

            let after = try await defaultNetwork(on: app.db)
            #expect(after.dnsServers == ["10.0.0.53"])
        }
    }

    // The test app runs against a pre-migrated database clone, so the env-var
    // cases clear the seeded value and re-run the migration by hand.

    @Test("STRATO_DEFAULT_NETWORK_DNS_SERVERS overrides the fallback")
    func honorsEnvironmentOverride() async throws {
        try await withTestApp { app in
            let network = try await defaultNetwork(on: app.db)
            network.dnsServersRaw = nil
            try await network.save(on: app.db)

            setenv("STRATO_DEFAULT_NETWORK_DNS_SERVERS", "9.9.9.9, 149.112.112.112", 1)
            defer { unsetenv("STRATO_DEFAULT_NETWORK_DNS_SERVERS") }
            try await SeedDefaultNetworkDNS().prepare(on: app.db)

            let seeded = try await defaultNetwork(on: app.db)
            #expect(seeded.dnsServers == ["9.9.9.9", "149.112.112.112"])
        }
    }

    @Test("An empty STRATO_DEFAULT_NETWORK_DNS_SERVERS opts out of seeding")
    func emptyEnvironmentOptsOut() async throws {
        try await withTestApp { app in
            let network = try await defaultNetwork(on: app.db)
            network.dnsServersRaw = nil
            try await network.save(on: app.db)

            setenv("STRATO_DEFAULT_NETWORK_DNS_SERVERS", "", 1)
            defer { unsetenv("STRATO_DEFAULT_NETWORK_DNS_SERVERS") }
            try await SeedDefaultNetworkDNS().prepare(on: app.db)

            let after = try await defaultNetwork(on: app.db)
            #expect(after.dnsServers.isEmpty)
        }
    }

    @Test("A malformed STRATO_DEFAULT_NETWORK_DNS_SERVERS fails the migration")
    func malformedEnvironmentThrows() async throws {
        try await withTestApp { app in
            setenv("STRATO_DEFAULT_NETWORK_DNS_SERVERS", "1.1.1.1,not-an-ip", 1)
            defer { unsetenv("STRATO_DEFAULT_NETWORK_DNS_SERVERS") }

            await #expect(throws: (any Error).self) {
                try await SeedDefaultNetworkDNS().prepare(on: app.db)
            }
        }
    }
}
