import Fluent
import Foundation
import StratoShared

/// Durable, frequently-polled state for one captured VM command. The invoked
/// argv and output live in `vm_command_payloads` so normal operation queries
/// never load either potentially large payload.
final class VMCommandExecution: Model, @unchecked Sendable {
    static let schema = "vm_command_executions"

    @ID(key: .id) var id: UUID?
    @Field(key: "vm_id") var vmID: UUID
    @Enum(key: "actor_type") var actorType: MutationActorType
    @Field(key: "actor_id") var actorID: UUID
    /// Request-time identity snapshots retained for asynchronous completion
    /// audit events. These deliberately have no foreign keys: the audit fact
    /// must remain attributable after a user, API key, or organization changes.
    @OptionalField(key: "actor_username") var actorUsername: String?
    @OptionalField(key: "api_key_id") var apiKeyID: UUID?
    @OptionalField(key: "organization_id") var organizationID: UUID?
    @OptionalField(key: "source_ip") var sourceIP: String?
    @Field(key: "admin_bypass") var adminBypass: Bool
    @Field(key: "agent_key") var agentKey: String
    @Enum(key: "status") var status: VMOperationStatus
    @OptionalField(key: "error") var error: String?
    /// Durable timeout provenance. Error text is operator-facing and cannot
    /// safely distinguish a sweeper timeout from an agent-supplied reason.
    @Field(key: "timed_out_by_sweeper") var timedOutBySweeper: Bool
    @Field(key: "deadline") var deadline: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "completed_at") var completedAt: Date?

    init() {}

    init(
        id: UUID = UUID(), vmID: UUID, actorID: UUID, agentKey: String,
        deadline: Date,
        actorUsername: String? = nil,
        apiKeyID: UUID? = nil,
        organizationID: UUID? = nil,
        sourceIP: String? = nil,
        adminBypass: Bool = false
    ) {
        self.id = id
        self.vmID = vmID
        self.actorType = .user
        self.actorID = actorID
        self.actorUsername = actorUsername
        self.apiKeyID = apiKeyID
        self.organizationID = organizationID
        self.sourceIP = sourceIP
        self.adminBypass = adminBypass
        self.agentKey = agentKey
        self.status = .pending
        self.timedOutBySweeper = false
        self.deadline = deadline
    }
}

/// Cold invocation and result payload. Created atomically with the execution so
/// the exact argv survives restarts; result fields remain nil until completion.
final class VMCommandPayload: Model, @unchecked Sendable {
    static let schema = "vm_command_payloads"

    @ID(custom: "execution_id", generatedBy: .user) var id: UUID?
    @Field(key: "command") var command: [String]
    @OptionalField(key: "stdout") var stdout: Data?
    @OptionalField(key: "stderr") var stderr: Data?
    @OptionalField(key: "exit_code") var exitCode: Int?
    @OptionalField(key: "truncated") var truncated: Bool?
    /// Agent-owned monotonic revision for authoritative recorded-command
    /// snapshots. Nil identifies the legacy incremental-frame fallback.
    @OptionalField(key: "result_revision") var resultRevision: Int64?

    init() {}

    init(executionID: UUID, command: [String]) {
        self.id = executionID
        self.command = command
    }

}
