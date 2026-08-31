import Foundation
import Logging
import StratoShared

/// The security-relevant local placement proof for a VM exec request.
public struct VMGuestExecPlacement: Equatable, Sendable {
    public let vmId: String
    public let vsockCID: UInt32

    public init(vmId: String, vsockCID: UInt32) {
        self.vmId = vmId
        self.vsockCID = vsockCID
    }

    /// Resolve only from the agent's actively managed map. Orphaned manifest
    /// entries are deliberately not accepted: they are not current placement.
    public static func resolve(
        vmId: String, managedVMs: [String: VMManifestEntry]
    ) throws -> VMGuestExecPlacement {
        guard let entry = managedVMs[vmId], entry.kind == .vm else {
            throw VMExecBridgeError.vmNotPlaced(vmId)
        }
        guard entry.spec.guestAgentEnabled, let cid = entry.vsockCID else {
            throw VMExecBridgeError.noGuestAgent(vmId)
        }
        return VMGuestExecPlacement(vmId: vmId, vsockCID: cid)
    }
}

public enum VMExecBridgeError: Error, LocalizedError, Sendable {
    case vmNotPlaced(String)
    case noGuestAgent(String)
    case guestAgentNotResponding(vmId: String, detail: String)
    case interactiveSessionsQuiesced
    case sessionManagerStopped
    case sessionNotFound(String)
    case identityMismatch(expected: String, got: String)
    case unexpectedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .vmNotPlaced(let vmId):
            return "VM \(vmId) is not placed on this agent"
        case .noGuestAgent(let vmId):
            return "VM \(vmId) has no guest agent"
        case .guestAgentNotResponding(let vmId, let detail):
            return "guest agent not responding for VM \(vmId): \(detail)"
        case .interactiveSessionsQuiesced:
            return "interactive VM exec is unavailable while the control plane is disconnected"
        case .sessionManagerStopped:
            return "VM exec session manager is stopping"
        case .sessionNotFound(let sessionId):
            return "VM exec session not found: \(sessionId)"
        case .identityMismatch(let expected, let got):
            return "guest identity nonce mismatch: expected \(expected), got \(got)"
        case .unexpectedResponse(let response):
            return "unexpected VM guest exec response: \(response)"
        }
    }
}

/// The authoritative, bounded state the agent retains for a recorded VM
/// command until the control plane acknowledges its durable result.
public struct RecordedVMExecSessionSnapshot: Equatable, Sendable {
    public let sessionId: String
    public let revision: Int64
    public let status: GuestExecRecordedStatus
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int?
    public let reason: String?
    public let truncated: Bool

    public var isTerminal: Bool { status != .running }
}

