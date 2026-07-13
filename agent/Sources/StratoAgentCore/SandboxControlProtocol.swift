import Foundation

/// The host side of the guest control protocol (issues #421/#423), mirroring
/// `sandbox-guest/init/src/protocol.rs`.
///
/// The wire format is newline-delimited JSON over vsock. The v1 surface is a
/// request/response control channel: the host writes one request object
/// terminated by `\n`, the guest replies with one response object terminated by
/// `\n` (`ping` and `get_status`). Protocol v2 adds two connection-scoped
/// modes, selected by the first request line on a fresh connection:
///
/// - `exec` turns the connection into a dedicated exec session: the guest
///   answers `exec_started` (or `error`), then streams `output` records and a
///   terminal `exec_exit`, while the host interleaves `stdin`/`stdin_eof`/
///   `resize` lines. Closing the connection before `exec_exit` kills the exec
///   process group.
/// - `stream_logs` turns the connection into a log follow stream: the guest
///   streams `log` records (the workload's stdout/stderr ring buffer) from
///   `since_seq` onward, forever; no further host input is expected.
///
/// Every v1 response echoes the sandbox identity (`sandbox_id` + `nonce`), so
/// the host can confirm it is talking to the generation it expects rather than
/// a stale one — the same identity check that lets a host re-confirm a guest
/// after re-adoption.
public enum SandboxControlProtocol {

    /// The parameters of an `exec` request (spec §1): the argv to spawn in the
    /// workload's container context, plus optional environment overrides,
    /// working directory, and PTY geometry.
    public struct ExecRequest: Codable, Equatable, Sendable {
        /// The command to run. Required, non-empty.
        public let argv: [String]
        /// Extra variables merged OVER the workload's resolved environment
        /// (replace on same key). Omitted when nil.
        public let env: [String: String]?
        /// Working directory; nil inherits the workload's resolved cwd.
        public let cwd: String?
        /// Allocate a PTY. When true all output is reported as `stdout`.
        public let tty: Bool
        /// Initial PTY rows/cols; meaningful only with `tty`. Guest defaults
        /// to 24x80 when omitted.
        public let rows: Int?
        public let cols: Int?

        public init(
            argv: [String],
            env: [String: String]? = nil,
            cwd: String? = nil,
            tty: Bool = false,
            rows: Int? = nil,
            cols: Int? = nil
        ) {
            self.argv = argv
            self.env = env
            self.cwd = cwd
            self.tty = tty
            self.rows = rows
            self.cols = cols
        }
    }

    /// A control request sent host → guest. `type`-tagged snake_case to match
    /// the guest's serde contract.
    public enum Request: Equatable, Sendable {
        case ping
        case getStatus
        /// First line of an exec session connection.
        case exec(ExecRequest)
        /// Stdin bytes for the exec process (base64 on the wire).
        case stdin(Data)
        /// Close the exec process's stdin.
        case stdinEof
        /// Resize the exec session's PTY.
        case resize(rows: Int, cols: Int)
        /// First line of a log follow connection: stream the workload's
        /// stdout/stderr ring buffer from `sinceSeq` onward (records already
        /// evicted are silently skipped).
        case streamLogs(sinceSeq: UInt64)

        /// Flat encoding shape for the tagged request union. Optional fields
        /// are omitted (not null) when absent, matching the guest's serde
        /// contract.
        private struct RawRequest: Encodable {
            let type: String
            var argv: [String]?
            var env: [String: String]?
            var cwd: String?
            var tty: Bool?
            var rows: Int?
            var cols: Int?
            var data: String?
            var sinceSeq: UInt64?

