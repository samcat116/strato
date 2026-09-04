import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Resource telemetry probe")
struct ResourceTelemetryProbeTests {
    @Test("host PSI, reclaim, swap, zram, OOM, and MGLRU are parsed")
    func hostSignals() throws {
        let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)
        let probe = fixtureProbe(
            [
                "/proc/pressure/cpu": "some avg10=12.50 avg60=4.00 avg300=1.00 total=900000\n",
                "/proc/pressure/memory":
                    "some avg10=1.25 avg60=0.50 avg300=0.25 total=8000\n"
                    + "full avg10=0.10 avg60=0.05 avg300=0.01 total=900\n",
                "/proc/pressure/io":
                    "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
                    + "full avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
                "/proc/meminfo":
                    "SwapTotal: 4096 kB\nSwapFree: 1024 kB\nZswap: 128 kB\nZswapped: 512 kB\n",
                "/proc/vmstat":
                    "pgmajfault 42\npgscan_kswapd 100\npgscan_direct 7\n"
                    + "pgsteal_kswapd 80\npgsteal_direct 5\noom_kill 2\n",
                "/sys/kernel/mm/lru_gen/enabled": "0x0007\n",
                "/sys/block/zram0/mm_stat": "1000 500 750 0 0 0 0 0\n",
            ], directories: ["/sys/block": ["sda", "zram0"]])

