import Testing

@testable import StratoAgentCore

@Suite("Gateway Chassis Plan")
struct GatewayChassisPlanTests {

    @Test("no existing bindings creates one for the local chassis")
    func createsWhenEmpty() {
        let actions = GatewayChassisPlan.plan(localChassis: "chassis-a", existing: [])
        #expect(actions == GatewayChassisPlan.Actions(deleteUUIDs: [], createForLocalChassis: true))
    }

    @Test("a managed binding to the local chassis is a no-op")
    func managedLocalIsSatisfied() {
        let actions = GatewayChassisPlan.plan(
            localChassis: "chassis-a",
            existing: [GatewayChassisBinding(uuid: "u1", chassisName: "chassis-a", managed: true)])
        #expect(actions == GatewayChassisPlan.Actions(deleteUUIDs: [], createForLocalChassis: false))
    }

    @Test("an operator's manual workaround binding is honored, not duplicated")
    func unmanagedLocalIsSatisfied() {
        // The documented workaround was `ovn-nbctl lrp-set-gateway-chassis`,
        // which leaves an unmanaged row naming this chassis.
        let actions = GatewayChassisPlan.plan(
            localChassis: "chassis-a",
            existing: [GatewayChassisBinding(uuid: "u1", chassisName: "chassis-a", managed: false)])
        #expect(actions == GatewayChassisPlan.Actions(deleteUUIDs: [], createForLocalChassis: false))
    }

    @Test("a stale managed binding to another chassis is replaced")
    func staleManagedIsReplaced() {
        let actions = GatewayChassisPlan.plan(
            localChassis: "chassis-a",
            existing: [GatewayChassisBinding(uuid: "u1", chassisName: "chassis-old", managed: true)])
        #expect(actions == GatewayChassisPlan.Actions(deleteUUIDs: ["u1"], createForLocalChassis: true))
    }

    @Test("unmanaged bindings to other chassis are operator config and kept")
    func unmanagedForeignIsKept() {
        let actions = GatewayChassisPlan.plan(
            localChassis: "chassis-a",
            existing: [GatewayChassisBinding(uuid: "u1", chassisName: "chassis-b", managed: false)])
        #expect(actions == GatewayChassisPlan.Actions(deleteUUIDs: [], createForLocalChassis: true))
    }

    @Test("mixed set deletes only the stale managed row")
    func mixedSet() {
        let actions = GatewayChassisPlan.plan(
            localChassis: "chassis-a",
            existing: [
                GatewayChassisBinding(uuid: "u1", chassisName: "chassis-old", managed: true),
                GatewayChassisBinding(uuid: "u2", chassisName: "chassis-b", managed: false),
                GatewayChassisBinding(uuid: "u3", chassisName: "chassis-a", managed: false),
            ])
        #expect(actions == GatewayChassisPlan.Actions(deleteUUIDs: ["u1"], createForLocalChassis: false))
    }

    @Test("gateway chassis row name matches ovn-nbctl's <port>-<chassis> convention")
    func rowNaming() {
        let name = OVNNaming.gatewayChassisName(portName: "lrp-ext-abc", chassis: "4b0e-sys")
        #expect(name == "lrp-ext-abc-4b0e-sys")
    }
}
