import Foundation
import StratoShared

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
/// Every v1 response echoes the guest's identity (`sandbox_id` + `nonce`), so
/// the host can confirm it is talking to the generation it expects rather than
/// a stale one — the same identity check that lets a host re-confirm a guest
/// after re-adoption.
///
/// Sandbox guests are the only speakers today, and the wire format is unchanged
/// from when this was `SandboxControlProtocol`. The shape was never actually
/// sandbox-specific: an exec mode that answers `exec_started`, streams `output`
/// and ends with `exec_exit` is exactly what a VM guest agent needs (STR-73).
///
/// Not to be confused with `StratoShared.SandboxGuestControlProtocol`, which is
/// only the *version gates* for this protocol — it is shared with the control
/// plane, while the message shapes below are the agent's alone.
///
/// ## Trust boundary
///
/// Everything decoded here is **fully hostile input produced inside a tenant
/// guest**. The response decoder is therefore total: every malformed, oversized
/// or out-of-range value is a thrown ``GuestControlError`` that its caller turns
/// into a closed connection, never a Swift runtime trap — a trap would abort the
/// whole agent process, taking down every other tenant's guests on the node.
/// ``GuestControlProtocol/Limits`` holds the caps that bound what a guest can
/// make the host allocate or retain.
public enum GuestControlProtocol {

    /// Hard bounds applied to every guest-supplied value on the way in.
    ///
    /// These are ceilings, not expectations: each sits far above what a healthy
    /// guest emits (the guest reads both workload and exec output in 8 KiB
    /// chunks), so they only ever fire on input that is broken or hostile.
    public enum Limits {
        /// Longest response line the decoder will look at, matching the ceiling
        /// the transport's line framer already enforces while accumulating an
        /// unterminated line (`LineFrameDecoder.maximumLineLength`). Checking it
        /// here too keeps the bound with the parser rather than with one
        /// transport, so any other channel carrying this protocol inherits it.
        public static let maxLineBytes = 1 << 20

        /// Largest decoded stdio payload accepted on an `output` or `log`
        /// record — 8× the largest chunk the guest can legitimately produce.
        public static let maxPayloadBytes = 64 * 1024

        /// Longest base64 text that can encode ``maxPayloadBytes``. Checked
        /// before decoding, so an oversized chunk is refused without ever being
        /// materialized.
        public static let maxEncodedPayloadBytes = ((maxPayloadBytes + 2) / 3) * 4

        /// Cap on the echoed identity fields (`sandbox_id`, `nonce`). Both are
        /// UUID-shaped in practice; they are compared against and reported in
        /// mismatch diagnostics, so they must not be guest-sized.
        public static let maxIdentifierBytes = 256

        /// Cap on a guest `error` message, which is logged verbatim and travels
        /// to the control plane as an exec session's close reason.
        public static let maxMessageBytes = 4096

        /// Cap on a `log` record's sequence number. The guest's counter starts
        /// at 1 and steps by one per record, so no real stream comes within
        /// astronomical distance of this; the point is to leave the host's own
        /// `lastSeq + 1` resume arithmetic unable to overflow.
        ///
        /// The cap stops the overflow, not everything a bogus seq can do. The
        /// follow loop takes `lastSeq = max(lastSeq, seq)`, so a guest that
        /// sends one *accepted* record near this ceiling pins its own resume
        /// point there: the guest only replays `seq >= since_seq`, its counter
        /// restarts small, and that sandbox's log follow then reconnects
        /// cleanly and delivers nothing, silently, forever. It is self-
        /// inflicted (a tenant wedging their own logs) and far better than
        /// trapping the agent, but no cap value fixes it — any ceiling can be
        /// claimed by the record below it. The fix is a plausibility check on
        /// how far one record may advance the resume point, which belongs with
        /// the follow loop's cross-boot seq semantics rather than here.
        public static let maxLogSeq: UInt64 = 1 << 53

        /// How much of an offending line a ``GuestControlError`` carries. The
        /// error text reaches the log, so the excerpt is bounded rather than
        /// echoing a megabyte of guest-chosen bytes.
        public static let excerptBytes = 256
    }

