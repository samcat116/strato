import Foundation
import Testing
@testable import App

@Suite("VM network-interface lifecycle migration")
struct VMNetworkInterfaceLifecycleMigrationTests {
    @Test("duplicate and swapped legacy slots normalize without name collisions")
    func normalizesLegacySlots() {
        let vmID = UUID()
        let first = UUID()
        let second = UUID()
        let third = UUID()
        let rows = [
            AddVMNetworkInterfaceLifecycle.Row(
                id: first, vmID: vmID, orderIndex: 0, deviceName: "net1"),
            AddVMNetworkInterfaceLifecycle.Row(
                id: second, vmID: vmID, orderIndex: 0, deviceName: "net2"),
            AddVMNetworkInterfaceLifecycle.Row(
                id: third, vmID: vmID, orderIndex: 1, deviceName: "net0"),
        ]

        let repairs = Dictionary(
            uniqueKeysWithValues: AddVMNetworkInterfaceLifecycle.repairs(for: rows)
                .map { ($0.id, ($0.orderIndex, $0.deviceName)) })
        #expect(repairs[first]?.0 == 0)
        #expect(repairs[first]?.1 == "net0")
        #expect(repairs[second]?.0 == 1)
        #expect(repairs[second]?.1 == "net1")
        #expect(repairs[third]?.0 == 2)
        #expect(repairs[third]?.1 == "net2")
    }
}
