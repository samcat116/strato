import Foundation
import Libvirt
import StratoShared

/// The libvirt typed-parameter boundary for QEMU per-disk throttling.
///
/// Keeping field names and value coercion out of the runtime driver makes the
/// two dangerous translations unit-testable: nil becomes libvirt's explicit
/// zero only on an update (so removing one dimension really clears it), and a
/// read-back zero becomes an explicitly observed uncapped dimension.
public enum DomainBlockIOTune {
    public static let totalIOPSField = "total_iops_sec"
    public static let totalBytesField = "total_bytes_sec"

    /// Both fields are always sent. Omitting an uncapped dimension from an
    /// update leaves its previous value in place on some libvirt versions.
    public static func parameters(for limits: VolumeIOLimits?) -> [TypedParam] {
        [
            TypedParam(
                field: totalIOPSField,
                value: .ullong(UInt64(clamping: limits?.iopsTotal ?? 0))),
            TypedParam(
                field: totalBytesField,
                value: .ullong(UInt64(clamping: limits?.bpsTotal ?? 0))),
        ]
    }

    /// Returns a present value even when both dimensions are zero. At the wire
    /// boundary that means "the agent read back uncapped", distinct from nil
    /// ("the agent could not report applied limits").
    public static func limits(from parameters: [TypedParam]) -> VolumeIOLimits {
        VolumeIOLimits(
            iopsTotal: positiveInt64(parameters, field: totalIOPSField),
            bpsTotal: positiveInt64(parameters, field: totalBytesField))
    }

    private static func positiveInt64(_ parameters: [TypedParam], field: String) -> Int64? {
        guard let value = parameters.first(where: { $0.field == field })?.value else { return nil }
        let parsed: Int64?
        switch value {
        case .ullong(let raw): parsed = Int64(exactly: raw)
        case .llong(let raw): parsed = raw
        case .uint(let raw): parsed = Int64(raw)
        case .int(let raw): parsed = Int64(raw)
        case .double, .boolean, .string: parsed = nil
        }
        guard let parsed, parsed > 0 else { return nil }
        return parsed
    }
}

/// Cumulative live-domain counters returned by `virDomainBlockStats`.
public struct VolumeIOCounters: Equatable, Sendable {
    public let readOperations: UInt64
    public let writeOperations: UInt64
    public let readBytes: UInt64
    public let writeBytes: UInt64

    public init?(_ stats: DomainBlockStatsRet) {
        guard stats.rdReq >= 0, stats.wrReq >= 0, stats.rdBytes >= 0, stats.wrBytes >= 0 else {
            return nil
        }
        readOperations = UInt64(stats.rdReq)
        writeOperations = UInt64(stats.wrReq)
        readBytes = UInt64(stats.rdBytes)
        writeBytes = UInt64(stats.wrBytes)
    }

    public init(
        readOperations: UInt64, writeOperations: UInt64,
        readBytes: UInt64, writeBytes: UInt64
    ) {
        self.readOperations = readOperations
        self.writeOperations = writeOperations
        self.readBytes = readBytes
        self.writeBytes = writeBytes
    }

    /// Nil across counter resets, zero/negative elapsed time, or non-finite
    /// arithmetic. A process restart is not a burst of negative I/O.
    public func rate(since previous: Self, elapsedSeconds: Double) -> VolumeIOObservedRate? {
        guard elapsedSeconds > 0, elapsedSeconds.isFinite,
            readOperations >= previous.readOperations,
            writeOperations >= previous.writeOperations,
            readBytes >= previous.readBytes,
            writeBytes >= previous.writeBytes
        else { return nil }

        let operations =
            Double(readOperations - previous.readOperations)
            + Double(writeOperations - previous.writeOperations)
        let bytes =
            Double(readBytes - previous.readBytes)
            + Double(writeBytes - previous.writeBytes)
        let iops = operations / elapsedSeconds
        let bytesPerSecond = bytes / elapsedSeconds
        guard iops.isFinite, bytesPerSecond.isFinite else { return nil }
        return VolumeIOObservedRate(iops: iops, bytesPerSecond: bytesPerSecond)
    }
}

/// One cumulative counter reading tied to the live hypervisor incarnation that
/// produced it. A domain restart can create larger counters than the previous
/// process, so counter magnitude alone cannot identify a reset.
public struct VolumeIOCounterSample: Equatable, Sendable {
    public let counters: VolumeIOCounters
    public let incarnation: Int32

    public init(counters: VolumeIOCounters, incarnation: Int32) {
        self.counters = counters
        self.incarnation = incarnation
    }

    /// Rates are meaningful only between readings from the same live domain.
    public func rate(since previous: Self, elapsedSeconds: Double) -> VolumeIOObservedRate? {
        guard incarnation == previous.incarnation else { return nil }
        return counters.rate(since: previous.counters, elapsedSeconds: elapsedSeconds)
    }
}
