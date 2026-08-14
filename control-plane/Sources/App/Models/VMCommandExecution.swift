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

    init() {}

    init(executionID: UUID, command: [String]) {
        self.id = executionID
        self.command = command
    }

    func recordResult(stdout: Data, stderr: Data, exitCode: Int, truncated: Bool) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.truncated = truncated
    }
}
