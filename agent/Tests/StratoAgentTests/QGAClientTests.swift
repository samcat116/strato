import Foundation
import Logging
import Testing

@testable import StratoAgentCore

/// Behavioral coverage for `QGAClient` against an in-memory fake guest agent
/// (issue #563): the `guest-sync-delimited` handshake, typed command replies,
/// the shutdown-drops-connection path, error propagation, and the qga →
/// `GuestInfo` mapping — all without a real socket.
@Suite("QGA Client")
struct QGAClientTests {

    // MARK: - Fake guest agent

    /// What the fake agent does with a parsed request.
    enum Reply: Sendable {
        /// Reply with these bytes (the fake prepends the `0xFF` marker itself
        /// for `guest-sync-delimited`).
        case object([UInt8])
        /// Drop the connection instead of replying (models a guest powering off
        /// mid-`guest-shutdown`, or a hung agent that closes).
        case close
    }

    /// Records every request seen across channels — the `execute` name and the
    /// raw request object, so argument-shaping can be asserted — guarded by a
    /// scoped lock (safe to touch from the fake's actor-isolated methods).
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(execute: String, object: [UInt8])] = []
        func record(_ execute: String, object: [UInt8]) {
            lock.withLock { items.append((execute, object)) }
        }
        var all: [String] { lock.withLock { items.map(\.execute) } }
        func objects(for execute: String) -> [[UInt8]] {
            lock.withLock { items.filter { $0.execute == execute }.map(\.object) }
        }
    }

    /// A transport whose channels answer requests from a caller-supplied
    /// handler.
    final class FakeQGATransport: QGATransport, @unchecked Sendable {
        let handler: @Sendable (_ execute: String, _ syncId: Int?) -> Reply
        /// Bytes per `readSome()` — set small to exercise the framer's
        /// reassembly across partial reads. `nil` returns everything at once.
        let chunkSize: Int?
        let recorder = Recorder()

        init(chunkSize: Int? = nil, handler: @escaping @Sendable (String, Int?) -> Reply) {
            self.handler = handler
            self.chunkSize = chunkSize
        }

        var executes: [String] { recorder.all }
        func requests(for execute: String) -> [[UInt8]] { recorder.objects(for: execute) }

        func openChannel() async throws -> any QGAByteChannel {
            FakeQGAChannel(handler: handler, chunkSize: chunkSize, recorder: recorder)
        }
    }

    /// One fake connection. An actor so its buffers need no manual locking.
    actor FakeQGAChannel: QGAByteChannel {
        private let handler: @Sendable (String, Int?) -> Reply
        private let chunkSize: Int?
        private let recorder: Recorder
        private var writeAccumulator: [UInt8] = []
        private var readBuffer: [UInt8] = []

        init(handler: @escaping @Sendable (String, Int?) -> Reply, chunkSize: Int?, recorder: Recorder) {
            self.handler = handler
            self.chunkSize = chunkSize
            self.recorder = recorder
        }

        func write(_ bytes: [UInt8]) async throws {
            writeAccumulator.append(contentsOf: bytes)
            // Extract each complete JSON object the client wrote (skipping the
            // leading 0xFF the sync carries) and enqueue its reply.
            let framer = QGAObjectFramer()
            framer.append(writeAccumulator)
            writeAccumulator.removeAll(keepingCapacity: true)
            while let object = framer.nextObject() {
                try handle(object)
            }
        }

        private func handle(_ object: [UInt8]) throws {
            let json = try JSONSerialization.jsonObject(with: Data(object)) as? [String: Any]
            let execute = json?["execute"] as? String ?? ""
            let syncId = (json?["arguments"] as? [String: Any])?["id"] as? Int
            recorder.record(execute, object: object)

            switch handler(execute, syncId) {
            case .object(var bytes):
                if execute == "guest-sync-delimited" {
                    bytes = [0xFF] + bytes  // the delimited reply is 0xFF-prefixed
                }
                readBuffer.append(contentsOf: bytes)
            case .close:
                readBuffer.removeAll(keepingCapacity: true)  // nothing more to read → EOF
            }
        }

        func readSome() async throws -> [UInt8] {
            // The fake is synchronous: a reply is enqueued by the time the
            // client reads, so no continuation parking is needed.
            guard !readBuffer.isEmpty else { return [] }  // closed or nothing pending → EOF
            if let chunk = chunkSize, chunk < readBuffer.count {
                let head = Array(readBuffer.prefix(chunk))
                readBuffer.removeFirst(chunk)
                return head
            }
            let all = readBuffer
            readBuffer.removeAll(keepingCapacity: true)
            return all
        }

        func close() async {}
    }

    // MARK: - Response builders

    private static func returnObject(_ json: String) -> [UInt8] { Array(#"{"return": \#(json)}"#.utf8) }

    /// A handler covering the common healthy replies. Interfaces/hostname are
    /// injected so individual tests can vary them.
    private static func healthyHandler(
        hostName: String = "web01",
        interfacesJSON: String = "[]",
        shutdownDropsConnection: Bool = false
    ) -> @Sendable (String, Int?) -> Reply {
        { execute, syncId in
            switch execute {
            case "guest-sync-delimited":
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            case "guest-ping":
                return .object(returnObject("{}"))
            case "guest-fsfreeze-freeze":
                return .object(returnObject("2"))
            case "guest-fsfreeze-thaw":
                return .object(returnObject("2"))
            case "guest-get-host-name":
                return .object(returnObject(#"{"host-name": "\#(hostName)"}"#))
            case "guest-network-get-interfaces":
                return .object(returnObject(interfacesJSON))
            case "guest-shutdown":
                return shutdownDropsConnection ? .close : .object(returnObject("{}"))
            default:
                return .object(Array(#"{"error": {"class": "CommandNotFound", "desc": "\#(execute)"}}"#.utf8))
            }
        }
    }

    private func makeClient(_ transport: FakeQGATransport) -> QGAClient {
        QGAClient(transport: transport, logger: Logger(label: "test.qga"))
    }

    // MARK: - Tests

    @Test("ping succeeds against a responsive agent and drives a sync first")
    func pingSucceeds() async throws {
        let transport = FakeQGATransport(handler: Self.healthyHandler())
        try await makeClient(transport).ping()
        #expect(transport.executes == ["guest-sync-delimited", "guest-ping"])
    }

    @Test("ping reassembles replies delivered one byte at a time")
    func pingWithTinyChunks() async throws {
        let transport = FakeQGATransport(chunkSize: 1, handler: Self.healthyHandler())
        try await makeClient(transport).ping()
        #expect(transport.executes == ["guest-sync-delimited", "guest-ping"])
    }

    @Test("freeze and thaw return the filesystem counts qga reports")
    func freezeThaw() async throws {
        let transport = FakeQGATransport(handler: Self.healthyHandler())
        let client = makeClient(transport)
        #expect(try await client.freezeFilesystems() == 2)
        #expect(try await client.thawFilesystems() == 2)
    }

    @Test("shutdown treats a mid-command connection drop as success")
    func shutdownConnectionDrop() async throws {
        let transport = FakeQGATransport(
            handler: Self.healthyHandler(shutdownDropsConnection: true))
        // Must not throw: the sync proved liveness, and the guest dropping the
        // connection as it powers off is the expected outcome.
        try await makeClient(transport).requestShutdown()
        #expect(transport.executes == ["guest-sync-delimited", "guest-shutdown"])
    }

    @Test("a sync-token mismatch fails the operation")
    func syncMismatch() async throws {
        let transport = FakeQGATransport { execute, _ in
            // Always echo the wrong token.
            .object(Array(#"{"return": 999999}"#.utf8))
        }
        await #expect(throws: QGAClient.QGAError.syncMismatch) {
            try await makeClient(transport).ping()
        }
    }

    @Test("a qga error object surfaces as a commandError")
    func commandErrorSurfaces() async throws {
        let transport = FakeQGATransport { execute, syncId in
            if execute == "guest-sync-delimited" {
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            }
            return .object(Array(#"{"error": {"class": "GenericError", "desc": "no freezable fs"}}"#.utf8))
        }
        await #expect(throws: QGAClient.QGAError.self) {
            _ = try await makeClient(transport).freezeFilesystems()
        }
    }

    @Test("collectGuestInfo maps hostname and per-MAC addresses into GuestInfo")
    func collectGuestInfoMapping() async throws {
        let interfacesJSON = """
            [
              {"name":"lo","hardware-address":"00:00:00:00:00:00",
               "ip-addresses":[{"ip-address-type":"ipv4","ip-address":"127.0.0.1","prefix":8}]},
              {"name":"enp0s3","hardware-address":"52:54:00:AB:CD:EF",
               "ip-addresses":[
                 {"ip-address-type":"ipv4","ip-address":"10.0.0.5","prefix":24},
                 {"ip-address-type":"ipv6","ip-address":"fe80::5054:ff:feab:cdef","prefix":64}
               ]},
              {"name":"noaddr"}
            ]
            """
        let transport = FakeQGATransport(
            handler: Self.healthyHandler(hostName: "app-7", interfacesJSON: interfacesJSON))
        let info = try await makeClient(transport).collectGuestInfo()

        #expect(info.qgaAvailable)
        #expect(info.hostname == "app-7")
        #expect(info.interfaces.count == 3)

        let eth = try #require(info.interfaces.first { $0.name == "enp0s3" })
        // MAC is lowercased for case-insensitive control-plane matching.
        #expect(eth.hardwareAddress == "52:54:00:ab:cd:ef")
        #expect(eth.addresses.count == 2)
        #expect(eth.addresses.contains { $0.family == .ipv4 && $0.address == "10.0.0.5" && $0.prefixLength == 24 })
        #expect(eth.addresses.contains { $0.family == .ipv6 && $0.prefixLength == 64 })

        // An interface qga reported without ip-addresses maps to an empty list.
        let noaddr = try #require(info.interfaces.first { $0.name == "noaddr" })
        #expect(noaddr.addresses.isEmpty)
    }

    @Test("collectGuestInfo still reports availability when detail queries fail")
    func collectGuestInfoDegrades() async throws {
        // Only the sync succeeds; hostname/interfaces come back as errors.
        let transport = FakeQGATransport { execute, syncId in
            if execute == "guest-sync-delimited" {
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            }
            return .object(Array(#"{"error": {"class": "GenericError", "desc": "unsupported"}}"#.utf8))
        }
        let info = try await makeClient(transport).collectGuestInfo()
        #expect(info.qgaAvailable)
        #expect(info.hostname == nil)
        #expect(info.interfaces.isEmpty)
    }

    @Test("a channel that never syncs (EOF) throws rather than hanging")
    func unresponsiveAgent() async throws {
        // Every request drops the connection: models a guest with no qga.
        let transport = FakeQGATransport { _, _ in .close }
        await #expect(throws: QGAClient.QGAError.connectionClosed) {
            try await makeClient(transport).ping()
        }
    }

    // MARK: - guest-exec (STR-74)

    /// A fake agent answering the spawn-and-poll pair: `guest-exec` hands back a
    /// PID, and `guest-exec-status` reports "still running" until the
    /// `pollsBeforeExit`th ask. A nil `terminalStatus` models a command that
    /// never exits.
    final class FakeExecAgent: @unchecked Sendable {
        let pid: Int
        private let pollsBeforeExit: Int
        private let terminalStatus: String?
        private let lock = NSLock()
        private var statusPolls = 0

        init(pid: Int = 4242, pollsBeforeExit: Int = 0, terminalStatus: String?) {
            self.pid = pid
            self.pollsBeforeExit = pollsBeforeExit
            self.terminalStatus = terminalStatus
        }

        /// How many `guest-exec-status` requests the client has issued.
        var polls: Int { lock.withLock { statusPolls } }

        var handler: @Sendable (String, Int?) -> Reply {
            { [self] execute, syncId in
                switch execute {
                case "guest-sync-delimited":
                    return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
                case "guest-exec":
                    return .object(QGAClientTests.returnObject(#"{"pid": \#(pid)}"#))
                case "guest-exec-status":
                    let poll = lock.withLock {
                        statusPolls += 1
                        return statusPolls
                    }
                    guard let terminalStatus, poll > pollsBeforeExit else {
                        return .object(QGAClientTests.returnObject(#"{"exited": false}"#))
                    }
                    return .object(QGAClientTests.returnObject(terminalStatus))
                default:
                    return .object(Array(#"{"error": {"class": "CommandNotFound", "desc": "\#(execute)"}}"#.utf8))
                }
            }
        }
    }

    /// A latch that reads `true` exactly once, so a handler can fail the first
    /// request of a kind and answer the rest.
    final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func fire() -> Bool {
            lock.withLock {
                defer { fired = true }
                return !fired
            }
        }
    }

    private static func exitedStatus(
        exitCode: Int? = nil, signal: Int? = nil, stdout: Data = Data(), stderr: Data = Data()
    ) -> String {
        var fields = [#""exited": true"#]
        if let exitCode { fields.append(#""exitcode": \#(exitCode)"#) }
        if let signal { fields.append(#""signal": \#(signal)"#) }
        if !stdout.isEmpty { fields.append(#""out-data": "\#(stdout.base64EncodedString())""#) }
        if !stderr.isEmpty { fields.append(#""err-data": "\#(stderr.base64EncodedString())""#) }
        return "{\(fields.joined(separator: ", "))}"
    }

    @Test("runCommand spawns with argv/env/stdin and polls until the guest reports exit")
    func runCommandPollsToCompletion() async throws {
        let agent = FakeExecAgent(
            pollsBeforeExit: 2,
            terminalStatus: Self.exitedStatus(
                exitCode: 0, stdout: Data("hello\n".utf8), stderr: Data("warned\n".utf8)))
        let transport = FakeQGATransport(handler: agent.handler)

        let result = try await makeClient(transport).runCommand(
            GuestCommand(
                path: "/bin/sh",
                arguments: ["-c", "echo hello"],
                environment: ["FOO": "bar", "BAZ": "qux"],
                input: Data("stdin payload".utf8)))

        #expect(result.pid == agent.pid)
        #expect(result.exitCode == 0)
        #expect(result.signal == nil)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "warned\n")
        #expect(!result.stdoutTruncated)
        // Two "still running" answers, then the terminal one.
        #expect(agent.polls == 3)

        // The spawn carries qga's hyphenated argument names, and `arg` is the
        // list *after* the program name (qga supplies no argv[0]).
        let spawn = try #require(transport.requests(for: "guest-exec").first)
        let spawnJSON = try JSONSerialization.jsonObject(with: Data(spawn))
        let request = try #require(spawnJSON as? [String: Any])
        let arguments = try #require(request["arguments"] as? [String: Any])
        #expect(arguments["path"] as? String == "/bin/sh")
        #expect(arguments["arg"] as? [String] == ["-c", "echo hello"])
        // The dictionary is flattened to qga's KEY=VALUE form, key-sorted so
        // the request bytes don't depend on dictionary ordering.
        #expect(arguments["env"] as? [String] == ["BAZ=qux", "FOO=bar"])
        #expect(arguments["capture-output"] as? Bool == true)
        #expect(arguments["input-data"] as? String == Data("stdin payload".utf8).base64EncodedString())

        // The status poll asks by the PID the spawn returned.
        let poll = try #require(transport.requests(for: "guest-exec-status").first)
        let pollJSON = try JSONSerialization.jsonObject(with: Data(poll))
        let pollRequest = try #require(pollJSON as? [String: Any])
        #expect((pollRequest["arguments"] as? [String: Any])?["pid"] as? Int == agent.pid)
    }

    @Test("a command killed by a signal reports the signal and no exit code")
    func runCommandReportsSignal() async throws {
        let agent = FakeExecAgent(terminalStatus: Self.exitedStatus(signal: 9))
        let transport = FakeQGATransport(handler: agent.handler)
        let result = try await makeClient(transport).runCommand(GuestCommand(path: "/bin/sleep"))
        #expect(result.exitCode == nil)
        #expect(result.signal == 9)
        #expect(result.stdout.isEmpty)
    }

    @Test("qga's own truncation flags are reported rather than treated as failure")
    func runCommandReportsGuestTruncation() async throws {
        let encoded = Data("partial".utf8).base64EncodedString()
        let agent = FakeExecAgent(
            terminalStatus: #"{"exited": true, "exitcode": 0, "out-data": "\#(encoded)", "out-truncated": true}"#)
        let transport = FakeQGATransport(handler: agent.handler)
        let result = try await makeClient(transport).runCommand(GuestCommand(path: "/bin/cat"))
        #expect(result.exitCode == 0)
        #expect(result.stdoutTruncated)
        #expect(!result.stderrTruncated)
    }

    @Test("a command that never exits fails at its deadline, naming the guest pid")
    func runCommandTimesOut() async throws {
        // terminalStatus nil: the guest always answers "still running".
        let agent = FakeExecAgent(terminalStatus: nil)
        let transport = FakeQGATransport(handler: agent.handler)
        await #expect(throws: QGAClient.QGAError.executionTimedOut(pid: agent.pid, seconds: 1)) {
            _ = try await makeClient(transport).runCommand(
                GuestCommand(path: "/bin/sleep", arguments: ["infinity"]), timeoutSeconds: 1)
        }
        // The polling was a plain loop, not a task left running: it stopped at
        // the deadline, having actually polled.
        #expect(agent.polls > 1)
    }

    @Test("output past the caller's cap fails cleanly instead of being buffered")
    func runCommandRefusesOversizedOutput() async throws {
        // Comfortably past the framer's budget for a 1 KiB cap, so the reply is
        // refused mid-stream rather than held whole.
        let huge = Data(repeating: UInt8(ascii: "x"), count: 512 * 1024)
        let agent = FakeExecAgent(terminalStatus: Self.exitedStatus(exitCode: 0, stdout: huge))
        let transport = FakeQGATransport(handler: agent.handler)
        do {
            _ = try await makeClient(transport).runCommand(
                GuestCommand(path: "/bin/cat"), timeoutSeconds: 5, maxCapturedBytes: 1024)
            Issue.record("expected an oversized reply to fail")
        } catch let error as QGAClient.QGAError {
            guard case .responseTooLarge = error else {
                Issue.record("expected responseTooLarge, got \(error)")
                return
            }
        }
    }

    @Test("output that fits the stream but not the cap is refused at decode")
    func runCommandEnforcesTheExactCap() async throws {
        // Small enough that the framer's (necessarily loose, base64-inflated)
        // budget admits it — only the exact per-stream check rejects it.
        let output = Data(repeating: UInt8(ascii: "y"), count: 4096)
        let agent = FakeExecAgent(terminalStatus: Self.exitedStatus(exitCode: 0, stdout: output))
        let transport = FakeQGATransport(handler: agent.handler)
        await #expect(throws: QGAClient.QGAError.responseTooLarge(limitBytes: 1024)) {
            _ = try await makeClient(transport).runCommand(
                GuestCommand(path: "/bin/cat"), timeoutSeconds: 5, maxCapturedBytes: 1024)
        }
    }

    @Test("a guest whose agent filters guest-exec away reports it as unavailable")
    func runCommandOnFilteredAgent() async throws {
        // The RHEL family's --allow-rpcs allowlist omits guest-exec; qga answers
        // CommandNotFound with a desc that says it was disabled (issue #803).
        let transport = FakeQGATransport { execute, syncId in
            if execute == "guest-sync-delimited" {
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            }
            return .object(
                Array(
                    #"{"error": {"class": "CommandNotFound", "desc": "Command guest-exec has been disabled: the command is not allowed"}}"#
                        .utf8))
        }
        do {
            _ = try await makeClient(transport).runCommand(GuestCommand(path: "/bin/true"))
            Issue.record("expected a filtered guest-exec to fail")
        } catch let error as QGAClient.QGAError {
            guard case .commandUnavailable = error else {
                Issue.record("expected commandUnavailable, got \(error)")
                return
            }
        }
        // Unavailable is an answer, not a transport hiccup: no retrying it.
        #expect(transport.executes.filter { $0 == "guest-exec" }.count == 1)
    }

    @Test("a spawn that loses its channel is never retried — the command may have started")
    func runCommandDoesNotRetryTheSpawn() async throws {
        let transport = FakeQGATransport { execute, syncId in
            if execute == "guest-sync-delimited" {
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            }
            return .close  // the agent drops the connection mid-spawn
        }
        await #expect(throws: QGAClient.QGAError.connectionClosed) {
            _ = try await makeClient(transport).runCommand(
                GuestCommand(path: "/bin/true"), timeoutSeconds: 5)
        }
        #expect(transport.executes.filter { $0 == "guest-exec" }.count == 1)
    }

    @Test("a poll that loses the one-client-at-a-time socket is retried until the deadline")
    func runCommandRetriesATransientPollFailure() async throws {
        let agent = FakeExecAgent(terminalStatus: Self.exitedStatus(exitCode: 3))
        let inner = agent.handler
        // The first status poll finds the chardev gone (a concurrent probe owns
        // it); later polls get through.
        let firstPoll = OneShot()
        let transport = FakeQGATransport { execute, syncId in
            if execute == "guest-exec-status", firstPoll.fire() { return .close }
            return inner(execute, syncId)
        }

        let result = try await makeClient(transport).runCommand(
            GuestCommand(path: "/bin/false"), timeoutSeconds: 5)
        #expect(result.exitCode == 3)
    }

    @Test("queryCapabilities separates the commands an agent will answer from those it won't")
    func queryCapabilitiesReportsFilteredCommands() async throws {
        let transport = FakeQGATransport { execute, syncId in
            switch execute {
            case "guest-sync-delimited":
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            case "guest-info":
                return .object(
                    Self.returnObject(
                        """
                        {"version": "10.1.0", "supported_commands": [
                          {"name": "guest-ping", "enabled": true, "success-response": true},
                          {"name": "guest-exec", "enabled": false, "success-response": true},
                          {"name": "guest-exec-status", "enabled": false, "success-response": true}
                        ]}
                        """))
            default:
                return .object(Array(#"{"error": {"class": "CommandNotFound", "desc": "\#(execute)"}}"#.utf8))
            }
        }
        let capabilities = try await makeClient(transport).queryCapabilities()
        #expect(capabilities.version == "10.1.0")
        #expect(capabilities.enabledCommands == ["guest-ping"])
        #expect(capabilities.disabledCommands == ["guest-exec", "guest-exec-status"])
        // Both halves of the pair are required, and neither is enabled here.
        #expect(!capabilities.supportsCommandExecution)
    }

    @Test("a large reply arriving in socket-sized chunks reassembles correctly")
    func runCommandReassemblesAChunkedReply() async throws {
        // The path a real socket always takes: the framer sees the reply in
        // pieces and has to resume its scan across every boundary. Not
        // hypothetical at this size — 384 KiB of stdout is ~512 KiB of base64.
        var stdout = Data()
        for line in 0..<12_000 {
            stdout.append(Data("line \(line): the quick brown fox\n".utf8))
        }
        let agent = FakeExecAgent(terminalStatus: Self.exitedStatus(exitCode: 0, stdout: stdout))
        let transport = FakeQGATransport(chunkSize: 16 * 1024, handler: agent.handler)

        let result = try await makeClient(transport).runCommand(GuestCommand(path: "/bin/cat"))
        #expect(result.exitCode == 0)
        #expect(result.stdout == stdout)
    }

    @Test("capture-output: false asks for no capture and still reports the exit status")
    func runCommandWithoutCapture() async throws {
        let agent = FakeExecAgent(terminalStatus: Self.exitedStatus(exitCode: 7))
        let transport = FakeQGATransport(handler: agent.handler)
        let result = try await makeClient(transport).runCommand(
            GuestCommand(path: "/usr/bin/logger", arguments: ["hi"], captureOutput: false))

        #expect(result.exitCode == 7)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)

        let spawn = try #require(transport.requests(for: "guest-exec").first)
        let spawnJSON = try JSONSerialization.jsonObject(with: Data(spawn))
        let request = try #require(spawnJSON as? [String: Any])
        let arguments = try #require(request["arguments"] as? [String: Any])
        #expect(arguments["capture-output"] as? Bool == false)
        // No stdin was given, so the key is omitted rather than sent as null.
        #expect(arguments["input-data"] == nil)
    }

    @Test("a poll failure at the deadline still reports the timeout, keeping the pid")
    func runCommandTimingOutOnAFailedPoll() async throws {
        // Polls succeed ("still running") until the deadline is close, then the
        // channel drops. The command was demonstrably running the whole time,
        // so the deadline — not the dropped channel — is what the caller needs
        // to hear, and the pid has to survive with it.
        let agent = FakeExecAgent(terminalStatus: nil)
        let inner = agent.handler
        let transport = FakeQGATransport { execute, syncId in
            if execute == "guest-exec-status", agent.polls >= 3 { return .close }
            return inner(execute, syncId)
        }
        await #expect(throws: QGAClient.QGAError.executionTimedOut(pid: agent.pid, seconds: 1)) {
            _ = try await makeClient(transport).runCommand(
                GuestCommand(path: "/bin/sleep"), timeoutSeconds: 1)
        }
    }

    @Test("a guest that never answers a poll reports why, not a bare timeout")
    func runCommandNeverReachingTheAgent() async throws {
        // Every status poll drops the channel: the agent was never reached, so
        // "still running at the deadline" would be a fabrication.
        let agent = FakeExecAgent(terminalStatus: nil)
        let inner = agent.handler
        let transport = FakeQGATransport { execute, syncId in
            execute == "guest-exec-status" ? .close : inner(execute, syncId)
        }
        await #expect(throws: QGAClient.QGAError.connectionClosed) {
            _ = try await makeClient(transport).runCommand(
                GuestCommand(path: "/bin/sleep"), timeoutSeconds: 1)
        }
    }

    @Test("a reply that can't be decoded fails at once instead of polling to the deadline")
    func runCommandOnUndecodableStatus() async throws {
        // `exitcode` as a string: a shape ExecStatus doesn't model. It will
        // decode identically next time, so retrying until the deadline would
        // just be a slower way to fail.
        let agent = FakeExecAgent(terminalStatus: #"{"exited": true, "exitcode": "zero"}"#)
        let transport = FakeQGATransport(handler: agent.handler)
        await #expect(throws: DecodingError.self) {
            _ = try await makeClient(transport).runCommand(
                GuestCommand(path: "/bin/true"), timeoutSeconds: 30)
        }
        // One poll, not thirty seconds of them.
        #expect(agent.polls == 1)
    }

    @Test("undecodable captured output surfaces as a malformed reply")
    func runCommandOnUndecodableCapture() async throws {
        let agent = FakeExecAgent(
            terminalStatus: #"{"exited": true, "exitcode": 0, "out-data": "not valid base64!!"}"#)
        let transport = FakeQGATransport(handler: agent.handler)
        await #expect(throws: QGAClient.QGAError.malformedResponse) {
            _ = try await makeClient(transport).runCommand(GuestCommand(path: "/bin/cat"))
        }
    }

    @Test("an agent too old to know guest-info reports the query as unavailable")
    func queryCapabilitiesOnAnOldAgent() async throws {
        let transport = FakeQGATransport { execute, syncId in
            if execute == "guest-sync-delimited" {
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            }
            return .object(
                Array(#"{"error": {"class": "CommandNotFound", "desc": "guest-info"}}"#.utf8))
        }
        do {
            _ = try await makeClient(transport).queryCapabilities()
            Issue.record("expected an unknown guest-info to fail")
        } catch let error as QGAClient.QGAError {
            guard case .commandUnavailable = error else {
                Issue.record("expected commandUnavailable, got \(error)")
                return
            }
        }
    }

    @Test("an agent that enables both exec commands reports exec support")
    func queryCapabilitiesReportsExecSupport() async throws {
        let transport = FakeQGATransport { execute, syncId in
            if execute == "guest-sync-delimited" {
                return .object(Array(#"{"return": \#(syncId ?? -1)}"#.utf8))
            }
            return .object(
                Self.returnObject(
                    """
                    {"version": "8.2.2", "supported_commands": [
                      {"name": "guest-exec", "enabled": true},
                      {"name": "guest-exec-status", "enabled": true}
                    ]}
                    """))
        }
        let capabilities = try await makeClient(transport).queryCapabilities()
        #expect(capabilities.supportsCommandExecution)
        #expect(capabilities.disabledCommands.isEmpty)
    }
}
