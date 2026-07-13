import Foundation

/// The host side of the guest control protocol (issue #421), mirroring
/// `sandbox-guest/init/src/protocol.rs`.
///
/// The wire format is newline-delimited JSON over vsock: the host writes one
/// request object terminated by `\n`, the guest replies with one response
/// object terminated by `\n`. The v1 surface is deliberately tiny — a `ping`
/// health probe and a `get_status` that returns the workload's lifecycle state
/// and, once it has ended, its exit code.
///
/// Every response echoes the sandbox identity (`sandbox_id` + `nonce`), so the
/// host can confirm it is talking to the generation it expects rather than a
/// stale one — the same identity check that lets a host re-confirm a guest
/// after re-adoption.
public enum SandboxControlProtocol {

    /// A control request sent host → guest. `type`-tagged snake_case to match
    /// the guest's serde contract.
    public enum Request: Equatable, Sendable {
        case ping
        case getStatus

        /// Encode as a single newline-terminated JSON line.
        public func encodedLine() -> Data {
            let type: String
            switch self {
            case .ping: type = "ping"
            case .getStatus: type = "get_status"
            }
            return Data("{\"type\":\"\(type)\"}\n".utf8)
        }
    }

    /// The workload's lifecycle state as reported by the guest agent.
    public enum WorkloadState: String, Codable, Equatable, Sendable {
        case starting
        case running
        case exited
    }

    /// A control response sent guest → host.
    public enum Response: Equatable, Sendable {
        case pong(sandboxId: String, nonce: String)
        case status(sandboxId: String, nonce: String, state: WorkloadState, exitCode: Int?)
        case error(message: String)

        /// Decode one response line (the trailing newline is optional).
        public static func decode(line: String) throws -> Response {
            guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
                throw SandboxControlError.malformedResponse(line)
            }
            let raw = try JSONDecoder().decode(RawResponse.self, from: data)
            switch raw.type {
            case "pong":
                return .pong(sandboxId: raw.sandboxId ?? "", nonce: raw.nonce ?? "")
            case "status":
                guard let stateString = raw.state, let state = WorkloadState(rawValue: stateString) else {
                    throw SandboxControlError.malformedResponse(line)
                }
                return .status(
                    sandboxId: raw.sandboxId ?? "", nonce: raw.nonce ?? "", state: state, exitCode: raw.exitCode)
            case "error":
                return .error(message: raw.message ?? "")
            default:
                throw SandboxControlError.malformedResponse(line)
            }
        }
    }

    /// Flat decoding shape for the tagged response union.
    private struct RawResponse: Decodable {
        let type: String
        let sandboxId: String?
        let nonce: String?
        let state: String?
        let exitCode: Int?
        let message: String?

        enum CodingKeys: String, CodingKey {
            case type
            case sandboxId = "sandbox_id"
            case nonce
            case state
            case exitCode = "exit_code"
            case message
        }
    }
}

/// Failures speaking the guest control protocol.
public enum SandboxControlError: Error, LocalizedError, Equatable, Sendable {
    /// A response line could not be decoded as a v1 response.
    case malformedResponse(String)
    /// The guest returned an `error` response.
    case guestError(String)
    /// No response arrived before the deadline.
    case timeout
    /// The guest echoed an identity that does not match the sandbox we expect
    /// to be talking to — a stale generation still serving the deterministic
    /// vsock UDS (a leaked process, a pre-adoption resume).
    case identityMismatch(expected: String, got: String)

    public var errorDescription: String? {
        switch self {
        case .malformedResponse(let line):
            return "malformed sandbox control response: \(line)"
        case .guestError(let message):
            return "guest control agent error: \(message)"
        case .timeout:
            return "timed out waiting for the sandbox guest control agent"
        case .identityMismatch(let expected, let got):
            return "sandbox guest identity mismatch: expected \(expected), got \(got)"
        }
    }
}
