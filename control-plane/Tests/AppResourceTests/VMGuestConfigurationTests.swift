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
}