    /// The stdio stream labels a guest may put on an `output` or `log` record.
    ///
    /// Anything else is rejected at parse time. That is not cosmetic: the host's
    /// log-line assembler buffers a partial line *per stream name*, so accepting
    /// arbitrary labels would hand a guest a way to grow host memory by
    /// inventing streams. The label stays a `String` in ``Response`` — the
    /// guest's serde contract declares it as one, and this is a rename plus a
    /// hardening pass, not a redesign.
    public static let allowedStreams: Set<String> = ["stdout", "stderr"]

    /// `text` cut to at most `limit` UTF-8 bytes, on a scalar boundary.
    ///
    /// Two things make this more than a `prefix`. Truncation is by UTF-8 bytes,
    /// not by `Character`, because one grapheme cluster can be arbitrarily long
    /// — a character-wise prefix would let a guest push a megabyte of combining
    /// marks through a byte cap. And the cut lands on a scalar boundary, because
    /// a fragment left behind is repaired by `String(decoding:)` into a 3-byte
    /// U+FFFD, which would make the result *longer* than the cap enforcing it.
    static func truncated(_ text: some StringProtocol, toUTF8Bytes limit: Int) -> String {
        // One byte past the cap: its value is what says whether the cut landed
        // inside a multi-byte scalar.
        var bytes = Array(text.utf8.prefix(limit + 1))
        guard bytes.count > limit else { return String(text) }

        let overrun = bytes.removeLast()
        if isContinuationByte(overrun) {
            while let last = bytes.last, isContinuationByte(last) {
                bytes.removeLast()
            }
            if !bytes.isEmpty {
                bytes.removeLast()  // the split scalar's leading byte
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `text` held to `limit` UTF-8 bytes with a visible marker when it had to
    /// be cut, so a reader can tell a clipped diagnostic from a short one. The
    /// result is never longer than `limit`.
    static func elided(_ text: some StringProtocol, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return String(text) }
        let marker = "…[truncated]"
        guard limit > marker.utf8.count else { return truncated(text, toUTF8Bytes: limit) }
        return truncated(text, toUTF8Bytes: limit - marker.utf8.count) + marker
    }

    /// Whether `byte` is a UTF-8 continuation byte (`10xxxxxx`).
    private static func isContinuationByte(_ byte: UInt8) -> Bool {
        byte & 0b1100_0000 == 0b1000_0000
    }

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

    /// The parameters of a warm-start `launch` request (issue #426). The
    /// `imageConfig`/`overrides` shapes are exactly the config drive's — the
    /// guest merges them with the identical cold-boot rules.
    public struct LaunchRequest: Equatable, Sendable {
        public let sandboxId: String
        public let identityNonce: String
        public let imageConfig: SandboxConfigDrive.ImageConfig
        public let overrides: SandboxConfigDrive.ProcessOverrides
        /// Random bytes the guest mixes into `/dev/urandom` (base64 on the
        /// wire). Warm launch treats this as best-effort; checkpoint fork
        /// re-identification uses a separate strict request.
        public let entropy: Data?
        /// Hostname the restored-into sandbox should take (STR-101).
        ///
        /// A template guest booted under the template's own (absent) hostname,
        /// so without this a warm-launched sandbox would keep it while a
        /// cold-booted one got `strato-<id>` — an asymmetry decided by warm
        /// cache state. Optional and additive: omitted when nil, and a guest
        /// that predates it ignores the field.
        public let hostname: String?
        /// The launched-into sandbox's NIC configuration (STR-104), for the
        /// device the snapshot load just repointed at this sandbox's TAP. Nil
        /// for a network-free sandbox.
        ///
        /// Unlike the hostname this is **not** ignorable: a guest that
        /// silently dropped it would run with an unaddressed interface while
        /// reporting healthy, so a networked launch is only ever sent to a
        /// guest that advertised control protocol
        /// ``SandboxGuestControlProtocol/networkReconfigureMinimumVersion``.
        public let network: SandboxConfigDrive.NetworkConfig?

        public init(
            sandboxId: String,
            identityNonce: String,
            imageConfig: SandboxConfigDrive.ImageConfig,
            overrides: SandboxConfigDrive.ProcessOverrides,
            entropy: Data?,
            hostname: String? = nil,
            network: SandboxConfigDrive.NetworkConfig? = nil
        ) {
            self.sandboxId = sandboxId
            self.identityNonce = identityNonce
            self.imageConfig = imageConfig
            self.overrides = overrides
            self.entropy = entropy
            self.hostname = hostname
            self.network = network
        }
    }

    /// Identity rotation applied immediately after restoring a user checkpoint
    /// into a different sandbox (issue #427). The expected source identity
    /// binds the request to the checkpoint we verified before any mutation;
    /// the target identity is echoed by all later health/status responses.
    public struct ReidentifyRequest: Equatable, Sendable {
        public let expectedSandboxId: String
        public let expectedNonce: String
        public let sandboxId: String
        public let identityNonce: String
        public let hostname: String
        public let entropy: Data
        public let unixNanos: Int64
        /// The fork target's NIC configuration (STR-104). The checkpointed
        /// kernel holds the *source* sandbox's MAC and address — generally one
        /// that still belongs to a live sandbox — so re-addressing the device
        /// is part of the identity boundary, not an afterthought to it. Nil
        /// when the fork has no NIC.
        public let network: SandboxConfigDrive.NetworkConfig?

        public init(
            expectedSandboxId: String,
            expectedNonce: String,
            sandboxId: String,
            identityNonce: String,
            hostname: String,
            entropy: Data,
            unixNanos: Int64,
            network: SandboxConfigDrive.NetworkConfig? = nil
        ) {
            self.expectedSandboxId = expectedSandboxId
            self.expectedNonce = expectedNonce
            self.sandboxId = sandboxId
            self.identityNonce = identityNonce
            self.hostname = hostname
            self.entropy = entropy
            self.unixNanos = unixNanos
            self.network = network
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
        /// Set the guest's realtime clock (issue #426): a guest restored from
        /// a snapshot resumes with its wall clock frozen at checkpoint time,
        /// so the host pushes the current time right after a restore. Guests
        /// that predate this request answer `error`, which the host treats as
        /// best-effort.
        case syncClock(unixNanos: Int64)
        /// Launch the workload in a guest that booted with `warm_hold` (issue
        /// #426 warm start). Sent after restoring a warm-template snapshot
        /// for a new sandbox: delivers the sandbox's identity, the image
        /// config + spec overrides (the guest resolves them with the same
        /// rules as a cold boot), and random bytes to diverge the snapshot's
        /// frozen RNG pool. The guest answers `launched`, after which every
        /// control response echoes the new identity.
        case launch(LaunchRequest)
        /// Rotate identity, machine-id, hostname, RNG state, and wall clock for
        /// a checkpoint restored as a new sandbox.
        case reidentify(ReidentifyRequest)

        /// Flat encoding shape for the tagged request union. The synthesized
        /// `Encodable` conformance already does exactly what the guest's serde
        /// contract needs: fields encode in declaration order (`type` first)
        /// and optionals are omitted (not null) when absent — pinned by the
        /// byte-exact v1 lines in `GuestControlProtocolTests`.
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
            var unixNanos: Int64?

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
                case unixNanos = "unix_nanos"
            }
        }

        /// Nested encoding shape for `launch` — the only request whose
        /// payload is not flat scalars. Optionals are omitted when absent,
        /// matching the guest's serde defaults.
        private struct RawLaunchRequest: Encodable {
            let type: String
            let sandboxId: String
            let identityNonce: String
            let imageConfig: SandboxConfigDrive.ImageConfig
            let overrides: SandboxConfigDrive.ProcessOverrides
            let entropy: String?
            let hostname: String?
            let network: SandboxConfigDrive.NetworkConfig?

            enum CodingKeys: String, CodingKey {
                case type
                case sandboxId = "sandbox_id"
                case identityNonce = "identity_nonce"
                case imageConfig = "image_config"
                case overrides
                case entropy
                case hostname
                case network
            }
        }

        private struct RawReidentifyRequest: Encodable {
            let type: String
            let expectedSandboxId: String
            let expectedNonce: String
            let sandboxId: String
            let identityNonce: String
            let hostname: String
            let entropy: String
            let unixNanos: Int64
            let network: SandboxConfigDrive.NetworkConfig?

            enum CodingKeys: String, CodingKey {
                case type
                case expectedSandboxId = "expected_sandbox_id"
                case expectedNonce = "expected_nonce"
                case sandboxId = "sandbox_id"
                case identityNonce = "identity_nonce"
                case hostname
                case entropy
                case unixNanos = "unix_nanos"
                case network
            }
        }

        /// Encode as a single newline-terminated JSON line.
        public func encodedLine() -> Data {
            var raw: RawRequest
            switch self {
            case .reidentify(let request):
                return Self.terminatedLine(
                    encoding: RawReidentifyRequest(
                        type: "reidentify",
                        expectedSandboxId: request.expectedSandboxId,
                        expectedNonce: request.expectedNonce,
                        sandboxId: request.sandboxId,
                        identityNonce: request.identityNonce,
                        hostname: request.hostname,
                        entropy: request.entropy.base64EncodedString(),
                        unixNanos: request.unixNanos,
                        network: request.network))
            case .launch(let request):
                // The one request with nested payloads — encoded via its own
                // raw shape instead of the flat RawRequest.
                let rawLaunch = RawLaunchRequest(
                    type: "launch",
                    sandboxId: request.sandboxId,
                    identityNonce: request.identityNonce,
                    imageConfig: request.imageConfig,
                    overrides: request.overrides,
                    entropy: request.entropy?.base64EncodedString(),
                    hostname: request.hostname,
                    network: request.network)
                return Self.terminatedLine(encoding: rawLaunch)
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
            case .syncClock(let unixNanos):
                raw = RawRequest(type: "sync_clock")
                raw.unixNanos = unixNanos
            }
            return Self.terminatedLine(encoding: raw)
        }

        /// Encode a raw request shape as one newline-terminated line. A flat
        /// struct of JSON scalars/arrays/string-maps cannot fail to encode;
        /// fall back to an empty line rather than crashing the host if that
        /// invariant is ever broken.
        private static func terminatedLine(encoding raw: some Encodable) -> Data {
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
        /// Warm-start template hold (issue #426): fully booted, deliberately
        /// no workload — waiting to be snapshotted or, post-restore, for a
        /// `launch` request.
        case held
    }

    /// A control response sent guest → host.
    public enum Response: Equatable, Sendable {
        /// `controlProtocolVersion` is nil for guests predating explicit
        /// capability advertisement. Callers must treat nil as legacy rather
        /// than inferring support from the host agent's version.
        case pong(sandboxId: String, nonce: String, controlProtocolVersion: Int?)
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
        /// Terminal for a log follow stream: every workload stdio pipe hit
        /// EOF and all retained records were delivered — no record will ever
        /// follow, so a partial final line can be flushed now.
        case logEof
        /// The guest applied a `sync_clock` request (issue #426).
        case clockSynced
        /// The guest applied a warm-start `launch` request: the workload
        /// spawned under the delivered identity (issue #426).
        case launched
        /// The guest completed fork identity rotation (issue #427).
        case reidentified

        /// Explicitly advertised only by versioned `pong` replies. A missing
        /// value means the checkpointed guest predates capability discovery.
        public var controlProtocolVersion: Int? {
            guard case .pong(_, _, let version) = self else { return nil }
            return version
        }

        /// Decode one response line (the trailing newline is optional).
        ///
        /// Total by construction: every rejection throws a
        /// ``GuestControlError``, including the ones `JSONDecoder` would
        /// otherwise report as a `DecodingError` carrying guest-chosen text.
        /// Callers treat any throw as "close this connection".
        public static func decode(line: String) throws -> Response {
            // Bound the work before doing any: refuse an oversized line rather
            // than trimming, re-encoding, and JSON-scanning it first.
            let lineBytes = line.utf8.count
            guard lineBytes <= Limits.maxLineBytes else {
                throw GuestControlError.responseTooLarge(bytes: lineBytes, limit: Limits.maxLineBytes)
            }

            guard let raw = try? JSONDecoder().decode(RawResponse.self, from: Self.trimmed(line)) else {
                throw GuestControlError.malformed(line)
            }

            switch raw.type {
            case "pong":
                return .pong(
                    sandboxId: try raw.identity(\.sandboxId, field: "sandbox_id"),
                    nonce: try raw.identity(\.nonce, field: "nonce"),
                    controlProtocolVersion: try raw.protocolVersion())
            case "status":
                guard let stateString = raw.state, let state = WorkloadState(rawValue: stateString) else {
                    throw GuestControlError.malformed(line)
                }
                return .status(
                    sandboxId: try raw.identity(\.sandboxId, field: "sandbox_id"),
                    nonce: try raw.identity(\.nonce, field: "nonce"),
                    state: state,
                    exitCode: try raw.boundedExitCode())
            case "error":
                return .error(message: raw.errorMessage())
            case "exec_started":
                return .execStarted
            case "output":
                return .output(stream: try raw.streamLabel(line: line), data: try raw.payload(line: line))
            case "exec_exit":
                guard let exitCode = try raw.boundedExitCode() else {
                    throw GuestControlError.malformed(line)
                }
                return .execExit(exitCode: exitCode)
            case "log":
                return .log(
                    seq: try raw.boundedSeq(line: line),
                    stream: try raw.streamLabel(line: line),
                    data: try raw.payload(line: line))
            case "log_eof":
                return .logEof
            case "clock_synced":
                return .clockSynced
            case "launched":
                return .launched
            case "reidentified":
                return .reidentified
            default:
                throw GuestControlError.malformed(line)
            }
        }

        /// The line's bytes with the framing newline (and any other ASCII
        /// padding) removed from either end.
        ///
        /// Deliberately not `trimmingCharacters(in: .whitespacesAndNewlines)`:
        /// that bridges through `NSString` and a `CharacterSet`, which dominates
        /// the cost of rejecting a junk line — measurable as soon as a fuzzer
        /// (or a guest) throws junk at this in volume. JSON's insignificant
        /// whitespace is ASCII-only anyway, so a byte scan is also the stricter
        /// reading of the format.
        private static func trimmed(_ line: String) -> Data {
            let utf8 = line.utf8
            var start = utf8.startIndex
            var end = utf8.endIndex
            while start < end, isASCIIWhitespace(utf8[start]) {
                start = utf8.index(after: start)
            }
            while end > start, isASCIIWhitespace(utf8[utf8.index(before: end)]) {
                end = utf8.index(before: end)
            }
            return Data(utf8[start..<end])
        }

        private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }
    }

    /// Flat decoding shape for the tagged response union.
    ///
    /// Decoding this only proves the line was JSON of roughly the right shape;
    /// every field is still guest-controlled and unbounded at that point. The
    /// accessors below are the validating layer, and nothing outside this file
    /// reads the stored properties directly.
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
        let controlProtocolVersion: Int?

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
            case controlProtocolVersion = "control_protocol_version"
        }

