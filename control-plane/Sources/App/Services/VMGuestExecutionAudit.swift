import Fluent
import Foundation
import Vapor

/// Immutable attribution retained from the request that accepted a VM guest
/// execution. Durable commands persist these fields on `VMCommandExecution`;
/// interactive sessions carry the same value through their in-memory lifecycle.
///
/// The deliberately narrow shape is also the privacy boundary: environment,
/// working directory, terminal input/output, and wire frames cannot enter an
/// audit record through this context.
struct VMGuestExecutionAuditContext: Sendable {
    let vmID: UUID
    let organizationID: UUID?
    let userID: UUID?
    let username: String?
    let apiKeyID: UUID?
    let sourceIP: String?
    let adminBypass: Bool
    let correlationID: String
    let argv: [String]

    init(
        vmID: UUID,
        organizationID: UUID? = nil,
        userID: UUID? = nil,
        username: String? = nil,
        apiKeyID: UUID? = nil,
        sourceIP: String? = nil,
        adminBypass: Bool = false,
        correlationID: String,
        argv: [String]
    ) {
        self.vmID = vmID
        self.organizationID = organizationID
        self.userID = userID
        self.username = username
        self.apiKeyID = apiKeyID
        self.sourceIP = sourceIP
        self.adminBypass = adminBypass
        self.correlationID = correlationID
        self.argv = argv
    }
}

/// Constructs and records the approved STR-84 event vocabulary.
///
/// Callers own execution state transitions. This component owns only canonical
/// event names, metadata encoding, privacy bounds, and fail-open delivery through
/// `AuditService`.
enum VMGuestExecutionAudit {
    enum CommandOutcome: String, Sendable {
        case exited
        case failed
        case timedOut = "timed_out"
    }

    enum ExecEndOutcome: String, Sendable {
        case exited
        case refused
        case timedOut = "timed_out"
        case disconnected
        case terminated
    }

    /// Unicode-scalar ceiling, matching the repository's persisted-text bounds.
    /// `String.count` is not a bound because one grapheme may contain an
    /// arbitrary number of combining scalars.
    static let maxReasonCharacters = 1_024
    private static let maxReasonInputScalars = maxReasonCharacters * 4

    /// Build the request-owned context without making an audit-only database
    /// lookup part of execution acceptance. VM authorization has already
    /// resolved and cached the resource's project-to-organization chain; a
    /// missing/truncated cache entry leaves `organizationID` absent while every
    /// other attribution field still lands.
    static func makeContext(
        vmID: UUID,
        projectID: UUID,
        correlationID: String,
        argv: [String],
        on request: Request
    ) -> VMGuestExecutionAuditContext {
        let projectNode = IAMNode(type: .project, id: projectID)
        let organizationID = request.iamCache.chain(of: projectNode)?.chain.first {
            $0.type == .organization
        }?.id

        if organizationID == nil {
            request.logger.warning(
                "VM organization was absent from the authorization cache for guest execution audit",
                metadata: [
                    "strato.vm.id": .string(vmID.uuidString),
                    "strato.project.id": .string(projectID.uuidString),
                ])
        }

        let user = request.auth.get(User.self)
        return VMGuestExecutionAuditContext(
            vmID: vmID,
            organizationID: organizationID,
            userID: user?.id,
            username: user?.username,
            apiKeyID: request.apiKey?.id,
            sourceIP: request.auditClientIP,
            adminBypass: request.adminBypassUsed,
            correlationID: correlationID,
            argv: argv)
    }

    /// Accepted-only request fact. Authorization and validation refusals remain
    /// in the generic `api.request` trail, which surrounds authorization.
    static func makeCommandRequestedRecord(
        _ context: VMGuestExecutionAuditContext
    ) -> AuditRecord {
        makeRecord(
            .vmCommandRequested,
            context: context,
            action: "vm:runCommand",
            method: "POST",
            path: "/api/vms/\(context.vmID.uuidString)/actions/run",
            status: 202,
            metadata: metadata(context: context, outcome: "accepted", phase: "requested"))
    }

    static func makeCommandCompletedRecord(
        _ context: VMGuestExecutionAuditContext,
        outcome: CommandOutcome,
        exitCode: Int? = nil,
        reason: String? = nil,
        correctsOutcome: CommandOutcome? = nil,
        timestamp: Date = Date()
    ) -> AuditRecord {
        makeRecord(
            .vmCommandCompleted,
            context: context,
            action: "vm:runCommand",
            timestamp: timestamp,
            metadata: metadata(
                context: context,
                outcome: outcome.rawValue,
                phase: "completed",
                exitCode: exitCode,
                reason: reason,
                correctsOutcome: correctsOutcome?.rawValue))
    }

