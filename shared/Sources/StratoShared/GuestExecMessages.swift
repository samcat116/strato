import Foundation
import SwiftProtobuf

// MARK: - Guest Exec Messages (STR-78/STR-260; resource kind v44, session kind/state v56)
//
// Control plane ⟷ agent messages carrying an exec session inside a guest. The
// resource discriminator selects either a VM or a sandbox; the session-kind
// discriminator separates live interactive streams from recorded commands that
// survive a control-plane WebSocket reconnect while the agent process stays
// alive. The agent bridges both kinds to that guest's control protocol.
//
// Interactive frames are stream messages: correlated by `sessionId` (not
// `requestId`), ordered by the WebSocket, and never answered with
// `success`/`error`. A `guestExecStart` is answered by `guestExecStarted` on
// success or `guestExecClosed` (with a reason) on failure. Recorded reconnect
// state is instead a full level-triggered snapshot keyed by the same session.

/// A resource whose guest control channel can host an exec session.
public typealias GuestResourceKind = Strato_Agent_V1_GuestResourceKind
extension Strato_Agent_V1_GuestResourceKind: Codable {

    public var protocolValue: String {
        switch self {
        case .virtualMachine: return "virtual_machine"
        case .sandbox: return "sandbox"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "virtual_machine": self = .virtualMachine
        case "sandbox": self = .sandbox
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.virtualMachine, .sandbox] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// Whether an exec session is tied to a live frontend or records a durable
/// command result for later retrieval.
public typealias GuestExecSessionKind = Strato_Agent_V1_GuestExecSessionKind
extension Strato_Agent_V1_GuestExecSessionKind: Codable {

    public var protocolValue: String {
        switch self {
        case .interactive: return "interactive"
        case .recorded: return "recorded"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "interactive": self = .interactive
        case "recorded": self = .recorded
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.interactive, .recorded] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// Control plane → agent: start an exec session inside a running guest.
public typealias GuestExecStartMessage = Strato_Agent_V1_GuestExecStartMessage
extension Strato_Agent_V1_GuestExecStartMessage: WebSocketMessage {
    public var type: MessageType { .guestExecStart }
    /// Interactive sessions end with their frontend connection. Recorded
    /// sessions survive a control-plane WebSocket reconnect while this agent
    /// process remains alive and replay their state until acknowledged.
    /// Control-plane-minted session identifier every subsequent message on
    /// this exec session carries.
    /// The argv to run in the guest context. Never empty.
    /// Extra environment merged over the workload's resolved environment.
    /// Working directory; nil inherits the workload's resolved cwd.
    /// Allocate a PTY. When true all output arrives as the `stdout` stream.

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        resourceKind: GuestResourceKind,
        resourceId: String,
        sessionKind: GuestExecSessionKind,
        sessionId: String,
        command: [String],
        env: [String: String]? = nil,
        workingDir: String? = nil,
        tty: Bool = false,
        rows: Int? = nil,
        cols: Int? = nil
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonResourceKind = resourceKind
        self._jsonResourceId = resourceId
        self._jsonSessionKind = sessionKind
        self._jsonSessionId = sessionId
        self._jsonCommand = command
        self._jsonEnv = env
        self._jsonWorkingDir = workingDir
        self._jsonTty = tty
        self._jsonRows = rows
        self._jsonCols = cols
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case resourceKind; case resourceId; case sessionKind; case sessionId;
        case command; case env; case workingDir; case tty; case rows; case cols
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonResourceKind = try container.decode(GuestResourceKind.self, forKey: .resourceKind)
        self._jsonResourceId = try container.decode(String.self, forKey: .resourceId)
        self._jsonSessionKind = try container.decode(GuestExecSessionKind.self, forKey: .sessionKind)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonCommand = try container.decode([String].self, forKey: .command)
        self._jsonEnv = try container.decodeIfPresent([String: String].self, forKey: .env)
        self._jsonWorkingDir = try container.decodeIfPresent(String.self, forKey: .workingDir)
        self._jsonTty = try container.decode(Bool.self, forKey: .tty)
        self._jsonRows = try container.decodeIfPresent(Int.self, forKey: .rows)
        self._jsonCols = try container.decodeIfPresent(Int.self, forKey: .cols)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonResourceKind, forKey: .resourceKind)
        try container.encode(_jsonResourceId, forKey: .resourceId)
        try container.encode(_jsonSessionKind, forKey: .sessionKind)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encode(_jsonCommand, forKey: .command)
        try container.encodeIfPresent(_jsonEnv, forKey: .env)
        try container.encodeIfPresent(_jsonWorkingDir, forKey: .workingDir)
        try container.encode(_jsonTty, forKey: .tty)
        try container.encodeIfPresent(_jsonRows, forKey: .rows)
        try container.encodeIfPresent(_jsonCols, forKey: .cols)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonResourceKind: GuestResourceKind {
        get { resourceKind }
        set { let value = newValue; resourceKind = value }
    }
    var _jsonResourceId: String {
        get { resourceID }
        set { let value = newValue; resourceID = value }
    }
    var _jsonSessionKind: GuestExecSessionKind {
        get { sessionKind }
        set { let value = newValue; sessionKind = value }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonCommand: [String] {
        get { command.values }
        set {
            let value = newValue;
            command = Strato_Agent_V1_GuestExecStartMessageCommandSection.with { $0.values = value }
        }
    }
    var _jsonEnv: [String: String]? {
        get { hasEnv ? (env.values) : nil }
        set {
            if let value = newValue {
                env = Strato_Agent_V1_GuestExecStartMessageEnvSection.with { $0.values = value }
            } else {
                clearEnv()
            }
        }
    }
    var _jsonWorkingDir: String? {
        get { hasWorkingDir ? (workingDir) : nil }
        set { if let value = newValue { workingDir = value } else { clearWorkingDir() } }
    }
    var _jsonTty: Bool {
        get { tty }
        set { let value = newValue; tty = value }
    }
    var _jsonRows: Int? {
        get { hasRows ? (Int(rows)) : nil }
        set { if let value = newValue { rows = Int64(value) } else { clearRows() } }
    }
    var _jsonCols: Int? {
        get { hasCols ? (Int(cols)) : nil }
        set { if let value = newValue { cols = Int64(value) } else { clearCols() } }
    }
}

/// The agent's current state for a recorded exec session.
public typealias GuestExecRecordedStatus = Strato_Agent_V1_GuestExecRecordedStatus
extension Strato_Agent_V1_GuestExecRecordedStatus: Codable {

    public var isTerminal: Bool {
        self != .running
    }

    public var protocolValue: String {
        switch self {
        case .running: return "running"
        case .exited: return "exited"
        case .closed: return "closed"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "running": self = .running
        case "exited": self = .exited
        case "closed": self = .closed
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.running, .exited, .closed] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// Agent → control plane: the complete bounded state of a recorded exec
/// session. This is a level-triggered snapshot, not an output delta or a reply.
///
/// The agent re-offers running snapshots after registration and replays a
/// terminal snapshot until it receives ``GuestExecRecordedAckMessage``. The
/// status fields have these invariants:
///
/// - `running`: `exitCode` and `reason` are nil.
/// - `exited`: `exitCode` is non-nil and `reason` is nil.
/// - `closed`: `exitCode` is nil and `reason` is non-nil.
///
/// `revision` is a non-negative, per-session counter. The agent advances it
/// whenever the authoritative capture changes, so replicas can reject an older
/// snapshot after a reconnect without relying on socket arrival order.
///
/// `stdout` and `stderr` are authoritative base64-encoded snapshots. Their
/// combined decoded size never exceeds ``outputLimitBytes``. `truncated` says
/// the capture may be incomplete: either bytes exceeded that bound or the
/// channel closed without an authoritative `exec_exit` record.
public typealias GuestExecRecordedStateMessage = Strato_Agent_V1_GuestExecRecordedStateMessage
extension Strato_Agent_V1_GuestExecRecordedStateMessage: WebSocketMessage {
    /// Maximum combined decoded stdout and stderr retained for one recorded
    /// session. Both peers use this value so the replay remains bounded.
    public static let outputLimitBytes = 1_048_576

    public var type: MessageType { .guestExecRecordedState }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        revision: Int64,
        status: GuestExecRecordedStatus,
        stdout: String,
        stderr: String,
        exitCode: Int? = nil,
        reason: String? = nil,
        truncated: Bool
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSessionId = sessionId
        self._jsonRevision = revision
        self._jsonStatus = status
        self._jsonStdout = stdout
        self._jsonStderr = stderr
        self._jsonExitCode = exitCode
        self._jsonReason = reason
        self._jsonTruncated = truncated
    }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        revision: Int64,
        status: GuestExecRecordedStatus,
        rawStdout: Data,
        rawStderr: Data,
        exitCode: Int? = nil,
        reason: String? = nil,
        truncated: Bool
    ) {
        self.init(
            requestId: requestId,
            timestamp: timestamp,
            sessionId: sessionId,
            revision: revision,
            status: status,
            stdout: "",
            stderr: "",
            exitCode: exitCode,
            reason: reason,
            truncated: truncated
        )
        self.stdout = rawStdout
        self.stderr = rawStderr
    }

    public var rawStdout: Data? {
        hasStdout ? stdout : nil
    }

    public var rawStderr: Data? {
        hasStderr ? stderr : nil
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case sessionId; case revision; case status; case stdout; case stderr;
        case exitCode; case reason; case truncated
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonRevision = try container.decode(Int64.self, forKey: .revision)
        self._jsonStatus = try container.decode(GuestExecRecordedStatus.self, forKey: .status)
        self._jsonStdout = try container.decode(String.self, forKey: .stdout)
        self._jsonStderr = try container.decode(String.self, forKey: .stderr)
        self._jsonExitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        self._jsonReason = try container.decodeIfPresent(String.self, forKey: .reason)
        self._jsonTruncated = try container.decode(Bool.self, forKey: .truncated)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encode(_jsonRevision, forKey: .revision)
        try container.encode(_jsonStatus, forKey: .status)
        try container.encode(_jsonStdout, forKey: .stdout)
        try container.encode(_jsonStderr, forKey: .stderr)
        try container.encodeIfPresent(_jsonExitCode, forKey: .exitCode)
        try container.encodeIfPresent(_jsonReason, forKey: .reason)
        try container.encode(_jsonTruncated, forKey: .truncated)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonRevision: Int64 {
        get { revision }
        set { let value = newValue; revision = value }
    }
    var _jsonStatus: GuestExecRecordedStatus {
        get { status }
        set { let value = newValue; status = value }
    }
    var _jsonStdout: String {
        get { stdout.base64EncodedString() }
        set {
            let value = newValue; if let bytes = Data(base64Encoded: value) { stdout = bytes } else { clearStdout() }
        }
    }
    var _jsonStderr: String {
        get { stderr.base64EncodedString() }
        set {
            let value = newValue; if let bytes = Data(base64Encoded: value) { stderr = bytes } else { clearStderr() }
        }
    }
    var _jsonExitCode: Int? {
        get { hasExitCode ? (Int(exitCode)) : nil }
        set { if let value = newValue { exitCode = Int64(value) } else { clearExitCode() } }
    }
    var _jsonReason: String? {
        get { hasReason ? (reason) : nil }
        set { if let value = newValue { reason = value } else { clearReason() } }
    }
    var _jsonTruncated: Bool {
        get { truncated }
        set { let value = newValue; truncated = value }
    }
}

/// Control plane → agent: retire a terminal recorded-session snapshot after
/// the control plane durably committed or deliberately discarded its outcome.
///
/// This typed acknowledgement is keyed by `sessionId`. Its independently
/// minted `requestId` is only a log-correlation handle; it does not correlate
/// this message as a generic RPC reply. An acknowledgement is meaningful only
/// for an `exited` or `closed` snapshot.
public typealias GuestExecRecordedAckMessage = Strato_Agent_V1_GuestExecRecordedAckMessage
extension Strato_Agent_V1_GuestExecRecordedAckMessage: WebSocketMessage {
    public var type: MessageType { .guestExecRecordedAck }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSessionId = sessionId
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case sessionId }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSessionId, forKey: .sessionId)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
}

/// Agent → control plane: the exec process spawned; output may follow.
public typealias GuestExecStartedMessage = Strato_Agent_V1_GuestExecStartedMessage
extension Strato_Agent_V1_GuestExecStartedMessage: WebSocketMessage {
    public var type: MessageType { .guestExecStarted }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSessionId = sessionId
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case sessionId }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSessionId, forKey: .sessionId)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
}

/// Control plane → agent: stdin bytes for the exec process, and/or stdin EOF.
public typealias GuestExecInputMessage = Strato_Agent_V1_GuestExecInputMessage
extension Strato_Agent_V1_GuestExecInputMessage: WebSocketMessage {
    public var type: MessageType { .guestExecInput }
    /// Base64-encoded stdin bytes; nil for an EOF-only message.
    /// Close the exec process's stdin after writing `data` (if any).

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        data: String? = nil,
        eof: Bool = false
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSessionId = sessionId
        self._jsonData = data
        self._jsonEof = eof
    }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        rawData: Data,
        eof: Bool = false
    ) {
        self.init(
            requestId: requestId, timestamp: timestamp, sessionId: sessionId,
            data: nil, eof: eof)
        self.data = rawData
    }

    public var rawData: Data? {
        hasData ? data : nil
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case sessionId; case data; case eof }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonData = try container.decodeIfPresent(String.self, forKey: .data)
        self._jsonEof = try container.decode(Bool.self, forKey: .eof)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encodeIfPresent(_jsonData, forKey: .data)
        try container.encode(_jsonEof, forKey: .eof)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonData: String? {
        get { hasData ? (data.base64EncodedString()) : nil }
        set {
            if let value = newValue {
                if let bytes = Data(base64Encoded: value) { data = bytes } else { clearData() }
            } else {
                clearData()
            }
        }
    }
    var _jsonEof: Bool {
        get { eof }
        set { let value = newValue; eof = value }
    }
}

