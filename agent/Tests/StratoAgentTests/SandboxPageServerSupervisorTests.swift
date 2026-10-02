import Foundation
import Synchronization
import Testing
@testable import StratoAgentCore

@Suite("Bounded page server transport supervision")
struct SandboxPageServerSupervisorTests {
    private final class Stops: Sendable {
        let reasons = Mutex<[SandboxPageServerSupervisor.Failure]>([])
        func append(_ reason: SandboxPageServerSupervisor.Failure) { reasons.withLock { $0.append(reason) } }
        var count: Int { reasons.withLock { $0.count } }
    }
    private func supervisor(
        stops: Stops, capacity: Int = 2, timeout: Duration = .milliseconds(40),
        handshake: @escaping @Sendable () async throws -> Void = {},
        read: @escaping @Sendable (Int) async throws -> Data = { _ in Data(repeating: 1, count: 4096) }
    ) throws -> SandboxPageServerSupervisor {
        try .init(
            transport: .init(handshake: handshake, readPage: read, stop: { stops.append($0) }), pageCount: 2,
            capacity: capacity, faultTimeout: timeout, handshakeTimeout: timeout)
    }
    @Test func successfulServiceAndSingleRevocation() async throws {
        let stops = Stops()
        let server = try supervisor(stops: stops)
        try await server.start()
        #expect(try await server.request(page: 0) == Data(repeating: 1, count: 4096))
        #expect(await server.metrics.served == 1)
        #expect(await server.metrics.bytesServed == 4096)
        await server.cancel()
        await server.cancel()
        await server.handlerExited()
        #expect(stops.count == 1)
        #expect(await server.state == .cancelled)
    }
    @Test func handshakeTimeoutAndExitFailClosed() async throws {
        let stops = Stops()
        let server = try supervisor(stops: stops, handshake: { try await Task.sleep(for: .seconds(10)) })
        await #expect(throws: SandboxPageServerSupervisor.Failure.deadline) { try await server.start() }
        #expect(await server.state == .failed)
        #expect(stops.count == 1)
        let exited = try supervisor(stops: Stops())
        try await exited.start()
        await exited.handlerExited()
        await #expect(throws: SandboxPageServerSupervisor.Failure.notReady) { try await exited.request(page: 0) }
    }
    @Test func faultTimeoutDoesNotWaitForCooperativeCancellation() async throws {
        let stops = Stops()
        // Detached transport work deliberately outlives its cancellation. The
        // independent deadline must resolve the caller before it finishes.
        let server = try supervisor(
            stops: stops,
            read: { _ in
                let operation = Task.detached {
                    try await Task.sleep(for: .milliseconds(200))
                    return Data(repeating: 1, count: 4096)
                }
                return try await operation.value
            })
        try await server.start()
        let clock = ContinuousClock()
        let before = clock.now
        await #expect(throws: SandboxPageServerSupervisor.Failure.deadline) { try await server.request(page: 0) }
        #expect(before.duration(to: clock.now) < .milliseconds(180))
        #expect(await server.state == .failed)
        #expect(stops.count == 1)
    }
    @Test func overflowOnlyRevokesAffectedLease() async throws {
        let aStops = Stops()
        let bStops = Stops()
        let a = try supervisor(
            stops: aStops, capacity: 1, timeout: .seconds(1),
            read: { _ in
                try await Task.sleep(for: .seconds(10))
                return Data(repeating: 1, count: 4096)
            })
        let b = try supervisor(stops: bStops)
        try await a.start()
        try await b.start()
        let first = Task { try await a.request(page: 0) }
        while await a.metrics.admitted == 0 { await Task.yield() }
        await #expect(throws: SandboxPageServerSupervisor.Failure.queueFull) { try await a.request(page: 1) }
        await #expect(throws: SandboxPageServerSupervisor.Failure.queueFull) { try await first.value }
        #expect(try await b.request(page: 0).count == 4096)
        #expect(aStops.count == 1 && bStops.count == 0)
        #expect(await a.metrics.queueOverflows == 1)
        await b.cancel()
    }
    private final class LocalChild: Sendable {
        let process = Mutex<ProcessRunner.SpawnedProcess?>(nil)
        let owner = Mutex<SandboxPageServerSupervisor?>(nil)
        func stop() {
            owner.withLock { $0 = nil }
            let child = process.withLock { value in
                let child = value
                value = nil
                return child
            }
            if let child { Task { await child.terminate(grace: .milliseconds(10)) } }
        }
    }