        /// An echoed identity field, capped. A missing one stays `""` — the
        /// host's identity check reads that as "no identity to match", which is
        /// how guests predating identity echo have always been handled.
        func identity(_ key: KeyPath<RawResponse, String?>, field: String) throws -> String {
            guard let value = self[keyPath: key] else { return "" }
            return try Self.capped(value, field: field, limit: Limits.maxIdentifierBytes)
        }

        /// A guest `error` message, bounded by **truncation** rather than by
        /// rejection — the one field where those differ deliberately.
        ///
        /// Every other capped field is compared against or feeds arithmetic, so
        /// an out-of-contract value must not enter the system at all. `message`
        /// is purely diagnostic: it is logged verbatim and becomes an exec
        /// session's close reason. Throwing here would replace the guest's
        /// actual complaint with "field too large" — losing the only thing the
        /// field is for — and the memory it could cost is already bounded by
        /// the line cap. So it is clipped, with a marker, and delivered.
        func errorMessage() -> String {
            guard let message else { return "" }
            return GuestControlProtocol.elided(message, toUTF8Bytes: Limits.maxMessageBytes)
        }

        /// The `stream` label, which must be one the protocol defines. See
        /// ``GuestControlProtocol/allowedStreams`` for why an arbitrary label is
        /// a memory-growth primitive rather than a curiosity.
        func streamLabel(line: String) throws -> String {
            guard let stream, GuestControlProtocol.allowedStreams.contains(stream) else {
                throw GuestControlError.malformed(line)
            }
            return stream
        }

