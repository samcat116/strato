import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Sandbox Jail Tests")
struct SandboxJailTests {

    private let config = SandboxJailerConfig(
        jailerBinaryPath: "/usr/local/bin/jailer",
        chrootBaseDir: "/var/lib/strato/vms/jailer",
        uidBase: 100_000)

    private func plan(_ sandboxId: String = "0d9f8c6a-1b2c-4d3e-9f4a-5b6c7d8e9f0a") -> SandboxJailPlan {
        SandboxJailPlan(
            sandboxId: sandboxId, config: config,
            firecrackerBinaryPath: "/usr/local/bin/firecracker")
    }

    // MARK: - uid/gid derivation

    @Test("uid derivation is deterministic and inside the configured range")
    func uidDerivation() {
        let a = plan()
        let b = plan()

        // Stable across derivations (and hence agent restarts): create,
        // adoption, and teardown always agree.
        #expect(a.uid == b.uid)
        #expect(a.gid == a.uid)
        #expect(a.uid >= config.uidBase)
        #expect(a.uid < config.uidBase + SandboxJailerConfig.uidCount)
    }

    @Test("different sandboxes get their own uids")
    func uidsDifferPerSandbox() {
        let uids = Set((0..<32).map { plan("sandbox-\($0)").uid })
        // FNV-1a over 32 inputs into a 65536 slot range: collisions are
        // possible but all-collide is not; require substantial spread.
        #expect(uids.count > 16)
    }

    @Test("uid never lands on root even with a wrapping base")
    func uidNeverZero() {
        // A base near UInt32.max can wrap to exactly 0 for some hash slot;
        // scan for a wrapping input and confirm the guard kicks in.
        let hostile = SandboxJailerConfig(
            jailerBinaryPath: "/j", chrootBaseDir: "/c", uidBase: UInt32.max &- 100)
        for i in 0..<100_000 {
            let plan = SandboxJailPlan(
                sandboxId: "probe-\(i)", config: hostile, firecrackerBinaryPath: "/f")
            #expect(plan.uid != 0)
            if plan.uid == 1 { return }  // found (and passed) a wrap case
        }
    }

    // MARK: - Layout

    @Test("jail layout derives from the chroot base, exec file name, and sandbox id")
    func jailLayout() {
        let p = plan("abc-123")

        #expect(p.jailDirectory == "/var/lib/strato/vms/jailer/firecracker/abc-123")
        #expect(p.jailRoot == "/var/lib/strato/vms/jailer/firecracker/abc-123/root")
        #expect(
            p.hostPath(forInJail: SandboxJailPlan.rootfsPathInJail)
                == "/var/lib/strato/vms/jailer/firecracker/abc-123/root/rootfs.ext4")
        #expect(
            p.vsockUDSHostPath
                == "/var/lib/strato/vms/jailer/firecracker/abc-123/root/run/vsock.sock")
        #expect(p.netnsName == "strato-sbx-abc-123")
        #expect(p.netnsPath == "/var/run/netns/strato-sbx-abc-123")
    }

    @Test("the exec file basename keys the layout, not its directory")
    func execFileBasename() {
        let p = SandboxJailPlan(
            sandboxId: "abc", config: config, firecrackerBinaryPath: "/opt/fc/bin/firecracker-v1.13")
        #expect(p.jailDirectory == "/var/lib/strato/vms/jailer/firecracker-v1.13/abc")
    }

    // MARK: - Resource ceiling

    @Test("the jailer memory ceiling is guest memory plus the fixed VMM allowance")
    func memoryCeiling() {
        let guest: Int64 = 512 * 1024 * 1024
        #expect(SandboxJailPlan.memoryLimitBytes(guestMemoryBytes: guest) == guest + 128 * 1024 * 1024)
    }

    @Test("the memory ceiling requires the v2 memory controller, not just a v2 mount")
    func memoryCeilingDetection() {
        // Full controller set: ceiling available.
        #expect(
            SandboxJailPlan.hostSupportsMemoryCeiling(readFile: { path in
                path == "/sys/fs/cgroup/cgroup.controllers" ? "cpuset cpu io memory pids\n" : nil
            }))
        // v2 mounted but memory controller disabled (cgroup_disable=memory):
        // passing memory.max would make the jailer abort every create.
        #expect(
            SandboxJailPlan.hostSupportsMemoryCeiling(readFile: { _ in "cpuset cpu io pids\n" }) == false)
        // No v2 hierarchy at all (cgroup v1 host).
        #expect(SandboxJailPlan.hostSupportsMemoryCeiling(readFile: { _ in nil }) == false)
    }
}