            enum CodingKeys: String, CodingKey {
                case type
                case argv
                case env
                case cwd
                case tty
                case rows
                case cols
                case data
                case sinceSeq = "since_seq"
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(type, forKey: .type)
                try container.encodeIfPresent(argv, forKey: .argv)
                try container.encodeIfPresent(env, forKey: .env)
                try container.encodeIfPresent(cwd, forKey: .cwd)
                try container.encodeIfPresent(tty, forKey: .tty)
                try container.encodeIfPresent(rows, forKey: .rows)
                try container.encodeIfPresent(cols, forKey: .cols)
                try container.encodeIfPresent(data, forKey: .data)
                try container.encodeIfPresent(sinceSeq, forKey: .sinceSeq)
            }
        }

        /// Encode as a single newline-terminated JSON line.
        public func encodedLine() -> Data {
            var raw: RawRequest
            switch self {
            case .ping:
                raw = RawRequest(type: "ping")
            case .getStatus:
                raw = RawRequest(type: "get_status")
            case .exec(let request):
                raw = RawRequest(type: "exec")
                raw.argv = request.argv
                raw.env = request.env
                raw.cwd = request.cwd
                raw.tty = request.tty
                raw.rows = request.rows
                raw.cols = request.cols
            case .stdin(let data):
                raw = RawRequest(type: "stdin")
                raw.data = data.base64EncodedString()
            case .stdinEof:
                raw = RawRequest(type: "stdin_eof")
            case .resize(let rows, let cols):
                raw = RawRequest(type: "resize")
                raw.rows = rows
                raw.cols = cols
            case .streamLogs(let sinceSeq):
                raw = RawRequest(type: "stream_logs")
                raw.sinceSeq = sinceSeq
            }
            // A flat struct of JSON scalars/arrays/string-maps cannot fail to
            // encode; fall back to an empty line rather than crashing the host
            // if that invariant is ever broken.
            var line = (try? JSONEncoder().encode(raw)) ?? Data("{}".utf8)
            line.append(0x0A)
            return line
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
        /// The exec process spawned; output may follow on this connection.
        case execStarted
        /// Output bytes from the exec process (`stream` is `stdout`/`stderr`;
        /// always `stdout` for a tty session).
        case output(stream: String, data: Data)
        /// Terminal for an exec session: the child was reaped (signal N →
        /// 128+N) after all buffered output was flushed.
        case execExit(exitCode: Int)
        /// One record of the workload's stdout/stderr ring buffer. `seq` is
        /// monotonic across both streams, starting at 1.
        case log(seq: UInt64, stream: String, data: Data)

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
            case "exec_started":
                return .execStarted
            case "output":
                guard let stream = raw.stream, let payload = raw.decodedData else {
                    throw SandboxControlError.malformedResponse(line)
                }
                return .output(stream: stream, data: payload)
            case "exec_exit":
                guard let exitCode = raw.exitCode else {
                    throw SandboxControlError.malformedResponse(line)
                }
                return .execExit(exitCode: exitCode)
            case "log":
                guard let seq = raw.seq, let stream = raw.stream, let payload = raw.decodedData else {
                    throw SandboxControlError.malformedResponse(line)
                }
                return .log(seq: seq, stream: stream, data: payload)
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
        let stream: String?
        let data: String?
        let seq: UInt64?

        /// The base64 `data` field decoded to bytes; nil when absent or not
        /// valid base64.
        var decodedData: Data? {
            data.flatMap { Data(base64Encoded: $0) }
        }

        enum CodingKeys: String, CodingKey {
            case type
            case sandboxId = "sandbox_id"
            case nonce
            case state
            case exitCode = "exit_code"
            case message
            case stream
            case data
            case seq
        }
    }
}

/// Failures speaking the guest control protocol.
public enum SandboxControlError: Error, LocalizedError, Equatable, Sendable {
    /// A response line could not be decoded as a known response.
    case malformedResponse(String)
    /// The guest returned an `error` response.
    case guestError(String)
    /// No response arrived before the deadline.
    case timeout

    public var errorDescription: String? {
        switch self {
        case .malformedResponse(let line):
            return "malformed sandbox control response: \(line)"
        case .guestError(let message):
            return "guest control agent error: \(message)"
        case .timeout:
            return "timed out waiting for the sandbox guest control agent"
        }
    }
}
