import Crypto
import Fluent
import Foundation
import SQLKit
import Vapor

/// Stable identity for one HTTP mutation request.
///
/// JSON objects are re-encoded with sorted keys so semantically identical
/// payloads do not diverge only because an encoder chose another dictionary
/// order. The method and request target (path plus query) are part of the
/// digest: a key reused on another mutation surface is a conflicting request,
/// never an alias.
enum IdempotencyRequestDigest {
    static func compute(method: HTTPMethod, path: String, body: Data) throws -> Data {
        let canonicalBody: Data
        if !body.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
            JSONSerialization.isValidJSONObject(object)
        {
            canonicalBody = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        } else {
            canonicalBody = body
        }

        let envelope: [String: String] = [
            "body": canonicalBody.base64EncodedString(),
            "method": method.rawValue,
            "path": path,
        ]
        let bytes = try JSONSerialization.data(
            withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        return Data(SHA256.hash(data: bytes))
    }
}

/// The immutable request identity captured by `IdempotencyMiddleware` and
/// consumed only from inside the mutation's own transaction.
struct IdempotencyRequestContext: Sendable {
    let actor: MutationActor
    let key: String
    let requestDigest: Data
}

/// Signals that another transaction won the principal/key claim. This is
/// deliberately not a `DatabaseError`: callers such as VM IPAM retry generic
/// constraint failures, while this outcome must roll their mutation back and
/// replay the committed winner.
struct IdempotencyReplayRequired: Error, Sendable {}

enum IdempotencyService {
    static let retention: TimeInterval = 24 * 60 * 60

    /// Claims the request key before the transaction performs any mutation.
    ///
    /// PostgreSQL waits when the conflicting unique-index entry is still
    /// uncommitted. `DO NOTHING` then returns no id if that transaction won,
    /// which lets this transaction roll back every duplicate effect without
    /// exposing the uniqueness violation to an outer retry loop. A transaction
    /// that later fails rolls this reservation back with the mutation.
    static func reserve(
        _ context: IdempotencyRequestContext?,
        actor: MutationActor,
        on database: any Database
    ) async throws {
        guard let context else { return }
        guard context.actor == actor else {
            throw Abort(
                .internalServerError,
                reason: "The idempotency principal did not match the mutation actor")
        }
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Idempotency requires a SQL database")
        }

        let now = Date()
        let expiresAt = now.addingTimeInterval(retention)
        try await deleteExpiredClaim(
            actor: actor, key: context.key, now: now, on: sql)

        let insertedIDs: [UUID]
        if let principalID = actor.id {
            insertedIDs = try await sql.raw(
                """
                INSERT INTO idempotency_keys
                  (id, principal_type, principal_id, key, request_digest,
                   created_at, expires_at)
                VALUES
                  (\(bind: UUID()), \(bind: actor.type.rawValue), \(bind: principalID),
                   \(bind: context.key), \(bind: context.requestDigest),
                   \(bind: now), \(bind: expiresAt))
                ON CONFLICT DO NOTHING
                RETURNING id
                """
            ).all(decodingColumn: "id", as: UUID.self)
        } else {
            insertedIDs = try await sql.raw(
                """
                INSERT INTO idempotency_keys
                  (id, principal_type, principal_id, key, request_digest,
                   created_at, expires_at)
                VALUES
                  (\(bind: UUID()), \(bind: actor.type.rawValue), NULL,
                   \(bind: context.key), \(bind: context.requestDigest),
                   \(bind: now), \(bind: expiresAt))
                ON CONFLICT DO NOTHING
                RETURNING id
                """
            ).all(decodingColumn: "id", as: UUID.self)
        }

        guard !insertedIDs.isEmpty else { throw IdempotencyReplayRequired() }
    }

