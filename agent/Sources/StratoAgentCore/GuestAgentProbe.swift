import Foundation
import Logging
import StratoShared

/// Never starts a command. A valid protocol pong proves the Strato daemon responds.
public enum GuestAgentProbe {
    public typealias Connector =
        @Sendable (UInt32, UInt32, TimeInterval, Logger) async throws -> any GuestLineConnection

    public static func check(
        cid: UInt32, logger: Logger,
        connector: Connector = { cid, port, timeout, logger in
            try await HostVsockConnection.connect(cid: cid, port: port, timeout: timeout, logger: logger)
        }
    ) async throws -> GuestAgentObservation {
        let connection: any GuestLineConnection
        do {
            connection = try await connector(cid, VMExecSessionManager.guestAgentPort, 1, logger)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return GuestAgentObservation(reachable: false, checkedAt: Date())
        }
        do {
            try await connection.write(GuestControlProtocol.Request.ping.encodedLine())
            let line = try await connection.nextLine(timeout: 1)
            var reachable = false
            if let line, case .pong = try GuestControlProtocol.Response.decode(line: line) { reachable = true }
            await connection.close()
            try Task.checkCancellation()
            return GuestAgentObservation(reachable: reachable, checkedAt: Date())
        } catch is CancellationError {
            await connection.close()
            throw CancellationError()
        } catch {
            await connection.close()
            try Task.checkCancellation()
            return GuestAgentObservation(reachable: false, checkedAt: Date())
        }
    }
}