        /// The base64 `data` field as bytes. The encoded length is checked
        /// first, so an oversized chunk is refused before it is materialized.
        func payload(line: String) throws -> Data {
            guard let data else { throw GuestControlError.malformed(line) }
            let encodedBytes = data.utf8.count
            guard encodedBytes <= Limits.maxEncodedPayloadBytes else {
                throw GuestControlError.fieldTooLarge(
                    field: "data", bytes: encodedBytes, limit: Limits.maxEncodedPayloadBytes)
            }
            guard let decoded = Data(base64Encoded: data) else {
                throw GuestControlError.malformed(line)
            }
            // Implied by the check above, but stated independently so the
            // decoded-size guarantee does not rest on base64's expansion ratio.
            guard decoded.count <= Limits.maxPayloadBytes else {
                throw GuestControlError.fieldTooLarge(
                    field: "data", bytes: decoded.count, limit: Limits.maxPayloadBytes)
            }
            return decoded
        }

        /// A `log` record's sequence number, capped so the host's `lastSeq + 1`
        /// resume arithmetic cannot be driven into an overflow trap.
        func boundedSeq(line: String) throws -> UInt64 {
            guard let seq else { throw GuestControlError.malformed(line) }
            guard seq <= Limits.maxLogSeq else {
                throw GuestControlError.fieldOutOfRange(field: "seq", value: String(seq))
            }
            return seq
        }