@Suite("Sandbox Jailer Resolver Tests")
struct SandboxJailerResolverTests {

    private func resolve(
        mode: SandboxJailerMode, root: Bool, binary: Bool
    ) -> SandboxJailerResolver.Resolution {
        SandboxJailerResolver.resolve(
            mode: mode, jailerBinaryPath: "/usr/local/bin/jailer",
            isRoot: root, isExecutable: { _ in binary })
    }

    @Test("disabled never jails and never complains")
    func disabledMode() {
        #expect(resolve(mode: .disabled, root: true, binary: true) == .unjailed(reason: nil))
        #expect(resolve(mode: .disabled, root: false, binary: false) == .unjailed(reason: nil))
    }

    @Test("auto jails when the host can")
    func autoJailsWhenUsable() {
        #expect(resolve(mode: .auto, root: true, binary: true) == .jailed)
    }

    @Test("auto degrades to unjailed with a reason when the host can't")
    func autoDegradesWithReason() {
        for (root, binary) in [(false, true), (true, false), (false, false)] {
            guard case .unjailed(let reason) = resolve(mode: .auto, root: root, binary: binary) else {
                Issue.record("expected unjailed for root=\(root) binary=\(binary)")
                return
            }
            #expect(reason?.isEmpty == false)
        }
    }

    @Test("the resolved ip path is the first executable candidate")
    func ipBinaryResolution() {
        #expect(
            SandboxJailerResolver.resolveIPBinaryPath(isExecutable: { $0 == "/sbin/ip" }) == "/sbin/ip")
        #expect(SandboxJailerResolver.resolveIPBinaryPath(isExecutable: { _ in false }) == nil)
    }

    @Test("a host without iproute2 cannot jail — netns creation would fail every create")
    func missingIPRouteBlocksJailing() {
        // Everything but `ip` present: only the jailer binary path resolves.
        let onlyJailer: (String) -> Bool = { $0 == "/usr/local/bin/jailer" }

        guard
            case .unjailed(let reason) = SandboxJailerResolver.resolve(
                mode: .auto, jailerBinaryPath: "/usr/local/bin/jailer",
                isRoot: true, isExecutable: onlyJailer)
        else {
            Issue.record("expected unjailed without iproute2")
            return
        }
        #expect(reason?.contains("iproute2") == true)

        guard
            case .blocked(let blockedReason) = SandboxJailerResolver.resolve(
                mode: .required, jailerBinaryPath: "/usr/local/bin/jailer",
                isRoot: true, isExecutable: onlyJailer)
        else {
            Issue.record("expected blocked without iproute2 in required mode")
            return
        }
        #expect(blockedReason.contains("iproute2"))
    }

    @Test("required jails when the host can, blocks when it can't")
    func requiredBlocks() {
        #expect(resolve(mode: .required, root: true, binary: true) == .jailed)

        guard case .blocked(let reason) = resolve(mode: .required, root: false, binary: true) else {
            Issue.record("expected blocked without root")
            return
        }
        #expect(reason.contains("root"))

        guard case .blocked(let binaryReason) = resolve(mode: .required, root: true, binary: false) else {
            Issue.record("expected blocked without the jailer binary")
            return
        }
        #expect(binaryReason.contains("jailer binary"))
    }
}
