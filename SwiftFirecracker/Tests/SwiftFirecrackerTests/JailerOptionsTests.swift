import Foundation
import Testing

@testable import SwiftFirecracker

@Suite("JailerOptions")
struct JailerOptionsTests {

    private let options = JailerOptions(
        jailerBinaryPath: "/usr/local/bin/jailer",
        chrootBaseDir: "/var/lib/strato/vms/jailer",
        uid: 123_456,
        gid: 123_456)

    @Test("jail layout derives from the base dir, exec file basename, and VM id")
    func layoutDerivation() {
        let base = "/var/lib/strato/vms/jailer"
        let fc = "/usr/local/bin/firecracker"

        #expect(
            JailerOptions.jailDirectory(chrootBaseDir: base, firecrackerBinaryPath: fc, vmId: "abc")
                == "/var/lib/strato/vms/jailer/firecracker/abc")
        #expect(
            JailerOptions.jailRoot(chrootBaseDir: base, firecrackerBinaryPath: fc, vmId: "abc")
                == "/var/lib/strato/vms/jailer/firecracker/abc/root")
        #expect(
            JailerOptions.socketPath(chrootBaseDir: base, firecrackerBinaryPath: fc, vmId: "abc")
                == "/var/lib/strato/vms/jailer/firecracker/abc/root/run/firecracker.socket")
    }

    @Test("minimal argv: barrier flags, then the pass-through section without --id")
    func minimalArguments() {
        let args = options.arguments(vmId: "vm-1", firecrackerBinaryPath: "/usr/local/bin/firecracker")

        #expect(
            args == [
                "--id", "vm-1",
                "--exec-file", "/usr/local/bin/firecracker",
                "--uid", "123456",
                "--gid", "123456",
                "--chroot-base-dir", "/var/lib/strato/vms/jailer",
                "--",
                "--api-sock", "/run/firecracker.socket",
                "--level", "Info",
            ])
        // The jailer appends `--id` to the Firecracker arguments itself; the
        // pass-through section repeating it would be an error.
        let passThrough = args.drop(while: { $0 != "--" }).dropFirst()
        #expect(!passThrough.contains("--id"))
    }

    @Test("netns and cgroup flags are emitted before the pass-through section")
    func netnsAndCgroupArguments() {
        var full = options
        full.netnsPath = "/var/run/netns/strato-sbx-vm-1"
        full.cgroupVersion = 2
        full.cgroups = ["memory.max=1207959552"]

        let args = full.arguments(vmId: "vm-1", firecrackerBinaryPath: "/usr/local/bin/firecracker")
        let barrier = Array(args.prefix(while: { $0 != "--" }))

        #expect(barrier.contains("--netns"))
        #expect(barrier.contains("/var/run/netns/strato-sbx-vm-1"))
        #expect(barrier.contains("--cgroup-version"))
        #expect(barrier.contains("2"))
        #expect(barrier.contains("--cgroup"))
        #expect(barrier.contains("memory.max=1207959552"))
    }

    @Test("cgroup-version is omitted when there are no cgroup limits")
    func cgroupVersionOnlyWithLimits() {
        var versionOnly = options
        versionOnly.cgroupVersion = 2

        let args = versionOnly.arguments(vmId: "vm-1", firecrackerBinaryPath: "/fc")
        #expect(!args.contains("--cgroup-version"))
        #expect(!args.contains("--cgroup"))
    }

    @Test("the per-VM cgroup directory derives from the exec file basename")
    func cgroupDirectoryDerivation() {
        #expect(
            JailerOptions.cgroupDirectory(
                firecrackerBinaryPath: "/usr/local/bin/firecracker", vmId: "abc")
                == "/sys/fs/cgroup/firecracker/abc")
    }

    @Test("PID discovery matches both --id spellings")
    func argvIdMatching() {
        // The two-token form this client uses when spawning directly.
        #expect(FirecrackerClient.argvCarriesVMId(["/usr/bin/firecracker", "--id", "vm-1"], vmId: "vm-1"))
        // The single-token form the jailer passes to the exec'd Firecracker.
        #expect(FirecrackerClient.argvCarriesVMId(["/firecracker", "--id=vm-1"], vmId: "vm-1"))
        // Wrong id, either spelling: no match — and no prefix confusion.
        #expect(!FirecrackerClient.argvCarriesVMId(["/firecracker", "--id", "vm-10"], vmId: "vm-1"))
        #expect(!FirecrackerClient.argvCarriesVMId(["/firecracker", "--id=vm-10"], vmId: "vm-1"))
        // A trailing bare --id must not crash or match.
        #expect(!FirecrackerClient.argvCarriesVMId(["/firecracker", "--id"], vmId: "vm-1"))
    }

    @Test("the client derives jailed and unjailed socket paths from one place")
    func clientSocketPathSelection() async {
        let client = FirecrackerClient(
            firecrackerBinaryPath: "/usr/local/bin/firecracker",
            socketDirectory: "/tmp/firecracker")

        let unjailed = await client.socketPath(vmId: "abc", jail: nil)
        #expect(unjailed == "/tmp/firecracker/abc.sock")

        let jailed = await client.socketPath(vmId: "abc", jail: options)
        #expect(jailed == "/var/lib/strato/vms/jailer/firecracker/abc/root/run/firecracker.socket")
    }
}
