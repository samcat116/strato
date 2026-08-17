import Foundation
import HTTPTypes
import NIOCore
import NIOHTTP1
import NIOPosix
import OpenAPIRuntime
import StratoAPIClient
import Synchronization
import WebSocketKit

public struct GuestExecTerminalSize: Sendable, Equatable {
    public let rows: Int
    public let cols: Int

    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
    }
}

public enum GuestExecOutput: Sendable, Equatable {
    case stdout(Data)
    case stderr(Data)
}

public enum GuestExecOutputMode: Sendable, Equatable {
    case raw
    case multiplexed

    fileprivate var schemaValue: Components.Schemas.GuestExecOutputMode {
        switch self {
        case .raw: .raw
        case .multiplexed: .multiplexed
        }
    }
}

/// One complete guest-exec invocation. The session module owns both the HTTP
/// mint and WebSocket attach so callers do not need to understand the
/// replica-local, single-use protocol.
public struct GuestExecInvocation: Sendable {
    public let sandboxID: String
    public let command: [String]
    public let environment: [String: String]?
    public let workingDirectory: String?
    public let tty: Bool
    public let initialSize: GuestExecTerminalSize?
    public let outputMode: GuestExecOutputMode
    public let input: AsyncStream<Data>?
    public let closeStdinWhenInputEnds: Bool
    public let resizes: AsyncStream<GuestExecTerminalSize>?

    public init(
        sandboxID: String,
        command: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        tty: Bool,
        initialSize: GuestExecTerminalSize? = nil,
        outputMode: GuestExecOutputMode,
        input: AsyncStream<Data>? = nil,
        closeStdinWhenInputEnds: Bool = false,
        resizes: AsyncStream<GuestExecTerminalSize>? = nil
    ) {
        self.sandboxID = sandboxID
        self.command = command
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.tty = tty
        self.initialSize = initialSize
        self.outputMode = outputMode
        self.input = input
        self.closeStdinWhenInputEnds = closeStdinWhenInputEnds
        self.resizes = resizes
    }
}

/// Deep session module used by both `sandbox exec` and `sandbox attach`.
/// Authentication, typed minting, replica retries, frame validation, ordered
/// input, and cleanup all remain behind this single `run` interface.
public struct GuestExecSessionClient: Sendable {
    private static let mintRetryBudget: TimeInterval = 30
    private static let retryDelay: Duration = .milliseconds(500)
    private static let retryableAttachError =
        "Invalid, expired, or already attached exec session"