    /// Completes the reservation with the stable identity of the accepted
    /// outcome. This must run in the same transaction as `reserve` and the
    /// mutation itself, so no incomplete claim can become visible.
    static func complete(
        _ context: IdempotencyRequestContext?,
        actor: MutationActor,
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        accepted: ResourceMutation.Accepted,
        responseBody: Data? = nil,
        responseStatus: HTTPStatus = .accepted,
        on database: any Database
    ) async throws {
        guard let context else { return }
        guard context.actor == actor else {
            throw Abort(
                .internalServerError,
                reason: "The idempotency principal did not match the mutation actor")
        }
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Idempotency requires a SQL database")
        }

        let completedIDs: [UUID]
        if let principalID = actor.id {
            completedIDs = try await sql.raw(
                """
                UPDATE idempotency_keys
                SET resource_kind = \(bind: resourceKind.rawValue),
                    resource_id = \(bind: resourceID),
                    mutation_id = \(bind: accepted.mutationID),
                    target_generation = \(bind: accepted.targetGeneration),
                    response_status = \(bind: Int(responseStatus.code)),
                    response_body = \(bind: responseBody)
                WHERE principal_type = \(bind: actor.type.rawValue)
                  AND principal_id = \(bind: principalID)
                  AND key = \(bind: context.key)
                  AND request_digest = \(bind: context.requestDigest)
                  AND response_status IS NULL
                RETURNING id
                """
            ).all(decodingColumn: "id", as: UUID.self)
        } else {
            completedIDs = try await sql.raw(
                """
                UPDATE idempotency_keys
                SET resource_kind = \(bind: resourceKind.rawValue),
                    resource_id = \(bind: resourceID),
                    mutation_id = \(bind: accepted.mutationID),
                    target_generation = \(bind: accepted.targetGeneration),
                    response_status = \(bind: Int(responseStatus.code)),
                    response_body = \(bind: responseBody)
                WHERE principal_type = \(bind: actor.type.rawValue)
                  AND principal_id IS NULL
                  AND key = \(bind: context.key)
                  AND request_digest = \(bind: context.requestDigest)
                  AND response_status IS NULL
                RETURNING id
                """
            ).all(decodingColumn: "id", as: UUID.self)
        }

