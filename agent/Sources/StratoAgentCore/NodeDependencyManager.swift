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

    public static let disabled = NodeDependencyInspection(
        supervisorState: .notApplicable,
        compatibility: .compatible,
        functionalState: .healthy)

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

public enum NodeDependencyRemediationResult: Sendable, Equatable {
    case noAction
    case remediated(restarted: Bool)
    case failed(String)
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
    func ensureRunning(_ observation: NodeDependencyObservation) async -> NodeDependencyRemediationResult
    func reconcile(_ observation: NodeDependencyObservation) async -> NodeDependencyRemediationResult
}

extension NodeDependencyModule {
    public var dependencies: [NodeDependencyID] { [] }
    public func ensureRunning(_ observation: NodeDependencyObservation) async -> NodeDependencyRemediationResult {
        .noAction
    }
    public func reconcile(_ observation: NodeDependencyObservation) async -> NodeDependencyRemediationResult {
        .noAction
    }
}

/// A concrete module useful when the service-specific API already exists as an
/// actor or closure (SPIRE and OVN are both in that shape).
public struct ClosureNodeDependencyModule: NodeDependencyModule {
    public let id: NodeDependencyID
    public let role: NodeDependencyRole
    public let dependencies: [NodeDependencyID]
    public let desiredState: NodeDependencyDesiredState
    public let ownership: NodeDependencyOwnership
    public let affectedCapabilities: [NodeCapability]
    private let inspection: @Sendable () async -> NodeDependencyInspection
    private let ensureRunningOperation: @Sendable (NodeDependencyObservation) async -> NodeDependencyRemediationResult
    private let reconciliation: @Sendable (NodeDependencyObservation) async -> NodeDependencyRemediationResult

    public init(
        id: NodeDependencyID,
        role: NodeDependencyRole,
        dependencies: [NodeDependencyID] = [],
        desiredState: NodeDependencyDesiredState,
        ownership: NodeDependencyOwnership,
        affectedCapabilities: [NodeCapability],
        inspect: @escaping @Sendable () async -> NodeDependencyInspection,
        ensureRunning: @escaping @Sendable (NodeDependencyObservation) async -> NodeDependencyRemediationResult = {
            _ in .noAction
        },
        reconcile: @escaping @Sendable (NodeDependencyObservation) async -> NodeDependencyRemediationResult = { _ in
            .noAction
        }
    ) {
        self.id = id
        self.role = role
        self.dependencies = dependencies
        self.desiredState = desiredState
        self.ownership = ownership
        self.affectedCapabilities = affectedCapabilities
        self.inspection = inspect
        self.ensureRunningOperation = ensureRunning
        self.reconciliation = reconcile
    }

    public func inspect() async -> NodeDependencyInspection { await inspection() }
    public func ensureRunning(
        _ observation: NodeDependencyObservation
    ) async -> NodeDependencyRemediationResult {
        await ensureRunningOperation(observation)
    }
    public func reconcile(_ observation: NodeDependencyObservation) async -> NodeDependencyRemediationResult {
        await reconciliation(observation)
    }
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

public struct NodeDependencyManagerPolicy: Sendable, Equatable {
    public var functionalFailureThreshold: Int
    public var recoverySuccessThreshold: Int
    public var inspectionTimeoutSeconds: Int
    public var remediationTimeoutSeconds: Int
    public var remediationCooldown: TimeInterval
    public var remediationBackoffBase: TimeInterval
    public var restartBudget: Int
    public var restartBudgetWindow: TimeInterval