    private let serverURL: URL
    private let client: any APIProtocol
    private let credentials: CredentialSession
    private let connector: any GuestExecSocketConnecting
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        serverURL: URL,
        client: any APIProtocol,
        credentials: CredentialSession
    ) {
        self.init(
            serverURL: serverURL,
            client: client,
            credentials: credentials,
            connector: WebSocketKitGuestExecConnector(),
            now: Date.init,
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    init(
        serverURL: URL,
        client: any APIProtocol,
        credentials: CredentialSession,
        connector: any GuestExecSocketConnecting,
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.serverURL = serverURL
        self.client = client
        self.credentials = credentials
        self.connector = connector
        self.now = now
        self.sleep = sleep
    }

    /// Runs until the remote process exits and returns its shell-style exit
    /// code. Output callbacks are invoked in WebSocket arrival order.
    public func run(
        _ invocation: GuestExecInvocation,
        onOutput: @escaping @Sendable (GuestExecOutput) -> Void
    ) async throws -> Int32 {
        guard !invocation.command.isEmpty else {
            throw CLIError.config("Guest exec requires a non-empty command.")
        }

        let minted = try await mint(invocation)
        if let selectedMode = minted.outputMode,
            selectedMode != invocation.outputMode
        {
            throw CLIError.unexpectedResponse(
                "The control plane selected a different guest-exec output mode than requested.")
        }
        if invocation.outputMode == .multiplexed, minted.outputMode == nil {
            throw CLIError.unexpectedResponse(
                "The control plane did not negotiate multiplexed guest-exec output.")
        }

        let socket = try await attach(minted)
        do {
            let code = try await runAttached(socket, invocation: invocation, onOutput: onOutput)
            await socket.close()
            return code
        } catch {
            await socket.close()
            throw error
        }
    }

    private func mint(_ invocation: GuestExecInvocation) async throws -> MintedSession {
        let deadline = now().addingTimeInterval(Self.mintRetryBudget)
        let environment = invocation.environment.map {
            Components.Schemas.GuestExecRequest.EnvPayload(additionalProperties: $0)
        }
        let request = Components.Schemas.GuestExecRequest(
            command: invocation.command,
            env: environment,
            workingDir: invocation.workingDirectory,
            tty: invocation.tty,
            rows: invocation.initialSize?.rows,
            cols: invocation.initialSize?.cols,
            outputMode: invocation.outputMode.schemaValue
        )

        while true {
            do {
                let response = try await client.createSandboxExecSession(
                    path: .init(sandboxID: invocation.sandboxID),
                    body: .json(request)
                ).created.body.json
                return MintedSession(
                    websocketPath: response.websocketPath,
                    expiresAt: response.expiresAt,
                    outputMode: response.outputMode.map(Self.outputMode)
                )
            } catch {
                guard let cliError = CLIError.from(error) else { throw error }
                guard case .api(let status, _) = cliError,
                    status == 503,
                    now() < deadline
                else {
                    throw cliError
                }
                try await sleep(Self.retryDelay)
            }
        }
    }

    private func attach(_ session: MintedSession) async throws -> any GuestExecSocket {
        let websocketURL = try Self.websocketURL(
            serverURL: serverURL, websocketPath: session.websocketPath)

        while now() < session.expiresAt {
            let token = try await credentials.accessToken()
            let socket: any GuestExecSocket
            do {
                socket = try await connector.connect(url: websocketURL, bearerToken: token)
            } catch {
                throw CLIError.network("Could not attach guest exec WebSocket: \(error)")
            }

            do {
                guard let first = try await socket.nextFrame() else {
                    await socket.close()
                    throw CLIError.network("Guest exec WebSocket closed before the process started.")
                }
                switch try Self.control(from: first) {
                case .ready:
                    return socket
                case .error(let message) where message == Self.retryableAttachError:
                    await socket.close()
                    if now() < session.expiresAt {
                        try await sleep(Self.retryDelay)
                        continue
                    }
                    throw CLIError.guestExec(message)
                case .error(let message):
                    await socket.close()
                    throw CLIError.guestExec(message)
                case .exit:
                    await socket.close()
                    throw CLIError.unexpectedResponse(
                        "Guest exec exited before reporting that the process started.")
                }
            } catch {
                await socket.close()
                throw error
            }
        }
        throw CLIError.timedOut("The guest exec session expired before it could attach.")
    }

    private func runAttached(
        _ socket: any GuestExecSocket,
        invocation: GuestExecInvocation,
        onOutput: @escaping @Sendable (GuestExecOutput) -> Void
    ) async throws -> Int32 {
        try await withThrowingTaskGroup(of: SessionTaskResult.self) { group in
            group.addTask {
                if let input = invocation.input {
                    for await data in input where !data.isEmpty {
                        try Task.checkCancellation()
                        try await socket.send(binary: data)
                    }
                }
                if invocation.closeStdinWhenInputEnds {
                    try await socket.send(text: #"{"type":"stdin_eof"}"#)
                }
                return .sideFinished
            }

            if let resizes = invocation.resizes {
                group.addTask {
                    for await size in resizes {
                        try Task.checkCancellation()
                        let data = try JSONEncoder().encode(
                            ResizeControl(type: "resize", cols: size.cols, rows: size.rows))
                        try await socket.send(text: String(decoding: data, as: UTF8.self))
                    }
                    return .sideFinished
                }
            }

            group.addTask {
                while let frame = try await socket.nextFrame() {
                    switch frame {
                    case .binary(let data):
                        onOutput(try Self.output(from: data, mode: invocation.outputMode))
                    case .text:
                        switch try Self.control(from: frame) {
                        case .ready:
                            throw CLIError.unexpectedResponse(
                                "Guest exec sent more than one ready frame.")
                        case .exit(let code):
                            guard (0...255).contains(code) else {
                                throw CLIError.unexpectedResponse(
                                    "Guest exec returned invalid exit code \(code).")
                            }
                            return .exit(Int32(code))
                        case .error(let message):
                            throw CLIError.guestExec(message)
                        }
                    }
                }
                throw CLIError.network("Guest exec WebSocket closed without an exit status.")
            }

            while let result = try await group.next() {
                switch result {
                case .sideFinished:
                    continue
                case .exit(let code):
                    group.cancelAll()
                    return code
                }
            }
            throw CLIError.network("Guest exec ended without an exit status.")
        }
    }

    private static func websocketURL(serverURL: URL, websocketPath: String) throws -> URL {
        let request = HTTPRequest(
            method: .get, scheme: nil, authority: nil, path: websocketPath)
        let httpURL = try URLSessionClientTransport.url(baseURL: serverURL, request: request)
        guard var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false) else {
            throw CLIError.network("Could not build the guest exec WebSocket URL.")
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default:
            throw CLIError.config("The control plane URL must use http or https.")
        }
        guard let url = components.url else {
            throw CLIError.network("Could not build the guest exec WebSocket URL.")
        }
        return url
    }

    private static func outputMode(
        _ value: Components.Schemas.GuestExecOutputMode
    ) -> GuestExecOutputMode {
        switch value {
        case .raw: .raw
        case .multiplexed: .multiplexed
        }
    }

    private static func output(from data: Data, mode: GuestExecOutputMode) throws -> GuestExecOutput {
        switch mode {
        case .raw:
            return .stdout(data)
        case .multiplexed:
            guard let tag = data.first else {
                throw CLIError.unexpectedResponse("Guest exec sent an empty multiplexed output frame.")
            }
            let payload = Data(data.dropFirst())
            switch tag {
            case 0x01: return .stdout(payload)
            case 0x02: return .stderr(payload)
            default:
                throw CLIError.unexpectedResponse(
                    "Guest exec sent unknown output stream tag \(tag).")
            }
        }
    }

    private static func control(from frame: GuestExecSocketFrame) throws -> ServerControl {
        guard case .text(let text) = frame else {
            throw CLIError.unexpectedResponse(
                "Guest exec sent output before its ready control frame.")
        }
        let decoded: ServerControlFrame
        do {
            decoded = try JSONDecoder().decode(ServerControlFrame.self, from: Data(text.utf8))
        } catch {
            throw CLIError.unexpectedResponse("Guest exec sent a malformed control frame.")
        }
        switch decoded.type {
        case "ready": return .ready
        case "exit":
            guard let code = decoded.exitCode else {
                throw CLIError.unexpectedResponse("Guest exec exit frame omitted its exit code.")
            }
            return .exit(code)
        case "error": return .error(decoded.message ?? "Guest exec session failed.")
        default:
            throw CLIError.unexpectedResponse(
                "Guest exec sent unknown control frame '\(decoded.type)'.")
        }
    }

    private struct MintedSession: Sendable {
        let websocketPath: String
        let expiresAt: Date
        let outputMode: GuestExecOutputMode?
    }

    private struct ServerControlFrame: Decodable {
        let type: String
        let exitCode: Int?
        let message: String?
    }

    private struct ResizeControl: Encodable {
        let type: String
        let cols: Int
        let rows: Int
    }

    private enum ServerControl {
        case ready
        case exit(Int)
        case error(String)
    }

    private enum SessionTaskResult: Sendable {
        case sideFinished
        case exit(Int32)
    }
}

enum GuestExecSocketFrame: Sendable, Equatable {
    case text(String)
    case binary(Data)
}

protocol GuestExecSocket: Sendable {
    func nextFrame() async throws -> GuestExecSocketFrame?
    func send(binary: Data) async throws
    func send(text: String) async throws
    func close() async
}

protocol GuestExecSocketConnecting: Sendable {
    func connect(url: URL, bearerToken: String) async throws -> any GuestExecSocket
}

typealias GuestExecWebSocketConnect =
    @Sendable (
        URL,
        HTTPHeaders,
        WebSocketClient.Configuration,
        any EventLoopGroup,
        @Sendable @escaping (WebSocket) -> Void
    ) -> EventLoopFuture<Void>

struct WebSocketKitGuestExecConnector: GuestExecSocketConnecting {
    private let startConnect: GuestExecWebSocketConnect

    init(
        startConnect: @escaping GuestExecWebSocketConnect = {
            url, headers, configuration, group,
            onUpgrade in
            WebSocket.connect(
                to: url,
                headers: headers,
                configuration: configuration,
                on: group,
                onUpgrade: onUpgrade)
        }
    ) {
        self.startConnect = startConnect
    }

    func connect(url: URL, bearerToken: String) async throws -> any GuestExecSocket {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: "Bearer \(bearerToken)")
        var configuration = WebSocketClient.Configuration()
        configuration.maxFrameSize = 1 << 20

        do {
            let attempt = GuestExecWebSocketConnectAttempt()
            let socket = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    guard attempt.install(continuation) else { return }
                    let future = startConnect(url, headers, configuration, group) { socket in
                        if !attempt.succeed(with: socket) {
                            _ = socket.close(code: .goingAway)
                        }
                    }
                    future.whenFailure { error in
                        attempt.fail(with: error)
                    }
                }
            } onCancel: {
                attempt.cancel()
                group.shutdownGracefully { _ in
                }
            }

            if Task.isCancelled {
                try? await socket.close(code: .goingAway)
                throw CancellationError()
            }
            return WebSocketKitGuestExecSocket(socket: socket, group: group)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }
}

