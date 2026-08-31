import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Sandbox Jail Tests")
struct SandboxJailTests {

    private func config(uidBase: UInt32 = 100_000) throws -> SandboxJailerConfig {
        try SandboxJailerConfig(
            jailerBinaryPath: "/usr/local/bin/jailer",
            chrootBaseDir: "/var/lib/strato/vms/jailer",
            uidBase: uidBase)
    }

    private func plan(
        _ sandboxId: String = "0d9f8c6a-1b2c-4d3e-9f4a-5b6c7d8e9f0a",
        jailUID: UInt32 = 120_000
    ) throws -> SandboxJailPlan {
        try SandboxJailPlan(
            sandboxId: sandboxId, jailUID: jailUID, config: config(),
            firecrackerBinaryPath: "/usr/local/bin/firecracker")
    }

    // MARK: - uid/gid allocation

    @Test("the plan carries its explicitly allocated uid and matching gid")
    func explicitIdentity() throws {
        let p = try plan(jailUID: 123_456)

        #expect(p.uid == 123_456)
        #expect(p.gid == 123_456)
    }

    @Test("the allocator supplies an exactly distinct identity to every plan")
    func allocatedUIDsAreDistinct() throws {
        var allocator = SandboxJailUIDAllocator(uidBase: 100_000)
        let plans = try (0..<32).map { index in
            let sandboxId = "sandbox-\(index)"
            return try plan(sandboxId, jailUID: allocator.allocate(for: sandboxId))
        }

        #expect(Set(plans.map(\.uid)).count == plans.count)
        #expect(plans.allSatisfy { $0.gid == $0.uid })
    }

