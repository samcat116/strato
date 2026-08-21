import Foundation
import PostgresNIO

public struct DecisionLogWrite: Sendable {
    public let id: UUID
    public let requestID: String?
    public let path: String?
    public let method: String?
    public let subject: String
    public let action: String?
    public let nodeType: String?
    public let nodeID: UUID?
    public let organizationID: UUID?
    public let decision: String
    public let determiningPolicies: [String]
    public let tier: String?
    public let cedarErrors: String?
    public let policyVersion: Int?
    public let skippedConditionedBindings: Int?
    public let credentialType: String?
    public let credentialID: UUID?
    /// Nil for normal writes, which use PostgreSQL `CURRENT_TIMESTAMP`.
    public let createdAt: Date?

    public init(
        id: UUID = UUID(),
        requestID: String? = nil,
        path: String? = nil,
        method: String? = nil,
        subject: String,
        action: String? = nil,
        nodeType: String? = nil,
        nodeID: UUID? = nil,
        organizationID: UUID? = nil,
        decision: String,
        determiningPolicies: [String] = [],
        tier: String? = nil,
        cedarErrors: String? = nil,
        policyVersion: Int? = nil,
        skippedConditionedBindings: Int? = nil,
        credentialType: String? = nil,
        credentialID: UUID? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.path = path
        self.method = method
        self.subject = subject
        self.action = action
        self.nodeType = nodeType
        self.nodeID = nodeID
        self.organizationID = organizationID
        self.decision = decision
        self.determiningPolicies = determiningPolicies
        self.tier = tier
        self.cedarErrors = cedarErrors
        self.policyVersion = policyVersion
        self.skippedConditionedBindings = skippedConditionedBindings
        self.credentialType = credentialType
        self.credentialID = credentialID
        self.createdAt = createdAt
    }

    /// Re-emit an immutable fact with an explicit timestamp. This supports
    /// imports and parity/retention tests without exposing row mutation.
    public init(copying snapshot: DecisionLogSnapshot, createdAt: Date) {
        self.init(
            id: snapshot.id,
            requestID: snapshot.requestID,
            path: snapshot.path,
            method: snapshot.method,
            subject: snapshot.subject,
            action: snapshot.action,
            nodeType: snapshot.nodeType,
            nodeID: snapshot.nodeID,
            organizationID: snapshot.organizationID,
            decision: snapshot.decision,
            determiningPolicies: snapshot.determiningPolicies,
            tier: snapshot.tier,
            cedarErrors: snapshot.cedarErrors,
            policyVersion: snapshot.policyVersion,
            skippedConditionedBindings: snapshot.skippedConditionedBindings,
            credentialType: snapshot.credentialType,
            credentialID: snapshot.credentialID,
            createdAt: createdAt
        )
    }
}

public struct DecisionLogSnapshot: Equatable, Sendable {
    public let id: UUID
    public let requestID: String?
    public let path: String?
    public let method: String?
    public let subject: String
    public let action: String?
    public let nodeType: String?
    public let nodeID: UUID?
    public let organizationID: UUID?
    public let decision: String
    public let determiningPolicies: [String]
    public let tier: String?
    public let cedarErrors: String?
    public let policyVersion: Int?
    public let skippedConditionedBindings: Int?
    public let credentialType: String?
    public let credentialID: UUID?
    public let createdAt: Date?
}

public struct DecisionLogFilter: Equatable, Sendable {
    public var nodeID: UUID?
    public var action: String?
    public var decision: String?
    public var credentialID: UUID?
    public var createdBefore: Date?
    public var subject: String?

    public init(
        nodeID: UUID? = nil,
        action: String? = nil,
        decision: String? = nil,
        credentialID: UUID? = nil,
        createdBefore: Date? = nil,
        subject: String? = nil
    ) {
        self.nodeID = nodeID
        self.action = action
        self.decision = decision
        self.credentialID = credentialID
        self.createdBefore = createdBefore
        self.subject = subject
    }
}

public struct DecisionLogPage: Equatable, Sendable {
    public let entries: [DecisionLogSnapshot]
    public let total: Int
}

public struct DecisionLogSummary: Equatable, Sendable {
    public let action: String?
    public let decision: String
    public let tier: String?
    public let count: Int
}