private final class GuestExecWebSocketConnectAttempt: Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<WebSocket, any Error>)
        case cancelled
        case finished
    }

    private let state = Mutex(State.pending)

    func install(_ continuation: CheckedContinuation<WebSocket, any Error>) -> Bool {
        let installed = state.withLock { state -> Bool in
            switch state {
            case .pending:
                state = .waiting(continuation)
                return true
            case .cancelled:
                return false
            case .waiting, .finished:
                preconditionFailure("WebSocket continuation installed more than once")
            }
        }
        if !installed {
            continuation.resume(throwing: CancellationError())
        }
        return installed
    }

    func succeed(with socket: WebSocket) -> Bool {
        resolve { $0.resume(returning: socket) }
    }

    func fail(with error: any Error) {
        _ = resolve { $0.resume(throwing: error) }
    }

    func cancel() {
        let continuation = state.withLock { state -> CheckedContinuation<WebSocket, any Error>? in
            switch state {
            case .pending, .waiting:
                let continuation: CheckedContinuation<WebSocket, any Error>?
                if case .waiting(let waiting) = state {
                    continuation = waiting
                } else {
                    continuation = nil
                }
                state = .cancelled
                return continuation
            case .cancelled, .finished:
                return nil
            }
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func resolve(
        _ body: (CheckedContinuation<WebSocket, any Error>) -> Void
    ) -> Bool {
        let continuation = state.withLock { state -> CheckedContinuation<WebSocket, any Error>? in
            guard case .waiting(let continuation) = state else { return nil }
            state = .finished
            return continuation
        }
        guard let continuation else { return false }
        body(continuation)
        return true
    }
}

private actor WebSocketKitGuestExecSocket: GuestExecSocket {
    private let socket: WebSocket
    private let group: MultiThreadedEventLoopGroup
    private let frames = GuestExecFrameQueue()
    private var closed = false

    init(socket: WebSocket, group: MultiThreadedEventLoopGroup) {
        self.socket = socket
        self.group = group
        let frames = self.frames
        socket.onBinary { _, buffer in
            frames.yield(.binary(Data(buffer.readableBytesView)))
        }
        socket.onText { _, text in
            frames.yield(.text(text))
        }
        socket.onClose.whenComplete { result in
            switch result {
            case .success:
                frames.finish()
            case .failure(let error):
                frames.finish(error: .network("Guest exec WebSocket failed: \(error)"))
            }
        }
    }

    func nextFrame() async throws -> GuestExecSocketFrame? {
        try await frames.next()
    }

    func send(binary: Data) async throws {
        guard !closed, !socket.isClosed else {
            throw CLIError.network("Guest exec WebSocket is closed.")
        }
        let promise = socket.eventLoop.makePromise(of: Void.self)
        socket.send(binary, promise: promise)
        try await promise.futureResult.get()
    }

    func send(text: String) async throws {
        guard !closed, !socket.isClosed else {
            throw CLIError.network("Guest exec WebSocket is closed.")
        }
        let promise = socket.eventLoop.makePromise(of: Void.self)
        socket.send(text, promise: promise)
        try await promise.futureResult.get()
    }

    func close() async {
        guard !closed else { return }
        closed = true
        if !socket.isClosed {
            try? await socket.close(code: .goingAway).get()
        }
        frames.finish()
        try? await group.shutdownGracefully()
    }
}

/// Single-consumer queue whose synchronous `yield` keeps NIO callback order
/// without spawning one task per frame.
private final class GuestExecFrameQueue: @unchecked Sendable {
    private struct State {
        var buffered: [Result<GuestExecSocketFrame?, CLIError>] = []
        var waiter: CheckedContinuation<Result<GuestExecSocketFrame?, CLIError>, Never>?
        var finished = false
    }

    private let state = Mutex(State())

    func yield(_ frame: GuestExecSocketFrame) {
        deliver(.success(frame), terminal: false)
    }

    func finish(error: CLIError? = nil) {
        deliver(error.map(Result.failure) ?? .success(nil), terminal: true)
    }

    func next() async throws -> GuestExecSocketFrame? {
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<GuestExecSocketFrame?, CLIError>, Never>) in
                var immediate: Result<GuestExecSocketFrame?, CLIError>?
                state.withLock { state in
                    if !state.buffered.isEmpty {
                        immediate = state.buffered.removeFirst()
                    } else if state.finished {
                        immediate = .success(nil)
                    } else {
                        precondition(
                            state.waiter == nil,
                            "Guest exec socket has more than one frame consumer")
                        state.waiter = continuation
                    }
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            cancelWaiter()
        }
        try Task.checkCancellation()
        return try result.get()
    }

    private func cancelWaiter() {
        var waiter: CheckedContinuation<Result<GuestExecSocketFrame?, CLIError>, Never>?
        state.withLock { state in
            guard !state.finished else { return }
            state.finished = true
            state.buffered.removeAll()
            waiter = state.waiter
            state.waiter = nil
        }
        waiter?.resume(returning: .success(nil))
    }

    private func deliver(
        _ result: Result<GuestExecSocketFrame?, CLIError>, terminal: Bool
    ) {
        var waiter: CheckedContinuation<Result<GuestExecSocketFrame?, CLIError>, Never>?
        state.withLock { state in
            guard !state.finished else { return }
            if terminal { state.finished = true }
            if let pending = state.waiter {
                state.waiter = nil
                waiter = pending
            } else {
                state.buffered.append(result)
            }
        }
        waiter?.resume(returning: result)
    }
}