    @Test func disposableChildExitRevokesOnlyItsLease() async throws {
        let short = LocalChild()
        let healthy = LocalChild()
        func make(_ child: LocalChild, lifetime: String, stalled: Bool) throws -> SandboxPageServerSupervisor {
            let transport = SandboxPageServerSupervisor.Transport(
                handshake: {
                    let process = try ProcessRunner.spawn(
                        executableURL: URL(fileURLWithPath: "/bin/sleep"),
                        arguments: [lifetime], environment: [:],
                        onExit: { _ in
                            let owner = child.owner.withLock { $0 }
                            if let owner { Task { await owner.handlerExited() } }
                        })
                    child.process.withLock { $0 = process }
                },
                readPage: { _ in
                    if stalled { try await Task.sleep(for: .seconds(10)) }
                    return Data(repeating: 1, count: 4096)
                }, stop: { _ in child.stop() })
            let server = try SandboxPageServerSupervisor(
                transport: transport, pageCount: 1,
                faultTimeout: .seconds(10), handshakeTimeout: .seconds(10))
            child.owner.withLock { $0 = server }
            return server
        }
        let a = try make(short, lifetime: "30", stalled: true)
        let b = try make(healthy, lifetime: "30", stalled: false)
        defer {
            short.stop()
            healthy.stop()
        }
        try await a.start()
        try await b.start()
        let aProcess = try #require(short.process.withLock { $0 })
        let bProcess = try #require(healthy.process.withLock { $0 })
        let request = Task { try await a.request(page: 0) }
        let admissionDeadline = ContinuousClock().now.advanced(by: .seconds(5))
        while await a.metrics.admitted == 0 && ContinuousClock().now < admissionDeadline { await Task.yield() }
        #expect(await a.metrics.admitted == 1)
        // Exit is triggered only after request admission, rather than relying
        // on a short-lived child's scheduling against the full test suite.
        await aProcess.terminate(grace: .milliseconds(10))
        await #expect(throws: SandboxPageServerSupervisor.Failure.handlerExited) { try await request.value }
        #expect(bProcess.isRunning)
        #expect(try await b.request(page: 0).count == 4096)
        await b.cancel()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while bProcess.isRunning && clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!bProcess.isRunning)
        // Real local child exit/termination evidence, not a Firecracker/UFFD proof.
    }

    @Test func invalidLimitsAndFaultAddressesAreRejected() async throws {
        #expect(throws: SandboxPageServerSupervisor.Failure.invalidLimits) {
            try supervisor(stops: Stops(), capacity: 0)
        }
        #expect(throws: SandboxPageServerSupervisor.Failure.invalidLimits) {
            try supervisor(stops: Stops(), timeout: .zero)
        }
        let server = try supervisor(stops: Stops())
        await #expect(throws: SandboxPageServerSupervisor.Failure.notReady) { try await server.request(page: 0) }
        try await server.start()
        await #expect(throws: SandboxPageServerSupervisor.Failure.invalidPage) {
            try await server.request(page: Int.max)
        }
        #expect(await server.state == .failed)
    }

    @Test func malformedResponseAndCancellation() async throws {
        let bad = try supervisor(stops: Stops(), read: { _ in Data([1]) })
        try await bad.start()
        await #expect(throws: SandboxPageServerSupervisor.Failure.transport) { try await bad.request(page: 0) }
        let stops = Stops()
        let cancelled = try supervisor(
            stops: stops, timeout: .seconds(1),
            read: { _ in
                try await Task.sleep(for: .seconds(10))
                return Data(repeating: 0, count: 4096)
            })
        try await cancelled.start()
        let request = Task { try await cancelled.request(page: 0) }
        while await cancelled.metrics.admitted == 0 { await Task.yield() }
        request.cancel()
        await #expect(throws: SandboxPageServerSupervisor.Failure.cancelled) { try await request.value }
        #expect(stops.count == 1)
    }
}