/// Append-only authorization-decision persistence with its owned operator
/// queries and retention operation.
public struct DecisionLogsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func append(_ entries: [DecisionLogWrite]) async throws -> [DecisionLogSnapshot] {
        guard !entries.isEmpty else { return [] }
        return try await database.withSession(operation: "decision_logs.append") { session in
            try await session.execute(
                AppendDecisionLogs(entries: entries),
                operation: "decision_logs.append.query"
            ).map(\.snapshot)
        }
    }

    public func entries(
        matching filter: DecisionLogFilter = .init(),
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> DecisionLogPage {
        precondition(limit > 0)
        precondition(offset >= 0)
        return try await database.withSession(operation: "decision_logs.list") { session in
            let totalRows = try await session.execute(
                CountDecisionLogs(filter: filter),
                operation: "decision_logs.list.count"
            )
            guard totalRows.count == 1, let total = totalRows.first else {
                throw DecisionLogRowCountError(expected: 1, actual: totalRows.count)
            }
            let rows = try await session.execute(
                ListDecisionLogs(filter: filter, limit: limit, offset: offset),
                operation: "decision_logs.list.query"
            )
            return DecisionLogPage(entries: rows.map(\.snapshot), total: total)
        }
    }

    public func summary(createdAtOrAfter since: Date, limit: Int) async throws
        -> [DecisionLogSummary]
    {
        precondition(limit > 0)
        return try await database.withSession(operation: "decision_logs.summary") { session in
            try await session.execute(
                SummarizeDecisionLogs(since: since, limit: limit),
                operation: "decision_logs.summary.query"
            )
        }
    }

    /// Delete old rows and return the exact number deleted from `RETURNING`.
    public func delete(createdBefore cutoff: Date) async throws -> Int {
        try await database.withSession(operation: "decision_logs.retention") { session in
            try await session.execute(
                DeleteExpiredDecisionLogs(cutoff: cutoff),
                operation: "decision_logs.retention.delete"
            ).count
        }
    }
}

private struct DecisionLogRecord: Sendable {
    let id: UUID
    let requestID: String?
    let path: String?
    let method: String?
    let subject: String
    let action: String?
    let nodeType: String?
    let nodeID: UUID?
    let organizationID: UUID?
    let decision: String
    let determiningPoliciesJSON: String?
    let tier: String?
    let cedarErrors: String?
    let policyVersion: Int?
    let skippedConditionedBindings: Int?
    let credentialType: String?
    let credentialID: UUID?
    let createdAt: Date?

    init(row: PostgresRow) throws {
        (
            id, requestID, path, method, subject, action, nodeType, nodeID,
            organizationID, decision, determiningPoliciesJSON, tier,
            cedarErrors, policyVersion, skippedConditionedBindings,
            credentialType, credentialID, createdAt
        ) = try row.decode((
            UUID, String?, String?, String?, String, String?, String?, UUID?,
            UUID?, String, String?, String?, String?, Int?, Int?, String?, UUID?, Date?
        ).self)
    }

    var snapshot: DecisionLogSnapshot {
        DecisionLogSnapshot(
            id: id,
            requestID: requestID,
            path: path,
            method: method,
            subject: subject,
            action: action,
            nodeType: nodeType,
            nodeID: nodeID,
            organizationID: organizationID,
            decision: decision,
            determiningPolicies: determiningPoliciesJSON.flatMap { json in
                guard let data = json.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode([String].self, from: data)
            } ?? [],
            tier: tier,
            cedarErrors: cedarErrors,
            policyVersion: policyVersion,
            skippedConditionedBindings: skippedConditionedBindings,
            credentialType: credentialType,
            credentialID: credentialID,
            createdAt: createdAt
        )
    }
}

private let decisionLogColumns = """
    id, request_id, path, method, subject, action, node_type, node_id,
    organization_id, decision, determining_policies, tier, cedar_errors,
    policy_version, skipped_conditioned_bindings, credential_type,
    credential_id, created_at
    """

private struct DecisionLogBatchJSON: Encodable, PostgresEncodable, Sendable {
    let entries: [DecisionLogWriteJSON]

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}

private struct DecisionLogWriteJSON: Encodable, Sendable {
    let id: UUID
    let requestID: String?
    let path: String?
    let method: String?
    let subject: String
    let action: String?
    let nodeType: String?
    let nodeID: UUID?
    let organizationID: UUID?
    let decision: String
    let determiningPolicies: String?
    let tier: String?
    let cedarErrors: String?
    let policyVersion: Int?
    let skippedConditionedBindings: Int?
    let credentialType: String?
    let credentialID: UUID?
    let createdAt: String?

    init(_ entry: DecisionLogWrite) throws {
        id = entry.id
        requestID = entry.requestID
        path = entry.path
        method = entry.method
        subject = entry.subject
        action = entry.action
        nodeType = entry.nodeType
        nodeID = entry.nodeID
        organizationID = entry.organizationID
        decision = entry.decision
        determiningPolicies = entry.determiningPolicies.isEmpty
            ? nil
            : String(data: try JSONEncoder().encode(entry.determiningPolicies), encoding: .utf8)
        tier = entry.tier
        cedarErrors = entry.cedarErrors
        policyVersion = entry.policyVersion
        skippedConditionedBindings = entry.skippedConditionedBindings
        credentialType = entry.credentialType
        credentialID = entry.credentialID
        createdAt = entry.createdAt?.ISO8601Format(.iso8601(timeZone: .gmt))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case requestID = "request_id"
        case path
        case method
        case subject
        case action
        case nodeType = "node_type"
        case nodeID = "node_id"
        case organizationID = "organization_id"
        case decision
        case determiningPolicies = "determining_policies"
        case tier
        case cedarErrors = "cedar_errors"
        case policyVersion = "policy_version"
        case skippedConditionedBindings = "skipped_conditioned_bindings"
        case credentialType = "credential_type"
        case credentialID = "credential_id"
        case createdAt = "created_at"
    }
}

