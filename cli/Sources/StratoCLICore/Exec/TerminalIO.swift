import Dispatch
import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public func parseGuestExecEnvironment(_ values: [String]) throws -> [String: String]? {
    guard !values.isEmpty else { return nil }
    var result: [String: String] = [:]
    for value in values {
        guard let separator = value.firstIndex(of: "=") else {
            throw CLIError.config("Invalid --env '\(value)'; expected KEY=VALUE.")
        }
        let key = String(value[..<separator])
        guard !key.isEmpty else {
            throw CLIError.config("Invalid --env '\(value)'; the key cannot be empty.")
        }
        result[key] = String(value[value.index(after: separator)...])
    }
    return result
}

/// Converts a POSIX file descriptor into a cancellation-friendly async byte
/// stream. `readabilityHandler` avoids parking a structured-concurrency child
/// forever in a blocking `read(2)` after the remote process exits.
public func fileHandleDataStream(_ handle: FileHandle) -> AsyncStream<Data> {
    AsyncStream { continuation in
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if data.isEmpty {
                readable.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        continuation.onTermination = { _ in
            handle.readabilityHandler = nil
        }
    }
}

public func standardInputIsTerminal() -> Bool {
    isatty(STDIN_FILENO) == 1
}

public protocol GuestExecTerminal: AnyObject, Sendable {
    func enterRawMode() throws
    func restore()
    func size() throws -> GuestExecTerminalSize
}

/// Scopes raw mode to one async operation. The defer is the single restoration
/// path for normal return, thrown errors, and task cancellation.
public func withRawTerminal<Result: Sendable>(
    _ terminal: any GuestExecTerminal,
    operation: () async throws -> Result
) async throws -> Result {
    try terminal.enterRawMode()
    defer { terminal.restore() }
    return try await operation()
}

/// Owns a local terminal's raw-mode transition. Restoration is idempotent and
/// is also performed during deinitialization as a last-resort safety net.
public final class RawTerminal: GuestExecTerminal, @unchecked Sendable {
    private struct State {
        var original: termios?
    }

    public let inputFileDescriptor: Int32
    public let outputFileDescriptor: Int32
    private let state = Mutex(State())

    public init(
        inputFileDescriptor: Int32 = STDIN_FILENO,
        outputFileDescriptor: Int32 = STDOUT_FILENO
    ) throws {
        guard isatty(inputFileDescriptor) == 1, isatty(outputFileDescriptor) == 1 else {
            throw CLIError.config(
                "Sandbox attach requires terminal stdin and stdout; use 'sandbox exec' for redirected I/O.")
        }
        self.inputFileDescriptor = inputFileDescriptor
        self.outputFileDescriptor = outputFileDescriptor
    }

    deinit {
        restore()
    }

    public func enterRawMode() throws {
        var current = termios()
        guard tcgetattr(inputFileDescriptor, &current) == 0 else {
            throw CLIError.config("Could not read the local terminal settings.")
        }
        var raw = current
        cfmakeraw(&raw)
        guard tcsetattr(inputFileDescriptor, TCSAFLUSH, &raw) == 0 else {
            throw CLIError.config("Could not put the local terminal into raw mode.")
        }
        state.withLock { state in
            state.original = current
        }
    }

    public func restore() {
        let saved = state.withLock { state -> termios? in
            defer { state.original = nil }
            return state.original
        }
        if var original = saved {
            _ = tcsetattr(inputFileDescriptor, TCSAFLUSH, &original)
        }
    }

    public func size() throws -> GuestExecTerminalSize {
        var value = winsize()
        guard ioctl(outputFileDescriptor, UInt(TIOCGWINSZ), &value) == 0 else {
            throw CLIError.config("Could not read the local terminal size.")
        }
        let rows = Int(value.ws_row)
        let cols = Int(value.ws_col)
        guard rows > 0, cols > 0 else {
            throw CLIError.config("The local terminal reported an invalid size.")
        }
        return GuestExecTerminalSize(rows: rows, cols: cols)
    }
}

public final class TerminalResizeMonitor: @unchecked Sendable {
    public let sizes: AsyncStream<GuestExecTerminalSize>
    private let source: DispatchSourceSignal

    public init(terminal: RawTerminal) {
        signal(SIGWINCH, SIG_IGN)
        let (sizes, continuation) = AsyncStream.makeStream(of: GuestExecTerminalSize.self)
        self.sizes = sizes
        source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        source.setEventHandler {
            if let size = try? terminal.size() {
                continuation.yield(size)
            }
        }
        source.setCancelHandler {
            continuation.finish()
        }
        source.resume()
    }

    deinit {
        source.cancel()
        signal(SIGWINCH, SIG_DFL)
    }
}

/// Converts process-termination signals into an async event. The command races
/// this stream against the remote session, cancels and closes the WebSocket,
/// and leaves raw mode before re-raising the signal.
public final class TerminalTerminationMonitor: @unchecked Sendable {
    public let signals: AsyncStream<Int32>
    private let continuation: AsyncStream<Int32>.Continuation
    private let sources: [DispatchSourceSignal]

    public init() {
        let (signals, continuation) = AsyncStream.makeStream(of: Int32.self)
        self.signals = signals
        self.continuation = continuation
        let delivered = Mutex(false)
        sources = [SIGTERM, SIGHUP].map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                let isFirst = delivered.withLock { delivered -> Bool in
                    guard !delivered else { return false }
                    delivered = true
                    return true
                }
                if isFirst {
                    continuation.yield(signalNumber)
                    continuation.finish()
                }
            }
            source.resume()
            return source
        }
    }

    deinit {
        continuation.finish()
        for (source, signalNumber) in zip(sources, [SIGTERM, SIGHUP]) {
            source.cancel()
            signal(signalNumber, SIG_DFL)
        }
    }
}

/// Reinstates the signal's default disposition after session cleanup and then
/// terminates with the same signal visible to the parent process.
public func reraiseTerminationSignal(_ signalNumber: Int32) -> Never {
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
    _exit(128 + signalNumber)
}
