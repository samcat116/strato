import Fluent
import Foundation
import Vapor

/// A confirmation binds an immutable argv and resolved VM list to its initiator.
/// Entries are claimed before delivery: a crash may lose a dispatch, but never
/// replays a command with an unknown outcome.
final class VMFleetRun: Model, @unchecked Sendable {
    static let schema = "vm_fleet_runs"
    @ID(key: .id) var id: UUID?
    @Field(key: "actor_id") var actorID: UUID
    @OptionalField(key: "api_key_id") var apiKeyID: UUID?
    @Field(key: "command") var command: [String]
    @Field(key: "entries") var snapshot: VMFleetSnapshot
    var entries: [VMFleetEntry] {
        get { snapshot.values }
        set { snapshot = VMFleetSnapshot(values: newValue) }
    }
    @Field(key: "confirmed") var confirmed: Bool
    @Field(key: "deadline") var deadline: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(actorID: UUID, apiKeyID: UUID?, command: [String], entries: [VMFleetEntry], deadline: Date) {
        self.id = UUID()
        self.actorID = actorID
        self.apiKeyID = apiKeyID
        self.command = command
        self.snapshot = VMFleetSnapshot(values: entries)
        self.confirmed = false
        self.deadline = deadline
    }
}

struct VMFleetSnapshot: Codable, Sendable { var values: [VMFleetEntry] }

struct VMFleetEntry: Content, Equatable {
    var vmID: UUID
    var name: String?
    var state: String
    var reason: String?
    var operationID: UUID?
}

struct VMFleetRunResponse: Content {
    var id: UUID
    var command: [String]
    var confirmed: Bool
    var deadline: Date
    var entries: [VMFleetEntry]
    var operations: [OperationResponse]
    var complete: Bool
}
