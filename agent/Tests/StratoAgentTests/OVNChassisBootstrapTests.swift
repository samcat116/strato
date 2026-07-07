import Foundation
import Testing

@testable import StratoAgentCore

@Suite("OVN Chassis Bootstrap Tests")
struct OVNChassisBootstrapTests {

    // MARK: - external_ids parsing

    @Test("Parses ovs-vsctl external_ids output with bare and quoted values")
    func parseExternalIDs() {
        let raw = """
            {hostname=strato-dev, ovn-remote="unix:/var/run/ovn/ovnsb_db.sock", rundir="/var/run/openvswitch", system-id="4b0e...abc"}
            """
        let parsed = OVNChassisBootstrap.parseExternalIDs(raw)
        #expect(parsed["hostname"] == "strato-dev")
        #expect(parsed["ovn-remote"] == "unix:/var/run/ovn/ovnsb_db.sock")
        #expect(parsed["rundir"] == "/var/run/openvswitch")
        #expect(parsed["system-id"] == "4b0e...abc")
    }

    @Test("Parses empty and malformed external_ids maps")
    func parseExternalIDsEdgeCases() {
        #expect(OVNChassisBootstrap.parseExternalIDs("{}").isEmpty)
        #expect(OVNChassisBootstrap.parseExternalIDs("").isEmpty)
        #expect(OVNChassisBootstrap.parseExternalIDs("ovs-vsctl: no row found").isEmpty)
    }

    @Test("Quoted values may contain commas, spaces, and escapes")
    func parseExternalIDsQuoting() {
        let raw = #"{note="a, b \"c\"", plain=x}"#
        let parsed = OVNChassisBootstrap.parseExternalIDs(raw)
        #expect(parsed["note"] == #"a, b "c""#)
        #expect(parsed["plain"] == "x")
    }

    // MARK: - route source IP parsing

    @Test("Extracts the preferred source IP from ip -j route get output")
    func parseRouteSourceIP() {
        let json = """
            [{"dst":"1.1.1.1","gateway":"192.168.1.1","dev":"eth0","prefsrc":"192.168.1.10","flags":[],\
            "uid":0,"cache":[]}]
            """
        #expect(OVNChassisBootstrap.parseRouteSourceIP(json) == "192.168.1.10")
    }

    @Test("Route parse returns nil for missing prefsrc or invalid JSON")
    func parseRouteSourceIPEdgeCases() {
        #expect(OVNChassisBootstrap.parseRouteSourceIP("[]") == nil)
        #expect(OVNChassisBootstrap.parseRouteSourceIP(#"[{"dst":"1.1.1.1","dev":"eth0"}]"#) == nil)
        #expect(OVNChassisBootstrap.parseRouteSourceIP("not json") == nil)
    }

    // MARK: - plan

    private let freshHost = ["hostname": "node1", "rundir": "/var/run/openvswitch", "system-id": "host-uuid"]

    @Test("Fresh host with no OVN external_ids gets defaults plus the detected encap IP")
    func planFreshHost() {
        let plan = OVNChassisBootstrap.plan(
            config: OVNChassisConfig(),
            existing: freshHost,
            detectedEncapIP: "10.1.2.3",
            generatedSystemID: "gen-uuid")

        #expect(
            plan.settings == [
                OVNChassisBootstrap.Setting(key: "ovn-remote", value: OVNChassisBootstrap.defaultRemote),
                OVNChassisBootstrap.Setting(key: "ovn-encap-type", value: "geneve"),
                OVNChassisBootstrap.Setting(key: "ovn-encap-ip", value: "10.1.2.3"),
            ])
        #expect(!plan.encapIPUnresolved)
    }

    @Test("A fully configured chassis is left untouched")
    func planConfiguredHostIsNoop() {
        var existing = freshHost
        existing["ovn-remote"] = "tcp:10.0.0.1:6642"
        existing["ovn-encap-type"] = "geneve"
        existing["ovn-encap-ip"] = "10.0.0.5"

        let plan = OVNChassisBootstrap.plan(
            config: OVNChassisConfig(),
            existing: existing,
            detectedEncapIP: "192.168.9.9",
            generatedSystemID: "gen-uuid")

        #expect(plan.settings.isEmpty)
        #expect(!plan.encapIPUnresolved)
    }

    @Test("Explicit agent config overrides drifted host values")
    func planExplicitConfigWins() {
        var existing = freshHost
        existing["ovn-remote"] = "unix:/var/run/ovn/ovnsb_db.sock"
        existing["ovn-encap-type"] = "geneve"
        existing["ovn-encap-ip"] = "127.0.0.1"

        let plan = OVNChassisBootstrap.plan(
            config: OVNChassisConfig(encapIP: "10.0.0.5", remote: "tcp:central:6642"),
            existing: existing,
            detectedEncapIP: nil,
            generatedSystemID: "gen-uuid")

        #expect(
            plan.settings == [
                OVNChassisBootstrap.Setting(key: "ovn-remote", value: "tcp:central:6642"),
                OVNChassisBootstrap.Setting(key: "ovn-encap-ip", value: "10.0.0.5"),
            ])
    }

    @Test("Explicit config matching the host produces no writes")
    func planExplicitConfigAlreadyApplied() {
        var existing = freshHost
        existing["ovn-remote"] = "tcp:central:6642"
        existing["ovn-encap-type"] = "vxlan"
        existing["ovn-encap-ip"] = "10.0.0.5"

        let plan = OVNChassisBootstrap.plan(
            config: OVNChassisConfig(encapIP: "10.0.0.5", encapType: "vxlan", remote: "tcp:central:6642"),
            existing: existing,
            detectedEncapIP: nil,
            generatedSystemID: "gen-uuid")

        #expect(plan.settings.isEmpty)
    }

    @Test("Missing system-id is replaced with the generated one")
    func planGeneratesSystemID() {
        let plan = OVNChassisBootstrap.plan(
            config: OVNChassisConfig(),
            existing: ["hostname": "node1"],
            detectedEncapIP: "10.1.2.3",
            generatedSystemID: "gen-uuid")

        #expect(plan.settings.first == OVNChassisBootstrap.Setting(key: "system-id", value: "gen-uuid"))
    }

    @Test("Unset and undetectable encap IP is flagged unresolved, not defaulted")
    func planUnresolvedEncapIP() {
        let plan = OVNChassisBootstrap.plan(
            config: OVNChassisConfig(),
            existing: freshHost,
            detectedEncapIP: nil,
            generatedSystemID: "gen-uuid")

        #expect(plan.encapIPUnresolved)
        #expect(!plan.settings.contains { $0.key == "ovn-encap-ip" })
        // The other keys are still planned; only the encap IP is blocked.
        #expect(plan.settings.contains { $0.key == "ovn-remote" })
    }

    @Test("Settings render as ovs-vsctl set arguments")
    func settingVsctlArgument() {
        let setting = OVNChassisBootstrap.Setting(key: "ovn-remote", value: "unix:/var/run/ovn/ovnsb_db.sock")
        #expect(setting.vsctlArgument == "external_ids:ovn-remote=unix:/var/run/ovn/ovnsb_db.sock")
    }
}
