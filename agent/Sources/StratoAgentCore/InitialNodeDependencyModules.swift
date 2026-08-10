import Foundation
import StratoShared

public enum SPIREIdentityHealth: Sendable, Equatable {
    case ready(expiresAt: Date)
    case unavailable(String)
}

public enum SPIREIdentitySource: Sendable, Equatable {
    case workloadAPI
    case files
}

public struct NodeDependencyFunctionalHealth: Sendable, Equatable {
    public let state: NodeDependencyFunctionalState
    public let reason: NodeDependencyFailureReason?

    public init(state: NodeDependencyFunctionalState, reason: NodeDependencyFailureReason? = nil) {
        self.state = state
        self.reason = reason
    }

    public static let healthy = NodeDependencyFunctionalHealth(state: .healthy)
    public static func unhealthy(
        _ message: String,
        code: NodeDependencyFailureCode = .functionalProbeFailed
    ) -> NodeDependencyFunctionalHealth {
        NodeDependencyFunctionalHealth(
            state: .unhealthy,
            reason: NodeDependencyFailureReason(code: code, message: message))
    }
}

public struct SPIRENodeDependencyModule: NodeDependencyModule {
    public let id = NodeDependencyID.spire
    public let role = NodeDependencyRole.identity
    public let dependencies: [NodeDependencyID] = []
    public let desiredState = NodeDependencyDesiredState.required
    public let ownership = NodeDependencyOwnership.observeOnly
    public let affectedCapabilities = [NodeCapability.workloadIdentity]

    private let systemd: any SystemdControlling
    private let source: SPIREIdentitySource
    private let version: @Sendable () async -> String?
    private let svid: @Sendable () async -> SPIREIdentityHealth
    private let now: @Sendable () -> Date

    public init(
        systemd: any SystemdControlling,
        source: SPIREIdentitySource = .workloadAPI,
        version: @escaping @Sendable () async -> String?,
        svid: @escaping @Sendable () async -> SPIREIdentityHealth,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.systemd = systemd
        self.source = source
        self.version = version
        self.svid = svid
        self.now = now
    }

    public func inspect() async -> NodeDependencyInspection {
        if source == .files {
            return identityInspection(
                supervisorState: .notApplicable,
                installedVersion: nil,
                identityHealth: await svid())
        }

        async let unit = systemd.inspect(unit: "spire-agent.service")
        async let installedVersion = version()
        async let identity = svid()
        let (supervisor, installed, identityHealth) = await (unit, installedVersion, identity)

        guard supervisor.supervisorState != .missing else {
            return NodeDependencyInspection(
                supervisorState: .missing, installedVersion: installed,
                compatibility: installed == nil ? .unknown : .compatible,
                functionalState: .unhealthy,
                reason: .init(code: .missingUnit, message: "spire-agent.service is not installed"))
        }
        guard supervisor.supervisorState == .active else {
            return NodeDependencyInspection(
                supervisorState: supervisor.supervisorState, installedVersion: installed,
                compatibility: installed == nil ? .unknown : .compatible,
                functionalState: .unhealthy,
                reason: .init(
                    code: supervisor.supervisorState == .failed ? .failedUnit : .inactiveUnit,
                    message: "spire-agent.service is \(supervisor.activeState)"))
        }
        guard installed != nil else {
            return NodeDependencyInspection(
                supervisorState: .active,
                compatibility: .unknown,
                functionalState: .unhealthy,
                reason: .init(code: .missingBinary, message: "spire-agent executable is not installed"))
        }

        return identityInspection(
            supervisorState: .active,
            installedVersion: installed,
            identityHealth: identityHealth)
    }

