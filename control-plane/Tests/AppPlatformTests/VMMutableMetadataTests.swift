import AppTestSupport
import Fluent
import Foundation
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

private actor MetadataDoorbellCollector {
    private var messages: [String] = []

    func append(_ message: String) { messages.append(message) }

    func waitFor(count: Int, timeoutMilliseconds: Int = 2_000) async -> [String] {
        for _ in 0..<(timeoutMilliseconds / 20) {
            if messages.count >= count { return messages }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return messages
    }
}

@Suite("VM mutable metadata tests", .serialized)
final class VMMutableMetadataTests {
    private static let firstKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f first@test"
    private static let secondKey =
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f second@test"

    private func withApp(
        _ test: (Application, Project, String, InMemoryCoordinationStore) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)

            let store = InMemoryCoordinationStore()
            app.coordination = CoordinationService(store: store, logger: app.logger)

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "metadata-editor", email: "metadata-editor@example.com",
                displayName: "Metadata Editor")
            let organization = try await builder.createOrganization(name: "Mutable Metadata Org")
            try await builder.addUserToOrganization(
                user: user, organization: organization, role: "admin")
            user.currentOrganizationId = try organization.requireID()
            try await user.save(on: app.db)
            let project = try await builder.createProject(
                name: "Mutable Metadata Project", description: "metadata patch tests",
                organization: organization)
            let token = try await user.generateAPIKey(on: app.db)

            try await test(app, project, token, store)
        } catch {
            try? await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    private func registerAgent(
        app: Application, project: Project, organizationID: UUID
    ) async throws -> String {
        let siteID = try await TestDataBuilder(db: app.db).placementSite(for: project).requireID()
        return try await TestDataBuilder(db: app.db).registerAgent(
            on: app,
            named: "mutable-metadata-agent",
            hostname: "mutable-metadata-host",
            siteID: siteID,
            organizationScope: .organization(organizationID))
    }

    @Test("PATCH persists tags and keys with one generation bump and rings the placed agent")
    func patchConvergesMutableMetadata() async throws {
        try await withApp { app, project, token, store in
            let organizationID = try #require(await project.getRootOrganizationId(on: app.db))
            let agentID = try await self.registerAgent(
                app: app, project: project, organizationID: organizationID)
            let vm = try await TestDataBuilder(db: app.db).createVM(
                name: "mutable-vm", project: project)
            vm.status = .running
            vm.desiredStatus = .running
            vm.hypervisorId = agentID
            vm.setSSHAuthorizedKeys([Self.firstKey])
            try await vm.save(on: app.db)
            try await attachBootVolume(to: vm, on: agentID, using: app.db)
            let vmID = try vm.requireID()
            let startingGeneration = vm.generation

            let collector = MetadataDoorbellCollector()
            await store.subscribe(channel: CoordinationService.doorbellChannel) { message in
                Task { await collector.append(message) }
            }

            let request = PatchVMMetadataRequest(
                tags: ["environment": "production", "owner": "platform"],
                sshAuthorizedKeys: [Self.secondKey])
            try await app.test(.PATCH, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(request)
            } afterResponse: { response in
                #expect(response.status == .ok)
                let body = try response.content.decode(VMDetailResponse.self)
                #expect(body.tags == request.tags)
                #expect(body.sshAuthorizedKeys == [Self.secondKey])
                #expect(body.conditions.targetGeneration == startingGeneration + 1)
            }

            let updated = try #require(await VM.find(vmID, on: app.db))
            #expect(updated.generation == startingGeneration + 1)
            #expect(updated.tags == request.tags)
            #expect(updated.sshAuthorizedKeys == [Self.secondKey])
            #expect(updated.sshPublicKey == Self.secondKey)

            let sync = try await app.desiredStateAssembler.assemble(agentId: agentID)
            let desired = try #require(sync.vms.first { $0.vmId == vmID })
            #expect(desired.generation == startingGeneration + 1)
            #expect(desired.metadata?.tags == request.tags)
            #expect(desired.metadata?.sshAuthorizedKeys == [Self.secondKey])
            #expect(desired.spec.sshAuthorizedKeys == [Self.secondKey])

            let messages = await collector.waitFor(count: 1)
            #expect(
                messages.compactMap { CoordinationService.parseDoorbell($0)?.agentKey }
                    == [agentKey("mutable-metadata-agent")])
        }
    }

    @Test("an unchanged or empty PATCH is a no-op, while empty collections clear metadata")
    func noOpAndClearSemantics() async throws {
        try await withApp { app, project, token, store in
            let organizationID = try #require(await project.getRootOrganizationId(on: app.db))
            let agentID = try await self.registerAgent(
                app: app, project: project, organizationID: organizationID)
            let vm = try await TestDataBuilder(db: app.db).createVM(
                name: "clearable-vm", project: project)
            vm.hypervisorId = agentID
            vm.tags = ["role": "api"]
            vm.setSSHAuthorizedKeys([Self.firstKey])
            try await vm.save(on: app.db)
            let vmID = try vm.requireID()
            let startingGeneration = vm.generation

            let collector = MetadataDoorbellCollector()
            await store.subscribe(channel: CoordinationService.doorbellChannel) { message in
                Task { await collector.append(message) }
            }

            try await app.test(.PATCH, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(PatchVMMetadataRequest(tags: nil, sshAuthorizedKeys: nil))
            } afterResponse: { response in
                #expect(response.status == .ok)
            }
            #expect(try await VM.find(vmID, on: app.db)?.generation == startingGeneration)
            #expect(await collector.waitFor(count: 1, timeoutMilliseconds: 200).isEmpty)

            try await app.test(.PATCH, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(PatchVMMetadataRequest(tags: [:], sshAuthorizedKeys: []))
            } afterResponse: { response in
                #expect(response.status == .ok)
                let body = try response.content.decode(VMDetailResponse.self)
                #expect(body.tags.isEmpty)
                #expect(body.sshAuthorizedKeys.isEmpty)
            }

            let cleared = try #require(await VM.find(vmID, on: app.db))
            #expect(cleared.generation == startingGeneration + 1)
            #expect(cleared.tags.isEmpty)
            #expect(cleared.sshAuthorizedKeys.isEmpty)
            #expect(cleared.sshPublicKey == nil)
            #expect(await collector.waitFor(count: 1).count == 1)
        }
    }

    @Test("invalid authorized keys are rejected before metadata or generation changes")
    func invalidKeyIsRejected() async throws {
        try await withApp { app, project, token, _ in
            let vm = try await TestDataBuilder(db: app.db).createVM(
                name: "invalid-key-vm", project: project)
            let vmID = try vm.requireID()
            let startingGeneration = vm.generation

            try await app.test(.PATCH, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(
                    PatchVMMetadataRequest(
                        tags: ["safe": "unchanged"],
                        sshAuthorizedKeys: ["not an ssh key"]))
            } afterResponse: { response in
                #expect(response.status == .badRequest)
            }

            let unchanged = try #require(await VM.find(vmID, on: app.db))
            #expect(unchanged.generation == startingGeneration)
            #expect(unchanged.tags.isEmpty)
            #expect(unchanged.sshAuthorizedKeys.isEmpty)
        }
    }
}