        let host = probe.sample(targets: [], at: sampleDate).host
        #expect(host.sampledAt == sampleDate)
        #expect(host.health == .pressured)
        #expect(host.cpuPressure.some?.average10 == 12.5)
        #expect(host.cpuPressure.full == nil)
        #expect(host.memoryPressure.full?.totalMicroseconds == 900)
        #expect(host.swapTotalBytes == .available(4_194_304))
        #expect(host.swapUsedBytes == .available(3_145_728))
        #expect(host.zswapStoredBytes == .available(524_288))
        #expect(host.zswapPoolBytes == .available(131_072))
        #expect(host.zramUsedBytes == .available(750))
        #expect(host.majorFaultsTotal == .available(42))
        #expect(host.reclaimScannedPagesTotal == .available(107))
        #expect(host.reclaimReclaimedPagesTotal == .available(85))
        #expect(host.oomKillsTotal == .available(2))
        #expect(host.mglruEnabled == .available(true))
    }

    @Test("measured zero stays distinct from an unavailable signal")
    func zeroVersusUnavailable() {
        let probe = fixtureProbe([
            "/proc/meminfo": "SwapTotal: 0 kB\nSwapFree: 0 kB\n",
            "/proc/vmstat": "pgmajfault 0\noom_kill 0\n",
        ])

        let host = probe.sample(targets: []).host
        #expect(host.swapUsedBytes.availability == .available)
        #expect(host.swapUsedBytes.value == 0)
        #expect(host.majorFaultsTotal == .available(0))
        #expect(host.zswapPoolBytes == .unavailable)
        #expect(host.zramUsedBytes == .unavailable)
        #expect(host.cpuPressure.availability == .unavailable)
        #expect(host.health == .unknown)
    }

    @Test("a direct cgroup exposes memory events, PSI, CPU use, and throttling")
    func directCgroup() throws {
        let root = "/sys/fs/cgroup/firecracker/sandbox-id"
        let probe = fixtureProbe([
            "\(root)/memory.current": "536870912\n",
            "\(root)/memory.events":
                "low 1\nhigh 8\nmax 2\noom 1\noom_kill 0\noom_group_kill 0\n",
            "\(root)/memory.pressure":
                "some avg10=6.00 avg60=2.00 avg300=1.00 total=700\n"
                + "full avg10=0.75 avg60=0.25 avg300=0.10 total=90\n",
            "\(root)/cpu.pressure": "some avg10=18.00 avg60=8.00 avg300=3.00 total=5000\n",
            "\(root)/io.pressure": "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
            "\(root)/cpu.stat": "usage_usec 123456\nnr_throttled 17\nthrottled_usec 9000\n",
        ])
        let target = WorkloadTelemetryProbeTarget(
            workloadID: "sandbox-id", kind: .sandbox, directCgroupPath: root)

        let workload = try #require(probe.sample(targets: [target]).workloads["sandbox-id"])
        #expect(workload.cgroupV2 == .available)
        #expect(workload.health == .pressured)
        #expect(workload.memoryCurrentBytes == .available(536_870_912))
        #expect(workload.memoryEvents.high == 8)
        #expect(workload.memoryEvents.oom == 1)
        #expect(workload.memoryPressure.full?.average10 == 0.75)
        #expect(workload.cpuPressure.some?.average10 == 18)
        #expect(workload.cpuUsageMicroseconds == .available(123_456))
        #expect(workload.cpuThrottledPeriodsTotal == .available(17))
        #expect(workload.cpuThrottledMicroseconds == .available(9_000))
        #expect(workload.guestStealMicroseconds == .unavailable)
    }

    @Test("libvirt PID membership resolves the unified cgroup")
    func pidCgroupDiscovery() throws {
        let root = "/sys/fs/cgroup/machine.slice/machine-qemu.scope"
        let probe = fixtureProbe([
            "/run/libvirt/qemu/vm-id.pid": "4321\n",
            "/proc/4321/cgroup": "0::/machine.slice/machine-qemu.scope\n",
            "\(root)/memory.current": "1024\n",
            "\(root)/cpu.stat": "usage_usec 55\nnr_throttled 0\nthrottled_usec 0\n",
        ])
        let target = WorkloadTelemetryProbeTarget(
            workloadID: "vm-id", kind: .vm,
            pidFilePath: "/run/libvirt/qemu/vm-id.pid",
            guestStealMicroseconds: .available(77))

        let workload = try #require(probe.sample(targets: [target]).workloads["vm-id"])
        #expect(workload.cgroupV2 == .available)
        #expect(workload.memoryCurrentBytes == .available(1024))
        #expect(workload.cpuUsageMicroseconds == .available(55))
        #expect(workload.cpuThrottledPeriodsTotal == .available(0))
        #expect(workload.guestStealMicroseconds == .available(77))
    }

    @Test("backend without a workload boundary reports unavailable rather than host data")
    func unavailableBackend() throws {
        let target = WorkloadTelemetryProbeTarget(workloadID: "vm-id", kind: .vm)
        let workload = try #require(
            fixtureProbe([:]).sample(targets: [target]).workloads["vm-id"])

        #expect(workload.cgroupV2 == .unavailable)
        #expect(workload.memoryCurrentBytes == .unavailable)
        #expect(workload.cpuPressure == .unavailable)
        #expect(workload.guestStealMicroseconds == .unavailable)
        #expect(workload.health == .unknown)
    }

    @Test("contention and memory-pressure fixture transitions cross alert thresholds")
    func stressTransitions() {
        let quiet = PressureStallTelemetry.available(
            some: stall(average10: 0), full: stall(average10: 0))
        let cpuContended = PressureStallTelemetry.available(
            some: stall(average10: 55), full: nil)
        let memoryContended = PressureStallTelemetry.available(
            some: stall(average10: 12), full: stall(average10: 2.5))

        #expect(ResourceTelemetryProbe.health(cpu: quiet, memory: quiet, io: quiet) == .healthy)
        #expect(
            ResourceTelemetryProbe.health(cpu: cpuContended, memory: quiet, io: quiet)
                == .critical)
        #expect(
            ResourceTelemetryProbe.health(cpu: quiet, memory: memoryContended, io: quiet)
                == .critical)
    }

    private func fixtureProbe(
        _ files: [String: String], directories: [String: [String]] = [:]
    ) -> ResourceTelemetryProbe {
        ResourceTelemetryProbe(
            read: { files[$0] },
            listDirectory: { directories[$0] })
    }

    private func stall(average10: Double) -> PressureStallSample {
        PressureStallSample(
            average10: average10, average60: average10,
            average300: average10, totalMicroseconds: 0)
    }
}