    /// Accepted-only mint fact. A WebSocket attach does not create another
    /// request event; its agent-confirmed lifecycle begins at `vm.exec.started`.
    static func makeExecRequestedRecord(
        _ context: VMGuestExecutionAuditContext
    ) -> AuditRecord {
        makeRecord(
            .vmExecRequested,
            context: context,
            action: "vm:exec",
            method: "POST",
            path: "/api/vms/\(context.vmID.uuidString)/exec",
            status: 201,
            metadata: metadata(context: context, outcome: "accepted", phase: "requested"))
    }

    static func makeExecStartedRecord(
        _ context: VMGuestExecutionAuditContext,
        timestamp: Date = Date()
    ) -> AuditRecord {
        makeRecord(
            .vmExecStarted,
            context: context,
            action: "vm:exec",
            timestamp: timestamp,
            metadata: metadata(context: context, outcome: "started", phase: "started"))
    }

    static func makeExecEndedRecord(
        _ context: VMGuestExecutionAuditContext,
        outcome: ExecEndOutcome,
        exitCode: Int? = nil,
        reason: String? = nil,
        timestamp: Date = Date()
    ) -> AuditRecord {
        makeRecord(
            .vmExecEnded,
            context: context,
            action: "vm:exec",
            timestamp: timestamp,
            metadata: metadata(
                context: context,
                outcome: outcome.rawValue,
                phase: "ended",
                exitCode: exitCode,
                reason: reason))
    }

    private static func makeRecord(
        _ type: AuditEventType,
        context: VMGuestExecutionAuditContext,
        action: String,
        method: String? = nil,
        path: String? = nil,
        status: Int? = nil,
        timestamp: Date = Date(),
        metadata: [String: String]
    ) -> AuditRecord {
        AuditRecord(
            eventType: type.rawValue,
            timestamp: timestamp,
            userID: context.userID,
            username: context.username,
            apiKeyID: context.apiKeyID,
            organizationID: context.organizationID,
            method: method,
            path: path,
            status: status,
            resourceType: "vms",
            resourceID: context.vmID.uuidString,
            action: action,
            sourceIP: context.sourceIP,
            adminBypass: context.adminBypass,
            metadata: metadata)
    }

    private static func metadata(
        context: VMGuestExecutionAuditContext,
        outcome: String,
        phase: String,
        exitCode: Int? = nil,
        reason: String? = nil,
        correctsOutcome: String? = nil
    ) -> [String: String] {
        var metadata = [
            "argv": encodedArgv(context.argv),
            "correlationID": context.correlationID,
            "outcome": outcome,
            "phase": phase,
        ]
        if let exitCode {
            metadata["exitCode"] = String(exitCode)
        }
        if let reason, let bounded = boundedReason(reason) {
            metadata["reason"] = bounded
        }
        if let correctsOutcome {
            metadata["correctsOutcome"] = correctsOutcome
        }
        return metadata
    }

    private static func encodedArgv(_ argv: [String]) -> String {
        // JSONEncoder cannot fail for an array whose only element type is
        // String. Accepted events must retain the exact argv, not replace a
        // large but valid command with a lossy marker.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = try! encoder.encode(argv)
        return String(decoding: data, as: UTF8.self)
    }

    private static func boundedReason(_ reason: String) -> String? {
        var normalized = String.UnicodeScalarView()
        var normalizedCount = 0
        var needsSeparator = false

        // Normalize while retaining only bounded input and output. Building a
        // complete normalized copy before truncation would let an untrusted
        // agent reason amplify memory on the fail-open producer path.
        for scalar in reason.unicodeScalars.prefix(maxReasonInputScalars) {
            if scalar.properties.isWhitespace {
                needsSeparator = normalizedCount > 0
                continue
            }

            if needsSeparator && normalizedCount + 1 < maxReasonCharacters {
                normalized.append(" ")
                normalizedCount += 1
            }
            needsSeparator = false

            guard normalizedCount < maxReasonCharacters else { break }
            normalized.append(scalar)
            normalizedCount += 1
        }

        guard normalizedCount > 0 else { return nil }
        return String(normalized)
    }
}
