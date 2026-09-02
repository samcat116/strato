import Foundation
import Logging
import StratoShared

/// One instantaneous module result before the manager applies counters and
/// hysteresis. Modules report facts; the manager owns scheduling policy.
public struct NodeDependencyInspection: Sendable, Equatable {
    public let supervisorState: NodeDependencySupervisorState
    public let installedVersion: String?
    public let daemonVersion: String?
    public let compatibility: NodeDependencyCompatibility
    public let functionalState: NodeDependencyFunctionalState
    public let reason: NodeDependencyFailureReason?

    public init(
        supervisorState: NodeDependencySupervisorState,
        installedVersion: String? = nil,
        daemonVersion: String? = nil,
        compatibility: NodeDependencyCompatibility,
        functionalState: NodeDependencyFunctionalState,
        reason: NodeDependencyFailureReason? = nil
    ) {
        self.supervisorState = supervisorState
        self.installedVersion = installedVersion
        self.daemonVersion = daemonVersion
        self.compatibility = compatibility
        self.functionalState = functionalState
        self.reason = reason
    }

    var isHealthy: Bool {
        compatibility == .compatible && functionalState == .healthy
    }

    /// A module can intentionally report a usable warning state, such as a
    /// still-valid SPIRE SVID nearing expiry. The module has already decided
    /// whether its supervisor state is functional or advisory, so the manager
    /// must not reinterpret that metadata. This is not a failed health sample
    /// and must not accumulate toward the unhealthy threshold.
    var isExplicitlyDegraded: Bool {
        compatibility == .compatible && functionalState == .degraded
    }
}

/// A statically registered dependency module. Implementations may use typed
/// host adapters, but configuration never supplies executable paths or code.
public protocol NodeDependencyModule: Sendable {
    var id: NodeDependencyID { get }
    var role: NodeDependencyRole { get }
    var dependencies: [NodeDependencyID] { get }
    var desiredState: NodeDependencyDesiredState { get }
    var ownership: NodeDependencyOwnership { get }
    var affectedCapabilities: [NodeCapability] { get }

    func inspect() async -> NodeDependencyInspection
}

extension NodeDependencyModule {
    public var dependencies: [NodeDependencyID] { [] }
    public var desiredState: NodeDependencyDesiredState { .required }
    public var ownership: NodeDependencyOwnership { .observeOnly }
}

public enum NodeDependencyGraphError: Error, Equatable, CustomStringConvertible {
    case duplicate(NodeDependencyID)
    case missingDependency(module: NodeDependencyID, dependency: NodeDependencyID)
    case cycle([NodeDependencyID])

    public var description: String {
        switch self {
        case .duplicate(let id):
            return "dependency module \(id.rawValue) is registered more than once"
        case .missingDependency(let module, let dependency):
            return "dependency module \(module.rawValue) requires unregistered module \(dependency.rawValue)"
        case .cycle(let ids):
            return "dependency graph contains a cycle: \(ids.map(\.rawValue).joined(separator: ", "))"
        }
    }
}

