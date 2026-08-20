import Fluent
import StratoShared
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// The per-instance metadata kill switch at the API boundary (STR-185):
/// `VM.metadataEnabled`, the default that must not change for an existing
/// fleet, and the version gate that stops the API reporting a security control
/// as applied when the agent behind it would ignore the field.
@Suite("VM Metadata Opt-Out Tests", .serialized)
final class VMMetadataOptOutTests {

    private func withVMTestApp(
        _ test: (Application, Project, String) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "mduser", email: "md@example.com", displayName: "Metadata User",
                isSystemAdmin: false)
            let org = try await builder.createOrganization(name: "Metadata Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            try await user.replacingCurrentOrganization(org.id).save(on: app.db)
            let project = try await builder.createProject(
                name: "Metadata Project", description: "Project for kill-switch tests",
                organization: org)
            let token = try await user.generateAPIKey(on: app)

            try await test(app, project, token)
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    /// Registers an agent at `protocolVersion` and returns its id, so a VM can
    /// be placed on a host of a chosen vintage.
    private func registerAgent(
        app: Application, named name: String, protocolVersion: Int
    ) async throws -> String {
        let message = AgentRegisterMessage(
            agentId: name,
            hostname: "host-\(name)",
            version: "1.0.0",
            resources: AgentResources(
                totalCPU: 16, availableCPU: 16,
                totalMemory: 1 << 34, availableMemory: 1 << 34,
                totalDisk: 1 << 40, availableDisk: 1 << 40),
            hypervisors: [
                HypervisorSupport(type: .qemu, available: true, accelerated: true, capabilities: .qemu)
            ],
            protocolVersion: protocolVersion
        )
        let orgID = try await Organization.all(on: app.db).first?.id
        let uuid = try await app.agentService.registerAgent(
            message, agentName: name, siteID: nil,
            organizationScope: orgID.map { .organization($0) })
        return uuid.uuidString
    }

    private func placeVM(
        app: Application, project: Project, named name: String, onAgent agentId: String?
    ) async throws -> VM {
        let vm = try await TestDataBuilder(db: app.db).createVM(name: name, project: project)
        vm.hypervisorId = agentId
        try await vm.save(on: app.db)
        return vm
    }

    private struct UpdateBody: Content {
        let metadataEnabled: Bool?
    }

    // MARK: - The default

    @Test("A VM is served metadata unless someone says otherwise")
    func defaultsToServed() async throws {
        try await withVMTestApp { app, project, _ in
            // The load-bearing default: STR-54's carve-out means IMDS
            // reachability does not depend on a VM's security groups, so a
            // column defaulting off would blackhole every guest's cloud-init
            // datasource the moment the migration landed.
            let vm = try await self.placeVM(app: app, project: project, named: "vm-default", onAgent: nil)
            #expect(vm.metadataEnabled)
            let reloaded = try await VM.find(vm.id, on: app.db)
            #expect(reloaded?.metadataEnabled == true)
        }
    }

    // MARK: - The switch

    @Test("The switch toggles on a placed VM, both ways, without bumping the generation")
    func togglesWithoutBumpingGeneration() async throws {
        try await withVMTestApp { app, project, token in
            let agentId = try await self.registerAgent(
                app: app, named: "current-agent", protocolVersion: WireProtocol.currentVersion)
            let vm = try await self.placeVM(
                app: app, project: project, named: "vm-toggle", onAgent: agentId)
            let vmID = try vm.requireID()
            let startGeneration = try #require(await VM.find(vmID, on: app.db)?.generation)

            try await app.test(.PUT, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateBody(metadataEnabled: false))
            } afterResponse: { res in
                // A metadata-only update: 200 with the VM, not 202 with a
                // mutation to poll. Nothing has to converge for the switch to
                // take effect beyond the next sync.
                #expect(res.status == .ok)
                let body = try res.content.decode(VMDetailResponse.self)
                #expect(body.metadataEnabled == false)
            }

            let off = try await VM.find(vmID, on: app.db)
            #expect(off?.metadataEnabled == false)
            // Deliberately no bump, like the network's switch: nothing about
            // how the VM is realized changes, both enforcement points are
            // level-triggered, and a bump would additionally stop the edit
            // reaching a VM whose convergence is already failing.
            #expect(off?.generation == startGeneration)

            try await app.test(.PUT, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(UpdateBody(metadataEnabled: true))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }
            let backOn = try await VM.find(vmID, on: app.db)
            #expect(backOn?.metadataEnabled == true)
            #expect(backOn?.generation == startGeneration)
        }
    }

    @Test("An update that omits the switch leaves it alone")
    func omittedSwitchIsNotAnInstruction() async throws {
        try await withVMTestApp { app, project, token in
            var vm = try await self.placeVM(
                app: app, project: project, named: "vm-omit", onAgent: nil)
            vm.metadataEnabled = false
            try await vm.save(on: app.db)
            let vmID = try vm.requireID()

            struct RenameBody: Content { let name: String }
            try await app.test(.PUT, "/api/vms/\(vmID)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(RenameBody(name: "vm-omit-renamed"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            // An absent key is silence, not "turn it back on" — otherwise every
            // unrelated edit would quietly undo an operator's hardening.
            let after = try await VM.find(vmID, on: app.db)
            #expect(after?.metadataEnabled == false)
            #expect(after?.name == "vm-omit-renamed")
        }
    }

}
