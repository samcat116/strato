import Foundation
import Logging

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
        case .sessionNotFound(let sessionId):
            return "VM exec session not found: \(sessionId)"
        case .identityMismatch(let expected, let got):
            return "guest identity nonce mismatch: expected \(expected), got \(got)"
        case .unexpectedResponse(let response):
            return "unexpected VM guest exec response: \(response)"
        }
    }
}

/// Bridges VM exec sessions to the guest agent's AF_VSOCK control channel.
public actor VMExecSessionManager {
    public typealias Connector =
        @Sendable (
            _ cid: UInt32, _ port: UInt32, _ timeout: TimeInterval, _ logger: Logger
        ) async throws -> any GuestLineConnection

    public static let guestAgentPort: UInt32 = 1024
    public static let connectTimeout: TimeInterval = 10

    private struct Session {
        let vmId: String
        let connection: any GuestLineConnection
        let events: @Sendable (SandboxExecEvent) -> Void
        var reader: Task<Void, Never>?
    }

    private let logger: Logger
    private let connector: Connector
    private var sessions: [String: Session] = [:]
    private var startingSessions: Set<String> = []
    private var sweepEpoch: UInt64 = 0

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
        request: SandboxExecRequest,
        placementIsCurrent: @escaping @Sendable () async -> Bool,
        events: @escaping @Sendable (SandboxExecEvent) -> Void
    ) async throws {
        guard sessions[sessionId] == nil, !startingSessions.contains(sessionId) else { return }
        guard await placementIsCurrent() else {
            throw VMExecBridgeError.vmNotPlaced(placement.vmId)
        }

        startingSessions.insert(sessionId)
        defer { startingSessions.remove(sessionId) }
        let epoch = sweepEpoch

        let connection: any GuestLineConnection
        do {
            connection = try await connector(
                placement.vsockCID, Self.guestAgentPort, Self.connectTimeout, logger)
        } catch {
            throw VMExecBridgeError.guestAgentNotResponding(
                vmId: placement.vmId, detail: error.localizedDescription)
        }

        do {
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
            guard sweepEpoch == epoch, await placementIsCurrent() else {
                throw VMExecBridgeError.vmNotPlaced(placement.vmId)
            }

            // Register before starting the detached reader: an exec can write
            // output and exit in the same packet as exec_started, and the
            // reader's terminal callback must already be able to find it.
            sessions[sessionId] = Session(
                vmId: placement.vmId, connection: connection, events: events, reader: nil)
            events(.started)
            let reader = Task.detached { [weak self, logger] in
                await Self.runReader(
                    sessionId: sessionId, expectedNonce: nonce, connection: connection,
                    events: events, manager: self, logger: logger)
            }
            sessions[sessionId]?.reader = reader
        } catch {
            await connection.close()
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
    public func closeExec(sessionId: String) async {
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        await session.connection.close()
        session.reader?.cancel()
    }

    public func closeAll(reason: String) async {
        sweepEpoch &+= 1
        let current = sessions
        sessions.removeAll()
        for (_, session) in current {
            await session.connection.close()
            session.reader?.cancel()
            session.events(.closed(reason: reason))
        }
    }

    private func readerEnded(sessionId: String, terminal: SandboxExecEvent) async {
        guard let session = sessions.removeValue(forKey: sessionId) else { return }
        await session.connection.close()
        logger.info(
            "VM exec session ended",
            metadata: [
                "vmId": .string(session.vmId), "sessionId": .string(sessionId),
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
                        "sessionId": .string(sessionId),
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
                events(.output(stream: stream, data: data))
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