        /// An exit code, which the guest declares as an `i32`. Holding the host
        /// to that range keeps the value safe for the `128 + signal` arithmetic
        /// it takes part in on both sides.
        func boundedExitCode() throws -> Int? {
            guard let exitCode else { return nil }
            guard exitCode >= Int(Int32.min), exitCode <= Int(Int32.max) else {
                throw GuestControlError.fieldOutOfRange(field: "exit_code", value: String(exitCode))
            }
            return exitCode
        }

        /// The advertised control protocol version, declared `u32` guest-side.
        /// Callers gate capabilities on it, so a negative or absurd value is a
        /// rejection rather than something to compare against.
        func protocolVersion() throws -> Int? {
            guard let controlProtocolVersion else { return nil }
            guard controlProtocolVersion >= 0, controlProtocolVersion <= Int(UInt32.max) else {
                throw GuestControlError.fieldOutOfRange(
                    field: "control_protocol_version", value: String(controlProtocolVersion))
            }
            return controlProtocolVersion
        }

        private static func capped(_ value: String, field: String, limit: Int) throws -> String {
            let bytes = value.utf8.count
            guard bytes <= limit else {
                throw GuestControlError.fieldTooLarge(field: field, bytes: bytes, limit: limit)
            }
            return value
        }
    }
}

