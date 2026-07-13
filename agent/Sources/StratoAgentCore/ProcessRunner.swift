import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Result of running a subprocess to completion.
public struct ProcessResult: Sendable {
    public let terminationStatus: Int32
    public let standardOutput: Data
    public let standardError: Data

    public init(terminationStatus: Int32, standardOutput: Data, standardError: Data) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    /// stdout and stderr decoded and concatenated — convenient for building
    /// human-readable error messages where the two streams were previously
    /// merged into a single pipe.
    public var combinedOutput: String {
        let out = String(data: standardOutput, encoding: .utf8) ?? ""
        let err = String(data: standardError, encoding: .utf8) ?? ""
        return out + err
    }
}

/// Runs external commands without blocking the Swift concurrency cooperative
/// thread pool.
///
/// `Process.run()` + `waitUntilExit()` blocks the calling thread for the entire
/// lifetime of the subprocess. Doing that directly inside an `async` method ties
/// up a cooperative-pool thread, which can starve unrelated work. `ProcessRunner`
/// moves the blocking wait and pipe draining onto global dispatch queues and hands
/// the result back through continuations, so `await`ing it suspends rather than
/// blocks.
public enum ProcessRunner {
    /// Launches `executableURL` with `arguments`, draining stdout and stderr, and
    /// returns once the process exits.
    ///
    /// stdout and stderr are drained concurrently (each from its own file
    /// descriptor), so a process that fills one stream while the other is idle
    /// cannot deadlock.
    public static func run(
        executableURL: URL,
        arguments: [String]
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // `run()` only spawns the child and returns; it does not block for the
        // subprocess lifetime, so calling it inline is fine.
        try process.run()

        // Drain both streams concurrently before awaiting exit — a full pipe
        // buffer on either stream would otherwise stall the subprocess.
        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        async let stdoutData = drain(fd: stdoutFD)
        async let stderrData = drain(fd: stderrFD)

        let (out, err) = await (stdoutData, stderrData)
        await waitForExit(process)

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: out,
            standardError: err
        )
    }

    /// Launches `executableURL` with stdin wired to `inputFile` and stdout to
    /// `outputFile` (created/truncated), so arbitrarily large streams never
    /// pass through this process's memory — used for filter-style tools like
    /// gzip/zstd. stderr is drained into the result for error messages;
    /// `standardOutput` in the result is always empty.
    public static func runStreaming(
        executableURL: URL,
        arguments: [String],
        inputFile: URL,
        outputFile: URL
    ) async throws -> ProcessResult {
        let inputHandle = try FileHandle(forReadingFrom: inputFile)
        defer { try? inputHandle.close() }
        FileManager.default.createFile(atPath: outputFile.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputFile)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = inputHandle
        process.standardOutput = outputHandle

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        try process.run()

        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        async let stderrData = drain(fd: stderrFD)

        let err = await stderrData
        await waitForExit(process)

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            standardOutput: Data(),
            standardError: err
        )
    }

    /// Reads a file descriptor to EOF on a background queue.
    private static func drain(fd: Int32) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                let bufferSize = 4096
                var buffer = [UInt8](repeating: 0, count: bufferSize)
                while true {
                    let count = buffer.withUnsafeMutableBytes { ptr in
                        read(fd, ptr.baseAddress, bufferSize)
                    }
                    if count < 0 {
                        if errno == EINTR { continue }
                        break
                    }
                    if count == 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
                continuation.resume(returning: data)
            }
        }
    }

    /// Waits for the process to exit on a background queue.
    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}
