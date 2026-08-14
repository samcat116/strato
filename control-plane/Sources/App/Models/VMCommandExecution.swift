import Fluent
import Foundation
import StratoShared

/// Durable, frequently-polled state for one captured VM command. Output lives
/// in `vm_command_outputs` so normal operation queries never load a large blob.
final class VMCommandExecution: Model, @unchecked Sendable {
    static let schema = "vm_command_executions"

    @ID(key: .id) var id: UUID?
    @Field(key: "vm_id") var vmID: UUID
    @Enum(key: "actor_type") var actorType: MutationActorType
    @Field(key: "actor_id") var actorID: UUID
    @Field(key: "agent_key") var agentKey: String
    @Enum(key: "status") var status: VMOperationStatus
    @OptionalField(key: "error") var error: String?
    @Field(key: "deadline") var deadline: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "completed_at") var completedAt: Date?

    init() {}

    init(
        id: UUID = UUID(), vmID: UUID, actorID: UUID, agentKey: String,
        deadline: Date
    ) {
        self.id = id
        self.vmID = vmID
        self.actorType = .user
        self.actorID = actorID
        self.agentKey = agentKey
        self.status = .pending
        self.deadline = deadline
    }
}

/// Cold result payload for a completed command. One row at most per execution.
final class VMCommandOutput: Model, @unchecked Sendable {
    static let schema = "vm_command_outputs"

    @ID(custom: "execution_id", generatedBy: .user) var id: UUID?
    @Field(key: "stdout") var stdout: Data
    @Field(key: "stderr") var stderr: Data
    @Field(key: "exit_code") var exitCode: Int
    @Field(key: "truncated") var truncated: Bool

    init() {}

    init(executionID: UUID, stdout: Data, stderr: Data, exitCode: Int, truncated: Bool) {
        self.id = executionID
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.truncated = truncated
    }
}