/// Bridges VM exec sessions to the guest agent's AF_VSOCK control channel.
public actor VMExecSessionManager {
    public typealias Connector =
        @Sendable (
            _ cid: UInt32, _ port: UInt32, _ timeout: TimeInterval, _ logger: Logger
        ) async throws -> any GuestLineConnection

    public static let guestAgentPort: UInt32 = 1024
    public static let connectTimeout: TimeInterval = 10
    public static let recordedOutputLimitBytes = GuestExecRecordedStateMessage.outputLimitBytes
    private static let missingRecordedExitReason =
        "guest command session closed without an exit code"

    private struct Session {
        let vmId: String
        let sessionKind: GuestExecSessionKind
        let connection: any GuestLineConnection
        let events: @Sendable (SandboxExecEvent) -> Void
        var reader: Task<Void, Never>?
    }

    private struct RecordedCapture {
        var revision: Int64 = 0
        var stdout = Data()
        var stderr = Data()
        var status = GuestExecRecordedStatus.running
        var exitCode: Int?
        var reason: String?
        var truncated = false

        mutating func append(_ data: Data, stream: String) {
            guard status == .running else { return }
            guard stream == "stdout" || stream == "stderr" else {
                if !truncated {
                    truncated = true
                    advanceRevision()
                }
                return
            }
            let remaining = max(
                0, VMExecSessionManager.recordedOutputLimitBytes - stdout.count - stderr.count)
            let wasTruncated = truncated
            if data.count > remaining { truncated = true }
            guard remaining > 0 else {
                if truncated != wasTruncated { advanceRevision() }
                return
            }
            let accepted = data.prefix(remaining)
            guard !accepted.isEmpty || truncated != wasTruncated else { return }
            if stream == "stderr" {
                stderr.append(contentsOf: accepted)
            } else {
                stdout.append(contentsOf: accepted)
            }
            advanceRevision()
        }

        mutating func finish(_ terminal: SandboxExecEvent) {
            guard status == .running else { return }
            switch terminal {
            case .exited(let code):
                status = .exited
                exitCode = code
            case .closed(let reason):
                status = .closed
                self.reason = reason ?? VMExecSessionManager.missingRecordedExitReason
                // There is no exit record proving the capture is complete.
                truncated = true
            case .started, .output:
                return
            }
            advanceRevision()
        }

        private mutating func advanceRevision() {
            if revision < .max { revision += 1 }
        }

        func snapshot(sessionId: String) -> RecordedVMExecSessionSnapshot {
            RecordedVMExecSessionSnapshot(
                sessionId: sessionId,
                revision: revision,
                status: status,
                stdout: stdout,
                stderr: stderr,
                exitCode: exitCode,
                reason: reason,
                truncated: truncated)
        }
    }

    private let logger: Logger
    private let connector: Connector
    private var sessions: [String: Session] = [:]
    private var externallyClosingSessions: Set<String> = []
    private var startingSessions: Set<String> = []
    private var cancelledStartingSessions: Set<String> = []
    private var recordedCaptures: [String: RecordedCapture] = [:]
    private var sweepEpoch: UInt64 = 0
    private var interactiveSweepEpoch: UInt64 = 0
    private var acceptingSessions = true
    private var acceptingInteractiveSessions = true

    public init(
        logger: Logger,
        connector: @escaping Connector = { cid, port, timeout, logger in
            try await HostVsockConnection.connect(
                cid: cid, port: port, timeout: timeout, logger: logger)
        }
    ) {
        self.logger = logger
        self.connector = connector
    }

    public func startExec(
        placement: VMGuestExecPlacement,
        sessionId: String,
        sessionKind: GuestExecSessionKind,
        request: SandboxExecRequest,
        placementIsCurrent: @escaping @Sendable () async -> Bool,
        events: @escaping @Sendable (SandboxExecEvent) -> Void
    ) async throws {
        guard sessions[sessionId] == nil, !startingSessions.contains(sessionId) else { return }
        guard acceptingSessions else { throw VMExecBridgeError.sessionManagerStopped }
        guard sessionKind == .recorded || acceptingInteractiveSessions else {
            throw VMExecBridgeError.interactiveSessionsQuiesced
        }
        if sessionKind == .recorded {
            // A retained running or terminal record means this same agent
            // process has already accepted the command. Never spawn it twice.
            guard recordedCaptures[sessionId] == nil else { return }
            recordedCaptures[sessionId] = RecordedCapture()
        }

        startingSessions.insert(sessionId)
        defer {
            startingSessions.remove(sessionId)
            cancelledStartingSessions.remove(sessionId)
        }
        let epoch = sweepEpoch
        let interactiveEpoch = interactiveSweepEpoch
        var openedConnection: (any GuestLineConnection)?

        do {
            guard await placementIsCurrent() else {
                throw VMExecBridgeError.vmNotPlaced(placement.vmId)
            }

            let connection: any GuestLineConnection
            do {
                connection = try await connector(
                    placement.vsockCID, Self.guestAgentPort, Self.connectTimeout, logger)
                openedConnection = connection
            } catch {
                throw VMExecBridgeError.guestAgentNotResponding(
                    vmId: placement.vmId, detail: error.localizedDescription)
            }

            // The connector suspends. A socket loss or shutdown can quiesce
            // this start while it is opening the guest channel; do not send
            // exec after that lifecycle edge.
            guard acceptingSessions, sweepEpoch == epoch else {
                throw VMExecBridgeError.sessionManagerStopped
            }
            guard
                sessionKind == .recorded
                    || (acceptingInteractiveSessions
                        && interactiveSweepEpoch == interactiveEpoch),
                !cancelledStartingSessions.contains(sessionId)
            else {
                throw VMExecBridgeError.interactiveSessionsQuiesced
            }

            try await connection.write(GuestControlProtocol.Request.exec(request.guestRequest).encodedLine())
            guard let line = try await connection.nextLine(timeout: Self.connectTimeout) else {
                throw VMExecBridgeError.guestAgentNotResponding(
                    vmId: placement.vmId, detail: "connection closed before exec_started")
            }
            let response = try GuestControlProtocol.Response.decode(line: line)
            if case .error(_, let message) = response {
                throw GuestControlError.guestError(message)
            }
            guard case .execStarted(let nonce) = response else {
                throw VMExecBridgeError.unexpectedResponse(String(describing: response))
            }
            // Recorded commands expose no stdin surface. Close it at the
            // guest boundary rather than relying on a control-plane round
            // trip that can be interrupted by the socket blip we survive.
            if sessionKind == .recorded {
                try await connection.write(GuestControlProtocol.Request.stdinEof.encodedLine())
            }

            // Do every suspension before the generation check. Actor methods
            // can re-enter while placement or the guest write is awaiting; a
            // disconnect or shutdown in that window must invalidate this
            // start before it becomes an owned session.
            let placementStillCurrent = await placementIsCurrent()
            guard acceptingSessions, sweepEpoch == epoch,
                (sessionKind == .recorded
                    || (acceptingInteractiveSessions
                        && interactiveSweepEpoch == interactiveEpoch)),
                !cancelledStartingSessions.contains(sessionId),
                placementStillCurrent
            else {
                throw VMExecBridgeError.vmNotPlaced(placement.vmId)
            }

            // Register before starting the detached reader: an exec can write
            // output and exit in the same packet as exec_started, and the
            // reader's terminal callback must already be able to find it.
            sessions[sessionId] = Session(
                vmId: placement.vmId,
                sessionKind: sessionKind,
                connection: connection,
                events: events,
                reader: nil)
            openedConnection = nil
            events(.started)
            let reader = Task.detached { [weak self, logger] in
                await Self.runReader(
                    sessionId: sessionId, expectedNonce: nonce, connection: connection,
                    events: events, manager: self, logger: logger)
            }
            sessions[sessionId]?.reader = reader
        } catch {
            await openedConnection?.close()
            if let session = sessions.removeValue(forKey: sessionId) {
                await session.connection.close()
                session.reader?.cancel()
            }
            if sessionKind == .recorded {
                recordedCaptures[sessionId]?.finish(
                    .closed(reason: error.localizedDescription))
            }
            if error is VMExecBridgeError || error is GuestControlError { throw error }
            throw VMExecBridgeError.guestAgentNotResponding(
                vmId: placement.vmId, detail: error.localizedDescription)
        }
    }

    public func sendExecInput(sessionId: String, data: Data?, eof: Bool) async throws {
        guard let session = sessions[sessionId] else {
            throw VMExecBridgeError.sessionNotFound(sessionId)
        }
        if let data, !data.isEmpty {
            try await session.connection.write(GuestControlProtocol.Request.stdin(data).encodedLine())
        }
        if eof {
            try await session.connection.write(GuestControlProtocol.Request.stdinEof.encodedLine())
        }
    }

    public func resizeExec(sessionId: String, rows: Int, cols: Int) async throws {
        guard let session = sessions[sessionId] else {
            throw VMExecBridgeError.sessionNotFound(sessionId)
        }
        try await session.connection.write(
            GuestControlProtocol.Request.resize(rows: rows, cols: cols).encodedLine())
    }

    /// Idempotent. Closing before `exec_exit` is the guest contract that kills
    /// the exec process group.
    public func closeExec(sessionId: String, reason: String? = nil) async {
        if startingSessions.contains(sessionId) {
            cancelledStartingSessions.insert(sessionId)
            recordedCaptures[sessionId]?.finish(.closed(reason: reason))
        }
        guard let session = sessions[sessionId] else { return }
        externallyClosingSessions.insert(sessionId)
        await session.connection.close()
        // Keep the route installed while close suspends so a readerOutput
        // already decoded by the guest reader can still enter the bounded
        // recorded capture. readerEnded may remove it first.
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        externallyClosingSessions.remove(sessionId)
        session.reader?.cancel()
        if session.sessionKind == .recorded {
            let terminal = SandboxExecEvent.closed(reason: reason)
            recordedCaptures[sessionId]?.finish(terminal)
            session.events(terminal)
        }
    }

    /// Ends only frontend-bound sessions. Recorded commands retain their guest
    /// channels and bounded state across a control-plane WebSocket gap.
    public func closeInteractive(reason: String) async {
        acceptingInteractiveSessions = false
        interactiveSweepEpoch &+= 1
        let interactive = sessions.filter { $0.value.sessionKind == .interactive }
        for (sessionId, session) in interactive {
            externallyClosingSessions.insert(sessionId)
            await session.connection.close()
            guard let session = sessions.removeValue(forKey: sessionId) else { continue }
            externallyClosingSessions.remove(sessionId)
            session.reader?.cancel()
            session.events(.closed(reason: reason))
        }
    }

    /// Registration makes frontend-bound starts safe again. Keeping this gate
    /// in the manager prevents a frame already queued on the dead socket from
    /// entering while disconnect cleanup is suspended on a channel close.
    public func resumeInteractive() {
        acceptingInteractiveSessions = true
    }

    public func closeAll(reason: String) async {
        acceptingSessions = false
        acceptingInteractiveSessions = false
        sweepEpoch &+= 1
        let current = sessions
        for (sessionId, session) in current {
            externallyClosingSessions.insert(sessionId)
            await session.connection.close()
            guard let session = sessions.removeValue(forKey: sessionId) else { continue }
            externallyClosingSessions.remove(sessionId)
            session.reader?.cancel()
            let terminal = SandboxExecEvent.closed(reason: reason)
            if session.sessionKind == .recorded {
                recordedCaptures[sessionId]?.finish(terminal)
            }
            session.events(terminal)
        }
    }

    public func recordedSessionSnapshot(
        sessionId: String
    ) -> RecordedVMExecSessionSnapshot? {
        recordedCaptures[sessionId]?.snapshot(sessionId: sessionId)
    }

    public func recordedSessionSnapshots(
        terminalOnly: Bool = false
    ) -> [RecordedVMExecSessionSnapshot] {
        recordedCaptures
            .map { $0.value.snapshot(sessionId: $0.key) }
            .filter { !terminalOnly || $0.isTerminal }
            .sorted { $0.sessionId < $1.sessionId }
    }

    /// Choose one terminal snapshot after a stable cursor, wrapping at the
    /// end. A persistently unacknowledgeable result therefore cannot prevent
    /// later commands from being offered on subsequent heartbeats, while the
    /// caller still sends only one unacknowledged large frame at a time.
    public func recordedTerminalSnapshot(
        after sessionId: String?
    ) -> RecordedVMExecSessionSnapshot? {
        let terminal = recordedSessionSnapshots(terminalOnly: true)
        guard let first = terminal.first else { return nil }
        guard let sessionId else { return first }
        return terminal.first { $0.sessionId > sessionId } ?? first
    }

    /// Preserve a start failure that happened before this manager could open
    /// the guest channel (for example, placement resolution in the Agent).
    /// Recorded starts are accepted durably: even their earliest failures must
    /// enter the same reconnect-and-ACK path as a later terminal result.
    public func retainRecordedStartFailure(sessionId: String, reason: String) {
        if recordedCaptures[sessionId] == nil {
            recordedCaptures[sessionId] = RecordedCapture()
        }
        recordedCaptures[sessionId]?.finish(.closed(reason: reason))
    }

    /// Retire only terminal state. A stale or forged ACK must never make a
    /// still-running command lose its reconnect record.
    @discardableResult
    public func acknowledgeRecordedSession(sessionId: String) -> Bool {
        guard recordedCaptures[sessionId]?.status != .running else { return false }
        return recordedCaptures.removeValue(forKey: sessionId) != nil
    }

    private func readerOutput(sessionId: String, stream: String, data: Data) {
        guard let session = sessions[sessionId] else { return }
        if session.sessionKind == .recorded {
            recordedCaptures[sessionId]?.append(data, stream: stream)
        } else {
            session.events(.output(stream: stream, data: data))
        }
    }

    private func readerEnded(sessionId: String, terminal: SandboxExecEvent) async {
        // An explicit close owns the terminal event and keeps the route alive
        // until any output decoded before the channel close is captured.
        guard !externallyClosingSessions.contains(sessionId) else { return }
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        await session.connection.close()
        if session.sessionKind == .recorded {
            recordedCaptures[sessionId]?.finish(terminal)
        }
        logger.info(
            "VM exec session ended",
            metadata: [
                "strato.vm.id": .string(session.vmId), "strato.session.kind": .string("guest_exec"),
                "strato.session.id": .string(sessionId),
                "terminal": .string(String(describing: terminal)),
            ])
        session.events(terminal)
    }

    private static func runReader(
        sessionId: String,
        expectedNonce: String,
        connection: any GuestLineConnection,
        events: @escaping @Sendable (SandboxExecEvent) -> Void,
        manager: VMExecSessionManager?,
        logger: Logger
    ) async {
        func finish(_ event: SandboxExecEvent) async {
            await manager?.readerEnded(sessionId: sessionId, terminal: event)
        }

        while true {
            let line: String?
            do {
                line = try await connection.nextLine(timeout: nil)
            } catch {
                await finish(.closed(reason: "VM guest exec channel failed: \(error.localizedDescription)"))
                return
            }
            guard let line else {
                await finish(.closed(reason: "VM guest exec channel closed"))
                return
            }

            let response: GuestControlProtocol.Response
            do {
                response = try GuestControlProtocol.Response.decode(line: line)
            } catch {
                await finish(.closed(reason: "malformed exec record from VM guest agent"))
                return
            }
            guard response.nonce == expectedNonce else {
                logger.warning(
                    "Closing VM exec session after guest identity nonce changed",
                    metadata: [
                        "strato.session.kind": .string("guest_exec"), "strato.session.id": .string(sessionId),
                        "expectedNonce": .string(expectedNonce),
                        "receivedNonce": .string(response.nonce),
                    ])
                await finish(
                    .closed(
                        reason: VMExecBridgeError.identityMismatch(
                            expected: expectedNonce, got: response.nonce
                        ).localizedDescription))
                return
            }

            switch response {
            case .output(_, let stream, let data):
                await manager?.readerOutput(sessionId: sessionId, stream: stream, data: data)
            case .execExit(_, let exitCode):
                await finish(.exited(code: exitCode))
                return
            case .error(_, let message):
                await finish(.closed(reason: "guest error: \(message)"))
                return
            default:
                await finish(.closed(reason: "unexpected exec record from VM guest agent"))
                return
            }
        }
    }
}