    @Test("legacy hash adoption preserves the historical assignment")
    func legacyUIDGoldenValue() throws {
        #expect(
            try SandboxJailPlan.legacyUID(
                sandboxId: "0d9f8c6a-1b2c-4d3e-9f4a-5b6c7d8e9f0a",
                uidBase: 100_000) == 149_626)
    }

    @Test("legacy adoption preserves the old wrapping-zero guard")
    func legacyUIDWrappingCompatibility() {
        let hostileBase = UInt32.max &- 100
        let adopted = (0..<100_000).compactMap { index in
            try? SandboxJailPlan.legacyUID(
                sandboxId: "probe-\(index)", uidBase: hostileBase)
        }

        #expect(adopted.contains(1))
        #expect(!adopted.contains(0))
        #expect(!adopted.contains(UInt32.max))
    }

    @Test("uid ranges reject system-space and wrapping bases")
    func uidRangeValidation() throws {
        let invalidBases: [UInt32] = [
            0,
            SandboxJailerConfig.minimumUIDBase - 1,
            SandboxJailerConfig.maximumUIDBase + 1,
            UInt32.max,
        ]
        for base in invalidBases {
            #expect(throws: SandboxJailerConfigError.invalidUIDBase(base)) {
                _ = try config(uidBase: base)
            }
        }

        #expect(
            try config(uidBase: SandboxJailerConfig.minimumUIDBase).uidBase
                == SandboxJailerConfig.minimumUIDBase)
        #expect(
            try config(uidBase: SandboxJailerConfig.maximumUIDBase).uidBase
                == SandboxJailerConfig.maximumUIDBase)
    }

    @Test("a plan cannot run Firecracker as root or uid_t(-1)")
    func rootIdentityIsRejected() throws {
        #expect(throws: SandboxJailPlanError.rootIdentity) {
            _ = try plan(jailUID: 0)
        }
        #expect(throws: SandboxJailPlanError.rootIdentity) {
            _ = try plan(jailUID: UInt32.max)
        }
    }

    // MARK: - Layout

    @Test("jail layout derives from the chroot base, exec file name, and sandbox id")
    func jailLayout() throws {
        let p = try plan("abc-123")

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

    @Test("the NIC placement carries the jail's namespace and uid (issue STR-100)")
    func nicPlacementDerivation() throws {
        // The attachment path needs exactly these three facts, and each must
        // match what the jailer itself is given — the TAP is created in that
        // namespace and chowned to that uid, and Firecracker opens it after the
        // jailer has setuid'd.
        let p = try plan("abc-123")
        let placement = NICPlacement.sandboxNetns(
            netnsName: p.netnsName, owner: JailOwner(uid: p.uid, gid: p.gid))
        #expect(placement.netnsName == "strato-sbx-abc-123")
        #expect(NICPlacement.hostNamespace.netnsName == nil)

        guard case .sandboxNetns(_, let owner) = placement else {
            Issue.record("expected a sandbox placement")
            return
        }
        #expect(owner?.uid == p.uid)
        #expect(owner?.gid == p.gid)
        #expect(owner?.uid != 0)
    }

    @Test("the namespace name is derivable from the sandbox id alone")
    func netnsNameNeedsNoConfig() throws {
        // Teardown runs on agents whose jailer config is gone (the sandbox
        // runtime was deconfigured since the sandbox was created). If the
        // namespace name needed the config, that cleanup would have to fall
        // back to the VM path and would leak the port, veth, and namespace.
        let p = try plan("abc-123")
        #expect(SandboxJailPlan.netnsName(sandboxId: "abc-123") == "strato-sbx-abc-123")
        #expect(SandboxJailPlan.netnsName(sandboxId: "abc-123") == p.netnsName)

        // And a teardown placement is expressible with no ownership at all.
        let teardown = NICPlacement.sandboxNetns(
            netnsName: SandboxJailPlan.netnsName(sandboxId: "abc-123"), owner: nil)
        #expect(teardown.netnsName == "strato-sbx-abc-123")
        #expect(teardown != NICPlacement.hostNamespace)
    }

    /// The crash sweep for warm templates reads `/var/run/netns` back into ids
    /// (STR-104): a NIC-shaped template's namespace is the first artifact its
    /// build creates, before the jail root or storage directory the rest of
    /// the sweep scans, so a crash in that window leaves nothing else to find
    /// it by.
    @Test("a namespace name maps back to the id it was derived from")
    func netnsNameRoundTrips() {
        for id in ["abc-123", "warm-template-0f9c", UUID().uuidString] {
            let name = SandboxJailPlan.netnsName(sandboxId: id)
            #expect(SandboxJailPlan.sandboxId(fromNetnsName: name) == id)
        }

        // Namespaces that are not ours are left entirely alone — the sweep
        // deletes what this returns.
        #expect(SandboxJailPlan.sandboxId(fromNetnsName: "ovnmeta-1234") == nil)
        #expect(SandboxJailPlan.sandboxId(fromNetnsName: "strato-sbx-") == nil)
        #expect(SandboxJailPlan.sandboxId(fromNetnsName: "") == nil)
        #expect(SandboxJailPlan.sandboxId(fromNetnsName: "sbx-abc") == nil)
    }

    @Test("the exec file basename keys the layout, not its directory")
    func execFileBasename() throws {
        let p = try SandboxJailPlan(
            sandboxId: "abc", jailUID: 120_000, config: config(),
            firecrackerBinaryPath: "/opt/fc/bin/firecracker-v1.13")
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

    @Test("the resolved tc path is the first executable candidate")
    func tcBinaryResolution() {
        #expect(
            SandboxJailerResolver.resolveTCBinaryPath(isExecutable: { $0 == "/sbin/tc" }) == "/sbin/tc")
        #expect(SandboxJailerResolver.resolveTCBinaryPath(isExecutable: { _ in false }) == nil)
    }

    @Test("a host without tc still jails — only networked sandboxes need it")
    func missingTCDoesNotBlockJailing() {
        // `tc` installs the redirects splicing a jailed VMM's TAP to its veth
        // (issue STR-100). Losing that must cost NICs, not the whole barrier.
        let noTC: (String) -> Bool = {
            $0 != "/usr/sbin/tc" && $0 != "/sbin/tc" && $0 != "/usr/bin/tc" && $0 != "/bin/tc"
        }
        #expect(
            SandboxJailerResolver.resolve(
                mode: .required, jailerBinaryPath: "/usr/local/bin/jailer",
                isRoot: true, isExecutable: noTC) == .jailed)
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