/// Failures speaking the guest control protocol.
public enum GuestControlError: Error, LocalizedError, Equatable, Sendable {
    /// A response line could not be decoded as a known response. The payload is
    /// a bounded excerpt of the offending line, never the whole of it — build
    /// this with ``malformed(_:)`` rather than by hand.
    case malformedResponse(String)
    /// A response line exceeded ``GuestControlProtocol/Limits/maxLineBytes``.
    case responseTooLarge(bytes: Int, limit: Int)
    /// A field exceeded its length cap.
    case fieldTooLarge(field: String, bytes: Int, limit: Int)
    /// A numeric field fell outside the range the protocol allows for it.
    case fieldOutOfRange(field: String, value: String)
    /// The guest returned an `error` response.
    case guestError(String)
    /// No response arrived before the deadline.
    case timeout
    /// The guest echoed an identity that does not match the guest we expect to
    /// be talking to — a stale generation still serving the deterministic vsock
    /// UDS (a leaked process, a pre-adoption resume).
    case identityMismatch(expected: String, got: String)

    /// A ``malformedResponse`` carrying at most
    /// ``GuestControlProtocol/Limits/excerptBytes`` of the offending line.
    public static func malformed(_ line: some StringProtocol) -> GuestControlError {
        .malformedResponse(
            GuestControlProtocol.truncated(line, toUTF8Bytes: GuestControlProtocol.Limits.excerptBytes))
    }

    public var errorDescription: String? {
        switch self {
        case .malformedResponse(let line):
            return "malformed guest control response: \(line)"
        case .responseTooLarge(let bytes, let limit):
            return "guest control response line of \(bytes) bytes exceeds the \(limit) byte limit"
        case .fieldTooLarge(let field, let bytes, let limit):
            return "guest control response field '\(field)' of \(bytes) bytes exceeds the \(limit) byte limit"
        case .fieldOutOfRange(let field, let value):
            return "guest control response field '\(field)' is out of range: \(value)"
        case .guestError(let message):
            return "guest control agent error: \(message)"
        case .timeout:
            return "timed out waiting for the guest control agent"
        case .identityMismatch(let expected, let got):
            return "guest identity mismatch: expected \(expected), got \(got)"
        }
    }
}
