import Foundation
import Logging
import StratoShared

/// One bounded guest diff/apply/read-back exchange; injectable transport keeps
/// tests independent of a guest or an AF_VSOCK device.
public struct GuestConfigClient: Sendable {
    // Worst-case JSON escaping: 6x content, 2x paths/sysctl text, plus
    // bounded identities, records and envelope. Responses fit the same bound.
    public static let maxFrameBytes = 4 * 1024 * 1024
    private let connector: VMExecSessionManager.Connector
    private let logger: Logger

    public init(
        logger: Logger,
        connector: @escaping VMExecSessionManager.Connector = { cid, port, timeout, logger in
            try await HostVsockConnection.connect(
                cid: cid, port: port, timeout: timeout, maximumLineLength: Self.maxFrameBytes, logger: logger)
        }
    ) {
        self.logger = logger
        self.connector = connector
    }

    private struct Request: Encodable {
        let type = "converge_guest_config"
        let generation: Int64
        let guest_config: GuestConfig
    }
    private struct Response: Decodable {
        let type: String
        let nonce: String
        let observation: GuestConfigObservation?
        let message: String?
    }

    public func converge(
        placement: VMGuestExecPlacement,
        config: GuestConfig,
        generation: Int64,
        placementIsCurrent: @escaping @Sendable () async -> Bool
    ) async throws -> GuestConfigObservation {
        try config.validate()
        guard await placementIsCurrent() else { throw VMExecBridgeError.vmNotPlaced(placement.vmId) }
        let connection = try await connector(placement.vsockCID, 1024, 60, logger)
        do {
            try await connection.write(GuestControlProtocol.Request.ping.encodedLine())
            guard let ping = try await connection.nextLine(timeout: 10),
                case .pong(_, let nonce, _) = try? GuestControlProtocol.Response.decode(line: ping)
            else { throw GuestConfigurationFailure.invalidResponse }
            guard await placementIsCurrent() else { throw VMExecBridgeError.vmNotPlaced(placement.vmId) }
            var data = try JSONEncoder().encode(Request(generation: generation, guest_config: config))
            guard data.count < Self.maxFrameBytes else {
                throw GuestConfigurationFailure.invalidResponse
            }
            data.append(0x0A)
            try await connection.write(data)
            guard let line = try await connection.nextLine(timeout: 190),
                line.utf8.count < Self.maxFrameBytes
            else { throw GuestConfigurationFailure.invalidResponse }
            // Do not feed this into malformed-line diagnostics: a guest can
            // echo file contents in an invalid response, which must not be logged.
            let response: Response
            do { response = try JSONDecoder().decode(Response.self, from: Data(line.utf8)) } catch {
                throw GuestConfigurationFailure.invalidResponse
            }
            if response.type == "error", response.nonce == nonce,
                response.message == "guest configuration convergence busy or unavailable"
            {
                throw GuestConfigurationFailure.busy
            }
            guard response.type == "guest_config_state", response.nonce == nonce,
                let observation = response.observation
            else { throw GuestConfigurationFailure.invalidResponse }
            try observation.validate(for: config, generation: generation)
            guard await placementIsCurrent() else { throw VMExecBridgeError.vmNotPlaced(placement.vmId) }
            await connection.close()
            return observation
        } catch {
            await connection.close()
            throw error
        }
    }
}

public enum GuestConfigurationFailure: Error, LocalizedError, ClassifiableError, Sendable {
    case invalidResponse
    case busy
    case failed(reason: String)
    public static func safeReason(_ reason: String?) -> String {
        // Never put guest-chosen text in node logs. Project known categories.
        if reason?.hasPrefix("package operation budget exhausted") == true {
            return "Guest package operation budget exhausted; mirror or package manager unavailable"
        }
        if reason?.hasPrefix("package operation failed") == true {
            return "Guest package operation failed; package manager or mirror unavailable"
        }
        if reason?.hasPrefix("guest convergence interrupted") == true {
            return "Guest convergence interrupted by restart; submit a new VM generation to retry"
        }
        return
            "Guest configuration convergence failed; inspect guestConfigObservation.error and submit a new VM generation to retry"
    }
    public var failureClassification: FailureClassification {
        if case .busy = self { return .waitingOnDependency }
        return .permanent
    }
    public var errorDescription: String? {
        switch self {
        case .busy: "Guest configuration convergence is still running in the guest"
        case .invalidResponse: "Guest configuration response unavailable, unsupported, or invalid"
        case .failed(let reason): reason
        }
    }
}