    public init(
        functionalFailureThreshold: Int = 2,
        recoverySuccessThreshold: Int = 2,
        inspectionTimeoutSeconds: Int = 10,
        remediationTimeoutSeconds: Int = 30,
        remediationCooldown: TimeInterval = 60,
        remediationBackoffBase: TimeInterval = 15,
        restartBudget: Int = 3,
        restartBudgetWindow: TimeInterval = 3600
    ) {
        self.functionalFailureThreshold = max(1, functionalFailureThreshold)
        self.recoverySuccessThreshold = max(1, recoverySuccessThreshold)
        self.inspectionTimeoutSeconds = max(1, inspectionTimeoutSeconds)
        self.remediationTimeoutSeconds = max(1, remediationTimeoutSeconds)
        self.remediationCooldown = max(0, remediationCooldown)
        self.remediationBackoffBase = max(0, remediationBackoffBase)
        self.restartBudget = max(0, restartBudget)
        self.restartBudgetWindow = max(1, restartBudgetWindow)
    }
}

/// Continuously inspects a validated dependency DAG and owns the policy state
/// around those inspections. It delegates all host effects to modules and will
/// never call reconciliation for externally owned (`observeOnly`) software.
public actor NodeDependencyManager {
    private struct ModuleState {
        var observation: NodeDependencyObservation?
        var recoverySuccesses = 0
        var remediationFailures = 0
        var nextRemediationAt: Date?
        var restartTimestamps: [Date] = []
        var remediationCount = 0
        var restartCount = 0
    }

    private let modules: [NodeDependencyID: any NodeDependencyModule]
    private let layers: [[NodeDependencyID]]
    private let policy: NodeDependencyManagerPolicy
    private let now: @Sendable () -> Date
    private let logger: Logger
    private var states: [NodeDependencyID: ModuleState] = [:]

    public init(
        modules: [any NodeDependencyModule],
        policy: NodeDependencyManagerPolicy = .init(),
        now: @escaping @Sendable () -> Date = Date.init,
        logger: Logger
    ) throws {
        let graph = try Self.validate(modules)
        self.modules = graph.modules
        self.layers = graph.layers
        self.policy = policy
        self.now = now
        self.logger = logger
    }

    /// Inspect all modules. Independent modules in each graph layer run
    /// concurrently; dependants wait for the layer they require.
    @discardableResult
    public func refresh(allowRemediation: Bool = false) async -> [NodeDependencyObservation] {
        var refreshed: [NodeDependencyID: NodeDependencyObservation] = [:]

        for layer in layers {
            let inspectionTimeoutSeconds = policy.inspectionTimeoutSeconds
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

                if allowRemediation { await remediateIfAllowed(module: module, observation: observation) }
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
                    state.recoverySuccesses >= policy.recoverySuccessThreshold ? .healthy : .starting
            } else {
                state.recoverySuccesses = policy.recoverySuccessThreshold
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
            if !categorical, consecutiveFailures < policy.functionalFailureThreshold {
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
            remediationCount: state.remediationCount,
            restartCount: state.restartCount,
            affectedCapabilities: module.affectedCapabilities)
    }

    private func remediateIfAllowed(
        module: any NodeDependencyModule,
        observation: NodeDependencyObservation
    ) async {
        guard module.ownership != .observeOnly,
            module.desiredState == .required,
            observation.functionalState == .unhealthy,
            observation.compatibility != .incompatible
        else { return }

        var state = states[module.id] ?? ModuleState()
        let current = now()
        if let next = state.nextRemediationAt, next > current { return }
        state.restartTimestamps.removeAll {
            current.timeIntervalSince($0) > policy.restartBudgetWindow
        }
        guard state.restartTimestamps.count < policy.restartBudget else {
            state.observation = replacingReason(
                observation,
                NodeDependencyFailureReason(
                    code: .remediationBudgetExhausted,
                    message: "restart budget exhausted; waiting for the budget window to reset"))
            states[module.id] = state
            return
        }

        let remediation: NodeDependencyRemediationResult
        do {
            remediation = try await StageBudget.run(
                seconds: policy.remediationTimeoutSeconds,
                stage: "reconcile node dependency \(module.id.rawValue)"
            ) {
                switch module.ownership {
                case .observeOnly:
                    return .noAction
                case .ensureRunning:
                    return await module.ensureRunning(observation)
                case .reconcile:
                    return await module.reconcile(observation)
                }
            }
        } catch {
            remediation = .failed("dependency remediation exceeded its time budget")
        }

        switch remediation {
        case .noAction:
            return
        case .remediated(let restarted):
            state.remediationCount += 1
            if restarted {
                state.restartCount += 1
                state.restartTimestamps.append(current)
            }
            state.remediationFailures = 0
            state.nextRemediationAt = current.addingTimeInterval(policy.remediationCooldown)
        case .failed(let detail):
            state.remediationCount += 1
            state.remediationFailures += 1
            let exponent = min(state.remediationFailures - 1, 8)
            let delay = policy.remediationBackoffBase * pow(2, Double(exponent))
            state.nextRemediationAt = current.addingTimeInterval(max(policy.remediationCooldown, delay))
            state.observation = replacingReason(
                observation,
                NodeDependencyFailureReason(code: .remediationFailed, message: detail))
        }
        if let currentObservation = state.observation {
            state.observation = replacingCounters(
                currentObservation,
                remediationCount: state.remediationCount,
                restartCount: state.restartCount)
        }
        states[module.id] = state
    }

    private func replacingReason(
        _ observation: NodeDependencyObservation,
        _ reason: NodeDependencyFailureReason
    ) -> NodeDependencyObservation {
        NodeDependencyObservation(
            id: observation.id, role: observation.role,
            desiredState: observation.desiredState, ownership: observation.ownership,
            supervisorState: observation.supervisorState,
            installedVersion: observation.installedVersion, daemonVersion: observation.daemonVersion,
            compatibility: observation.compatibility, functionalState: observation.functionalState,
            checkedAt: observation.checkedAt, lastHealthyAt: observation.lastHealthyAt,
            reason: reason, consecutiveFailures: observation.consecutiveFailures,
            remediationCount: observation.remediationCount, restartCount: observation.restartCount,
            affectedCapabilities: observation.affectedCapabilities)
    }

    private func replacingCounters(
        _ observation: NodeDependencyObservation,
        remediationCount: Int,
        restartCount: Int
    ) -> NodeDependencyObservation {
        NodeDependencyObservation(
            id: observation.id, role: observation.role,
            desiredState: observation.desiredState, ownership: observation.ownership,
            supervisorState: observation.supervisorState,
            installedVersion: observation.installedVersion, daemonVersion: observation.daemonVersion,
            compatibility: observation.compatibility, functionalState: observation.functionalState,
            checkedAt: observation.checkedAt, lastHealthyAt: observation.lastHealthyAt,
            reason: observation.reason, consecutiveFailures: observation.consecutiveFailures,
            remediationCount: remediationCount, restartCount: restartCount,
            affectedCapabilities: observation.affectedCapabilities)
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
