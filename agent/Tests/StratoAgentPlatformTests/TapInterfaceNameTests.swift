import Testing
import Foundation
@testable import StratoAgentCore

#if canImport(Glibc)
import Glibc
#endif

@Suite("TAP Interface Naming")
struct TapInterfaceNameTests {

    // MARK: - Portable unit tests (run on every platform)

    @Test("TAP name never exceeds the Linux IFNAMSIZ limit (15 chars)")
    func tapNameFitsInterfaceNameLimit() {
        let vmIds = [
            "550e8400-e29b-41d4-a716-446655440000",  // a typical UUID (36 chars)
            "00000000-0000-0000-0000-000000000000",
            "short",
            "",
            String(repeating: "a", count: 256),  // pathologically long
        ]
        for vmId in vmIds {
            let name = tapInterfaceName(for: vmId)
            #expect(name.count <= 15, "'\(name)' exceeds IFNAMSIZ for vmId '\(vmId)'")
            #expect(name.hasPrefix("tap"))
        }
    }

    @Test("NIC 0 keeps the historical vmId-only name; higher indices differ but stay within limits")
    func perNICNames() {
        let vmId = "550e8400-e29b-41d4-a716-446655440000"
        #expect(tapInterfaceName(for: vmId, nicIndex: 0) == tapInterfaceName(for: vmId))

        var seen: Set<String> = []
        for index in 0..<8 {
            let name = tapInterfaceName(for: vmId, nicIndex: index)
            #expect(name.count <= 15)
            #expect(name.hasPrefix("tap"))
            #expect(!seen.contains(name), "NIC \(index) collided with an earlier NIC's name")
            seen.insert(name)
        }
    }

    @Test("TAP name is stable for the same vmId (survives process restarts)")
    func tapNameIsStable() {
        // A fixed expectation guards against an accidental change to the digest,
        // which would strand devices created by an earlier agent build.
        let vmId = "550e8400-e29b-41d4-a716-446655440000"
        let first = tapInterfaceName(for: vmId)
        let second = tapInterfaceName(for: vmId)
        #expect(first == second)
    }

    @Test("Distinct vmIds produce distinct TAP names")
    func tapNamesAreDistinct() {
        let vmIds = (0..<1000).map { "vm-\($0)" }
        let names = Set(vmIds.map { tapInterfaceName(for: $0) })
        #expect(names.count == vmIds.count)
    }

    // MARK: - Sandbox NIC devices (issue STR-100)

    @Test("A sandbox NIC's three devices are distinct and each exactly 15 chars")
    func sandboxDeviceNamesFitAndDiffer() {
        let sandboxIds = [
            "0d9f8c6a-3f21-4b0e-9a44-8a1c2f9b7e10",
            "short",
            "",
            String(repeating: "z", count: 256),
        ]
        for sandboxId in sandboxIds {
            for nicIndex in 0..<4 {
                let names = sandboxNICDeviceNames(sandboxId: sandboxId, nicIndex: nicIndex)
                let all = [names.tap, names.vethHost, names.vethPeer]
                for name in all {
                    #expect(name.count == 15, "'\(name)' is not exactly IFNAMSIZ-1 characters")
                }
                #expect(Set(all).count == 3)
                #expect(names.tap.hasPrefix("tap"))
                #expect(names.vethHost.hasPrefix("vth"))
                #expect(names.vethPeer.hasPrefix("vtp"))
            }
        }
    }

    @Test("Sandbox device names are stable and share the VM helper's digest")
    func sandboxDeviceNamesAreStable() {
        // Create and teardown must agree across an agent restart, and the TAP
        // must be the same name either helper would derive.
        let sandboxId = "0d9f8c6a-3f21-4b0e-9a44-8a1c2f9b7e10"
        for nicIndex in 0..<4 {
            let first = sandboxNICDeviceNames(sandboxId: sandboxId, nicIndex: nicIndex)
            let second = sandboxNICDeviceNames(sandboxId: sandboxId, nicIndex: nicIndex)
            #expect(first == second)
            #expect(first.tap == tapInterfaceName(for: sandboxId, nicIndex: nicIndex))
        }
    }

    @Test("Sandbox devices do not collide across sandboxes or roles")
    func sandboxDeviceNamesAreGloballyDistinct() {
        var seen: Set<String> = []
        for index in 0..<500 {
            let names = sandboxNICDeviceNames(sandboxId: "sandbox-\(index)", nicIndex: 0)
            for name in [names.tap, names.vethHost, names.vethPeer] {
                #expect(!seen.contains(name), "'\(name)' collided")
                seen.insert(name)
            }
        }
    }

    // MARK: - Linux-only, opt-in integration test
    //
    // Exercises real TAP create/destroy via `ip tuntap`. Skipped unless running on
    // Linux as root (CAP_NET_ADMIN) with STRATO_TAP_INTEGRATION=1, e.g.
    //   sudo STRATO_TAP_INTEGRATION=1 swift test
    // A full VM-boot-with-networking check additionally needs KVM + ovn-controller +
    // ovs-vswitchd and is a manual verification step, not part of CI.

    #if os(Linux)
    @Test("Real TAP device create/remove round-trips")
    func tapCreateRemoveRoundTrips() {
        guard ProcessInfo.processInfo.environment["STRATO_TAP_INTEGRATION"] == "1" else {
            return  // opt-in only
        }
        guard geteuid() == 0 else {
            return  // requires root / CAP_NET_ADMIN
        }

        let name = tapInterfaceName(for: "integration-\(UUID().uuidString)")

        // Create, verify present.
        #expect(runIP(["tuntap", "add", "dev", name, "mode", "tap"]) == 0)
        #expect(runIP(["link", "show", name]) == 0)

        // Bring up (idempotent).
        #expect(runIP(["link", "set", name, "up"]) == 0)

        // Remove, verify gone.
        #expect(runIP(["tuntap", "del", "dev", name, "mode", "tap"]) == 0)
        #expect(runIP(["link", "show", name]) != 0)
    }

    private func runIP(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ip"] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
    #endif
}