private struct AppendDecisionLogs: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO iam_decision_logs (
            id, request_id, path, method, subject, action, node_type, node_id,
            organization_id, decision, determining_policies, tier, cedar_errors,
            policy_version, skipped_conditioned_bindings, credential_type,
            credential_id, created_at
        )
        SELECT input.id, input.request_id, input.path, input.method,
               input.subject, input.action, input.node_type, input.node_id,
               input.organization_id, input.decision,
               input.determining_policies, input.tier, input.cedar_errors,
               input.policy_version, input.skipped_conditioned_bindings,
               input.credential_type, input.credential_id,
               COALESCE(input.created_at, CURRENT_TIMESTAMP)
        FROM jsonb_to_recordset($1) AS input(
            id UUID,
            request_id TEXT,
            path TEXT,
            method TEXT,
            subject TEXT,
            action TEXT,
            node_type TEXT,
            node_id UUID,
            organization_id UUID,
            decision TEXT,
            determining_policies TEXT,
            tier TEXT,
            cedar_errors TEXT,
            policy_version BIGINT,
            skipped_conditioned_bindings BIGINT,
            credential_type TEXT,
            credential_id UUID,
            created_at TIMESTAMPTZ
        )
        RETURNING \(decisionLogColumns)
        """

    typealias Row = DecisionLogRecord
    let entries: [DecisionLogWrite]

    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        try bindings.append(DecisionLogBatchJSON(entries: try entries.map(DecisionLogWriteJSON.init)))
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> DecisionLogRecord {
        try DecisionLogRecord(row: row)
    }
}

private protocol FilteredDecisionLogsStatement: PostgresPreparedStatement {}

private extension FilteredDecisionLogsStatement {
    static var filterSQL: String {
        """
        ($1::uuid IS NULL OR node_id = $1)
        AND ($2::text IS NULL OR action = $2)
        AND ($3::text IS NULL OR decision = $3)
        AND ($4::uuid IS NULL OR credential_id = $4)
        AND ($5::timestamptz IS NULL OR created_at < $5)
        AND ($6::text IS NULL OR subject = $6)
        """
    }

    static var filterBindingDataTypes: [PostgresDataType] {
        [.uuid, .text, .text, .uuid, .timestamptz, .text]
    }
}

private func decisionLogBindings(
    _ filter: DecisionLogFilter, capacity: Int = 6
) -> PostgresBindings {
    var bindings = PostgresBindings(capacity: capacity)
    bindings.append(filter.nodeID)
    bindings.append(filter.action)
    bindings.append(filter.decision)
    bindings.append(filter.credentialID)
    bindings.append(filter.createdBefore)
    bindings.append(filter.subject)
    return bindings
}

private struct CountDecisionLogs: FilteredDecisionLogsStatement {
    static var sql: String { "SELECT count(*)::bigint FROM iam_decision_logs WHERE \(filterSQL)" }
    static let bindingDataTypes = filterBindingDataTypes
    typealias Row = Int
    let filter: DecisionLogFilter

    func makeBindings() -> PostgresBindings { decisionLogBindings(filter) }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct ListDecisionLogs: FilteredDecisionLogsStatement {
    static var sql: String {
        """
        SELECT \(decisionLogColumns)
        FROM iam_decision_logs
        WHERE \(filterSQL)
        ORDER BY created_at DESC, id DESC
        LIMIT $7 OFFSET $8
        """
    }
    static let bindingDataTypes = filterBindingDataTypes + [.int8, .int8]
    typealias Row = DecisionLogRecord
    let filter: DecisionLogFilter
    let limit: Int
    let offset: Int

    func makeBindings() -> PostgresBindings {
        var bindings = decisionLogBindings(filter, capacity: 8)
        bindings.append(limit)
        bindings.append(offset)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> DecisionLogRecord {
        try DecisionLogRecord(row: row)
    }
}

private struct SummarizeDecisionLogs: PostgresPreparedStatement {
    static let sql = """
        SELECT action, decision, tier, count(*)::bigint
        FROM iam_decision_logs
        WHERE created_at >= $1
        GROUP BY action, decision, tier
        ORDER BY count(*) DESC
        LIMIT $2
        """
    static let bindingDataTypes: [PostgresDataType] = [.timestamptz, .int8]
    typealias Row = DecisionLogSummary
    let since: Date
    let limit: Int

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(since)
        bindings.append(limit)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> DecisionLogSummary {
        let decoded = try row.decode((String?, String, String?, Int).self)
        return DecisionLogSummary(
            action: decoded.0,
            decision: decoded.1,
            tier: decoded.2,
            count: decoded.3
        )
    }
}

private struct DeleteExpiredDecisionLogs: PostgresPreparedStatement {
    static let sql = "DELETE FROM iam_decision_logs WHERE created_at < $1 RETURNING id"
    typealias Row = UUID
    let cutoff: Date

    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(cutoff)
        return bindings
    }

    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct DecisionLogRowCountError: Error, Sendable {
    let expected: Int
    let actual: Int
}
