import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Comma-separated intersecting filters, or an explicit semicolon-separated
/// list. Environment/tag selectors require a project to keep resolution bounded
/// to a tenant subtree. Unknown/duplicate filters fail closed.
struct VMFleetSelector: Sendable {
    var projectID: UUID?
    var environment: String?
    var tag: (String, String)?
    var ids: [UUID]?

    init(_ raw: String) throws {
        guard raw.utf8.count <= 8192, !raw.isEmpty else { throw Abort(.badRequest, reason: "Invalid selector") }
        var seen = Set<String>()
        for term in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let pair = term.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !pair[1].isEmpty else { throw Abort(.badRequest, reason: "Invalid selector term") }
            let key = String(pair[0])
            guard seen.insert(key.hasPrefix("tag:") ? "tag" : key).inserted else {
                throw Abort(.badRequest, reason: "Duplicate selector filter")
            }
            switch key {
            case "project":
                guard let id = UUID(uuidString: String(pair[1])) else {
                    throw Abort(.badRequest, reason: "Invalid project ID")
                }
                projectID = id
            case "environment": environment = String(pair[1])
            case "ids":
                let values = pair[1].split(separator: ";", omittingEmptySubsequences: false)
                guard (1...VMFleetRunController.maxTargets).contains(values.count) else {
                    throw Abort(.badRequest, reason: "Too many VM IDs")
                }
                ids = try values.map {
                    guard let id = UUID(uuidString: String($0)) else {
                        throw Abort(.badRequest, reason: "Invalid VM ID")
                    }
                    return id
                }
                guard Set(ids!).count == ids!.count else { throw Abort(.badRequest, reason: "Duplicate VM ID") }
            default:
                guard key.hasPrefix("tag:"), key.count > 4 else {
                    throw Abort(.badRequest, reason: "Unknown selector filter")
                }
                tag = (String(key.dropFirst(4)), String(pair[1]))
            }
        }
        guard (ids != nil && seen.count == 1) || (ids == nil && projectID != nil) else {
            throw Abort(
                .badRequest, reason: "Use ids=<uuid;uuid> or project=<uuid>[,environment=<name>][,tag:<key>=<value>]")
        }
    }
}

struct VMFleetPrepareRequest: Content { var selector: String; var command: [String] }
struct VMFleetConfirmRequest: Content { var vmIDs: [UUID] }

struct VMFleetRunController: RouteCollection {
    static let maxTargets = 100
    static let concurrency = 8
    func boot(routes: any RoutesBuilder) throws {
        let runs = routes.grouped("api", "vm-fleet-runs")
        runs.post(use: prepare)
        runs.get(":runID", use: show)
        runs.post(":runID", "confirm", use: confirm)
    }

