import Testing
import Foundation
import StratoShared
@testable import App

@Suite("ByteConversion Tests")
struct ByteConversionTests {
    @Test("bytesToGB divides by 1024^3")
    func testBytesToGB() {
        #expect((Int64(8) * 1024 * 1024 * 1024).bytesToGB == 8.0)
        #expect(Int64(0).bytesToGB == 0.0)
        #expect((Int64(1) * 1024 * 1024 * 1024).bytesToGB == 1.0)
    }

    @Test("gbToBytes multiplies by 1024^3")
    func testGBToBytes() {
        #expect((8.0).gbToBytes == Int64(8) * 1024 * 1024 * 1024)
        #expect((0.0).gbToBytes == 0)
    }

    @Test("round trips whole-GiB values")
    func testRoundTrip() {
        let bytes = Int64(16) * 1024 * 1024 * 1024
        #expect(bytes.bytesToGB.gbToBytes == bytes)
    }
}

@Suite("ProjectStatsService Tests")
struct ProjectStatsServiceTests {
    private func gib(_ n: Int64) -> Int64 { n * 1024 * 1024 * 1024 }

    private func makeVM(env: String, cpu: Int, memoryGB: Int64, diskGB: Int64) -> VM {
        VM(
            name: "vm", description: "d", image: "img", projectID: UUID(),
            environment: env, cpu: cpu, memory: gib(memoryGB), disk: gib(diskGB)
        )
    }

    @Test("aggregates VM counts and resource totals")
    func testStats() {
        let project = Project(
            name: "P", description: "d", organizationID: UUID(), path: "/p",
            defaultEnvironment: "dev", environments: ["dev", "prod", "qa"]
        )
        let vms = [
            makeVM(env: "dev", cpu: 2, memoryGB: 2, diskGB: 10),
            makeVM(env: "dev", cpu: 2, memoryGB: 2, diskGB: 10),
            makeVM(env: "prod", cpu: 4, memoryGB: 4, diskGB: 20),
        ]

        let stats = ProjectStatsService.stats(for: project, vms: vms)

        #expect(stats.totalVMs == 3)
        #expect(stats.vmsByEnvironment["dev"] == 2)
        #expect(stats.vmsByEnvironment["prod"] == 1)
        // Declared-but-empty environment is seeded to zero.
        #expect(stats.vmsByEnvironment["qa"] == 0)

        #expect(stats.resourceUsage.totalVCPUs == 8)
        #expect(stats.resourceUsage.totalMemoryGB == 8.0)
        #expect(stats.resourceUsage.totalStorageGB == 40.0)
        #expect(stats.resourceUsage.totalVMs == 3)
    }

    @Test("empty project reports zeros for every declared environment")
    func testStatsEmpty() {
        let project = Project(
            name: "P", description: "d", organizationID: UUID(), path: "/p",
            environments: ["dev", "staging"]
        )
        let stats = ProjectStatsService.stats(for: project, vms: [])

        #expect(stats.totalVMs == 0)
        #expect(stats.vmsByEnvironment["dev"] == 0)
        #expect(stats.vmsByEnvironment["staging"] == 0)
        #expect(stats.resourceUsage.totalVCPUs == 0)
        #expect(stats.resourceUsage.totalMemoryGB == 0.0)
    }
}

@Suite("QuotaUsageService Tests")
struct QuotaUsageServiceTests {
    private func gib(_ n: Int64) -> Int64 { n * 1024 * 1024 * 1024 }

    private func makeVM(env: String, status: VMStatus) -> VM {
        VM(
            name: "vm", description: "d", image: "img", projectID: UUID(),
            environment: env, cpu: 1, memory: gib(1), disk: gib(1), status: status
        )
    }

    @Test("assembles limits, reservations, utilization, and VM breakdown")
    func testUsageResponse() {
        let quota = ResourceQuota(
            id: UUID(), name: "Q", organizationID: UUID(),
            maxVCPUs: 10, maxMemory: gib(8), maxStorage: gib(100), maxVMs: 5,
            environment: "prod"
        )
        let actual = QuotaUsage(vcpus: 3, memoryGB: 2.0, storageGB: 20.0, vms: 3, networks: 0)
        let vms = [
            makeVM(env: "dev", status: .running),
            makeVM(env: "dev", status: .running),
            makeVM(env: "prod", status: .shutdown),
        ]

        let response = QuotaUsageService.usageResponse(for: quota, actualUsage: actual, vms: vms)

        #expect(response.quotaName == "Q")
        #expect(response.limits.maxMemoryGB == 8.0)
        #expect(response.limits.maxStorageGB == 100.0)
        #expect(response.limits.maxVCPUs == 10)

        // Reservations default to zero, so utilization is zero.
        #expect(response.reserved.memoryGB == 0.0)
        #expect(response.utilization.cpuPercent == 0.0)
        #expect(response.utilization.memoryPercent == 0.0)

        // Measured usage is passed through untouched.
        #expect(response.actual.vcpus == 3)

        #expect(response.vmsByEnvironment["dev"] == 2)
        #expect(response.vmsByEnvironment["prod"] == 1)
        #expect(response.vmsByStatus[VMStatus.running.rawValue] == 2)
        #expect(response.vmsByStatus[VMStatus.shutdown.rawValue] == 1)
        #expect(response.environment == "prod")
    }
}
