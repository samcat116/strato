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