/// Continuously inspects a validated dependency DAG and owns the policy state
/// around those inspections. It delegates all host effects to modules and will
/// never call reconciliation for externally owned (`observeOnly`) software.
public actor NodeDependencyManager {
    private struct ModuleState {
        var observation: NodeDependencyObservation?
        var recoverySuccesses = 0
    }

    private static let functionalFailureThreshold = 2
    private static let recoverySuccessThreshold = 2
    private static let inspectionTimeoutSeconds = 10

    private let modules: [NodeDependencyID: any NodeDependencyModule]
    private let layers: [[NodeDependencyID]]
    private let now: @Sendable () -> Date
    private let logger: Logger
    private var states: [NodeDependencyID: ModuleState] = [:]

    public init(
        modules: [any NodeDependencyModule],
        now: @escaping @Sendable () -> Date = Date.init,
        logger: Logger
    ) throws {
        let graph = try Self.validate(modules)
        self.modules = graph.modules
        self.layers = graph.layers
        self.now = now
        self.logger = logger
    }

    /// Inspect all modules. Independent modules in each graph layer run
    /// concurrently; dependants wait for the layer they require.
    @discardableResult
    public func refresh() async -> [NodeDependencyObservation] {
        var refreshed: [NodeDependencyID: NodeDependencyObservation] = [:]

        for layer in layers {
            let inspectionTimeoutSeconds = Self.inspectionTimeoutSeconds
            let results = await withTaskGroup(
                of: (NodeDependencyID, NodeDependencyInspection).self,
                returning: [(NodeDependencyID, NodeDependencyInspection)].self
            ) { group in
                for id in layer {
                    guard let module = modules[id] else { continue }
                    let failedDependencies = module.dependencies.filter { dependency in
                        guard let observation = refreshed[dependency] else { return true }
                        return !observation.permitsDependentWork
                    }
                    group.addTask {
                        if let failed = failedDependencies.first {
                            return (
                                id,
                                NodeDependencyInspection(
                                    supervisorState: .unknown,
                                    compatibility: .unknown,
                                    functionalState: .unhealthy,
                                    reason: NodeDependencyFailureReason(
                                        code: .dependencyFailed,
                                        message: "required dependency \(failed.rawValue) is unavailable"))
                            )
                        }
                        do {
                            let inspection = try await StageBudget.run(
                                seconds: inspectionTimeoutSeconds,
                                stage: "inspect node dependency \(id.rawValue)",
                                onTimeout: .abandon
                            ) {
                                await module.inspect()
                            }
                            return (id, inspection)
                        } catch {
                            return (
                                id,
                                NodeDependencyInspection(
                                    supervisorState: .unknown,
                                    compatibility: .unknown,
                                    functionalState: .unhealthy,
                                    reason: NodeDependencyFailureReason(
                                        code: .commandTimedOut,
                                        message: "dependency inspection exceeded its time budget"))
                            )
                        }
                    }
                }

                var values: [(NodeDependencyID, NodeDependencyInspection)] = []
                for await value in group { values.append(value) }
                return values
            }

            for (id, inspection) in results.sorted(by: { $0.0.rawValue < $1.0.rawValue }) {
                guard let module = modules[id] else { continue }
                let observation = stabilize(inspection, for: module)
                refreshed[id] = observation
                logTransition(from: states[id]?.observation, to: observation)
                var state = states[id] ?? ModuleState()
                state.observation = observation
                states[id] = state

            }
        }

        return snapshot()
    }

    public func observations() -> [NodeDependencyObservation] { snapshot() }

    private func stabilize(
        _ inspection: NodeDependencyInspection,
        for module: any NodeDependencyModule
    ) -> NodeDependencyObservation {
        let checkedAt = now()
        var state = states[module.id] ?? ModuleState()
        let previous = state.observation
        var functionalState = inspection.functionalState
        var consecutiveFailures = previous?.consecutiveFailures ?? 0
        var lastHealthyAt = previous?.lastHealthyAt

        if module.desiredState == .disabled {
            functionalState = .healthy
            consecutiveFailures = 0
            state.recoverySuccesses = 0
        } else if inspection.isExplicitlyDegraded {
            consecutiveFailures = 0
            state.recoverySuccesses = 0
        } else if inspection.isHealthy {
            consecutiveFailures = 0
            lastHealthyAt = checkedAt
            if previous?.functionalState == .unhealthy || previous?.functionalState == .starting {
                state.recoverySuccesses += 1
                functionalState =
                    state.recoverySuccesses >= Self.recoverySuccessThreshold ? .healthy : .starting
            } else {
                state.recoverySuccesses = Self.recoverySuccessThreshold
                functionalState = .healthy
            }
        } else {
            state.recoverySuccesses = 0
            consecutiveFailures += 1
            // Structural failures are categorical and gate immediately.
            let categorical =
                inspection.compatibility == .incompatible
                || inspection.supervisorState == .missing
                || inspection.supervisorState == .inactive
                || inspection.supervisorState == .failed
            if !categorical, consecutiveFailures < Self.functionalFailureThreshold {
                functionalState = .degraded
            } else {
                functionalState = .unhealthy
            }
        }

        states[module.id] = state
        return NodeDependencyObservation(
            id: module.id,
            role: module.role,
            desiredState: module.desiredState,
            ownership: module.ownership,
            supervisorState: inspection.supervisorState,
            installedVersion: inspection.installedVersion,
            daemonVersion: inspection.daemonVersion,
            compatibility: inspection.compatibility,
            functionalState: functionalState,
            checkedAt: checkedAt,
            lastHealthyAt: lastHealthyAt,
            reason: inspection.reason,
            consecutiveFailures: consecutiveFailures,
            remediationCount: 0,
            restartCount: 0,
            affectedCapabilities: module.affectedCapabilities)
    }

    private func snapshot() -> [NodeDependencyObservation] {
        states.values.compactMap(\.observation).sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func logTransition(
        from previous: NodeDependencyObservation?,
        to current: NodeDependencyObservation
    ) {
        guard
            previous?.functionalState != current.functionalState
                || previous?.supervisorState != current.supervisorState
                || previous?.compatibility != current.compatibility
                || previous?.reason?.code != current.reason?.code
        else { return }

        let metadata: Logger.Metadata = [
            "dependency": .string(current.id.rawValue),
            "functionalState": .string(current.functionalState.rawValue),
            "supervisorState": .string(current.supervisorState.rawValue),
            "compatibility": .string(current.compatibility.rawValue),
            "reasonCode": .string(current.reason?.code.rawValue ?? "none"),
        ]
        if current.functionalState == .unhealthy {
            logger.error("Node dependency became unavailable", metadata: metadata)
        } else {
            logger.info("Node dependency observation changed", metadata: metadata)
        }
    }

    private static func validate(
        _ modules: [any NodeDependencyModule]
    ) throws -> (modules: [NodeDependencyID: any NodeDependencyModule], layers: [[NodeDependencyID]]) {
        var registry: [NodeDependencyID: any NodeDependencyModule] = [:]
        for module in modules {
            guard registry[module.id] == nil else { throw NodeDependencyGraphError.duplicate(module.id) }
            registry[module.id] = module
        }
        for module in modules {
            for dependency in module.dependencies where registry[dependency] == nil {
                throw NodeDependencyGraphError.missingDependency(module: module.id, dependency: dependency)
            }
        }

        var remaining = Set(registry.keys)
        var resolved: Set<NodeDependencyID> = []
        var layers: [[NodeDependencyID]] = []
        while !remaining.isEmpty {
            let layer = remaining.filter { id in
                registry[id]?.dependencies.allSatisfy(resolved.contains) == true
            }.sorted { $0.rawValue < $1.rawValue }
            guard !layer.isEmpty else {
                throw NodeDependencyGraphError.cycle(remaining.sorted { $0.rawValue < $1.rawValue })
            }
            layers.append(layer)
            resolved.formUnion(layer)
            remaining.subtract(layer)
        }
        return (registry, layers)
    }
}
