import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("host capacity admission")
struct HostCapacityAdmissionTests {
    private let gib: Int64 = 1024 * 1024 * 1024

    @Test("an exact fit is claimed and a larger request is refused")
    func exactFitAndRefusal() throws {
        var ledger = HostCapacityAdmissionLedger()
        let snapshot = HostCapacitySnapshot(
            total: HostReservation(cpus: 8, memoryBytes: 16 * gib),
            reserved: HostReservation(cpus: 4, memoryBytes: 8 * gib))

        let claim = try #require(
            try ledger.claim(
                HostReservation(cpus: 4, memoryBytes: 8 * gib),
                desiredWorkloadReservation: HostReservation(cpus: 4, memoryBytes: 8 * gib),
                snapshot: snapshot, agentName: "hv-03"))
        #expect(claim.reservation == HostReservation(cpus: 4, memoryBytes: 8 * gib))
        #expect(throws: HostCapacityAdmissionError.self) {
            try ledger.claim(
                HostReservation(cpus: 1), desiredWorkloadReservation: HostReservation(cpus: 1),
                snapshot: snapshot, agentName: "hv-03")
        }
    }

    @Test("stale concurrent snapshots cannot both spend the same capacity")
    func staleSnapshotClaims() throws {
        var ledger = HostCapacityAdmissionLedger()
        let initialRevision = ledger.revision
        let stale = HostCapacitySnapshot(
            total: HostReservation(cpus: 8, memoryBytes: 8 * gib),
            reserved: HostReservation(cpus: 4, memoryBytes: 4 * gib))
        let first = try #require(
            try ledger.claim(
                HostReservation(cpus: 3, memoryBytes: 3 * gib),
                desiredWorkloadReservation: HostReservation(cpus: 3, memoryBytes: 3 * gib),
                snapshot: stale, agentName: "hv"))
        #expect(ledger.revision == initialRevision + 1)

        #expect(throws: HostCapacityAdmissionError.self) {
            try ledger.claim(
                HostReservation(cpus: 2, memoryBytes: 2 * gib),
                desiredWorkloadReservation: HostReservation(cpus: 2, memoryBytes: 2 * gib),
                snapshot: stale, agentName: "hv")
        }

        ledger.release(first)
        #expect(ledger.revision == initialRevision + 2)
        #expect(
            try ledger.claim(
                HostReservation(cpus: 2, memoryBytes: 2 * gib),
                desiredWorkloadReservation: HostReservation(cpus: 2, memoryBytes: 2 * gib),
                snapshot: stale, agentName: "hv") != nil)
    }

    @Test("shrink is never credited before success and passes on a full host")
    func shrinkAndMixedResize() throws {
        let current = HostReservation(cpus: 8, memoryBytes: 8 * gib)
        #expect(
            HostReservation.positiveDelta(
                from: current, to: HostReservation(cpus: 4, memoryBytes: 4 * gib)) == HostReservation())
        #expect(
            HostReservation.positiveDelta(
                from: current, to: HostReservation(cpus: 4, memoryBytes: 10 * gib))
                == HostReservation(memoryBytes: 2 * gib))

        var ledger = HostCapacityAdmissionLedger()
        let full = HostCapacitySnapshot(total: current, reserved: current)
        #expect(
            try ledger.claim(
                HostReservation(),
                desiredWorkloadReservation: HostReservation(cpus: 4, memoryBytes: 4 * gib),
                snapshot: full, agentName: "hv") == nil)
    }

    @Test("mixed resize impossibility is judged by the desired footprint")
    func mixedResizeUsesDesiredFootprint() throws {
        let current = HostReservation(cpus: 8, memoryBytes: 8 * gib)
        let desired = HostReservation(cpus: 4, memoryBytes: 12 * gib)
        let snapshot = HostCapacitySnapshot(
            total: HostReservation(cpus: 6, memoryBytes: 16 * gib),
            reserved: current)
        var ledger = HostCapacityAdmissionLedger()

        let claim = try ledger.claim(
            .positiveDelta(from: current, to: desired),
            desiredWorkloadReservation: desired,
            snapshot: snapshot, agentName: "hv")

        #expect(claim?.reservation == HostReservation(memoryBytes: 4 * gib))
    }

    @Test("boot validation detects raw overcommit and unknown inventory")
    func existingReservationValidation() {
        let overcommitted = HostCapacitySnapshot(
            total: HostReservation(cpus: 8, memoryBytes: 8 * gib),
            reserved: HostReservation(cpus: 9, memoryBytes: 8 * gib))
        let unknown = HostCapacitySnapshot(
            total: HostReservation(cpus: 8, memoryBytes: 8 * gib),
            reserved: HostReservation(), inventoryKnown: false)
        let ledger = HostCapacityAdmissionLedger()
        #expect(throws: HostCapacityAdmissionError.self) {
            try ledger.validateExistingReservation(
                HostReservation(cpus: 4, memoryBytes: 4 * gib),
                snapshot: overcommitted, agentName: "hv")
        }
        #expect(throws: HostCapacityAdmissionError.self) {
            try ledger.validateExistingReservation(
                HostReservation(cpus: 4, memoryBytes: 4 * gib),
                snapshot: unknown, agentName: "hv")
        }
    }

    @Test("arithmetic saturates instead of wrapping capacity")
    func overflowSafety() throws {
        let saturated = HostReservation(
            cpus: Int.max, memoryBytes: Int64.max, diskBytes: Int64.max
        ).addingSaturating(HostReservation(cpus: 1, memoryBytes: 1, diskBytes: 1))
        #expect(
            saturated
                == HostReservation(
                    cpus: Int.max, memoryBytes: Int64.max, diskBytes: Int64.max))

        var ledger = HostCapacityAdmissionLedger()
        let snapshot = HostCapacitySnapshot(
            total: HostReservation(cpus: Int.max, memoryBytes: Int64.max),
            reserved: HostReservation(cpus: Int.max - 1, memoryBytes: Int64.max - 1))
        _ = try ledger.claim(
            HostReservation(cpus: 1, memoryBytes: 1),
            desiredWorkloadReservation: HostReservation(cpus: 1, memoryBytes: 1),
            snapshot: snapshot, agentName: "hv")
        #expect(throws: HostCapacityAdmissionError.self) {
            try ledger.claim(
                HostReservation(cpus: 1), desiredWorkloadReservation: HostReservation(cpus: 1),
                snapshot: snapshot, agentName: "hv")
        }
    }

    @Test("disk claims admit exact fit, block contention, and reject impossible requests")
    func diskAdmission() throws {
        let snapshot = HostCapacitySnapshot(
            total: HostReservation(diskBytes: 100 * gib),
            reserved: HostReservation(diskBytes: 60 * gib))
        var ledger = HostCapacityAdmissionLedger()

        let exact = try #require(
            try ledger.claim(
                HostReservation(diskBytes: 40 * gib),
                desiredWorkloadReservation: HostReservation(diskBytes: 40 * gib),
                snapshot: snapshot,
                agentName: "disk-host"))
        #expect(exact.reservation.diskBytes == 40 * gib)

        do {
            _ = try ledger.claim(
                HostReservation(diskBytes: gib),
                desiredWorkloadReservation: HostReservation(diskBytes: gib),
                snapshot: snapshot,
                agentName: "disk-host")
            Issue.record("a concurrent disk claim should be refused")
        } catch let error as HostCapacityAdmissionError {
            #expect(error.resource == .disk)
            #expect(error.failureClassification == .blocked)
        }

        ledger.release(exact)
        do {
            _ = try ledger.claim(
                HostReservation(diskBytes: 101 * gib),
                desiredWorkloadReservation: HostReservation(diskBytes: 101 * gib),
                snapshot: snapshot,
                agentName: "disk-host")
            Issue.record("a volume larger than the host should be refused")
        } catch let error as HostCapacityAdmissionError {
            #expect(error.resource == .disk)
            #expect(error.failureClassification == .permanent)
        }
    }

    @Test("disk shrink has no positive claim and unknown disk inventory fails closed")
    func diskShrinkAndUnknownInventory() throws {
        let current = HostReservation(diskBytes: 80 * gib)
        let desired = HostReservation(diskBytes: 40 * gib)
        #expect(HostReservation.positiveDelta(from: current, to: desired).diskBytes == 0)

        var ledger = HostCapacityAdmissionLedger()
        let full = HostCapacitySnapshot(
            total: HostReservation(diskBytes: 80 * gib),
            reserved: current)
        #expect(
            try ledger.claim(
                .positiveDelta(from: current, to: desired),
                desiredWorkloadReservation: desired,
                snapshot: full,
                agentName: "disk-host") == nil)

        let unknown = HostCapacitySnapshot(
            total: HostReservation(cpus: 8, memoryBytes: 16 * gib, diskBytes: 100 * gib),
            reserved: HostReservation(),
            inventoryKnown: true,
            diskInventoryKnown: false)
        do {
            _ = try ledger.claim(
                HostReservation(diskBytes: gib),
                desiredWorkloadReservation: HostReservation(diskBytes: gib),
                snapshot: unknown,
                agentName: "disk-host")
            Issue.record("unknown disk inventory should be refused")
        } catch let error as HostCapacityAdmissionError {
            #expect(error.resource == .inventory)
            #expect(error.failureClassification == .blocked)
        }
    }

    @Test("QEMU reservation includes aligned hot-add headroom once")
    func qemuReservationSemantics() {
        let spec = VMSpec(
            cpus: 2, memoryBytes: 2 * gib, maxMemoryBytes: 8 * gib,
            boot: .disk(firmware: nil))
        #expect(
            VMHostReservation.forSpec(spec, hypervisorType: .qemu, architecture: .x86_64)
                == HostReservation(cpus: 2, memoryBytes: 8 * gib))
        #expect(
            VMHostReservation.forSpec(spec, hypervisorType: .firecracker, architecture: .x86_64)
                == HostReservation(cpus: 2, memoryBytes: 2 * gib))
    }

    @Test("manifest keeps a QEMU domain's fixed reservation after live resize")
    func fixedQEMUManifestReservation() {
        let created = VMSpec(
            cpus: 2, memoryBytes: gib, maxMemoryBytes: 2 * gib,
            boot: .disk(firmware: nil))
        let resized = VMSpec(
            cpus: 2, memoryBytes: gib + 768 * 1024 * 1024, maxMemoryBytes: 2 * gib,
            boot: .disk(firmware: nil))
        let entry = VMManifestEntry(
            hypervisorType: .qemu,
            spec: created,
            realizedMemoryReservationBytes: 2 * gib
        )
        .with(spec: resized)

        #expect(
            VMHostReservation.forManifestEntry(entry, architecture: .arm64)
                == HostReservation(cpus: 2, memoryBytes: 2 * gib))
    }

    @Test("legacy QEMU manifests conservatively keep requested maximum memory")
    func legacyQEMUManifestReservation() {
        let spec = VMSpec(
            cpus: 2, memoryBytes: gib, maxMemoryBytes: gib + 256 * 1024 * 1024,
            boot: .disk(firmware: nil))
        let entry = VMManifestEntry(hypervisorType: .qemu, spec: spec)

        #expect(
            VMHostReservation.forManifestEntry(entry, architecture: .arm64)
                == HostReservation(cpus: 2, memoryBytes: gib + 256 * 1024 * 1024))
    }

    @Test("backend inventory keeps only missing orphan reservations")
    func missingOrphanReservations() {
        let inventory = HypervisorReservationInventory(
            reservation: HostReservation(cpus: 2, memoryBytes: 2 * gib),
            workloadIDs: ["present-orphan"])
        let orphans = [
            "present-orphan": HostReservation(cpus: 2, memoryBytes: 2 * gib),
            "missing-orphan": HostReservation(cpus: 4, memoryBytes: 4 * gib),
        ]

        #expect(
            inventory.includingMissingWorkloads(orphans)
                == HostReservation(cpus: 6, memoryBytes: 6 * gib))
    }

    @Test("aggregate-only backends keep every orphan reserved")
    func aggregateOnlyInventoryIsConservative() {
        let inventory = HypervisorReservationInventory(
            reservation: HostReservation(cpus: 2, memoryBytes: 2 * gib))
        let orphans = [
            "orphan-a": HostReservation(cpus: 1, memoryBytes: 1 * gib),
            "orphan-b": HostReservation(cpus: 3, memoryBytes: 3 * gib),
        ]

        #expect(
            inventory.includingMissingWorkloads(orphans)
                == HostReservation(cpus: 6, memoryBytes: 6 * gib))
    }

    @Test("per-workload inventory raises stale sizing to the durable manifest")
    func staleInventorySizing() {
        let inventory = HypervisorReservationInventory(
            reservation: HostReservation(cpus: 3, memoryBytes: 3 * gib),
            workloadReservations: [
                "vm-a": HostReservation(cpus: 1, memoryBytes: gib),
                "vm-untracked": HostReservation(cpus: 2, memoryBytes: 2 * gib),
            ])
        let durable = [
            "vm-a": HostReservation(cpus: 4, memoryBytes: 4 * gib)
        ]

        #expect(
            inventory.includingMissingWorkloads(durable)
                == HostReservation(cpus: 6, memoryBytes: 6 * gib))
    }

    @Test("sandbox sizing uses the shared host reservation pools")
    func sandboxReservationSemantics() {
        let spec = SandboxSpec(
            image: "docker.io/library/alpine:3.20", cpus: 3, memoryBytes: 768 * 1024 * 1024)
        #expect(
            SandboxHostReservation.forSpec(spec)
                == HostReservation(cpus: 3, memoryBytes: 768 * 1024 * 1024))
    }

    @Test("capacity refusals are blocked and actionable")
    func refusalClassification() {
        let error = HostCapacityAdmissionError(
            agentName: "hv-03", resource: .memory,
            available: HostReservation(memoryBytes: 12 * gib),
            required: HostReservation(memoryBytes: 64 * gib))
        #expect(error.failureClassification == .blocked)
        #expect(error.localizedDescription.contains("agent `hv-03`"))
        #expect(error.localizedDescription.contains("12 GiB"))
        #expect(error.localizedDescription.contains("64 GiB"))
    }

    @Test("neighbour contention is blocked but an impossible workload is permanent")
    func contentionAndImpossibleRequests() throws {
        let snapshot = HostCapacitySnapshot(
            total: HostReservation(cpus: 8, memoryBytes: 16 * gib),
            reserved: HostReservation(cpus: 7, memoryBytes: 14 * gib))
        var ledger = HostCapacityAdmissionLedger()

        do {
            _ = try ledger.claim(
                HostReservation(cpus: 2, memoryBytes: 2 * gib),
                desiredWorkloadReservation: HostReservation(cpus: 6, memoryBytes: 10 * gib),
                snapshot: snapshot, agentName: "hv")
            Issue.record("contention should refuse the claim")
        } catch let error as HostCapacityAdmissionError {
            #expect(error.failureClassification == .blocked)
        }

        do {
            _ = try ledger.claim(
                HostReservation(cpus: 5, memoryBytes: 9 * gib),
                desiredWorkloadReservation: HostReservation(cpus: 9, memoryBytes: 17 * gib),
                snapshot: snapshot, agentName: "hv")
            Issue.record("a workload larger than the host should be refused")
        } catch let error as HostCapacityAdmissionError {
            #expect(error.failureClassification == .permanent)
            #expect(error.localizedDescription.contains("8 total vCPUs"))
            #expect(error.localizedDescription.contains("9 vCPUs"))
        }
    }

    @Test("boot is permanent only when this workload alone exceeds the host")
    func existingReservationClassification() {
        let snapshot = HostCapacitySnapshot(
            total: HostReservation(cpus: 8, memoryBytes: 16 * gib),
            reserved: HostReservation(cpus: 10, memoryBytes: 20 * gib))
        let ledger = HostCapacityAdmissionLedger()

        do {
            try ledger.validateExistingReservation(
                HostReservation(cpus: 4, memoryBytes: 8 * gib),
                snapshot: snapshot, agentName: "hv")
            Issue.record("aggregate overcommit should refuse boot")
        } catch let error as HostCapacityAdmissionError {
            #expect(error.failureClassification == .blocked)
        } catch {
            Issue.record("unexpected error: \(error)")
        }

        do {
            try ledger.validateExistingReservation(
                HostReservation(cpus: 9, memoryBytes: 8 * gib),
                snapshot: snapshot, agentName: "hv")
            Issue.record("an intrinsically oversized workload should refuse boot")
        } catch let error as HostCapacityAdmissionError {
            #expect(error.failureClassification == .permanent)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

@Suite("QEMU memory containment")
struct QEMUMemoryContainmentTests {
    private let gib: Int64 = 1024 * 1024 * 1024

    @Test("shared cgroup detection requires the v2 memory controller")
    func controllerDetection() {
        #expect(HostMemoryController.isAvailable(readFile: { _ in "cpu io memory pids" }))
        #expect(!HostMemoryController.isAvailable(readFile: { _ in "cpu io pids" }))
        #expect(!HostMemoryController.isAvailable(readFile: { _ in nil }))
    }

    @Test("hard-limit arithmetic is saturating and rounds up to KiB")
    func hardLimitArithmetic() {
        #expect(
            QEMUMemoryCeiling.bytes(guestMemoryBytes: 2 * gib, overheadBytes: 512 * 1024 * 1024)
                == 2_684_354_560)
        #expect(QEMUMemoryCeiling.kibibytes(guestMemoryBytes: 1, overheadBytes: 0) == 1)
        #expect(QEMUMemoryCeiling.bytes(guestMemoryBytes: Int64.max, overheadBytes: 1) == Int64.max)
    }

    @Test("domain hard limit is inserted before vCPU")
    func insertsHardLimit() throws {
        let xml = """
            <domain type='kvm'>
              <name>vm</name>
              <memory unit='KiB'>2097152</memory>
              <currentMemory unit='KiB'>2097152</currentMemory>
              <vcpu>2</vcpu>
            </domain>
            """
        let updated = try #require(try DomainMemoryTuning.updatingHardLimit(in: xml, bytes: 3 * gib))
        #expect(updated.contains("<hard_limit unit='KiB'>3145728</hard_limit>"))
        let memtune = try #require(updated.range(of: "<memtune>"))
        let vcpu = try #require(updated.range(of: "<vcpu>"))
        #expect(memtune.lowerBound < vcpu.lowerBound)
    }

    @Test("domain hard limit updates without losing unrelated memtune children")
    func updatesAndPreserves() throws {
        let xml = """
            <domain type='kvm'>
              <name>vm</name>
              <memtune>
                <soft_limit unit='KiB'>100</soft_limit>
                <hard_limit unit='KiB'>200</hard_limit>
                <swap_hard_limit unit='KiB'>300</swap_hard_limit>
              </memtune>
              <vcpu>2</vcpu>
            </domain>
            """
        let updated = try #require(try DomainMemoryTuning.updatingHardLimit(in: xml, bytes: 1024 * 1024))
        #expect(updated.contains("<soft_limit unit='KiB'>100</soft_limit>"))
        #expect(updated.contains("<hard_limit unit='KiB'>1024</hard_limit>"))
        #expect(updated.contains("<swap_hard_limit unit='KiB'>300</swap_hard_limit>"))
    }

    @Test("removal preserves other memtune children and removes an empty container")
    func removesHardLimit() throws {
        let withSoft = """
            <domain><memtune><soft_limit unit='KiB'>100</soft_limit><hard_limit unit='KiB'>200</hard_limit></memtune></domain>
            """
        let preserved = try #require(try DomainMemoryTuning.updatingHardLimit(in: withSoft, bytes: nil))
        #expect(preserved.contains("soft_limit"))
        #expect(!preserved.contains("hard_limit"))

        let hardOnly = "<domain><memtune><hard_limit unit='KiB'>200</hard_limit></memtune></domain>"
        let removed = try #require(try DomainMemoryTuning.updatingHardLimit(in: hardOnly, bytes: nil))
        #expect(!removed.contains("memtune"))
    }
}
