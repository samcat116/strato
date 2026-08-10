import Fluent
import Foundation
import NIOCore
import StratoShared
import Testing
import Vapor

import AppTestSupport
@testable import App

/// End-to-end tests for the desired-state long-poll (STR-146), the transport
/// that replaces pushed `desired_state` frames.
///
/// Like the image-download mTLS suite these bind a real HTTP server on an
/// ephemeral loopback port: the XFCC provenance check only accepts the header
/// from a loopback peer, and Vapor's in-memory `test()` harness has no remote
/// address at all, so neither the accept nor the reject path can be reached
/// through it.
@Suite("Desired-state long-poll", .serialized)
struct DesiredStatePollTests {

    private static let path = "/agent/desired-state"

    /// Enable SPIRE mTLS auth without a trust bundle, so the XFCC `URI=` alone
    /// establishes identity (relying on Envoy's own verification) — the same
    /// setup the image-download suite uses.
    private func enableSPIRE(on app: Application) {
        app.spireService = SPIREService(
            config: SPIREServiceConfig(enabled: true, trustDomain: "strato.local"),
            logger: app.logger,
            httpClient: app.client)
    }

    private func xfccHeader(identity: String) -> (name: String, value: String) {
        ("X-Forwarded-Client-Cert", "URI=spiffe://strato.local/\(identity)")
    }