    func prepare(req: Request) async throws -> VMFleetRunResponse {
        let user = try req.requireActingUser("Preparing a fleet run")
        let body = try req.content.decode(VMFleetPrepareRequest.self)
        var run = VMRunCommandRequest(command: body.command)
        try run.validate()
        let selector = try VMFleetSelector(body.selector)
        var query = VM.query(on: req.db)
        var hasReadableExplicitTargets = true
        if let projectID = selector.projectID {
            guard try await req.can("project:read", on: IAMNode(type: .project, id: projectID)) else {
                throw Abort(.notFound, reason: "Project not found")
            }
            query = query.filter(\.$project.$id == projectID)
        } else if let ids = selector.ids {
            // Authorize opaque IDs before loading VM rows across projects.
            let readable = try await req.canFilter("vm:read", on: ids.map { IAMNode(type: .virtualMachine, id: $0) })
            let permittedIDs = ids.filter { readable.contains(IAMNode(type: .virtualMachine, id: $0)) }
            hasReadableExplicitTargets = !permittedIDs.isEmpty
            query = query.filter(\.$id ~~ permittedIDs)
        }
        if let environment = selector.environment { query = query.filter(\.$environment == environment) }
        // Apply the tag in SQL, before the target limit; metadata is never an IAM claim.
        if let (key, value) = selector.tag {
            let tagJSON = String(decoding: try JSONEncoder().encode([key: value]), as: UTF8.self)
            query = query.filter(.sql(embed: "tags @> \(bind: tagJSON)::jsonb"))
        }
        let vms = hasReadableExplicitTargets ? try await query.sort(\.$id).limit(Self.maxTargets + 1).all() : []
        guard vms.count <= Self.maxTargets else {
            throw Abort(.badRequest, reason: "Selector exceeds 100 VMs; narrow it")
        }
        let nodes = vms.compactMap { $0.id.map { IAMNode(type: .virtualMachine, id: $0) } }
        let readable = try await req.canFilter("vm:read", on: nodes)
        let allowed = try await req.canFilter("vm:runCommand", on: nodes)
        var entries = vms.compactMap { vm -> VMFleetEntry? in
            guard let id = vm.id else { return nil }
            let node = IAMNode(type: .virtualMachine, id: id)
            // An explicit unreadable/missing ID has the same opaque outcome.
            guard readable.contains(node) else { return nil }
            return VMFleetEntry(
                vmID: id, name: vm.name, state: allowed.contains(node) ? "ready" : "skipped",
                reason: allowed.contains(node) ? nil : "Not authorized to run commands")
        }
        if let ids = selector.ids {
            let visible = Set(entries.map(\.vmID))
            entries += ids.filter { !visible.contains($0) }.map {
                VMFleetEntry(vmID: $0, state: "skipped", reason: "VM is missing or inaccessible")
            }
        }
        guard !entries.isEmpty else { throw Abort(.badRequest, reason: "Selector matched no visible VMs") }
        let now = try await ClusterClock.read(on: req.db)
        let fleet = VMFleetRun(
            actorID: try user.requireID(), apiKeyID: req.apiKey?.id,
            command: run.command, entries: entries, deadline: now.date.addingTimeInterval(600))
        try await fleet.create(on: req.db)
        return try await response(fleet, on: req.db)
    }

    private func owned(req: Request, on db: any Database) async throws -> VMFleetRun {
        let user = try req.requireActingUser("Reading a fleet run")
        guard let id = req.parameters.get("runID", as: UUID.self),
            let fleet = try await VMFleetRun.query(on: db).filter(\.$id == id)
                .filter(\.$actorID == user.requireID()).first(),
            fleet.apiKeyID == req.apiKey?.id
        else { throw Abort(.notFound, reason: "Fleet run not found") }
        return fleet
    }

    func show(req: Request) async throws -> VMFleetRunResponse {
        let fleet = try await owned(req: req, on: req.db)
        return try await response(fleet, on: req.db)
    }

