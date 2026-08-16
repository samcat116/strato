import Foundation
import StratoShared
import Testing

@testable import App

@Suite("Storage device controller")
struct StorageDeviceControllerTests {
    @Test("OSD eligibility blockers use a stable safety-first order")
    func eligibilityBlockerOrder() {
        let now = Date(timeIntervalSince1970: 1_000)
        let online = agent(lastHeartbeat: now.addingTimeInterval(-1))

        let anonymous = device(identityKind: nil, identityValue: nil, present: false, state: .faulted)
        #expect(StorageDeviceEligibility.evaluate(anonymous, agent: online, now: now).blockedReason == .missingIdentity)

        let missing = device(present: false, state: .faulted)
        #expect(StorageDeviceEligibility.evaluate(missing, agent: online, now: now).blockedReason == .notPresent)

        let inUse = device(state: .inUse)
        #expect(StorageDeviceEligibility.evaluate(inUse, agent: online, now: now).blockedReason == .inUse)

        let draining = device(state: .draining)
        #expect(StorageDeviceEligibility.evaluate(draining, agent: online, now: now).blockedReason == .draining)

        let faulted = device(state: .faulted)
        #expect(StorageDeviceEligibility.evaluate(faulted, agent: online, now: now).blockedReason == .faulted)

        let offline = agent(lastHeartbeat: now.addingTimeInterval(-61))
        #expect(StorageDeviceEligibility.evaluate(device(), agent: offline, now: now).blockedReason == .agentOffline)

        let stale = device(lastSeenAt: now.addingTimeInterval(-61))
        #expect(StorageDeviceEligibility.evaluate(stale, agent: online, now: now).blockedReason == .staleObservation)
    }

    @Test("only a fresh available identified disk on an online agent can be selected")
    func safeDeviceIsEligible() {
        let now = Date(timeIntervalSince1970: 1_000)
        let result = StorageDeviceEligibility.evaluate(
            device(lastSeenAt: now.addingTimeInterval(-60)),
            agent: agent(lastHeartbeat: now.addingTimeInterval(-1)),
            now: now)

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
            now: now)

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
            status: .online,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 16_000, availableMemory: 16_000,
                totalDisk: 100_000, availableDisk: 100_000),
            lastHeartbeat: lastHeartbeat)
    }
}
