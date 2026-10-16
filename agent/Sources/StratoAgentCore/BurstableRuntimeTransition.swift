import Foundation

/// Backend acknowledgements order live changes. Existing pressure is verified
/// before widening containment; shrink completes before containment narrows.
public enum BurstableRuntimeTransition {
    public static func apply(
        current: BurstableResourceLimits, target: BurstableResourceLimits, pageSize: Int64,
        setHigh: (Int64) async throws -> Void,
        setMaximum: (Int64) async throws -> Void,
        setWeight: (Int) async throws -> Void,
        resizeGuest: () async throws -> Void,
        verify: (BurstableResourceLimits) async throws -> Void,
        verifyExisting: ((BurstableResourceLimits, BurstableResourceLimits) async throws -> Void)? = nil,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        let old = try current.kernelMemoryBytes(pageSize: pageSize)
        let next = try target.kernelMemoryBytes(pageSize: pageSize)
        if let verifyExisting { try await verifyExisting(current, target) } else { try await verify(current) }
        if next.maximum > old.maximum {
            // memory.high is already effective before this widening.
            try await setMaximum(next.maximum)
            try await setHigh(next.high)
            try await setWeight(target.cpuWeight)
            try await verify(target)
            try await resizeGuest()
        } else {
            try await resizeGuest()
            try await setHigh(next.high)
            try await setMaximum(next.maximum)
            try await setWeight(target.cpuWeight)
        }
        try await verify(target)
    }
}