/// Agent → control plane: output bytes from the exec process.
public typealias GuestExecOutputMessage = Strato_Agent_V1_GuestExecOutputMessage
extension Strato_Agent_V1_GuestExecOutputMessage: WebSocketMessage {
    public var type: MessageType { .guestExecOutput }
    /// `stdout` or `stderr`; PTY sessions always use `stdout`.
    /// Base64-encoded output bytes.

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        stream: String,
        data: String
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSessionId = sessionId
        self._jsonStream = stream
        self._jsonData = data
    }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        stream: String,
        rawData: Data
    ) {
        self.init(
            requestId: requestId, timestamp: timestamp, sessionId: sessionId, stream: stream,
            data: "")
        self.data = rawData
    }

    public var rawData: Data? {
        hasData ? data : nil
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case sessionId; case stream; case data
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonStream = try container.decode(String.self, forKey: .stream)
        self._jsonData = try container.decode(String.self, forKey: .data)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encode(_jsonStream, forKey: .stream)
        try container.encode(_jsonData, forKey: .data)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonStream: String {
        get { stream }
        set { let value = newValue; stream = value }
    }
    var _jsonData: String {
        get { data.base64EncodedString() }
        set { let value = newValue; if let bytes = Data(base64Encoded: value) { data = bytes } else { clearData() } }
    }
}

