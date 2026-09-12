import AppTestSupport
import Fluent
import Foundation
import StratoShared
import Testing
import Vapor
import VaporTesting

@testable import App

@Suite("Storage device controller")
struct StorageDeviceControllerTests {
    @Test("agent usage observations insert, update, and list through the API")
    func reportedUsesRoundTripThroughAPI() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let admin = try await builder.createUser(
                username: "storage-reader",
                email: "storage-reader@example.com",
                displayName: "Storage Reader",
                isSystemAdmin: true)
            let token = try await admin.generateAPIKey(on: app.db)
            let organization = try await builder.createOrganization(name: "Storage Inventory Org")
            let organizationID = try organization.requireID()
            let site = Site(
                name: "Storage Inventory Site",
                organizationScope: .organization(organizationID))
            try await site.save(on: app.db)
            let agent = Agent(
                name: "storage-inventory-agent",
                hostname: "storage-inventory-agent.example",
                version: "1.0.0",
                siteID: try site.requireID(),
                status: .online,
                resources: AgentResources(
                    totalCPU: 8,
                    availableCPU: 8,
                    totalMemory: 16_000,
                    availableMemory: 16_000,
                    totalDisk: 100_000,
                    availableDisk: 100_000),
                lastHeartbeat: Date())
            agent.organizationScope = .organization(organizationID)
            try await agent.save(on: app.db)

            let identity = StorageDeviceIdentity(kind: .wwn, value: "5000cca1")
            let reconciler = StorageDeviceInventoryReconciler(database: app.db)
            try await reconciler.apply(
                [
                    ObservedStorageDevice(
                        identity: identity,
                        devicePath: "/dev/sdb",
                        sizeBytes: 1_000_000,
                        wwn: "5000cca1",
                        rotational: false,
                        state: .inUse,
                        uses: [.partitionTable])
                ],
                for: agent,
                receivedAt: Date())
            try await reconciler.apply(
                [
                    ObservedStorageDevice(
                        identity: identity,
                        devicePath: "/dev/sdb",
                        sizeBytes: 1_000_000,
                        wwn: "5000cca1",
                        rotational: false,
                        state: .inUse,
                        uses: [.filesystem, .mounted])
                ],
                for: agent,
                receivedAt: Date())

            try await app.test(
                .GET,
                "/api/storage-devices?agent_id=\(try agent.requireID())"
            ) { request in
                request.headers.bearerAuthorization = BearerAuthorization(token: token)
            } afterResponse: { response in
                #expect(response.status == .ok)
                let page = try response.content.decode(
                    PagedResponse<StorageDeviceResponse>.self)
                let item = try #require(page.items.first)
                #expect(page.total == 1)
                #expect(item.uses == [.filesystem, .mounted])
            }
        }
    }

    @Test("OSD eligibility blockers use a stable safety-first order")
    func eligibilityBlockerOrder() {
        let now = Date(timeIntervalSince1970: 1_000)
        let online = agent(lastHeartbeat: now.addingTimeInterval(-1))

        let anonymous = device(identityKind: nil, identityValue: nil, present: false, state: .faulted)
        #expect(
            StorageDeviceEligibility.evaluate(anonymous, agent: online, at: .testing(now))
                .blockedReason == .missingIdentity)

        let missing = device(present: false, state: .faulted)
        #expect(
            StorageDeviceEligibility.evaluate(missing, agent: online, at: .testing(now))
                .blockedReason == .notPresent)

        let inUse = device(state: .inUse)
        #expect(
            StorageDeviceEligibility.evaluate(inUse, agent: online, at: .testing(now))
                .blockedReason == .inUse)

        let draining = device(state: .draining)
        #expect(
            StorageDeviceEligibility.evaluate(draining, agent: online, at: .testing(now))
                .blockedReason == .draining)

        let faulted = device(state: .faulted)
        #expect(
            StorageDeviceEligibility.evaluate(faulted, agent: online, at: .testing(now))
                .blockedReason == .faulted)

        let offline = agent(lastHeartbeat: now.addingTimeInterval(-61))
        #expect(
            StorageDeviceEligibility.evaluate(device(), agent: offline, at: .testing(now))
                .blockedReason == .agentOffline)

        let stale = device(lastSeenAt: now.addingTimeInterval(-61))
        #expect(
            StorageDeviceEligibility.evaluate(stale, agent: online, at: .testing(now))
                .blockedReason == .staleObservation)
    }

    @Test("only a fresh available identified disk on an online agent can be selected")
    func safeDeviceIsEligible() {
        let now = Date(timeIntervalSince1970: 1_000)
        let result = StorageDeviceEligibility.evaluate(
            device(lastSeenAt: now.addingTimeInterval(-60)),
            agent: agent(lastHeartbeat: now.addingTimeInterval(-1)),
            at: .testing(now))

        #expect(result.canMarkOsdEligible)
        #expect(result.blockedReason == nil)
    }

    @Test("selected disks remain selected when later facts prevent new selection")
    func selectedUnsafeDeviceCanStillBeDisabled() {
        let now = Date(timeIntervalSince1970: 1_000)
        let selected = device(present: false)
        selected.role = .osd

        let result = StorageDeviceEligibility.evaluate(
            selected,
            agent: agent(lastHeartbeat: now.addingTimeInterval(-100)),
            at: .testing(now))

        #expect(result.osdEligible)
        #expect(result.canMarkOsdEligible == false)
        #expect(result.blockedReason == .notPresent)
    }

    private func device(
        identityKind: StorageDeviceIdentityKind? = .wwn,
        identityValue: String? = "5000cca1",
        present: Bool = true,
        state: StorageDeviceState = .available,
        lastSeenAt: Date = Date(timeIntervalSince1970: 950)
    ) -> StorageDevice {
        StorageDevice(
            agentID: UUID(),
            identityKind: identityKind,
            identityValue: identityValue,
            devicePath: "/dev/sdb",
            sizeBytes: 100,
            rotational: false,
            uses: state == .inUse ? [.filesystem] : [],
            state: state,
            present: present,
            lastSeenAt: lastSeenAt)
    }

    private func agent(lastHeartbeat: Date) -> Agent {
        Agent(
            id: UUID(),
            name: "agent",
            hostname: "agent.example",
            version: "1.0.0",
            siteID: UUID(),
            status: .online,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000, availableMemory: 16_000,
                totalDisk: 100_000, availableDisk: 100_000),
            lastHeartbeat: lastHeartbeat)
    }
}
