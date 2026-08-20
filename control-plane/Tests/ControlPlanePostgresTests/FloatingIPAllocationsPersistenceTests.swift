import Foundation
import Testing

@testable import ControlPlanePostgres

@Suite("Native floating-IP allocation persistence", .serialized)
struct FloatingIPAllocationsPersistenceTests {
    @Test("address selection skips the network, gateway, broadcast, and used addresses")
    func addressSelection() throws {
        let address = try FloatingIPAllocationsPersistence.lowestFreeAddress(
            poolName: "public",
            cidr: "203.0.113.0/29",
            gateway: "203.0.113.1",
            usedAddresses: ["203.0.113.2", "not-an-address", "203.0.113.4"]
        )
        #expect(address == "203.0.113.3")

        #expect(throws: FloatingIPAllocationError.invalidSubnet("invalid")) {
            try FloatingIPAllocationsPersistence.lowestFreeAddress(
                poolName: "public", cidr: "invalid", gateway: nil, usedAddresses: [])
        }
        #expect(throws: FloatingIPAllocationError.invalidGateway("invalid")) {
            try FloatingIPAllocationsPersistence.lowestFreeAddress(
                poolName: "public",
                cidr: "203.0.113.0/29",
                gateway: "invalid",
                usedAddresses: []
            )
        }
    }

    @Test("allocation and creator grant commit atomically with database timestamps")
    func allocationAndGrant() async throws {
        try await withAllocationDatabase { database, allocations, poolID in
            let projectID = UUID()
            let userID = UUID()
            let allocation = try await allocations.allocate(
                fromPoolID: poolID,
                toProjectID: projectID,
                createdByID: userID
            )

            #expect(allocation.poolID == poolID)
            #expect(allocation.projectID == projectID)
            #expect(allocation.createdByID == userID)
            #expect(allocation.address == "203.0.113.2")
            #expect(allocation.createdAt != nil)
            #expect(allocation.updatedAt == nil)

            try await database.withSession(operation: "test.floating_ips.verify") { session in
                let rows = try await session.query(
                    """
                    SELECT principal_type, principal_id, role_id, node_type, node_id, created_by
                    FROM role_bindings
                    """,
                    operation: "test.floating_ips.verify.binding"
                )
                #expect(rows.count == 1)
                let binding = try #require(rows.first)
                let decoded = try binding.decode(
                    (String, UUID, UUID, String, UUID, UUID?).self
                )
                #expect(decoded.0 == "user")
                #expect(decoded.1 == userID)
                #expect(decoded.2 == UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
                #expect(decoded.3 == "floating_ip")
                #expect(decoded.4 == allocation.id)
                #expect(decoded.5 == userID)
            }
        }
    }

    @Test("concurrent allocators serialize and reserve distinct addresses")
    func concurrentAllocation() async throws {
        try await withAllocationDatabase(maximumConnections: 2) {
            _, allocations, poolID in
            let projectID = UUID()
            let userID = UUID()
            let snapshots = try await withThrowingTaskGroup(
                of: FloatingIPAllocationSnapshot.self
            ) { group in
                group.addTask {
                    try await allocations.allocate(
                        fromPoolID: poolID,
                        toProjectID: projectID,
                        createdByID: userID
                    )
                }
                group.addTask {
                    try await allocations.allocate(
                        fromPoolID: poolID,
                        toProjectID: projectID,
                        createdByID: userID
                    )
                }
                var values: [FloatingIPAllocationSnapshot] = []
                for try await snapshot in group { values.append(snapshot) }
                return values
            }

            #expect(Set(snapshots.map(\.address)) == ["203.0.113.2", "203.0.113.3"])
            #expect(Set(snapshots.map(\.id)).count == 2)
        }
    }

    @Test("a creator-grant failure rolls the allocation back")
    func grantFailureRollsBack() async throws {
        try await withAllocationDatabase { database, allocations, poolID in
            _ = try await database.withSession(
                operation: "test.floating_ips.break_grant"
            ) { session in
                try await session.command(
                    "DROP TABLE role_bindings",
                    operation: "test.floating_ips.break_grant.drop"
                )
            }

            var failed = false
            do {
                _ = try await allocations.allocate(
                    fromPoolID: poolID,
                    toProjectID: UUID(),
                    createdByID: UUID()
                )
            } catch {
                failed = true
            }
            #expect(failed)

            try await database.withSession(operation: "test.floating_ips.rollback") { session in
                let rows = try await session.query(
                    "SELECT count(*)::bigint FROM floating_ips",
                    operation: "test.floating_ips.rollback.count"
                )
                #expect(try rows.first?.decode(Int64.self) == 0)
            }
        }
    }

    @Test("attach and detach are idempotent and advance network generation atomically")
    func attachmentLifecycle() async throws {
        try await withAllocationDatabase { database, allocations, poolID in
            let networkID = UUID()
            let vmID = UUID()
            let interfaceID = UUID()
            try await seedVMTopology(
                database: database,
                networkID: networkID,
                vmID: vmID,
                interfaceID: interfaceID,
                agentID: "agent-a",
                address: "10.0.0.10"
            )
            let allocation = try await allocations.allocate(
                fromPoolID: poolID, toProjectID: UUID(), createdByID: UUID())

            let attached = try await allocations.attach(
                id: allocation.id,
                to: .interface(id: interfaceID, networkID: networkID))
            guard case .attached(let attachedSnapshot) = attached else {
                Issue.record("expected a newly attached snapshot")
                return
            }
            #expect(attachedSnapshot.interfaceID == interfaceID)
            #expect(attachedSnapshot.vmID == vmID)
            #expect(attachedSnapshot.fixedIP == "10.0.0.10")
            #expect(try await generation(networkID: networkID, database: database) == 2)

            guard case .unchanged = try await allocations.attach(
                id: allocation.id,
                to: .interface(id: interfaceID, networkID: networkID))
            else {
                Issue.record("expected repeated attach to be unchanged")
                return
            }
            #expect(try await generation(networkID: networkID, database: database) == 2)

            guard case .attached(let detached) = try await allocations.detach(id: allocation.id)
            else {
                Issue.record("expected detach to update the allocation")
                return
            }
            #expect(detached.interfaceID == nil)
            #expect(detached.networkID == nil)
            #expect(try await generation(networkID: networkID, database: database) == 3)

            guard case .unchanged = try await allocations.detach(id: allocation.id) else {
                Issue.record("expected repeated detach to be unchanged")
                return
            }
            #expect(try await generation(networkID: networkID, database: database) == 3)
        }
    }

    @Test("the target unique index arbitrates competing attaches")
    func attachmentTargetConflict() async throws {
        try await withAllocationDatabase { database, allocations, poolID in
            let networkID = UUID()
            let interfaceID = UUID()
            try await seedVMTopology(
                database: database,
                networkID: networkID,
                vmID: UUID(),
                interfaceID: interfaceID,
                agentID: "agent-a",
                address: "10.0.0.10"
            )
            let first = try await allocations.allocate(
                fromPoolID: poolID, toProjectID: UUID(), createdByID: UUID())
            let second = try await allocations.allocate(
                fromPoolID: poolID, toProjectID: UUID(), createdByID: UUID())

            guard case .attached = try await allocations.attach(
                id: first.id,
                to: .interface(id: interfaceID, networkID: networkID))
            else {
                Issue.record("expected first attach to win")
                return
            }
            #expect(
                try await allocations.attach(
                    id: second.id,
                    to: .interface(id: interfaceID, networkID: networkID)) == .targetInUse)
            #expect(try await allocations.allocation(id: second.id)?.interfaceID == nil)
            #expect(try await generation(networkID: networkID, database: database) == 2)
        }
    }

    @Test("desired-state attachment reads stay batched across VM and load-balancer targets")
    func desiredAttachments() async throws {
        try await withAllocationDatabase { database, allocations, poolID in
            let networkID = UUID()
            let vmID = UUID()
            let interfaceID = UUID()
            try await seedVMTopology(
                database: database,
                networkID: networkID,
                vmID: vmID,
                interfaceID: interfaceID,
                agentID: "agent-a",
                address: "10.0.0.10"
            )
            let vmAllocation = try await allocations.allocate(
                fromPoolID: poolID, toProjectID: UUID(), createdByID: UUID())
            _ = try await allocations.attach(
                id: vmAllocation.id,
                to: .interface(id: interfaceID, networkID: networkID))

            let loadBalancerID = UUID()
            try await database.withSession(operation: "test.floating_ips.seed_lb") { session in
                _ = try await session.command(
                    """
                    INSERT INTO load_balancers (id, logical_network_id, vip)
                    VALUES (
                        '\(loadBalancerID.uuidString)'::uuid,
                        '\(networkID.uuidString)'::uuid,
                        '10.0.0.20'
                    )
                    """,
                    operation: "test.floating_ips.seed_lb.insert")
            }
            let loadBalancerAllocation = try await allocations.allocate(
                fromPoolID: poolID, toProjectID: UUID(), createdByID: UUID())
            _ = try await allocations.attach(
                id: loadBalancerAllocation.id,
                to: .loadBalancer(id: loadBalancerID, networkID: networkID))

            let desired = try await allocations.desiredAttachments(
                forAgentIDs: ["agent-a"], networkIDs: [networkID])
            #expect(desired.count == 2)
            #expect(desired.contains {
                $0.externalIP == vmAllocation.address && $0.logicalIP == "10.0.0.10"
                    && $0.vmID == vmID && $0.nicIndex == 2
            })
            #expect(desired.contains {
                $0.externalIP == loadBalancerAllocation.address && $0.logicalIP == "10.0.0.20"
                    && $0.vmID == nil && $0.nicIndex == nil
            })
        }
    }

    private func seedVMTopology(
        database: PostgresDatabase,
        networkID: UUID,
        vmID: UUID,
        interfaceID: UUID,
        agentID: String,
        address: String
    ) async throws {
        try await database.withSession(operation: "test.floating_ips.seed_topology") { session in
            _ = try await session.command(
                """
                INSERT INTO logical_networks (id, name) VALUES (
                    '\(networkID.uuidString)'::uuid, 'test-network')
                """,
                operation: "test.floating_ips.seed_topology.network")
            _ = try await session.command(
                """
                INSERT INTO vms (id, hypervisor_id) VALUES (
                    '\(vmID.uuidString)'::uuid, '\(agentID)')
                """,
                operation: "test.floating_ips.seed_topology.vm")
            _ = try await session.command(
                """
                INSERT INTO vm_network_interfaces (
                    id, vm_id, logical_network_id, order_index, detach_generation
                ) VALUES (
                    '\(interfaceID.uuidString)'::uuid, '\(vmID.uuidString)'::uuid,
                    '\(networkID.uuidString)'::uuid, 2, NULL)
                """,
                operation: "test.floating_ips.seed_topology.interface")
            _ = try await session.command(
                """
                INSERT INTO vm_interface_addresses (id, interface_id, family, address)
                VALUES (
                    '\(UUID().uuidString)'::uuid, '\(interfaceID.uuidString)'::uuid,
                    'ipv4', '\(address)')
                """,
                operation: "test.floating_ips.seed_topology.address")
        }
    }

    private func generation(networkID: UUID, database: PostgresDatabase) async throws -> Int64 {
        try await database.withSession(operation: "test.floating_ips.generation") { session in
            let rows = try await session.query(
                "SELECT generation FROM logical_networks WHERE id = '\(networkID.uuidString)'::uuid",
                operation: "test.floating_ips.generation.query")
            return try #require(rows.first).decode(Int64.self)
        }
    }

    private func withAllocationDatabase(
        maximumConnections: Int = 1,
        _ test: (
            PostgresDatabase,
            FloatingIPAllocationsPersistence,
            UUID
        ) async throws -> Void
    ) async throws {
        try await withBareNativePostgresDatabase(
            maximumConnections: maximumConnections
        ) { database in
            let poolID = UUID()
            try await database.withSession(operation: "test.floating_ips.schema") { session in
                _ = try await session.command(
                    """
                    CREATE TABLE floating_ip_pools (
                        id UUID PRIMARY KEY,
                        name TEXT NOT NULL,
                        cidr TEXT NOT NULL,
                        gateway TEXT
                    )
                    """,
                    operation: "test.floating_ips.schema.create_pools"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE floating_ips (
                        id UUID PRIMARY KEY,
                        pool_id UUID NOT NULL,
                        address TEXT NOT NULL,
                        project_id UUID NOT NULL,
                        interface_id UUID,
                        load_balancer_id UUID,
                        created_by_id UUID,
                        created_at TIMESTAMPTZ,
                        updated_at TIMESTAMPTZ,
                        UNIQUE (pool_id, address)
                    )
                    """,
                    operation: "test.floating_ips.schema.create_allocations"
                )
                _ = try await session.command(
                    """
                    CREATE UNIQUE INDEX uq_floating_ips_interface
                    ON floating_ips (interface_id) WHERE interface_id IS NOT NULL
                    """,
                    operation: "test.floating_ips.schema.create_interface_index"
                )
                _ = try await session.command(
                    """
                    CREATE UNIQUE INDEX uq_floating_ips_load_balancer_id
                    ON floating_ips (load_balancer_id) WHERE load_balancer_id IS NOT NULL
                    """,
                    operation: "test.floating_ips.schema.create_load_balancer_index"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE logical_networks (
                        id UUID PRIMARY KEY,
                        name TEXT NOT NULL,
                        generation BIGINT NOT NULL DEFAULT 1
                    )
                    """,
                    operation: "test.floating_ips.schema.create_networks"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE vms (
                        id UUID PRIMARY KEY,
                        hypervisor_id TEXT
                    )
                    """,
                    operation: "test.floating_ips.schema.create_vms"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE vm_network_interfaces (
                        id UUID PRIMARY KEY,
                        vm_id UUID NOT NULL,
                        logical_network_id UUID NOT NULL,
                        order_index INTEGER NOT NULL,
                        detach_generation BIGINT
                    )
                    """,
                    operation: "test.floating_ips.schema.create_interfaces"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE vm_interface_addresses (
                        id UUID PRIMARY KEY,
                        interface_id UUID NOT NULL,
                        family TEXT NOT NULL,
                        address TEXT NOT NULL
                    )
                    """,
                    operation: "test.floating_ips.schema.create_addresses"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE load_balancers (
                        id UUID PRIMARY KEY,
                        logical_network_id UUID NOT NULL,
                        vip TEXT NOT NULL
                    )
                    """,
                    operation: "test.floating_ips.schema.create_load_balancers"
                )
                _ = try await session.command(
                    """
                    CREATE TABLE role_bindings (
                        id UUID PRIMARY KEY,
                        principal_type TEXT NOT NULL,
                        principal_id UUID NOT NULL,
                        role_id UUID NOT NULL,
                        node_type TEXT NOT NULL,
                        node_id UUID NOT NULL,
                        condition TEXT,
                        expires_at TIMESTAMPTZ,
                        created_by UUID,
                        created_at TIMESTAMPTZ,
                        UNIQUE (principal_type, principal_id, role_id, node_type, node_id)
                    )
                    """,
                    operation: "test.floating_ips.schema.create_bindings"
                )
                _ = try await session.command(
                    """
                    INSERT INTO floating_ip_pools (id, name, cidr, gateway)
                    VALUES ('\(poolID.uuidString)'::uuid, 'public', '203.0.113.0/29', '203.0.113.1')
                    """,
                    operation: "test.floating_ips.schema.seed_pool"
                )
            }
            try await test(
                database,
                ControlPlanePersistence(database: database).floatingIPAllocations,
                poolID
            )
        }
    }
}