/// Control plane → agent: resize the exec session's PTY.
public typealias GuestExecResizeMessage = Strato_Agent_V1_GuestExecResizeMessage
extension Strato_Agent_V1_GuestExecResizeMessage: WebSocketMessage {
    public var type: MessageType { .guestExecResize }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        rows: Int,
        cols: Int
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSessionId = sessionId
        self._jsonRows = rows
        self._jsonCols = cols
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case sessionId; case rows; case cols }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonRows = try container.decode(Int.self, forKey: .rows)
        self._jsonCols = try container.decode(Int.self, forKey: .cols)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encode(_jsonRows, forKey: .rows)
        try container.encode(_jsonCols, forKey: .cols)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonRows: Int {
        get { Int(rows) }
        set { let value = newValue; rows = Int64(value) }
    }
    var _jsonCols: Int {
        get { Int(cols) }
        set { let value = newValue; cols = Int64(value) }
    }
}

/// Agent → control plane: the exec process ended. Terminal for the session;
/// all output was sent before this message.
public typealias GuestExecExitMessage = Strato_Agent_V1_GuestExecExitMessage
extension Strato_Agent_V1_GuestExecExitMessage: WebSocketMessage {
    public var type: MessageType { .guestExecExit }
    /// Shell convention: a process killed by signal N reports 128 + N.

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        exitCode: Int
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSessionId = sessionId
        self._jsonExitCode = exitCode
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case sessionId; case exitCode }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonExitCode = try container.decode(Int.self, forKey: .exitCode)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encode(_jsonExitCode, forKey: .exitCode)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonExitCode: Int {
        get { Int(exitCode) }
        set { let value = newValue; exitCode = Int64(value) }
    }
}

