import Foundation
import NIOCore
import NIOHTTP1
import StratoAPIClient
import Synchronization
import Testing
import WebSocketKit

@testable import StratoCLICore

@Suite("Guest exec session")
struct GuestExecSessionTests {
    private let baseURL = URL(string: "https://strato.example.com/control-plane")!

    @Test("Environment values split once, allow empty values, and use the last duplicate")
    func environmentParsing() throws {
        #expect(
            try parseGuestExecEnvironment(["A=one=two", "EMPTY=", "A=last"])
                == ["A": "last", "EMPTY": ""])
        #expect(throws: CLIError.self) {
            try parseGuestExecEnvironment(["=value"])
        }
        #expect(throws: CLIError.self) {
            try parseGuestExecEnvironment(["MISSING_EQUALS"])
        }
    }

    @Test("Raw terminal scope restores settings after cancellation")
    func terminalRestoration() async {
        let terminal = FakeGuestExecTerminal()
        let started = Mutex(false)
        let task = Task {
            try await withRawTerminal(terminal) {
                started.withLock { $0 = true }
                try await Task.sleep(for: .seconds(30))
            }
        }
        while !started.withLock({ $0 }) { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(terminal.transitions() == [.entered, .restored])
    }

    @Test("Cancellation aborts a stalled WebSocket handshake")
    func stalledHandshakeCancellation() async {
        let started = Mutex(false)
        let terminal = FakeGuestExecTerminal()
        let connector = WebSocketKitGuestExecConnector { _, _, _, group, _ in
            started.withLock { $0 = true }
            return group.next().makePromise(of: Void.self).futureResult
        }
        let task = Task {
            try await withRawTerminal(terminal) {
                try await connector.connect(
                    url: URL(string: "wss://strato.example.com/session")!,
                    bearerToken: "st_test")
            }
        }

        while !started.withLock({ $0 }) { await Task.yield() }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(terminal.transitions() == [.entered, .restored])
    }

    @Test(
        "Multiplexes output, streams stdin then EOF, preserves path prefixes, and returns exit",
        arguments: [GuestExecResource.sandbox("sandbox-1"), .virtualMachine("vm-1")])
    func multiplexedSession(resource: GuestExecResource) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 201, json: Self.sessionJSON(mode: "multiplexed", resource: resource))
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let socket = FakeGuestExecSocket(
                frames: [
                    .text(#"{"type":"ready"}"#),
                    .binary(Data([0x01]) + Data("out".utf8)),
                    .binary(Data([0x02]) + Data("err".utf8)),
                    .text(#"{"type":"exit","exitCode":37}"#),
                ], delayAfterReady: .milliseconds(50))
            let connector = FakeGuestExecConnector(sockets: [socket])
            let outputs = Mutex<[GuestExecOutput]>([])
            let session = GuestExecSessionClient(
                serverURL: baseURL,
                client: authenticated.client,
                credentials: authenticated.credentials,
                connector: connector,
                now: Date.init,
                sleep: { try await Task.sleep(for: $0) })

            let exit = try await session.run(
                GuestExecInvocation(
                    resource: resource,
                    command: ["/bin/test", "arg"],
                    environment: ["A": "B"],
                    workingDirectory: "/workspace",
                    tty: false,
                    outputMode: .multiplexed,
                    input: Self.input([Data("input".utf8)]),
                    closeStdinWhenInputEnds: true)
            ) { output in
                outputs.withLock { $0.append(output) }
            }

            #expect(exit == 37)
            #expect(
                outputs.withLock { $0 } == [
                    .stdout(Data("out".utf8)), .stderr(Data("err".utf8)),
                ])
            #expect(
                await socket.sentFrames() == [
                    .binary(Data("input".utf8)), .text(#"{"type":"stdin_eof"}"#),
                ])
            let call = try #require(await connector.calls().first)
            #expect(
                call.url.absoluteString
                    == "wss://strato.example.com/control-plane/api/\(Self.resourcePath(resource))/exec/session-1/attach"
            )
            #expect(call.bearerToken == "st_test")

            let mint = try #require(transport.recordedRequests.first)
            #expect(mint.path == "/api/\(Self.resourcePath(resource))/exec")
            #expect(mint.authorization == "Bearer st_test")
            let body = try #require(
                JSONSerialization.jsonObject(with: Data(mint.bodyText.utf8))
                    as? [String: Any])
            #expect(body["outputMode"] as? String == "multiplexed")
            #expect(body["workingDir"] as? String == "/workspace")
        }
    }

    @Test(
        "Fails closed when the server does not echo multiplexed mode",
        arguments: [GuestExecResource.sandbox("sandbox-1"), .virtualMachine("vm-1")])
    func requiresMultiplexNegotiation(resource: GuestExecResource) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 201, json: Self.sessionJSON(mode: nil, resource: resource))
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let connector = FakeGuestExecConnector(sockets: [])
            let session = GuestExecSessionClient(
                serverURL: baseURL,
                client: authenticated.client,
                credentials: authenticated.credentials,
                connector: connector,
                now: Date.init,
                sleep: { _ in })

            await #expect(throws: CLIError.self) {
                try await session.run(
                    GuestExecInvocation(
                        resource: resource, command: ["true"], tty: false,
                        outputMode: .multiplexed),
                    onOutput: { _ in })
            }
            #expect(await connector.calls().isEmpty)
        }
    }

    @Test(
        "Terminal stdin sends EOF immediately without reading input",
        arguments: [GuestExecResource.sandbox("sandbox-1"), .virtualMachine("vm-1")])
    func terminalStdinEOF(resource: GuestExecResource) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 201, json: Self.sessionJSON(mode: "multiplexed", resource: resource))
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let socket = FakeGuestExecSocket(
                frames: [
                    .text(#"{"type":"ready"}"#),
                    .text(#"{"type":"exit","exitCode":0}"#),
                ],
                delayAfterReady: .milliseconds(20))
            let session = GuestExecSessionClient(
                serverURL: baseURL,
                client: authenticated.client,
                credentials: authenticated.credentials,
                connector: FakeGuestExecConnector(sockets: [socket]),
                now: Date.init,
                sleep: { _ in })

            _ = try await session.run(
                GuestExecInvocation(
                    resource: resource, command: ["true"], tty: false,
                    outputMode: .multiplexed, input: nil, closeStdinWhenInputEnds: true),
                onOutput: { _ in })

            #expect(await socket.sentFrames() == [.text(#"{"type":"stdin_eof"}"#)])
        }
    }

    @Test(
        "Attach forwards terminal resizes",
        arguments: [GuestExecResource.sandbox("sandbox-1"), .virtualMachine("vm-1")])
    func forwardsResize(resource: GuestExecResource) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 201, json: Self.sessionJSON(mode: "raw", resource: resource))
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let socket = FakeGuestExecSocket(
                frames: [
                    .text(#"{"type":"ready"}"#),
                    .text(#"{"type":"exit","exitCode":0}"#),
                ],
                delayAfterReady: .milliseconds(20))
            let session = GuestExecSessionClient(
                serverURL: baseURL,
                client: authenticated.client,
                credentials: authenticated.credentials,
                connector: FakeGuestExecConnector(sockets: [socket]),
                now: Date.init,
                sleep: { _ in })

            _ = try await session.run(
                GuestExecInvocation(
                    resource: resource, command: ["/bin/sh"], tty: true,
                    initialSize: .init(rows: 24, cols: 80), outputMode: .raw,
                    resizes: Self.resizes([.init(rows: 40, cols: 120)])),
                onOutput: { _ in })

            let sent = try #require(await socket.sentFrames().first)
            guard case .text(let text) = sent else {
                Issue.record("Expected a JSON resize control")
                return
            }
            let control = try #require(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(control["type"] as? String == "resize")
            #expect(control["rows"] as? Int == 40)
            #expect(control["cols"] as? Int == 120)
        }
    }

    @Test(
        "Retries a replica that did not claim the single-use session",
        arguments: [GuestExecResource.sandbox("sandbox-1"), .virtualMachine("vm-1")])
    func attachRetry(resource: GuestExecResource) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 201, json: Self.sessionJSON(mode: "raw", resource: resource))
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let rejected = FakeGuestExecSocket(frames: [
                .text(#"{"type":"error","message":"Invalid, expired, or already attached exec session"}"#)
            ])
            let accepted = FakeGuestExecSocket(frames: [
                .text(#"{"type":"ready"}"#),
                .text(#"{"type":"exit","exitCode":0}"#),
            ])
            let connector = FakeGuestExecConnector(sockets: [rejected, accepted])
            let session = GuestExecSessionClient(
                serverURL: baseURL,
                client: authenticated.client,
                credentials: authenticated.credentials,
                connector: connector,
                now: Date.init,
                sleep: { _ in })

            let exit = try await session.run(
                GuestExecInvocation(
                    resource: resource, command: ["/bin/sh"], tty: true,
                    outputMode: .raw),
                onOutput: { _ in })

            #expect(exit == 0)
            #expect(await connector.calls().count == 2)
            #expect(await rejected.wasClosed())
            #expect(await accepted.wasClosed())
        }
    }

    @Test(
        "Retries 503 mint failures only within the thirty-second budget",
        arguments: [GuestExecResource.sandbox("sandbox-1"), .virtualMachine("vm-1")])
    func mintRetryBudget(resource: GuestExecResource) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(handler: { _ in
                .init(statusCode: 503, json: #"{"error":true,"reason":"No agent connection"}"#)
            })
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let clock = FakeGuestExecClock(now: Date(timeIntervalSince1970: 1_000))
            let connector = FakeGuestExecConnector(sockets: [])
            let session = GuestExecSessionClient(
                serverURL: baseURL,
                client: authenticated.client,
                credentials: authenticated.credentials,
                connector: connector,
                now: { clock.current() },
                sleep: { _ in clock.advance(by: 10) })

            await #expect(throws: CLIError.self) {
                try await session.run(
                    GuestExecInvocation(
                        resource: resource, command: ["true"], tty: false,
                        outputMode: .multiplexed),
                    onOutput: { _ in })
            }

            #expect(transport.recordedRequests.count == 4)
            #expect(clock.current().timeIntervalSince1970 == 1_030)
            #expect(await connector.calls().isEmpty)
        }
    }

    @Test("Waits for an accepted sandbox wake before attaching", arguments: [GuestExecOutputMode.raw, .multiplexed])
    func acceptedWake(mode: GuestExecOutputMode) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 202, json: Self.acceptedWakeJSON),
                .init(
                    statusCode: 200,
                    json: Self.wakeDetail(
                        status: "Suspended", degraded: #", "degraded":{"reason":"old failure","sinceGeneration":1}"#)),
                .init(statusCode: 200, json: Self.wakeDetail(status: "Starting")),
                .init(statusCode: 200, json: Self.wakeDetail(status: "Running", observed: 2)),
                .init(statusCode: 200, json: Self.wakeDetail(status: "Running", observed: 2, converged: true)),
                .init(statusCode: 201, json: Self.sessionJSON(mode: mode == .raw ? "raw" : "multiplexed")),
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let socket = FakeGuestExecSocket(frames: [
                .text(#"{"type":"ready"}"#),
                .text(#"{"type":"exit","exitCode":17}"#),
            ])
            let connector = FakeGuestExecConnector(sockets: [socket])
            let session = GuestExecSessionClient(
                serverURL: baseURL, client: authenticated.client,
                credentials: authenticated.credentials, connector: connector,
                now: Date.init,
                sleep: { _ in
                    #expect(transport.recordedRequests.filter { $0.request.method == .post }.count == 1)
                    #expect(await connector.calls().isEmpty)
                })
            let exit = try await session.run(
                GuestExecInvocation(
                    resource: .sandbox("sandbox-1"), command: ["true"],
                    tty: mode == .raw, outputMode: mode), onOutput: { _ in })
            #expect(exit == 17)
            #expect(transport.recordedRequests.map { $0.request.method } == [.post, .get, .get, .get, .get, .post])
            #expect(
                transport.recordedRequests.filter { $0.request.method == .get }.allSatisfy {
                    $0.path == "/api/sandboxes/sandbox-1"
                })
            #expect(await connector.calls().count == 1)
            #expect(await socket.wasClosed())
        }
    }

    @Test("Pending sandbox wake polling exhausts the existing mint budget")
    func acceptedWakeTimeout() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(handler: { request in
                request.request.method == .post
                    ? .init(statusCode: 202, json: Self.acceptedWakeJSON)
                    : .init(statusCode: 200, json: Self.wakeDetail(status: "Starting"))
            })
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let clock = FakeGuestExecClock(now: Date(timeIntervalSince1970: 1_000))
            let connector = FakeGuestExecConnector(sockets: [])
            let session = GuestExecSessionClient(
                serverURL: baseURL, client: authenticated.client,
                credentials: authenticated.credentials, connector: connector,
                now: { clock.current() }, sleep: { _ in clock.advance(by: 10) })
            let failure = await #expect(throws: CLIError.self) {
                try await session.run(
                    GuestExecInvocation(
                        resource: .sandbox("sandbox-1"), command: ["true"],
                        tty: false, outputMode: .multiplexed), onOutput: { _ in })
            }
            if case .timedOut(let message)? = failure {
                #expect(message == "Sandbox did not become ready for guest exec within thirty seconds.")
            } else {
                Issue.record("Expected a sandbox wake timeout, got \(String(describing: failure))")
            }
            #expect(transport.recordedRequests.map { $0.request.method } == [.post, .get, .get, .get])
            #expect(clock.current().timeIntervalSince1970 == 1_030)
            #expect(await connector.calls().isEmpty)
        }
    }

    @Test("Sandbox wake rejects superseded and degraded generations", arguments: [false, true])
    func acceptedWakeRejected(degraded: Bool) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let detail = Self.wakeDetail(
                status: "Starting", target: degraded ? 2 : 3,
                degraded: degraded ? #", "degraded":{"reason":"restore failed","sinceGeneration":2}"# : "")
            let transport = MockTransport(responses: [
                .init(statusCode: 202, json: Self.acceptedWakeJSON),
                .init(statusCode: 200, json: detail),
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let connector = FakeGuestExecConnector(sockets: [])
            let session = GuestExecSessionClient(
                serverURL: baseURL, client: authenticated.client,
                credentials: authenticated.credentials, connector: connector,
                now: Date.init, sleep: { _ in Issue.record("Terminal wake must not sleep or retry") })
            let failure = await #expect(throws: CLIError.self) {
                try await session.run(
                    GuestExecInvocation(
                        resource: .sandbox("sandbox-1"), command: ["true"],
                        tty: false, outputMode: .multiplexed), onOutput: { _ in })
            }
            switch failure {
            case .operationFailed(let kind, let message) where degraded:
                #expect(kind == "sandbox wake")
                #expect(message == "restore failed")
            case .guestExec(let message) where !degraded:
                #expect(message == "Sandbox wake was superseded by a newer mutation.")
            default: Issue.record("Unexpected terminal wake verdict: \(String(describing: failure))")
            }
            #expect(transport.recordedRequests.map { $0.request.method } == [.post, .get])
            #expect(await connector.calls().isEmpty)
        }
    }

    @Test("Transient wake polling failures retry GET without repeating the boot mutation")
    func acceptedWakePollRetry() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 202, json: Self.acceptedWakeJSON),
                .init(statusCode: 503, json: #"{"reason":"temporarily unavailable"}"#),
                .init(statusCode: 200, json: Self.wakeDetail(status: "Running", observed: 2, converged: true)),
                .init(statusCode: 201, json: Self.sessionJSON(mode: "multiplexed")),
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let socket = FakeGuestExecSocket(frames: [
                .text(#"{"type":"ready"}"#), .text(#"{"type":"exit","exitCode":0}"#),
            ])
            let connector = FakeGuestExecConnector(sockets: [socket])
            let session = GuestExecSessionClient(
                serverURL: baseURL, client: authenticated.client,
                credentials: authenticated.credentials, connector: connector, now: Date.init, sleep: { _ in })
            #expect(
                try await session.run(
                    GuestExecInvocation(
                        resource: .sandbox("sandbox-1"), command: ["true"], tty: false,
                        outputMode: .multiplexed), onOutput: { _ in }) == 0)
            #expect(transport.recordedRequests.map { $0.request.method } == [.post, .get, .get, .post])
            #expect(await connector.calls().count == 1)
        }
    }

    @Test("Cancellation during sandbox wake does not retry or attach")
    func acceptedWakeCancellation() async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(handler: { request in
                request.request.method == .post
                    ? .init(statusCode: 202, json: Self.acceptedWakeJSON)
                    : .init(statusCode: 200, json: Self.wakeDetail(status: "Starting"))
            })
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let waiting = Mutex(false)
            let connector = FakeGuestExecConnector(sockets: [])
            let session = GuestExecSessionClient(
                serverURL: baseURL, client: authenticated.client,
                credentials: authenticated.credentials, connector: connector,
                now: Date.init,
                sleep: { _ in
                    waiting.withLock { $0 = true }
                    while !Task.isCancelled { await Task.yield() }
                })
            let task = Task {
                try await session.run(
                    GuestExecInvocation(
                        resource: .sandbox("sandbox-1"), command: ["true"],
                        tty: false, outputMode: .multiplexed), onOutput: { _ in })
            }
            while !waiting.withLock({ $0 }) { await Task.yield() }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(transport.recordedRequests.map { $0.request.method } == [.post, .get])
            #expect(await connector.calls().isEmpty)
        }
    }

    @Test(
        "Authorization failures do not retry or open a WebSocket",
        arguments: [GuestExecResource.sandbox("sandbox-1"), .virtualMachine("vm-1")])
    func authorizationFailureIsFailFast(resource: GuestExecResource) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 403, json: #"{"error":true,"reason":"Forbidden"}"#)
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let connector = FakeGuestExecConnector(sockets: [])
            let session = GuestExecSessionClient(
                serverURL: baseURL,
                client: authenticated.client,
                credentials: authenticated.credentials,
                connector: connector,
                now: Date.init,
                sleep: { _ in Issue.record("Authorization failure unexpectedly retried") })

            await #expect(throws: CLIError.self) {
                try await session.run(
                    GuestExecInvocation(
                        resource: resource, command: ["true"], tty: false,
                        outputMode: .multiplexed),
                    onOutput: { _ in })
            }
            #expect(transport.recordedRequests.count == 1)
            #expect(await connector.calls().isEmpty)
        }
    }

    @Test(
        "Cancellation closes an attached WebSocket",
        arguments: [GuestExecResource.sandbox("sandbox-1"), .virtualMachine("vm-1")])
    func cancellationClosesSocket(resource: GuestExecResource) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 201, json: Self.sessionJSON(mode: "raw", resource: resource))
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let socket = FakeGuestExecSocket(
                frames: [.text(#"{"type":"ready"}"#)], suspendAfterFrames: true)
            let connector = FakeGuestExecConnector(sockets: [socket])
            let session = GuestExecSessionClient(
                serverURL: baseURL,
                client: authenticated.client,
                credentials: authenticated.credentials,
                connector: connector,
                now: Date.init,
                sleep: { try await Task.sleep(for: $0) })
            let task = Task {
                try await session.run(
                    GuestExecInvocation(
                        resource: resource, command: ["sleep", "30"], tty: true,
                        outputMode: .raw),
                    onOutput: { _ in })
            }

            while !(await socket.hasDeliveredReady()) { await Task.yield() }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(await socket.wasClosed())
        }
    }

    @Test(
        "Rejects malformed output and closure without an exit status",
        arguments: [
            MalformedSessionCase.unknownStreamTag,
            .earlyClosure,
            .invalidExitCode,
            .remoteError,
            .malformedControl,
            .duplicateReady,
        ], [GuestExecResource.sandbox("sandbox-1"), .virtualMachine("vm-1")])
    func rejectsMalformedSessions(testCase: MalformedSessionCase, resource: GuestExecResource) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let transport = MockTransport(responses: [
                .init(statusCode: 201, json: Self.sessionJSON(mode: "multiplexed", resource: resource))
            ])
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let socket = FakeGuestExecSocket(frames: testCase.frames)
            let connector = FakeGuestExecConnector(sockets: [socket])
            let session = GuestExecSessionClient(
                serverURL: baseURL,
                client: authenticated.client,
                credentials: authenticated.credentials,
                connector: connector,
                now: Date.init,
                sleep: { _ in })

            await #expect(throws: CLIError.self) {
                try await session.run(
                    GuestExecInvocation(
                        resource: resource, command: ["false"], tty: false,
                        outputMode: .multiplexed),
                    onOutput: { _ in })
            }
            #expect(await socket.wasClosed())
        }
    }

    @Test(
        "VM refusals retain their distinct server reasons and do not attach",
        arguments: [
            (400, "VM must be running to exec. Current state: Stopped"),
            (400, "VM exec requires a VM created with the Strato guest agent enabled"),
            (503, "Agent 'node' does not support VM guest exec for qemu"),
            (403, "Forbidden: vm:exec"),
            (404, "VM not found"),
        ])
    func vmRefusals(refusal: (Int, String)) async throws {
        try await withTemporaryDirectoryAsync { directory in
            let body = try JSONSerialization.data(withJSONObject: ["error": true, "reason": refusal.1])
            let transport = MockTransport(handler: { _ in
                .init(statusCode: refusal.0, json: String(decoding: body, as: UTF8.self))
            })
            let authenticated = try makeAuthenticated(transport: transport, directory: directory)
            let clock = FakeGuestExecClock(now: Date(timeIntervalSince1970: 1_000))
            let connector = FakeGuestExecConnector(sockets: [])
            let session = GuestExecSessionClient(
                serverURL: baseURL, client: authenticated.client, credentials: authenticated.credentials,
                connector: connector, now: { clock.current() }, sleep: { _ in clock.advance(by: 30) })
            do {
                _ = try await session.run(
                    GuestExecInvocation(
                        resource: .virtualMachine("vm-1"), command: ["true"],
                        tty: false, outputMode: .multiplexed), onOutput: { _ in })
                Issue.record("Expected a VM refusal")
            } catch let error as CLIError {
                guard case .api(let status, let message) = error else {
                    Issue.record("Expected HTTP refusal, got \(error)")
                    return
                }
                #expect(status == refusal.0)
                #expect(message == refusal.1)
            }
            #expect(await connector.calls().isEmpty)
            #expect(transport.recordedRequests.allSatisfy { $0.path == "/api/vms/vm-1/exec" })
        }
    }

    private func makeAuthenticated(
        transport: MockTransport,
        directory: URL
    ) throws -> StratoClient.AuthenticatedSession {
        let store = CredentialStore(directory: directory)
        try store.store(
            StoredCredentials(accessToken: "st_test", refreshToken: "rt_test"), for: "test")
        return StratoClient.authenticatedSession(
            serverURL: baseURL,
            contextName: "test",
            credentialStore: store,
            transport: transport)
    }

    private static func resourcePath(_ resource: GuestExecResource) -> String {
        switch resource {
        case .sandbox(let id): "sandboxes/\(id)"
        case .virtualMachine(let id): "vms/\(id)"
        }
    }

    private static func wakeDetail(
        status: String, target: Int = 2, observed: Int = 1, converged: Bool = false,
        degraded: String = ""
    ) -> String {
        """
        {"name":"sandbox-1","environment":"test","image":"alpine","cpus":1,"memory":256,
        "env":{},"status":"\(status)","conditions":{"converged":\(converged),
        "targetGeneration":\(target),"observedGeneration":\(observed)\(degraded)}}
        """
    }

    private static let acceptedWakeJSON = """
        {"resource":{"name":"sandbox-1","environment":"test","image":"alpine",
        "cpus":1,"memory":256,"env":{},"status":"Starting","conditions":{"converged":false,"targetGeneration":2,"observedGeneration":1}},
        "targetGeneration":2,"mutationId":"00000000-0000-0000-0000-000000000001"}
        """

    private static func sessionJSON(
        mode: String?, resource: GuestExecResource = .sandbox("sandbox-1")
    ) -> String {
        let outputMode = mode.map { #", "outputMode": "\#($0)""# } ?? ""
        return """
            {"sessionId":"session-1",
             "websocketPath":"/api/\(resourcePath(resource))/exec/session-1/attach",
             "expiresAt":"2099-01-01T00:00:00Z"\(outputMode)}
            """
    }

    private static func input(_ chunks: [Data]) -> AsyncStream<Data> {
        AsyncStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    private static func resizes(
        _ values: [GuestExecTerminalSize]
    ) -> AsyncStream<GuestExecTerminalSize> {
        AsyncStream { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish()
        }
    }
}

enum MalformedSessionCase: Sendable {
    case unknownStreamTag
    case earlyClosure
    case invalidExitCode
    case remoteError
    case malformedControl
    case duplicateReady

    var frames: [GuestExecSocketFrame] {
        switch self {
        case .unknownStreamTag:
            [.text(#"{"type":"ready"}"#), .binary(Data([0x03, 0x41]))]
        case .earlyClosure:
            [.text(#"{"type":"ready"}"#)]
        case .invalidExitCode:
            [.text(#"{"type":"ready"}"#), .text(#"{"type":"exit","exitCode":256}"#)]
        case .remoteError:
            [.text(#"{"type":"ready"}"#), .text(#"{"type":"error","message":"spawn failed"}"#)]
        case .malformedControl:
            [.text(#"{"type":"ready"}"#), .text("not-json")]
        case .duplicateReady:
            [.text(#"{"type":"ready"}"#), .text(#"{"type":"ready"}"#)]
        }
    }
}

private actor FakeGuestExecConnector: GuestExecSocketConnecting {
    struct Call: Sendable {
        let url: URL
        let bearerToken: String
    }

    private var sockets: [FakeGuestExecSocket]
    private var recordedCalls: [Call] = []

    init(sockets: [FakeGuestExecSocket]) {
        self.sockets = sockets
    }

    func connect(url: URL, bearerToken: String) async throws -> any GuestExecSocket {
        recordedCalls.append(Call(url: url, bearerToken: bearerToken))
        guard !sockets.isEmpty else { throw FakeGuestExecError.noSocket }
        return sockets.removeFirst()
    }

    func calls() -> [Call] { recordedCalls }
}

private actor FakeGuestExecSocket: GuestExecSocket {
    private var frames: [GuestExecSocketFrame]
    private var sent: [GuestExecSocketFrame] = []
    private var closed = false
    private var delayAfterReady: Duration?
    private var deliveredReady = false
    private let suspendAfterFrames: Bool

    init(
        frames: [GuestExecSocketFrame],
        delayAfterReady: Duration? = nil,
        suspendAfterFrames: Bool = false
    ) {
        self.frames = frames
        self.delayAfterReady = delayAfterReady
        self.suspendAfterFrames = suspendAfterFrames
    }

    func nextFrame() async throws -> GuestExecSocketFrame? {
        if deliveredReady, let delayAfterReady {
            self.delayAfterReady = nil
            try await Task.sleep(for: delayAfterReady)
        }
        if frames.isEmpty, suspendAfterFrames {
            try await Task.sleep(for: .seconds(30))
        }
        guard !frames.isEmpty else { return nil }
        let frame = frames.removeFirst()
        if frame == .text(#"{"type":"ready"}"#) { deliveredReady = true }
        return frame
    }

    func send(binary: Data) {
        sent.append(.binary(binary))
    }

    func send(text: String) {
        sent.append(.text(text))
    }

    func close() {
        closed = true
    }

    func sentFrames() -> [GuestExecSocketFrame] { sent }
    func wasClosed() -> Bool { closed }
    func hasDeliveredReady() -> Bool { deliveredReady }
}

private enum FakeGuestExecError: Error {
    case noSocket
}

private final class FakeGuestExecClock: Sendable {
    private let value: Mutex<Date>

    init(now: Date) {
        value = Mutex(now)
    }

    func current() -> Date {
        value.withLock { $0 }
    }

    func advance(by seconds: TimeInterval) {
        value.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

private final class FakeGuestExecTerminal: GuestExecTerminal, Sendable {
    enum Transition: Equatable { case entered, restored }

    private let state = Mutex<[Transition]>([])

    func enterRawMode() {
        state.withLock { $0.append(.entered) }
    }

    func restore() {
        state.withLock { $0.append(.restored) }
    }

    func size() -> GuestExecTerminalSize {
        GuestExecTerminalSize(rows: 24, cols: 80)
    }

    func transitions() -> [Transition] {
        state.withLock { $0 }
    }
}