    private func registerAgentRow(app: Application, name: String) async throws -> Agent {
        let agent = Agent(
            name: name,
            hostname: "\(name).test",
            version: "1.0.0",
            status: .online,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 1 << 33, availableMemory: 1 << 33,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            )
        )
        try await agent.save(on: app.db)
        return agent
    }

    private func poll(
        app: Application, port: Int, identity: String = "agent/poll-agent", ifNoneMatch: String? = nil
    ) async throws -> ClientResponse {
        let header = xfccHeader(identity: identity)
        return try await app.client.get(URI(string: "http://127.0.0.1:\(port)\(Self.path)")) { req in
            req.headers.add(name: header.name, value: header.value)
            if let ifNoneMatch {
                req.headers.add(name: "If-None-Match", value: ifNoneMatch)
            }
        }
    }

    private func decodeSync(_ response: ClientResponse) throws -> DesiredStateMessage {
        let body = try #require(response.body)
        let envelope = try WireProtocol.makeDecoder().decode(
            MessageEnvelope.self, from: Data(body.readableBytesView))
        #expect(envelope.type == .desiredState)
        return try envelope.decode(as: DesiredStateMessage.self)
    }

    // MARK: Payload

    /// The response is a full `MessageEnvelope`, not a bare payload, so both
    /// transports use the same routing and decoding path.
    @Test("An agent SVID identity is served its own desired state in an envelope")
    func servesDesiredState() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)
            let agent = try await self.registerAgentRow(app: app, name: "poll-agent")

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Poll Org")
            let project = try await builder.createProject(
                name: "Poll Project", description: "poll tests", organization: org)
            let vm = try await builder.createVM(name: "poll-vm", project: project)
            vm.hypervisorId = agent.id!.uuidString
            try await vm.save(on: app.db)

            let response = try await self.poll(app: app, port: port)

            #expect(response.status == .ok)
            #expect(response.headers.first(name: .eTag) != nil)
            let sync = try self.decodeSync(response)
            #expect(sync.vms.map(\.vmId) == [vm.id!])
        }
    }

    @Test("A poll for an agent with no workloads is served an empty sync, not an error")
    func servesEmptySync() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)
            _ = try await self.registerAgentRow(app: app, name: "poll-agent")

            let response = try await self.poll(app: app, port: port)

            #expect(response.status == .ok)
            #expect(try self.decodeSync(response).vms.isEmpty)
        }
    }

    // MARK: Conditional requests

    @Test("A matching If-None-Match parks and answers 304 with the same ETag")
    func matchingValidatorParksThen304() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)
            _ = try await self.registerAgentRow(app: app, name: "poll-agent")
            app.desiredStatePollHoldWindow = .milliseconds(200)

            let first = try await self.poll(app: app, port: port)
            let etag = try #require(first.headers.first(name: .eTag))

            let started = ContinuousClock().now
            let second = try await self.poll(app: app, port: port, ifNoneMatch: etag)
            let elapsed = ContinuousClock().now - started

            #expect(second.status == .notModified)
            #expect(second.headers.first(name: .eTag) == etag)
            // It parked rather than answering immediately, which is the whole
            // point: an instant 304 would make the agent spin.
            #expect(elapsed >= .milliseconds(150))
        }
    }

    /// The correctness invariant of the whole design (ADR 0001: the version is
    /// "a bandwidth saving", never a gate on *whether* the agent fetches). A
    /// request with no validator must always be answered with a full payload,
    /// however unchanged the state is — otherwise a wrong ETag anywhere would
    /// strand the agent with no way back.
    @Test("A request with no validator is always served a full payload")
    func unconditionalRequestAlwaysServed() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)
            _ = try await self.registerAgentRow(app: app, name: "poll-agent")
            // Deliberately long: the "did not park" assertion below is then a
            // gap of seconds rather than a race against how long one assembly
            // takes on a loaded test machine.
            app.desiredStatePollHoldWindow = .seconds(10)

            let first = try await self.poll(app: app, port: port)
            #expect(first.status == .ok)

            // Nothing changed in between, and a conditional poll would 304 here.
            let started = ContinuousClock().now
            let second = try await self.poll(app: app, port: port)
            let elapsed = ContinuousClock().now - started

            #expect(second.status == .ok)
            #expect(second.headers.first(name: .eTag) == first.headers.first(name: .eTag))
            // And it did not park on the way: an unconditional fetch has
            // nothing to wait for.
            #expect(elapsed < .seconds(5))
        }
    }

    @Test("A stale If-None-Match is served immediately rather than parked")
    func staleValidatorServedImmediately() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)
            _ = try await self.registerAgentRow(app: app, name: "poll-agent")
            app.desiredStatePollHoldWindow = .seconds(30)

            let response = try await self.poll(
                app: app, port: port, ifNoneMatch: "\"not-the-current-digest\"")

            #expect(response.status == .ok)
        }
    }

    // MARK: Doorbell

    /// The doorbell's whole job: a parked poll answers as soon as the state it
    /// is waiting on actually changes, rather than sitting out its hold window.
    @Test("A doorbell wakes a parked poll with the changed payload")
    func doorbellWakesParkedPoll() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)
            let agent = try await self.registerAgentRow(app: app, name: "poll-agent")
            // Long enough that a 200 inside it can only have come from the
            // doorbell, not from the window expiring.
            app.desiredStatePollHoldWindow = .seconds(30)

            let first = try await self.poll(app: app, port: port)
            let etag = try #require(first.headers.first(name: .eTag))

            let parked = Task { try await self.poll(app: app, port: port, ifNoneMatch: etag) }

            // Wait for the poll to actually be parked before changing anything,
            // so this tests the wake-up and not a lucky race with assembly.
            var isParked = false
            for _ in 0..<200 {
                isParked = await app.desiredStatePollRegistry.parkedAgentKeys
                    .contains("spiffe://strato.local/agent/poll-agent")
                if isParked { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(isParked)

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Doorbell Org")
            let project = try await builder.createProject(
                name: "Doorbell Project", description: "doorbell tests", organization: org)
            let vm = try await builder.createVM(name: "doorbell-vm", project: project)
            vm.hypervisorId = agent.id!.uuidString
            try await vm.save(on: app.db)

            await app.agentService.syncDesiredState(agentId: agent.id!.uuidString)

            let woken = try await parked.value
            #expect(woken.status == .ok)
            #expect(woken.headers.first(name: .eTag) != etag)
            #expect(try self.decodeSync(woken).vms.map(\.vmId) == [vm.id!])
        }
    }

    // MARK: Authentication and scoping

    @Test("A request with no client certificate is unauthorized")
    func noCertificateIsUnauthorized() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)
            _ = try await self.registerAgentRow(app: app, name: "poll-agent")

            let response = try await app.client.get(URI(string: "http://127.0.0.1:\(port)\(Self.path)"))

            #expect(response.status == .unauthorized)
        }
    }

    @Test("A non-agent SPIFFE identity is refused")
    func nonAgentIdentityRefused() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)
            _ = try await self.registerAgentRow(app: app, name: "poll-agent")

            let response = try await self.poll(app: app, port: port, identity: "control-plane")

            #expect(response.status == .forbidden)
        }
    }

    @Test("An agent identity with no registered agent row is refused")
    func unregisteredAgentRefused() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)

            // A valid SVID for a node that enrolled but never registered: there
            // is no row to scope desired state to, so there is nothing to serve.
            let response = try await self.poll(app: app, port: port, identity: "agent/never-registered")

            #expect(response.status == .forbidden)
        }
    }

    @Test("A client certificate is refused when SPIRE is not configured")
    func withoutSPIRERefused() async throws {
        try await withRunningPollApp { app, port in
            // No enableSPIRE: nothing an agent presents can authenticate here,
            // so this is operator misconfiguration rather than a 403.
            _ = try await self.registerAgentRow(app: app, name: "poll-agent")

            let response = try await self.poll(app: app, port: port)

            #expect(response.status == .serviceUnavailable)
        }
    }

    /// The route has to be classified or it is rejected at boot; classifying it
    /// as anything but public would put the session-authorization middleware in
    /// front of a caller that has no session.
    @Test("The poll path is a public route class")
    func pollPathIsPublic() {
        #expect(AuthorizationMiddleware.classify(path: Self.path) == .isPublic)
    }

    // MARK: Assembly-cost guards (PR #985 review)

    /// A refused park must idle, not answer. The agent treats `304` as
    /// "re-poll now", so answering immediately would turn the excess polls of a
    /// looping agent into a hot loop against an endpoint that is deliberately
    /// exempt from rate limiting.
    @Test("Polls past the per-agent park cap idle out the window rather than answering early")
    func parkCapIdlesRatherThanAnswering() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)
            _ = try await self.registerAgentRow(app: app, name: "poll-agent")
            app.desiredStatePollHoldWindow = .milliseconds(600)

            let first = try await self.poll(app: app, port: port)
            let etag = try #require(first.headers.first(name: .eTag))

            // One more than the cap, all conditional so they all try to park.
            let count = DesiredStatePollRegistry.maxParkedPollsPerAgent + 1
            let started = ContinuousClock().now
            let responses = try await withThrowingTaskGroup(of: ClientResponse.self) { group in
                for _ in 0..<count {
                    group.addTask { try await self.poll(app: app, port: port, ifNoneMatch: etag) }
                }
                var all: [ClientResponse] = []
                for try await response in group { all.append(response) }
                return all
            }
            let elapsed = ContinuousClock().now - started

            #expect(responses.count == count)
            #expect(responses.allSatisfy { $0.status == .notModified })
            // Including the refused one: nothing came back early.
            #expect(elapsed >= .milliseconds(500))
        }
    }

    /// Rings arriving inside the coalescing window collapse into one wake-up,
    /// and the single assembly that follows sees all of them — so a burst
    /// costs one assembly, not one per ring.
    @Test("A burst of doorbells wakes a parked poll once, with the latest state")
    func burstOfDoorbellsCoalesces() async throws {
        try await withRunningPollApp { app, port in
            self.enableSPIRE(on: app)
            let agent = try await self.registerAgentRow(app: app, name: "poll-agent")
            app.desiredStatePollHoldWindow = .seconds(30)

            let first = try await self.poll(app: app, port: port)
            let etag = try #require(first.headers.first(name: .eTag))

            let parked = Task { try await self.poll(app: app, port: port, ifNoneMatch: etag) }
            var isParked = false
            for _ in 0..<200 {
                isParked = await app.desiredStatePollRegistry.parkedAgentKeys
                    .contains("spiffe://strato.local/agent/poll-agent")
                if isParked { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            #expect(isParked)

            let builder = TestDataBuilder(db: app.db)
            let org = try await builder.createOrganization(name: "Burst Org")
            let project = try await builder.createProject(
                name: "Burst Project", description: "burst tests", organization: org)
            let vm = try await builder.createVM(name: "burst-vm", project: project)
            vm.hypervisorId = agent.id!.uuidString
            try await vm.save(on: app.db)

            // Twenty rings back to back, well inside the coalescing window.
            for _ in 0..<20 {
                await app.desiredStatePollRegistry.ring(
                    agentKey: "spiffe://strato.local/agent/poll-agent")
            }

            let woken = try await parked.value
            #expect(woken.status == .ok)
            #expect(try self.decodeSync(woken).vms.map(\.vmId) == [vm.id!])
        }
    }
}

// MARK: - Running-server harness

/// A real bound HTTP server, needed for the XFCC provenance check (which
/// demands a loopback remote address).
private func withRunningPollApp(_ test: (Application, Int) async throws -> Void) async throws {
    try await withApp { app in
        try await app.server.start(address: .hostname("127.0.0.1", port: 0))

        // `defer` cannot hold an `await`, so the outcome is captured and
        // rethrown after the one shutdown every path runs through — leaving the
        // server up would invite the ServeCommand deinit race.
        let outcome: Result<Void, any Error>
        do {
            let port = try #require(
                app.http.server.shared.localAddress?.port, "HTTP server did not report a bound port")
            try await test(app, port)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await app.server.shutdown()
        try outcome.get()
    }
}