/// Control plane → agent: tear down an exec session (the browser went away).
public typealias GuestExecCloseMessage = Strato_Agent_V1_GuestExecCloseMessage
extension Strato_Agent_V1_GuestExecCloseMessage: WebSocketMessage {
    public var type: MessageType { .guestExecClose }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        reason: String? = nil
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSessionId = sessionId
        self._jsonReason = reason
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case sessionId; case reason }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonReason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encodeIfPresent(_jsonReason, forKey: .reason)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonReason: String? {
        get { hasReason ? (reason) : nil }
        set { if let value = newValue { reason = value } else { clearReason() } }
    }
}

/// Agent → control plane: the exec session ended without an exit code — the
/// spawn failed, the guest channel died, or the resource stopped. Terminal for
/// the session.
public typealias GuestExecClosedMessage = Strato_Agent_V1_GuestExecClosedMessage
extension Strato_Agent_V1_GuestExecClosedMessage: WebSocketMessage {
    public var type: MessageType { .guestExecClosed }

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sessionId: String,
        reason: String? = nil
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSessionId = sessionId
        self._jsonReason = reason
    }

    private enum CodingKeys: String, CodingKey { case requestId; case timestamp; case sessionId; case reason }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSessionId = try container.decode(String.self, forKey: .sessionId)
        self._jsonReason = try container.decodeIfPresent(String.self, forKey: .reason)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSessionId, forKey: .sessionId)
        try container.encodeIfPresent(_jsonReason, forKey: .reason)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonSessionId: String {
        get { sessionID }
        set { let value = newValue; sessionID = value }
    }
    var _jsonReason: String? {
        get { hasReason ? (reason) : nil }
        set { if let value = newValue { reason = value } else { clearReason() } }
    }
}

