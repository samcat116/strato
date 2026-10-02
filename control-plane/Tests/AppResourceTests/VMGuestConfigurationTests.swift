import AppTestSupport
import Fluent
import Foundation
import StratoShared
import Testing
import Vapor
import VaporTesting
@testable import App

@Suite("VM guest configuration", .serialized)
struct VMGuestConfigurationTests {
    private func withFixture(_ test: (Application, User, VM, String) async throws -> Void) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "guestconfig", email: "guestconfig@example.com", displayName: "Guest config",
                isSystemAdmin: false)
            let org = try await builder.createOrganization(name: "Guest Config Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)
            let project = try await builder.createProject(
                name: "Guest config", description: "Guest config tests", organization: org)
            let vm = try await builder.createVM(name: "guestconfig", project: project)
            vm.guestAgentEnabled = true
            try await vm.save(on: app.db)
            let token = try await user.generateAPIKey(on: app.db)
            try await test(app, user, vm, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    @Test("Changing, reordering and clearing config preserves transactional generations and events")
    func changesAndNoOps() async throws {
        try await withFixture { app, user, vm, _ in
            let fake = FakeAgentDispatch()
            vm.hypervisorId = "guest-config-agent"
            try await vm.save(on: app.db)
            let mutation = VMGuestConfigMutation(dispatch: fake, logger: app.logger)
            let generation = vm.generation
            let config = GuestConfig(
                packages: [
                    .init(name: "curl", state: .present), .init(name: "wget", state: .absent),
                ], files: [.init(path: "/etc/app.conf", content: "STR92_SECRET_SENTINEL", mode: "0600")])
            let accepted = try #require(
                try await mutation.replace(
                    config, on: vm, actor: .user(try user.requireID()), context: nil, db: app.db, app: app))
            #expect(accepted.targetGeneration == generation + 1)
            let reordered = GuestConfig(packages: Array(config.packages.reversed()), files: config.files)
            #expect(
                try await mutation.replace(
                    reordered, on: vm, actor: .user(try user.requireID()), context: nil, db: app.db, app: app) == nil)
            #expect(vm.generation == generation + 1)
            #expect(try await ResourceEvent.query(on: app.db).filter(\.$resourceID == vm.id!).count() == 1)
            let cleared = try #require(
                try await mutation.replace(
                    nil, on: vm, actor: .user(try user.requireID()), context: nil, db: app.db, app: app))
            #expect(cleared.targetGeneration == generation + 2)
            #expect(vm.guestConfig == nil)
            #expect(
                try await mutation.replace(
                    GuestConfig(), on: vm, actor: .user(try user.requireID()), context: nil, db: app.db, app: app)
                    == nil)
            #expect(vm.generation == generation + 2)
            await app.backgroundTasks.drain(timeout: .seconds(10))
            #expect(await fake.syncedAgentIds.count == 2)
        }
    }

    @Test("Stale mutation instances refresh previous intent and observation under the lock")
    func staleInstances() async throws {
        try await withFixture { app, user, vm, _ in
            let id = try vm.requireID()
            let stale = try #require(try await VM.find(id, on: app.db))
            let mutation = VMGuestConfigMutation(dispatch: FakeAgentDispatch(), logger: app.logger)
            let first = try #require(
                try await mutation.replace(
                    GuestConfig(packages: [.init(name: "curl", state: .present)]), on: vm,
                    actor: .user(try user.requireID()), context: nil, db: app.db, app: app))
            await app.backgroundTasks.drain(timeout: .seconds(10))
            let committed = try #require(try await VM.find(id, on: app.db))
            committed.observedGeneration = first.targetGeneration
            try await committed.save(on: app.db)
            let second = try #require(
                try await mutation.replace(
                    GuestConfig(services: [.init(name: "sshd.service", enabled: true)]), on: stale,
                    actor: .user(try user.requireID()), context: nil, db: app.db, app: app))
            #expect(second.targetGeneration == first.targetGeneration + 1)
            #expect(stale.observedGeneration == first.targetGeneration)
            #expect(stale.guestConfig?.packages.isEmpty == true)
            #expect(stale.guestConfig?.services.count == 1)
        }
    }

    @Test("Seeded admin cannot read contents or configure a guest")
    func explicitGrantRequired() async throws {
        try await withFixture { app, _, vm, token in
            for method in [HTTPMethod.GET, .PUT] {
                try await app.test(method, "/api/vms/\(vm.id!)/guest-config") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: "{\"guestConfig\":null}")
                } afterResponse: { res async in
                    #expect(res.status == .forbidden)
                }
            }
            #expect(try await ResourceEvent.query(on: app.db).count() == 0)
        }
    }

    @Test("Invalid requests are rejected without leaking payloads or changing desired state")
    func invalidRequests() async throws {
        try await withFixture { app, user, vm, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let originalGeneration = vm.generation
            for body in [
                "{}", "null", "{\"unknown\":\"STR92_SECRET_SENTINEL\"}",
                "{\"guestConfig\":{\"files\":[{\"path\":\"/../bad\",\"mode\":\"04755\",\"content\":\"STR92_SECRET_SENTINEL\"}],\"packages\":[],\"services\":[],\"sysctls\":[]}}",
                "{\"guestConfig\":null,\"retry\":\"STR92_SECRET_SENTINEL\"}",
                "{\"guestConfig\":{\"packages\":[{\"name\":\"curl\",\"state\":\"present\"},{\"name\":\"curl\",\"state\":\"absent\"}],\"files\":[],\"services\":[],\"sysctls\":[]}}",
            ] {
                try await app.test(.PUT, "/api/vms/\(vm.id!)/guest-config") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                } afterResponse: { res async in
                    #expect(res.status == .badRequest || res.status == .unprocessableEntity)
                    #expect(!res.body.string.contains("STR92_SECRET_SENTINEL"))
                }
            }
            let persisted = try #require(try await VM.find(vm.id!, on: app.db))
            #expect(persisted.generation == originalGeneration)
            #expect(persisted.guestConfig == nil)
            #expect(try await ResourceEvent.query(on: app.db).count() == 0)
        }
    }

    @Test("Accepted updates replay once and revoking the deliberate grant blocks replay")
    func idempotentReplay() async throws {
        try await withFixture { app, user, vm, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let originalGeneration = vm.generation
            let body =
                "{\"guestConfig\":{\"packages\":[{\"name\":\"curl\",\"state\":\"present\"}],\"files\":[],\"services\":[],\"sysctls\":[]}}"
            for _ in 0..<2 {
                try await app.test(.PUT, "/api/vms/\(vm.id!)/guest-config") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                    req.headers.add(name: "Idempotency-Key", value: "str92-replay")
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: body)
                } afterResponse: { res async in
                    #expect(res.status == .accepted)
                }
            }
            #expect(try await VM.find(vm.id!, on: app.db)?.generation == originalGeneration + 1)
            #expect(try await ResourceEvent.query(on: app.db).count() == 1)
            user.isSystemAdmin = false
            try await user.save(on: app.db)
            try await app.test(.PUT, "/api/vms/\(vm.id!)/guest-config") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.add(name: "Idempotency-Key", value: "str92-replay")
                req.headers.contentType = .json
                req.body = ByteBuffer(string: body)
            } afterResponse: { res async in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("A deliberate VM grant cannot read another VM and a read-only credential cannot configure")
    func scopedGrantAndReadOnly() async throws {
        try await withFixture { app, user, vm, token in
            let roleID = UUID()
            let role = IAMRoleDefinition(
                id: roleID, name: "guest-config", ownerType: .project, ownerID: vm.$project.id,
                cedarText: RoleDescriptor.canonicalPermitText(id: roleID, actions: ["vm:configureGuest"]),
                actions: ["vm:configureGuest"], managed: false)
            try await role.save(on: app.db)
            try await PolicySetVersionService.bump(reason: "test guest configuration role", on: app.db)
            await app.announcePolicySetChange()
            try await RoleBindingService.grant(
                principalType: .user, principalID: try user.requireID(), roleID: roleID,
                nodeType: .virtualMachine, nodeID: try vm.requireID(), createdBy: nil, on: app.db)
            let project = try await vm.$project.get(on: app.db)
            let other = try await TestDataBuilder(db: app.db).createVM(name: "other-vm", project: project)
            for (id, status) in [(try vm.requireID(), HTTPStatus.ok), (try other.requireID(), .forbidden)] {
                try await app.test(.GET, "/api/vms/\(id)/guest-config") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                } afterResponse: { res async in
                    #expect(res.status == status)
                }
            }
            let restricted = try await user.generateAPIKey(on: app.db, name: "read-only", restriction: .readOnly)
            for method in [HTTPMethod.GET, .PUT] {
                try await app.test(method, "/api/vms/\(vm.id!)/guest-config") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: restricted)
                    req.headers.contentType = .json
                    req.body = ByteBuffer(string: "{\"guestConfig\":null}")
                } afterResponse: { res async in
                    #expect(res.status == .forbidden)
                }
            }
        }
    }

    @Test("Host convergence is not a guest-config success verdict without guest observations")
    func hostSuccessIsInsufficient() {
        let event = ResourceEvent()
        event.mutation = .guestConfig
        event.targetGeneration = 4
        let hostSuccess = ResourceConditions(
            targetGeneration: 4, observedGeneration: 4, desiredSatisfied: true,
            phase: nil, lastError: nil, failedGeneration: nil)
        #expect(
            OperationFacade.verdict(for: event, in: .init(conditions: hostSuccess, terminal: nil)).status == .pending)
        let failed = ResourceConditions(
            targetGeneration: 4, observedGeneration: 4, desiredSatisfied: true,
            phase: nil, lastError: "Guest configuration failed", failedGeneration: 4)
        #expect(OperationFacade.verdict(for: event, in: .init(conditions: failed, terminal: nil)).status == .failed)
    }

    @Test("Stored guest intent round-trips while diagnostic descriptions redact its contents")
    func diagnosticRedaction() throws {
        let config = GuestConfig(files: [.init(path: "/etc/app.conf", content: "STR92_SECRET_SENTINEL", mode: "0600")])
        let stored = StoredGuestConfig(config)
        #expect(!String(describing: stored).contains("STR92_SECRET_SENTINEL"))
        #expect(!String(reflecting: stored).contains("STR92_SECRET_SENTINEL"))
        let encoded = try JSONEncoder().encode(stored)
        #expect(try JSONDecoder().decode(GuestConfig.self, from: encoded) == config)
        #expect(try JSONDecoder().decode(StoredGuestConfig.self, from: encoded).value == config)
    }

    @Test("Opt-out prevents changes and public VM detail does not include file contents")
    func optOutAndDisclosure() async throws {
        try await withFixture { app, user, vm, _ in
            vm.guestAgentEnabled = false
            try await vm.save(on: app.db)
            let mutation = VMGuestConfigMutation(dispatch: FakeAgentDispatch(), logger: app.logger)
            await #expect(throws: Abort.self) {
                try await mutation.replace(
                    GuestConfig(packages: [.init(name: "curl", state: .present)]), on: vm,
                    actor: .user(try user.requireID()), context: nil, db: app.db, app: app)
            }
            vm.guestConfig = GuestConfig(files: [
                .init(path: "/etc/app.conf", content: "STR92_SECRET_SENTINEL", mode: "0600")
            ])
            let encoded = try JSONEncoder().encode(VMDetailResponse(from: vm))
            #expect(!String(decoding: encoded, as: UTF8.self).contains("STR92_SECRET_SENTINEL"))
        }
    }
    private func observation(_ values: [String: Any]) throws -> GuestConfigObservation {
        var payload: [String: Any] = [
            "generation": 3, "status": "converged", "packages": [], "files": [], "services": [], "sysctls": [],
        ]
        payload.merge(values) { _, new in new }
        return try JSONDecoder().decode(
            GuestConfigObservation.self, from: JSONSerialization.data(withJSONObject: payload))
    }

    private func apply(_ report: GuestConfigObservation?, vm: VM, app: Application, by agent: String? = nil)
        async throws
    {
        let observed = ObservedVMState(
            vmId: try vm.requireID(), status: .running, observedGeneration: vm.generation,
            lastError: report?.error, failedGeneration: report?.status == .failed ? report?.generation : nil,
            guestConfigObservation: report)
        let instant = try await ClusterClock.read(on: app.db)
        let applier = ObservedStateApplier(app: app)
        _ = try await applier.withLockedCurrent(vm, reportedBy: agent ?? vm.hypervisorId ?? "config-node", on: app.db) {
            vm, db in
            try await applier.applyObservedVMState(
                vm: vm, observed: observed, interfaces: [], bootVolumes: nil, at: instant, on: db)
        }
    }

    @Test("Only matching current guest read-back permits completion; clearing needs no guest report")
    func guestReadBackCompletion() async throws {
        try await withFixture { app, _, vm, _ in
            vm.hypervisorId = "config-node"
            vm.setFixtureDesiredStatus(.running)
            vm.generation = 3
            vm.guestConfig = GuestConfig(files: [.init(path: "/etc/app.conf", content: "desired", mode: "0600")])
            try await vm.save(on: app.db)
            let wrong = try observation([
                "files": [["path": "/etc/app.conf", "sha256": String(repeating: "a", count: 64), "mode": "0600"]]
            ])
            try await apply(wrong, vm: vm, app: app)
            #expect(vm.guestConfigEvidence == nil)
            #expect(vm.convergencePhase == "waiting for current guest configuration read-back")
            let good = try observation([
                "files": [
                    ["path": "/etc/app.conf", "sha256": VMGuestConfigPresentation.hash("desired"), "mode": "0600"]
                ]
            ])
            try await apply(good, vm: vm, app: app)
            #expect(VMGuestConfigPresentation.converged(vm))
            #expect(vm.isConverged)
            let event = ResourceEvent()
            event.mutation = .guestConfig
            event.targetGeneration = 3
            let confirmed = OperationFacade.ResourceView(
                conditions: vm.conditions, terminal: nil,
                guestConfiguration: .init(generation: 3, managed: true, converged: true))
            #expect(OperationFacade.verdict(for: event, in: confirmed).status == .succeeded)
            try await apply(nil, vm: vm, app: app)
            #expect(!VMGuestConfigPresentation.converged(vm))
            #expect(vm.guestConfigEvidence?.available == false)
            try await apply(good, vm: vm, app: app)
            #expect(VMGuestConfigPresentation.converged(vm))
            vm.guestConfig = nil
            try await vm.save(on: app.db)
            let cleared = OperationFacade.ResourceView(
                conditions: vm.conditions, terminal: nil,
                guestConfiguration: .init(generation: 3, managed: false, converged: false))
            #expect(OperationFacade.verdict(for: event, in: cleared).status == .succeeded)
        }
    }

    @Test("A same-generation failure after success remains terminal; only its named item is failed")
    func terminalFailureAndRetry() async throws {
        try await withFixture { app, user, vm, _ in
            vm.hypervisorId = "config-node"
            vm.setFixtureDesiredStatus(.running)
            vm.generation = 3
            vm.guestConfig = GuestConfig(packages: [
                .init(name: "curl", state: .present), .init(name: "wget", state: .present),
            ])
            try await vm.save(on: app.db)
            let good = try observation([
                "packages": [["name": "curl", "version": "1"], ["name": "wget", "version": "2"]]
            ])
            try await apply(good, vm: vm, app: app)
            #expect(vm.isConverged)
            let bad = try observation([
                "status": "failed", "error": "STR92_SECRET_SENTINEL",
                "failedItem": ["section": "packages", "identity": "curl", "reason": "STR92_SECRET_SENTINEL"],
                "packages": [["name": "curl", "version": NSNull()]],
            ])
            try await apply(bad, vm: vm, app: app)
            #expect(vm.failedGeneration == 3)
            #expect(!vm.isConverged)
            #expect(vm.lastError == VMGuestConfigPresentation.failure)
            let rows = VMGuestConfigPresentation.items(vm, agentOnline: true)
            #expect(rows.first { $0.identity == "curl" }?.state == .failed)
            #expect(rows.first { $0.identity == "wget" }?.state == .unknown)
            #expect(!String(describing: vm.guestConfigEvidence).contains("STR92_SECRET_SENTINEL"))
            // Reloading from storage models restart; a contradictory report cannot erase terminal failure.
            let restarted = try #require(try await VM.find(vm.id!, on: app.db))
            try await apply(good, vm: restarted, app: app)
            #expect(restarted.failedGeneration == 3)
            #expect(restarted.guestConfigEvidence?.observation.status == .failed)
            let intent = restarted.guestConfig
            let mutation = VMGuestConfigMutation(dispatch: FakeAgentDispatch(), logger: app.logger)
            #expect(
                try await mutation.replace(
                    intent, on: restarted, actor: .user(user.id!), context: nil, db: app.db, app: app) == nil)
            let retried = try #require(
                try await mutation.replace(
                    intent, retry: true, on: restarted, actor: .user(user.id!), context: nil, db: app.db, app: app))
            #expect(retried.targetGeneration == 4)
            #expect(VMGuestConfigPresentation.items(restarted, agentOnline: true).allSatisfy { $0.state != .failed })
            try await apply(bad, vm: restarted, app: app)
            #expect(!VMGuestConfigPresentation.converged(restarted))
            let newGood = try observation([
                "generation": 4, "packages": [["name": "curl", "version": "1"], ["name": "wget", "version": "2"]],
            ])
            try await apply(newGood, vm: restarted, app: app)
            #expect(VMGuestConfigPresentation.converged(restarted))
        }
    }

    @Test("Foreign placement, future generation and foreign identities never become current evidence")
    func rejectedObservationEvidence() async throws {
        try await withFixture { app, _, vm, _ in
            vm.hypervisorId = "config-node"
            vm.setFixtureDesiredStatus(.running)
            vm.generation = 3
            vm.guestConfig = GuestConfig(packages: [.init(name: "curl", state: .present)])
            try await vm.save(on: app.db)
            let good = try observation(["packages": [["name": "curl", "version": "1"]]])
            try await apply(good, vm: vm, app: app, by: "foreign-node")
            #expect(vm.guestConfigEvidence == nil)
            for report in [
                try observation(["generation": 4]),
                try observation(["packages": [["name": "foreign", "version": "1"]]]),
            ] {
                try await apply(report, vm: vm, app: app)
                #expect(vm.guestConfigEvidence == nil)
            }
        }
    }

    @Test(
        "Item comparisons use hash/mode, boot enablement and normalized sysctls; stopped and disconnected evidence is not current"
    )
    func itemComparisonAndAvailability() throws {
        let vm = VM()
        vm.generation = 2
        vm.setFixtureDesiredStatus(.running)
        vm.setStatus(.running)
        vm.generation = 3
        vm.hypervisorId = "config-node"
        vm.guestConfig = GuestConfig(
            packages: [.init(name: "curl", state: .absent)],
            files: [.init(path: "/etc/a", content: "private contents", mode: "0600")],
            services: [.init(name: "sshd", enabled: true)],
            sysctls: [.init(key: "net.test", value: "1 2")])
        let report = try observation([
            "status": "failed", "error": "failure",
            "packages": [["name": "curl", "version": NSNull()]],
            "files": [
                ["path": "/etc/a", "sha256": VMGuestConfigPresentation.hash("private contents"), "mode": "0644"]
            ],
            "services": [["name": "sshd", "enabled": true, "activeState": "inactive"]],
            "sysctls": [["key": "net.test", "value": "1   2\n"]],
        ])
        vm.guestConfigEvidence = .init(observation: report, agentID: "config-node", receivedAt: Date(), available: true)
        let rows = VMGuestConfigPresentation.items(vm, agentOnline: true)
        #expect(rows.map(\.state) == [.matched, .drift, .matched, .matched])
        #expect(!rows.map(\.desired).joined().contains("private contents"))
        #expect(VMGuestConfigPresentation.items(vm, agentOnline: false).allSatisfy { $0.state == .stale })
        let partial = try observation([
            "status": "failed", "error": "failure",
            "files": [["path": "/etc/a", "mode": "0600"]],
            "services": [["name": "sshd", "activeState": "inactive"]],
        ])
        vm.guestConfigEvidence = .init(
            observation: partial, agentID: "config-node", receivedAt: Date(), available: true)
        let partialRows = VMGuestConfigPresentation.items(vm, agentOnline: true)
        #expect(partialRows.first { $0.section == "files" }?.observed?.contains("mode 0600") == true)
        #expect(partialRows.first { $0.section == "services" }?.observed?.contains("active inactive") == true)
        #expect(partialRows.allSatisfy { $0.state == .unknown })
        vm.setFixtureDesiredStatus(.shutdown)
        #expect(VMGuestConfigPresentation.status(vm, agentOnline: true) == "deferred")
        vm.setFixtureDesiredStatus(.running)
        vm.generation = 4
        #expect(VMGuestConfigPresentation.status(vm, agentOnline: true) == "stale")
    }

    @Test("Privileged status distinguishes disconnect and reconnect, redacts failures, and retries through the API")
    func observedStatusAPIAndRetry() async throws {
        try await withFixture { app, user, vm, token in
            user.isSystemAdmin = true
            try await user.save(on: app.db)
            let instant = try await ClusterClock.read(on: app.db)
            let agent = try await TestDataBuilder(db: app.db).createAgent(
                named: "config-node", lastHeartbeat: instant.date)
            vm.hypervisorId = try agent.requireID().uuidString
            vm.setFixtureDesiredStatus(.running)
            vm.generation = 3
            vm.guestConfig = GuestConfig(packages: [.init(name: "curl", state: .present)])
            try await vm.save(on: app.db)
            let good = try observation(["packages": [["name": "curl", "version": "1"]]])
            try await apply(good, vm: vm, app: app)
            for status in ["converged", "unavailable", "converged"] {
                agent.lastHeartbeat = status == "unavailable" ? instant.date.addingTimeInterval(-61) : instant.date
                try await agent.save(on: app.db)
                try await app.test(.GET, "/api/vms/\(vm.id!)/guest-config") { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: token)
                } afterResponse: { res async throws in
                    #expect(res.status == .ok)
                    let response = try res.content.decode(VMGuestConfigurationResponse.self)
                    #expect(response.status == status)
                    #expect(response.observedGeneration == 3)
                    #expect(response.items.first?.state == (status == "unavailable" ? .stale : .matched))
                }
            }
            let bad = try observation([
                "status": "failed", "error": "STR92_SECRET_SENTINEL",
                "failedItem": ["section": "packages", "identity": "curl", "reason": "STR92_SECRET_SENTINEL"],
            ])
            try await apply(bad, vm: vm, app: app)
            try await app.test(.GET, "/api/vms/\(vm.id!)/guest-config") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res async throws in
                #expect(!res.body.string.contains("STR92_SECRET_SENTINEL"))
                let response = try res.content.decode(VMGuestConfigurationResponse.self)
                #expect(response.status == "failed")
                #expect(response.items.first?.state == .failed)
            }
            try await app.test(.PUT, "/api/vms/\(vm.id!)/guest-config") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                req.headers.contentType = .json
                req.body = ByteBuffer(
                    string:
                        "{\"guestConfig\":{\"packages\":[{\"name\":\"curl\",\"state\":\"present\"}],\"files\":[],\"services\":[],\"sysctls\":[]},\"retry\":true}"
                )
            } afterResponse: { res async in
                #expect(res.status == .accepted)
            }
            let retried = try #require(try await VM.find(vm.id!, on: app.db))
            #expect(retried.generation == 4)
            #expect(retried.guestConfig == vm.guestConfig)
            // Old failed facts are retained, but cannot be assigned to the new generation.
            #expect(VMGuestConfigPresentation.items(retried, agentOnline: true).allSatisfy { $0.state != .failed })
            try await apply(nil, vm: retried, app: app)
            try await app.test(.GET, "/api/vms/\(vm.id!)/guest-config") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { res async throws in
                let response = try res.content.decode(VMGuestConfigurationResponse.self)
                #expect(response.desiredGeneration == 4)
                #expect(response.failureGeneration == 3)
                #expect(response.error == nil)
            }
        }
    }

    @Test("A boot may realize deferred intent, while another config edit supersedes the earlier request")
    func deferredAndSupersededVerdicts() {
        let event = ResourceEvent()
        event.mutation = .guestConfig
        event.targetGeneration = 3
        let conditions = ResourceConditions(
            targetGeneration: 4, observedGeneration: 4,
            desiredSatisfied: true, phase: nil, lastError: nil, failedGeneration: nil)
        let booted = OperationFacade.ResourceView(
            conditions: conditions, terminal: nil,
            guestConfiguration: .init(generation: 4, managed: true, converged: true, intentGeneration: 3))
        #expect(OperationFacade.verdict(for: event, in: booted).status == .succeeded)
        let replaced = OperationFacade.ResourceView(
            conditions: conditions, terminal: nil,
            guestConfiguration: .init(generation: 4, managed: true, converged: true, intentGeneration: 4))
        #expect(OperationFacade.verdict(for: event, in: replaced).status == .failed)
    }

    @Test("Canonical Unicode equality cannot hide a change in guest file bytes")
    func distinctUTF8ContentAdvancesGeneration() async throws {
        try await withFixture { app, user, vm, _ in
            let composed = "\u{00e9}"
            let decomposed = "e\u{0301}"
            #expect(composed == decomposed)
            #expect(VMGuestConfigPresentation.hash(composed) != VMGuestConfigPresentation.hash(decomposed))
            let mutation = VMGuestConfigMutation(dispatch: FakeAgentDispatch(), logger: app.logger)
            let first = GuestConfig(files: [.init(path: "/etc/unicode", content: composed, mode: "0600")])
            let second = GuestConfig(files: [.init(path: "/etc/unicode", content: decomposed, mode: "0600")])
            let a = try #require(
                try await mutation.replace(first, on: vm, actor: .user(user.id!), context: nil, db: app.db, app: app))
            let b = try #require(
                try await mutation.replace(second, on: vm, actor: .user(user.id!), context: nil, db: app.db, app: app))
            #expect(b.targetGeneration == a.targetGeneration + 1)
            #expect(Array(vm.guestConfig!.files[0].content.utf8) == Array(decomposed.utf8))
            let pathConfig = GuestConfig(files: [.init(path: "/etc/\(composed)", content: "same", mode: "0600")])
            let aliased = try observation([
                "files": [
                    ["path": "/etc/\(decomposed)", "sha256": VMGuestConfigPresentation.hash("same"), "mode": "0600"]
                ]
            ])
            #expect(throws: GuestConfigObservationError.self) {
                try VMGuestConfigPresentation.validate(aliased, config: pathConfig, generation: 3)
            }
            let textConfig = GuestConfig(sysctls: [.init(key: "net.test", value: composed)])
            let differentText = try observation(["sysctls": [["key": "net.test", "value": decomposed]]])
            #expect(!VMGuestConfigPresentation.matches(differentText, config: textConfig, generation: 3))

        }
    }

}
