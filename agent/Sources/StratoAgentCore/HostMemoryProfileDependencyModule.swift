import StratoShared

/// Observation only: bootstrap and systemd own every host mutation.
public struct HostMemoryProfileDependencyModule: NodeDependencyModule {
    public let id: NodeDependencyID = .hostMemoryProfile
    public let role: NodeDependencyRole = .compute
    public let affectedCapabilities: [NodeCapability] = [.qemuPlacement, .sandboxNetworking]
    private let observation: @Sendable () async -> HostMemoryProfileObservation?

    private let warnings: @Sendable () async -> [String]

    public init(
        observation: @escaping @Sendable () async -> HostMemoryProfileObservation?,
        warnings: @escaping @Sendable () async -> [String] = { [] }
    ) {
        self.observation = observation
        self.warnings = warnings
    }

    public func inspect() async -> NodeDependencyInspection {
        let sample = await observation()
        let warning = sample == nil ? nil : await warnings().first
        let reason = sample?.reason ?? warning
        return NodeDependencyInspection(
            supervisorState: .notApplicable,
            compatibility: sample?.reason == nil ? .compatible : .incompatible,
            functionalState: sample?.reason != nil ? .unhealthy : (warning == nil ? .healthy : .degraded),
            reason: reason.map { NodeDependencyFailureReason(code: .functionalProbeFailed, message: $0) })
    }
}
