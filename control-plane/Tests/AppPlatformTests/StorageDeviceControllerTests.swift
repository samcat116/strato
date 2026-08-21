import ControlPlanePostgres
import Foundation
import StratoShared
import Testing

@testable import App

@Suite("Storage device controller")
struct StorageDeviceControllerTests {
    @Test("OSD eligibility blockers use a stable safety-first order")
    func eligibilityBlockerOrder() {
        let now = Date(timeIntervalSince1970: 1_000)
        let online = now.addingTimeInterval(-1)

        let anonymous = device(identityKind: nil, identityValue: nil, present: false, state: .faulted)
        #expect(eligibility(anonymous, heartbeat: online, now: now).blocker == .missingIdentity)

        let missing = device(present: false, state: .faulted)
        #expect(eligibility(missing, heartbeat: online, now: now).blocker == .notPresent)

        let inUse = device(state: .inUse)
        #expect(eligibility(inUse, heartbeat: online, now: now).blocker == .inUse)

        let draining = device(state: .draining)
        #expect(eligibility(draining, heartbeat: online, now: now).blocker == .draining)

        let faulted = device(state: .faulted)
        #expect(eligibility(faulted, heartbeat: online, now: now).blocker == .faulted)

        let offline = now.addingTimeInterval(-61)
        #expect(eligibility(device(), heartbeat: offline, now: now).blocker == .agentOffline)

        let stale = device(lastSeenAt: now.addingTimeInterval(-61))
        #expect(eligibility(stale, heartbeat: online, now: now).blocker == .staleObservation)
    }

    @Test("only a fresh available identified disk on an online agent can be selected")
    func safeDeviceIsEligible() {
        let now = Date(timeIntervalSince1970: 1_000)
        let result = eligibility(
            device(lastSeenAt: now.addingTimeInterval(-60)),
            heartbeat: now.addingTimeInterval(-1),
            now: now)

        #expect(result.canMarkOSDEligible)
        #expect(result.blocker == nil)
    }

    @Test("selected disks remain selected when later facts prevent new selection")
    func selectedUnsafeDeviceCanStillBeDisabled() {
        let now = Date(timeIntervalSince1970: 1_000)
        let selected = device(present: false, role: .osd)

        let result = eligibility(
            selected,
            heartbeat: now.addingTimeInterval(-100),
            now: now)

        #expect(result.osdEligible)
        #expect(result.canMarkOSDEligible == false)
        #expect(result.blocker == .notPresent)
    }

    private func device(
        identityKind: StorageDeviceIdentityKind? = .wwn,
        identityValue: String? = "5000cca1",
        present: Bool = true,
        state: StorageDeviceState = .available,
        role: StorageDeviceRole = .unassigned,
        lastSeenAt: Date = Date(timeIntervalSince1970: 950)
    ) -> StorageDeviceSnapshot {
        StorageDeviceSnapshot(
            id: UUID(),
            agentID: UUID(),
            identityKind: identityKind,
            identityValue: identityValue,
            devicePath: "/dev/sdb",
            sizeBytes: 100,
            rotational: false,
            uses: state == .inUse ? [.filesystem] : [],
            role: role,
            state: state,
            present: present,
            lastSeenAt: lastSeenAt)
    }

    private func eligibility(
        _ device: StorageDeviceSnapshot,
        heartbeat: Date?,
        now: Date
    ) -> ControlPlanePostgres.StorageDeviceEligibility {
        StorageDevicesPersistence.eligibility(
            for: device,
            agentLastHeartbeat: heartbeat,
            now: now
        )
    }
}