    private func identityInspection(
        supervisorState: NodeDependencySupervisorState,
        installedVersion: String?,
        identityHealth: SPIREIdentityHealth
    ) -> NodeDependencyInspection {
        switch identityHealth {
        case .unavailable(let detail):
            return NodeDependencyInspection(
                supervisorState: supervisorState, installedVersion: installedVersion,
                compatibility: .compatible, functionalState: .unhealthy,
                reason: .init(code: .functionalProbeFailed, message: detail))
        case .ready(let expiresAt):
            let remaining = expiresAt.timeIntervalSince(now())
            if remaining <= 0 {
                return NodeDependencyInspection(
                    supervisorState: supervisorState, installedVersion: installedVersion,
                    compatibility: .compatible, functionalState: .unhealthy,
                    reason: .init(code: .functionalProbeFailed, message: "the current X.509 SVID is expired"))
            }
            if remaining < 300 {
                return NodeDependencyInspection(
                    supervisorState: supervisorState, installedVersion: installedVersion,
                    compatibility: .compatible, functionalState: .degraded,
                    reason: .init(
                        code: .functionalProbeFailed,
                        message: "the current X.509 SVID expires in less than five minutes"))
            }
            return NodeDependencyInspection(
                supervisorState: supervisorState, installedVersion: installedVersion,
                compatibility: .compatible, functionalState: .healthy)
        }
    }
}

public struct LibvirtNodeDependencyModule: NodeDependencyModule {
    public let id = NodeDependencyID.libvirt
    public let role = NodeDependencyRole.compute
    public let dependencies: [NodeDependencyID] = []
    public let desiredState = NodeDependencyDesiredState.required
    public let ownership = NodeDependencyOwnership.observeOnly
    public let affectedCapabilities = [NodeCapability.qemuPlacement]

    private let systemd: any SystemdControlling
    private let installedVersion: @Sendable () async -> String?
    private let probe: @Sendable () async -> LibvirtProbe.Status

    public init(
        systemd: any SystemdControlling,
        installedVersion: @escaping @Sendable () async -> String? = { nil },
        probe: @escaping @Sendable () async -> LibvirtProbe.Status = { await LibvirtProbe.probe() }
    ) {
        self.systemd = systemd
        self.installedVersion = installedVersion
        self.probe = probe
    }

    public func inspect() async -> NodeDependencyInspection {
        async let unit = systemd.discoverFirst(units: ["virtqemud.socket", "libvirtd.socket"])
        async let clientVersion = installedVersion()
        async let probeStatus = probe()
        let (supervisor, installed, libvirt) = await (unit, clientVersion, probeStatus)
        switch libvirt {
        case .clientMissing:
            return NodeDependencyInspection(
                supervisorState: supervisor.supervisorState,
                installedVersion: installed,
                compatibility: .unknown, functionalState: .unhealthy,
                reason: .init(code: .missingBinary, message: "virsh is not installed"))
        case .unreachable(let detail):
            let state = supervisor.supervisorState
            return NodeDependencyInspection(
                supervisorState: state, installedVersion: installed,
                compatibility: .unknown, functionalState: .unhealthy,
                reason: .init(
                    code: state == .missing
                        ? .missingUnit
                        : state == .failed
                            ? .failedUnit
                            : state == .inactive ? .inactiveUnit : .functionalProbeFailed,
                    message: detail))
        case .unrecognizedOutput(let detail):
            return NodeDependencyInspection(
                supervisorState: supervisor.supervisorState,
                installedVersion: installed,
                compatibility: .unknown, functionalState: .unhealthy,
                reason: .init(code: .malformedOutput, message: detail))
        case .reachable(let daemonVersion):
            guard daemonVersion >= LibvirtProbe.minimumVersion else {
                return NodeDependencyInspection(
                    supervisorState: supervisor.supervisorState,
                    installedVersion: installed,
                    daemonVersion: daemonVersion.description,
                    compatibility: .incompatible, functionalState: .healthy,
                    reason: .init(
                        code: .incompatibleVersion,
                        message: "libvirt \(daemonVersion) is older than required \(LibvirtProbe.minimumVersion)"))
            }
            return NodeDependencyInspection(
                supervisorState: supervisor.supervisorState == .unknown ? .active : supervisor.supervisorState,
                installedVersion: installed,
                daemonVersion: daemonVersion.description,
                compatibility: .compatible, functionalState: .healthy)
        }
    }
}

