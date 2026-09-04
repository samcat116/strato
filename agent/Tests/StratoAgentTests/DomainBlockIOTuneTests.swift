import Libvirt
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("libvirt block I/O tuning")
struct DomainBlockIOTuneTests {
    @Test("updates always name both dimensions so a removed ceiling is cleared")
    func updateParametersClearMissingDimensions() throws {
        let parameters = DomainBlockIOTune.parameters(
            for: VolumeIOLimits(iopsTotal: 2_000))

        #expect(parameters.map(\.field) == ["total_iops_sec", "total_bytes_sec"])
        guard case .ullong(let iops) = parameters[0].value,
            case .ullong(let bytes) = parameters[1].value
        else {
            Issue.record("I/O tuning parameters were not unsigned 64-bit values")
            return
        }
        #expect(iops == 2_000)
        #expect(bytes == 0)
    }

    @Test("readback distinguishes an authoritative clear from no observation")
    func readback() {
        let limits = DomainBlockIOTune.limits(
            from: [
                TypedParam(field: "total_iops_sec", value: .ullong(0)),
                TypedParam(field: "total_bytes_sec", value: .ullong(9_000_000)),
            ])

        #expect(limits == VolumeIOLimits(bpsTotal: 9_000_000))
        #expect(DomainBlockIOTune.limits(from: []).isEmpty)
    }

    @Test("counter deltas become aggregate IOPS and bytes per second")
    func observedRate() {
        let previous = VolumeIOCounters(
            readOperations: 100, writeOperations: 200,
            readBytes: 1_000, writeBytes: 2_000)
        let current = VolumeIOCounters(
            readOperations: 130, writeOperations: 250,
            readBytes: 4_000, writeBytes: 7_000)

        #expect(
            current.rate(since: previous, elapsedSeconds: 2)
                == VolumeIOObservedRate(iops: 40, bytesPerSecond: 4_000))
    }

    @Test("a libvirt counter reset is not reported as a traffic burst")
    func counterReset() {
        let previous = VolumeIOCounters(
            readOperations: 100, writeOperations: 200,
            readBytes: 1_000, writeBytes: 2_000)
        let reset = VolumeIOCounters(
            readOperations: 1, writeOperations: 2,
            readBytes: 10, writeBytes: 20)

        #expect(reset.rate(since: previous, elapsedSeconds: 1) == nil)
    }
}