// MARK: - Sandbox Workload Logs

/// Agent → control plane: one line of the sandbox workload's stdout/stderr,
/// destined for Loki (the sandbox counterpart of `VMLogMessage`).
public typealias SandboxLogMessage = Strato_Agent_V1_SandboxLogMessage
extension Strato_Agent_V1_SandboxLogMessage: WebSocketMessage {
    public var type: MessageType { .sandboxLog }
    /// "stdout" or "stderr".
    /// One output line, decoded as UTF-8 (lossily) with the newline stripped.

    public init(
        requestId: String = UUID().uuidString,
        timestamp: Date = Date(),
        sandboxId: String,
        stream: String,
        message: String
    ) {
        self.init()
        self._jsonRequestId = requestId
        self._jsonTimestamp = timestamp
        self._jsonSandboxId = sandboxId
        self._jsonStream = stream
        self._jsonMessage = message
    }

    private enum CodingKeys: String, CodingKey {
        case requestId; case timestamp; case sandboxId; case stream; case message
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonRequestId = try container.decode(String.self, forKey: .requestId)
        self._jsonTimestamp = try container.decode(Date.self, forKey: .timestamp)
        self._jsonSandboxId = try container.decode(String.self, forKey: .sandboxId)
        self._jsonStream = try container.decode(String.self, forKey: .stream)
        self._jsonMessage = try container.decode(String.self, forKey: .message)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonRequestId, forKey: .requestId)
        try container.encode(_jsonTimestamp, forKey: .timestamp)
        try container.encode(_jsonSandboxId, forKey: .sandboxId)
        try container.encode(_jsonStream, forKey: .stream)
        try container.encode(_jsonMessage, forKey: .message)
    }

    var _jsonRequestId: String {
        get { requestID }
        set { let value = newValue; requestID = value }
    }
    var _jsonTimestamp: Date {
        get { timestamp.date }
        set { let value = newValue; timestamp = Google_Protobuf_Timestamp(date: value) }
    }
    var _jsonSandboxId: String {
        get { sandboxID }
        set { let value = newValue; sandboxID = value }
    }
    var _jsonStream: String {
        get { stream }
        set { let value = newValue; stream = value }
    }
    var _jsonMessage: String {
        get { message }
        set { let value = newValue; message = value }
    }
}
