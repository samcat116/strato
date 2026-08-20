import Fluent
import Foundation
import SQLKit
import Vapor

struct LoadBalancerListenerSnapshot: Equatable, Sendable {
    let id: UUID
    let loadBalancerID: UUID
    let port: Int
    let backendPort: Int
    let createdAt: Date?
    let updatedAt: Date?
}

struct LoadBalancerBackendSnapshot: Equatable, Sendable {
    let id: UUID
    let loadBalancerID: UUID
    let interfaceID: UUID?
    let address: String?
    let healthStatus: LoadBalancerBackendHealth
    let lastHealthCheckAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
}

/// Immutable SQL bridge for load-balancer membership operations that still
/// share a caller-owned Fluent transaction with the parent load balancer.
enum LegacyLoadBalancerTargetStore {
    static func listeners(
        loadBalancerID: UUID,
        on db: any Database
    ) async throws -> [LoadBalancerListenerSnapshot] {
        let rows = try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: listenerColumns)
            FROM load_balancer_listeners
            WHERE load_balancer_id = \(bind: loadBalancerID)
            ORDER BY port, id
            """
        ).all(decoding: ListenerRecord.self)
        return rows.map(\.snapshot)
    }

    static func listener(
        id: UUID,
        loadBalancerID: UUID,
        on db: any Database
    ) async throws -> LoadBalancerListenerSnapshot? {
        try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: listenerColumns)
            FROM load_balancer_listeners
            WHERE id = \(bind: id) AND load_balancer_id = \(bind: loadBalancerID)
            LIMIT 1
            """
        ).first(decoding: ListenerRecord.self)?.snapshot
    }

    @discardableResult
    static func insertListener(
        id: UUID = UUID(),
        loadBalancerID: UUID,
        port: Int,
        backendPort: Int,
        on db: any Database
    ) async throws -> LoadBalancerListenerSnapshot {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO load_balancer_listeners (
                id, load_balancer_id, port, backend_port, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: loadBalancerID), \(bind: port), \(bind: backendPort),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: listenerColumns)
            """
        ).first(decoding: ListenerRecord.self) else {
            throw Abort(.internalServerError, reason: "Could not create load-balancer listener")
        }
        return row.snapshot
    }

    @discardableResult
    static func updateListener(
        id: UUID,
        loadBalancerID: UUID,
        port: Int,
        backendPort: Int,
        on db: any Database
    ) async throws -> LoadBalancerListenerSnapshot? {
        try await requireSQL(db).raw(
            """
            UPDATE load_balancer_listeners
            SET port = \(bind: port),
                backend_port = \(bind: backendPort),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id) AND load_balancer_id = \(bind: loadBalancerID)
            RETURNING \(unsafeRaw: listenerColumns)
            """
        ).first(decoding: ListenerRecord.self)?.snapshot
    }

    @discardableResult
    static func deleteListener(
        id: UUID,
        loadBalancerID: UUID,
        on db: any Database
    ) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            """
            DELETE FROM load_balancer_listeners
            WHERE id = \(bind: id) AND load_balancer_id = \(bind: loadBalancerID)
            RETURNING id
            """
        ).first(decoding: Deleted.self)?.id
    }

    static func backends(
        loadBalancerID: UUID,
        on db: any Database
    ) async throws -> [LoadBalancerBackendSnapshot] {
        let rows = try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: backendColumns)
            FROM load_balancer_backends
            WHERE load_balancer_id = \(bind: loadBalancerID)
            ORDER BY created_at, id
            """
        ).all(decoding: BackendRecord.self)
        return try rows.map { try $0.snapshot() }
    }

    static func backend(
        id: UUID,
        loadBalancerID: UUID,
        on db: any Database
    ) async throws -> LoadBalancerBackendSnapshot? {
        guard let row = try await requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: backendColumns)
            FROM load_balancer_backends
            WHERE id = \(bind: id) AND load_balancer_id = \(bind: loadBalancerID)
            LIMIT 1
            """
        ).first(decoding: BackendRecord.self) else { return nil }
        return try row.snapshot()
    }

    @discardableResult
    static func insertBackend(
        id: UUID = UUID(),
        loadBalancerID: UUID,
        interfaceID: UUID?,
        address: String?,
        on db: any Database
    ) async throws -> LoadBalancerBackendSnapshot {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO load_balancer_backends (
                id, load_balancer_id, interface_id, address, health_status,
                last_health_check_at, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: loadBalancerID), \(bind: interfaceID), \(bind: address),
                \(bind: LoadBalancerBackendHealth.unknown.rawValue), NULL,
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: backendColumns)
            """
        ).first(decoding: BackendRecord.self) else {
            throw Abort(.internalServerError, reason: "Could not create load-balancer backend")
        }
        return try row.snapshot()
    }

    @discardableResult
    static func deleteBackend(
        id: UUID,
        loadBalancerID: UUID,
        on db: any Database
    ) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            """
            DELETE FROM load_balancer_backends
            WHERE id = \(bind: id) AND load_balancer_id = \(bind: loadBalancerID)
            RETURNING id
            """
        ).first(decoding: Deleted.self)?.id
    }

    @discardableResult
    static func recordHealth(
        id: UUID,
        loadBalancerID: UUID,
        healthStatus: LoadBalancerBackendHealth,
        lastHealthCheckAt: Date?,
        on db: any Database
    ) async throws -> LoadBalancerBackendSnapshot? {
        guard let row = try await requireSQL(db).raw(
            """
            UPDATE load_balancer_backends
            SET health_status = \(bind: healthStatus.rawValue),
                last_health_check_at = \(bind: lastHealthCheckAt),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id) AND load_balancer_id = \(bind: loadBalancerID)
            RETURNING \(unsafeRaw: backendColumns)
            """
        ).first(decoding: BackendRecord.self) else { return nil }
        return try row.snapshot()
    }

    static func backendCount(on db: any Database) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM load_balancer_backends"
        ).first(decoding: Count.self)?.count ?? 0
    }

    private struct ListenerRecord: Decodable, Sendable {
        let id: UUID
        let loadBalancerID: UUID
        let port: Int
        let backendPort: Int
        let createdAt: Date?
        let updatedAt: Date?

        var snapshot: LoadBalancerListenerSnapshot {
            LoadBalancerListenerSnapshot(
                id: id,
                loadBalancerID: loadBalancerID,
                port: port,
                backendPort: backendPort,
                createdAt: createdAt,
                updatedAt: updatedAt)
        }
    }

    private struct BackendRecord: Decodable, Sendable {
        let id: UUID
        let loadBalancerID: UUID
        let interfaceID: UUID?
        let address: String?
        let healthStatus: String
        let lastHealthCheckAt: Date?
        let createdAt: Date?
        let updatedAt: Date?

        func snapshot() throws -> LoadBalancerBackendSnapshot {
            guard let healthStatus = LoadBalancerBackendHealth(rawValue: healthStatus) else {
                throw Abort(.internalServerError, reason: "Load-balancer backend has invalid health status")
            }
            return LoadBalancerBackendSnapshot(
                id: id,
                loadBalancerID: loadBalancerID,
                interfaceID: interfaceID,
                address: address,
                healthStatus: healthStatus,
                lastHealthCheckAt: lastHealthCheckAt,
                createdAt: createdAt,
                updatedAt: updatedAt)
        }
    }

    private static let listenerColumns = """
        id,
        load_balancer_id AS "loadBalancerID",
        port,
        backend_port AS "backendPort",
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static let backendColumns = """
        id,
        load_balancer_id AS "loadBalancerID",
        interface_id AS "interfaceID",
        address,
        health_status AS "healthStatus",
        last_health_check_at AS "lastHealthCheckAt",
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Load-balancer targets require PostgreSQL")
        }
        return sql
    }
}