        guard completedIDs.count == 1 else {
            throw Abort(.internalServerError, reason: "The idempotency reservation was not completed")
        }
    }

    /// Completes a mutation whose established API contract returns the
    /// resource directly instead of creating an asynchronous operation.
    /// The resource identity is enough to rebuild a fresh response on replay.
    static func completeSynchronousResponse(
        _ context: IdempotencyRequestContext?,
        actor: MutationActor,
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        responseStatus: HTTPStatus,
        on database: any Database
    ) async throws {
        guard let context else { return }
        guard context.actor == actor else {
            throw Abort(
                .internalServerError,
                reason: "The idempotency principal did not match the mutation actor")
        }
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Idempotency requires a SQL database")
        }

        let completedIDs: [UUID]
        if let principalID = actor.id {
            completedIDs = try await sql.raw(
                """
                UPDATE idempotency_keys
                SET resource_kind = \(bind: resourceKind.rawValue),
                    resource_id = \(bind: resourceID),
                    response_status = \(bind: Int(responseStatus.code))
                WHERE principal_type = \(bind: actor.type.rawValue)
                  AND principal_id = \(bind: principalID)
                  AND key = \(bind: context.key)
                  AND request_digest = \(bind: context.requestDigest)
                  AND response_status IS NULL
                RETURNING id
                """
            ).all(decodingColumn: "id", as: UUID.self)
        } else {
            completedIDs = try await sql.raw(
                """
                UPDATE idempotency_keys
                SET resource_kind = \(bind: resourceKind.rawValue),
                    resource_id = \(bind: resourceID),
                    response_status = \(bind: Int(responseStatus.code))
                WHERE principal_type = \(bind: actor.type.rawValue)
                  AND principal_id IS NULL
                  AND key = \(bind: context.key)
                  AND request_digest = \(bind: context.requestDigest)
                  AND response_status IS NULL
                RETURNING id
                """
            ).all(decodingColumn: "id", as: UUID.self)
        }

        guard completedIDs.count == 1 else {
            throw Abort(.internalServerError, reason: "The idempotency reservation was not completed")
        }
    }

    static func activeClaim(
        for context: IdempotencyRequestContext, on database: any Database
    ) async throws -> IdempotencyKey? {
        var query = IdempotencyKey.query(on: database)
            .filter(\.$principalType == context.actor.type)
            .filter(\.$key == context.key)
            .filter(\.$expiresAt > Date())
        if let principalID = context.actor.id {
            query = query.filter(\.$principalID == principalID)
        } else {
            query = query.filter(\.$principalID == nil)
        }
        return try await query.first()
    }

    /// Retains the exact successful JSON before it leaves the HTTP pipeline.
    ///
    /// The stable outcome identity is committed with the mutation by
    /// `complete`; delete paths also pass their body there because their row
    /// can disappear immediately. This best-effort second step enriches other
    /// successful responses and is intentionally safe to repeat on replay.
    @discardableResult
    static func storeResponseBody(
        _ body: Data,
        for context: IdempotencyRequestContext,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Idempotency requires a SQL database")
        }

        let updatedIDs: [UUID]
        if let principalID = context.actor.id {
            updatedIDs = try await sql.raw(
                """
                UPDATE idempotency_keys
                SET response_body = COALESCE(response_body, \(bind: body))
                WHERE principal_type = \(bind: context.actor.type.rawValue)
                  AND principal_id = \(bind: principalID)
                  AND key = \(bind: context.key)
                  AND request_digest = \(bind: context.requestDigest)
                  AND response_status IS NOT NULL
                RETURNING id
                """
            ).all(decodingColumn: "id", as: UUID.self)
        } else {
            updatedIDs = try await sql.raw(
                """
                UPDATE idempotency_keys
                SET response_body = COALESCE(response_body, \(bind: body))
                WHERE principal_type = \(bind: context.actor.type.rawValue)
                  AND principal_id IS NULL
                  AND key = \(bind: context.key)
                  AND request_digest = \(bind: context.requestDigest)
                  AND response_status IS NOT NULL
                RETURNING id
                """
            ).all(decodingColumn: "id", as: UUID.self)
        }

        return updatedIDs.count == 1
    }

    @discardableResult
    static func sweepExpired(on database: any Database, now: Date = Date()) async throws -> Int {
        guard let sql = database as? any SQLDatabase else { return 0 }
        struct DeletedCount: Decodable { let count: Int }
        let result = try await sql.raw(
            """
            WITH deleted AS (
              DELETE FROM idempotency_keys
              WHERE expires_at <= \(bind: now)
              RETURNING 1
            )
            SELECT COUNT(*) AS count FROM deleted
            """
        ).first(decoding: DeletedCount.self)
        return result?.count ?? 0
    }

    private static func deleteExpiredClaim(
        actor: MutationActor, key: String, now: Date, on sql: any SQLDatabase
    ) async throws {
        if let principalID = actor.id {
            try await sql.raw(
                """
                DELETE FROM idempotency_keys
                WHERE principal_type = \(bind: actor.type.rawValue)
                  AND principal_id = \(bind: principalID)
                  AND key = \(bind: key)
                  AND expires_at <= \(bind: now)
                """
            ).run()
        } else {
            try await sql.raw(
                """
                DELETE FROM idempotency_keys
                WHERE principal_type = \(bind: actor.type.rawValue)
                  AND principal_id IS NULL
                  AND key = \(bind: key)
                  AND expires_at <= \(bind: now)
                """
            ).run()
        }
    }
}

private struct IdempotencyRequestContextKey: StorageKey {
    typealias Value = IdempotencyRequestContext
}

extension Request {
    var idempotencyContext: IdempotencyRequestContext? {
        get { storage[IdempotencyRequestContextKey.self] }
        set { storage[IdempotencyRequestContextKey.self] = newValue }
    }
}

extension MutationActor {
    init(principal: IAMPrincipal) {
        switch principal.type {
        case .user:
            self = .user(principal.id)
        case .serviceAccount:
            self = .serviceAccount(principal.id)
        case .workload:
            self = .workload(principal.id)
        case .group:
            preconditionFailure("A group cannot act as an HTTP request principal")
        }
    }
}