public struct OVNOVSNodeDependencyModule: NodeDependencyModule {
    public let id = NodeDependencyID.ovnOvs
    public let role = NodeDependencyRole.networking
    public let dependencies: [NodeDependencyID] = []
    public let desiredState = NodeDependencyDesiredState.required
    public let ownership = NodeDependencyOwnership.observeOnly
    public let affectedCapabilities: [NodeCapability] = [
        .overlayNetworking, .sandboxNetworking, .networkResolver,
    ]

    private let systemd: any SystemdControlling
    private let ovsVersion: @Sendable () async -> String?
    private let ovnVersion: @Sendable () async -> String?
    private let functional: @Sendable () async -> NodeDependencyFunctionalHealth

    public init(
        systemd: any SystemdControlling,
        ovsVersion: @escaping @Sendable () async -> String?,
        ovnVersion: @escaping @Sendable () async -> String?,
        functional: @escaping @Sendable () async -> NodeDependencyFunctionalHealth
    ) {
        self.systemd = systemd
        self.ovsVersion = ovsVersion
        self.ovnVersion = ovnVersion
        self.functional = functional
    }

    public func inspect() async -> NodeDependencyInspection {
        async let ovsUnit = systemd.discoverFirst(
            units: ["openvswitch-switch.service", "ovs-vswitchd.service"])
        async let ovnUnit = systemd.discoverFirst(
            units: ["ovn-host.service", "ovn-controller.service"])
        async let installedOVS = ovsVersion()
        async let installedOVN = ovnVersion()
        async let live = functional()
        let (ovsSupervisor, ovnSupervisor, ovs, ovn, health) = await (
            ovsUnit, ovnUnit, installedOVS, installedOVN, live
        )
        let supervisors = [ovsSupervisor.supervisorState, ovnSupervisor.supervisorState]
        let aggregate: NodeDependencySupervisorState = {
            if supervisors.contains(.missing) { return .missing }
            if supervisors.contains(.failed) { return .failed }
            if supervisors.contains(.inactive) { return .inactive }
            if supervisors.contains(.activating) { return .activating }
            if supervisors.allSatisfy({ $0 == .active }) { return .active }
            return .unknown
        }()
        let combinedVersion = [ovs.map { "OVS \($0)" }, ovn.map { "OVN \($0)" }]
            .compactMap { $0 }.joined(separator: ", ")

        if ovs == nil || ovn == nil {
            return NodeDependencyInspection(
                supervisorState: aggregate,
                installedVersion: combinedVersion.isEmpty ? nil : combinedVersion,
                compatibility: .unknown, functionalState: .unhealthy,
                reason: .init(
                    code: .missingBinary,
                    message: "OVS or OVN version executable is missing or returned malformed output"))
        }
        if aggregate != .active {
            return NodeDependencyInspection(
                supervisorState: aggregate, installedVersion: combinedVersion,
                compatibility: .compatible, functionalState: .unhealthy,
                reason: .init(
                    code: aggregate == .missing
                        ? .missingUnit
                        : aggregate == .failed ? .failedUnit : .inactiveUnit,
                    message: "OVS/OVN supervisor is \(aggregate.rawValue)"))
        }
        return NodeDependencyInspection(
            supervisorState: .active, installedVersion: combinedVersion,
            compatibility: .compatible, functionalState: health.state,
            reason: health.reason)
    }
}

public struct SimulatedNodeDependencyModule: NodeDependencyModule {
    public let id: NodeDependencyID
    public let role: NodeDependencyRole
    public let dependencies: [NodeDependencyID] = []
    public let desiredState = NodeDependencyDesiredState.required
    public let ownership = NodeDependencyOwnership.observeOnly
    public let affectedCapabilities: [NodeCapability]

    public init(id: NodeDependencyID, role: NodeDependencyRole, affectedCapabilities: [NodeCapability]) {
        self.id = id
        self.role = role
        self.affectedCapabilities = affectedCapabilities
    }

    public func inspect() async -> NodeDependencyInspection {
        NodeDependencyInspection(
            supervisorState: .notApplicable, installedVersion: "simulation",
            compatibility: .compatible, functionalState: .healthy)
    }
}