    func confirm(req: Request) async throws -> Response {
        let body = try req.content.decode(VMFleetConfirmRequest.self)
        let (id, audits) = try await req.db.transaction { db -> (UUID, [VMGuestExecutionAuditContext]) in
            let fleet = try await owned(req: req, on: db)
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("SELECT id FROM vm_fleet_runs WHERE id = \(bind: fleet.requireID()) FOR UPDATE").run()
            guard let current = try await VMFleetRun.find(fleet.requireID(), on: db) else { throw Abort(.notFound) }
            guard Set(body.vmIDs) == Set(current.entries.map(\.vmID)), body.vmIDs.count == current.entries.count else {
                throw Abort(.conflict, reason: "Confirm the exact resolved VM list")
            }
            // Repeated confirmation observes the same children, never redispatches.
            if current.confirmed { return (try current.requireID(), []) }
            let now = try await ClusterClock.read(on: db)
            guard current.deadline > now.date else {
                throw Abort(.conflict, reason: "Fleet preview expired; resolve again")
            }
            var audits: [VMGuestExecutionAuditContext] = []
            for index in current.entries.indices where current.entries[index].state == "ready" {
                do {
                    let vmID = current.entries[index].vmID
                    _ = try await req.authorizedVM(vmID, action: "vm:read")
                    let execution = try await VMController().acceptRunCommand(
                        req: req, vmID: vmID,
                        run: VMRunCommandRequest(command: current.command), on: db, recordAudit: false)
                    // Queue deadlines are separate from a dispatched child's capture budget.
                    execution.deadline = now.date.addingTimeInterval(7200)
                    try await execution.save(on: db)
                    audits.append(
                        VMGuestExecutionAuditContext(
                            vmID: execution.vmID,
                            organizationID: execution.organizationID, userID: execution.actorID,
                            username: execution.actorUsername, apiKeyID: execution.apiKeyID,
                            sourceIP: execution.sourceIP, adminBypass: execution.adminBypass,
                            correlationID: try execution.requireID().uuidString, argv: current.command))
                    current.entries[index].operationID = try execution.requireID()
                    current.entries[index].state = "queued"
                } catch let error as Abort {
                    current.entries[index].state = "skipped"
                    current.entries[index].reason =
                        error.status == .forbidden || error.status == .notFound
                        ? "VM is missing or no longer authorized" : error.reason
                }
            }
            current.confirmed = true
            current.deadline = now.date.addingTimeInterval(7200)
            try await current.save(on: db)
            return (try current.requireID(), audits)
        }
        for audit in audits {
            await req.audit.recordFailOpen(VMGuestExecutionAudit.makeCommandRequestedRecord(audit))
        }
        try await VMFleetRunDispatcher.advance(id: id, app: req.application)
        let fleet = try await owned(req: req, on: req.db)
        let result = Response(status: .accepted)
        try result.content.encode(try await response(fleet, on: req.db))
        return result
    }

    func response(_ fleet: VMFleetRun, on db: any Database) async throws -> VMFleetRunResponse {
        let ids = fleet.entries.compactMap(\.operationID)
        let executions = ids.isEmpty ? [] : try await VMCommandExecution.query(on: db).filter(\.$id ~~ ids).all()
        // Project bounded excerpts in PostgreSQL: batch terminal output without
        // loading up to 100 MiB of full payloads into a fleet poll.
        let terminalIDs = executions.filter { $0.status != .pending }.compactMap(\.id)
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let rows =
            terminalIDs.isEmpty
            ? []
            : try await sql.raw(
                """
                SELECT execution_id AS id, substring(stdout FROM 1 FOR 4096) AS stdout,
                    substring(stderr FROM 1 FOR 4096) AS stderr, exit_code AS "exitCode",
                    (truncated OR octet_length(stdout) > 4096 OR octet_length(stderr) > 4096) AS truncated
                FROM vm_command_payloads WHERE execution_id = ANY(\(bind: terminalIDs))
                """
            ).all(decoding: VMFleetResultRow.self)
        let results = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let operations = try executions.map { execution in
            let operation = try execution.operationResponse(payload: nil)
            let excerpt = execution.id.flatMap { results[$0]?.response }
            return OperationResponse(
                id: operation.id, resourceKind: operation.resourceKind,
                resourceID: operation.resourceId, kind: operation.kind, status: operation.status,
                error: operation.error, createdAt: operation.createdAt, completedAt: operation.completedAt,
                result: excerpt)
        }
        let pending = executions.contains { $0.status == .pending }
        return VMFleetRunResponse(
            id: try fleet.requireID(), command: fleet.command, confirmed: fleet.confirmed,
            deadline: fleet.deadline, entries: fleet.entries, operations: operations,
            complete: fleet.confirmed && !pending && !fleet.entries.contains { $0.state == "queued" })
    }
}

private struct VMFleetResultRow: Decodable {
    var id: UUID
    var stdout: Data?
    var stderr: Data?
    var exitCode: Int?
    var truncated: Bool?
    var response: VMCommandResultResponse? {
        guard let stdout, let stderr, let truncated else { return nil }
        return VMCommandResultResponse(
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self), exitCode: exitCode, truncated: truncated)
    }
}
