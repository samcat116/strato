import Fluent
import Vapor
import StratoShared

/// Check the host-reported framework contract before desired state is persisted.
/// Placement and the agent recheck it because registrations can change later.
enum AppleVirtualizationValidation {
    static func requireMemory(
        _ memory: Int64, agentID: String? = nil, architecture: CPUArchitecture? = nil,
        pool: StoragePool? = nil, on db: any Database
    ) async throws {
        guard memory > 0, memory % (1 << 20) == 0 else {
            throw Abort(.badRequest, reason: "Apple Virtualization memory must be a positive multiple of 1 MiB")
        }
        var query = Agent.query(on: db)
        if let agentID, let id = UUID(uuidString: agentID) {
            query = query.filter(\.$id == id)
        } else if agentID != nil {
            throw Abort(.conflict, reason: "The VM's placed agent identity is invalid")
        }
        let agents = try await query.all()
        let members = pool?.memberAgentIds ?? []
        let compatible = agents.filter { agent in
            (agentID == nil || agent.id?.uuidString == agentID)
                && (architecture == nil || agent.cpuArchitecture == architecture)
                && (members.isEmpty || members.contains(agent.id?.uuidString ?? ""))
                && (pool?.$site.id == nil || agent.$site.id == pool?.$site.id)
        }
        guard
            compatible.contains(where: { agent in
                agent.hypervisors.contains {
                    $0.type == .appleVirtualization && $0.available && $0.supportsMemorySize(memory)
                }
            })
        else {
            throw Abort(
                .badRequest,
                reason:
                    "Apple Virtualization memory is outside the registered hosts' reported bounds; "
                    + "register a compatible host before creating or resizing this VM")
        }
    }
}
