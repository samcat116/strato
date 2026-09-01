import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Node dependency manager")
struct NodeDependencyManagerTests {
    private let healthy = NodeDependencyInspection(
        supervisorState: .active,
        compatibility: .compatible,
        functionalState: .healthy)
    private let failed = NodeDependencyInspection(
        supervisorState: .active,
        compatibility: .compatible,
        functionalState: .unhealthy,
        reason: .init(code: .functionalProbeFailed, message: "probe failed"))

    @Test("Ceph client health advertises only the Ceph volume capability")
    func cephClientCapability() async {
        let healthy = CephClientNodeDependencyModule(version: { "ceph version 19.2.1" })
        let inspection = await healthy.inspect()
        #expect(inspection.supervisorState == .notApplicable)
        #expect(inspection.compatibility == .compatible)
        #expect(inspection.functionalState == .healthy)
        #expect(healthy.affectedCapabilities == [.cephVolumes])

        let missing = CephClientNodeDependencyModule(version: { nil })
        let absent = await missing.inspect()
        #expect(absent.supervisorState == .missing)
        #expect(absent.reason?.code == .missingBinary)
        #expect(absent.functionalState == .unhealthy)

        let libvirt115 = CephClientNodeDependencyModule(
            version: { "ceph version 19.2.1" },
            libvirt: { .reachable(.init(major: 11, minor: 5, patch: 0)) })
        let incompatible = await libvirt115.inspect()
        #expect(incompatible.compatibility == .incompatible)
        #expect(incompatible.functionalState == .unhealthy)
        #expect(incompatible.reason?.code == .incompatibleVersion)
        #expect(incompatible.reason?.message.contains("11.6.0") == true)

        let libvirt116 = CephClientNodeDependencyModule(
            version: { "ceph version 19.2.1" },
            libvirt: { .reachable(.init(major: 11, minor: 6, patch: 0)) })
        #expect(await libvirt116.inspect().isHealthy)

        // A Firecracker-only host uses krbd. Even if an old libvirt daemon is
        // installed and reachable for unrelated host tooling, it is not part
        // of the configured attach path and cannot withdraw Ceph placement.
        let firecrackerOnly = CephClientNodeDependencyModule(
            version: { "ceph version 19.2.1" },
            libvirt: { .reachable(.init(major: 11, minor: 5, patch: 0)) },
            qemuAttachmentsEnabled: false)
        #expect(await firecrackerOnly.inspect().isHealthy)

        let firecrackerWithoutLibvirt = CephClientNodeDependencyModule(
            version: { "ceph version 19.2.1" },
            libvirt: { .unreachable("no libvirt socket") },
            qemuAttachmentsEnabled: false)
        #expect(await firecrackerWithoutLibvirt.inspect().isHealthy)
    }

    @Test("The registry rejects missing dependencies and cycles")
    func validatesGraph() throws {
        let missing = module(.libvirt, dependencies: [.spire], inspection: healthy)
        #expect(throws: NodeDependencyGraphError.self) {
            try NodeDependencyManager(modules: [missing], logger: Logger(label: "test"))
        }

        let a = module(.spire, dependencies: [.libvirt], inspection: healthy)
        let b = module(.libvirt, dependencies: [.spire], inspection: healthy)
        #expect(throws: NodeDependencyGraphError.self) {
            try NodeDependencyManager(modules: [a, b], logger: Logger(label: "test"))
        }
    }

    @Test("A failed prerequisite blocks its dependant inspection")
    func blocksDependants() async throws {
        let downstream = CallCounter()
        let manager = try NodeDependencyManager(
            modules: [
                module(.spire, inspection: failed),
                ClosureNodeDependencyModule(
                    id: .libvirt, role: .compute, dependencies: [.spire],
                    desiredState: .required, ownership: .observeOnly,
                    affectedCapabilities: [.qemuPlacement]
                ) {
                    await downstream.increment()
                    return self.healthy
                },
            ],
            policy: .init(functionalFailureThreshold: 1),
            logger: Logger(label: "test"))

        let observations = await manager.refresh()
        #expect(await downstream.value == 0)
        #expect(observations.first { $0.id == .libvirt }?.reason?.code == .dependencyFailed)
    }

    @Test("Functional hysteresis delays failure and confirms recovery")
    func hysteresis() async throws {
        let sequence = InspectionSequence([healthy, failed, failed, healthy, healthy])
        let manager = try NodeDependencyManager(
            modules: [
                ClosureNodeDependencyModule(
                    id: .libvirt, role: .compute, desiredState: .required,
                    ownership: .observeOnly, affectedCapabilities: [.qemuPlacement]
                ) { await sequence.next() }
            ],
            policy: .init(functionalFailureThreshold: 2, recoverySuccessThreshold: 2),
            logger: Logger(label: "test"))

        #expect(await manager.refresh().first?.functionalState == .healthy)
        let degraded = await manager.refresh().first
        #expect(degraded?.functionalState == .degraded)
        #expect(degraded?.consecutiveFailures == 1)
        #expect(await manager.refresh().first?.functionalState == .unhealthy)
        #expect(await manager.refresh().first?.functionalState == .starting)
        #expect(await manager.refresh().first?.functionalState == .healthy)
    }

    @Test("Explicit degraded inspections remain eligible without accumulating failures")
    func preservesExplicitDegradedState() async throws {
        let intentionalDegradation = NodeDependencyInspection(
            supervisorState: .active,
            compatibility: .compatible,
            functionalState: .degraded,
            reason: .init(
                code: .functionalProbeFailed,
                message: "the current X.509 SVID expires in less than five minutes"))
        let sequence = InspectionSequence([healthy, intentionalDegradation, intentionalDegradation])
        let manager = try NodeDependencyManager(
            modules: [
                ClosureNodeDependencyModule(
                    id: .spire, role: .identity, desiredState: .required,
                    ownership: .observeOnly, affectedCapabilities: [.workloadIdentity]
                ) { await sequence.next() }
            ],
            policy: .init(functionalFailureThreshold: 2),
            logger: Logger(label: "test"))

        let healthyObservation = try #require(await manager.refresh().first)
        let firstDegraded = try #require(await manager.refresh().first)
        let secondDegraded = try #require(await manager.refresh().first)

        #expect(healthyObservation.functionalState == .healthy)
        #expect(firstDegraded.functionalState == .degraded)
        #expect(secondDegraded.functionalState == .degraded)
        #expect(firstDegraded.consecutiveFailures == 0)
        #expect(secondDegraded.consecutiveFailures == 0)
        #expect(secondDegraded.reason == intentionalDegradation.reason)
        #expect(secondDegraded.lastHealthyAt == healthyObservation.lastHealthyAt)
        #expect(secondDegraded.permitsDependentWork)
    }

    @Test("A module inspection cannot hold the manager past its time budget")
    func inspectionTimeout() async throws {
        let manager = try NodeDependencyManager(
            modules: [
                ClosureNodeDependencyModule(
                    id: .libvirt, role: .compute, desiredState: .required,
                    ownership: .observeOnly, affectedCapabilities: [.qemuPlacement]
                ) {
                    try? await Task.sleep(for: .seconds(60))
                    return self.healthy
                }
            ],
            policy: .init(functionalFailureThreshold: 1, inspectionTimeoutSeconds: 1),
            logger: Logger(label: "test"))

        let observation = await manager.refresh().first
        #expect(observation?.functionalState == .unhealthy)
        #expect(observation?.reason?.code == .commandTimedOut)
    }

    @Test("Observe-only ownership never receives remediation authority")
    func observeOnlyCannotRemediate() async throws {
        let reconciles = CallCounter()
        let module = ClosureNodeDependencyModule(
            id: .libvirt, role: .compute, desiredState: .required,
            ownership: .observeOnly, affectedCapabilities: [.qemuPlacement],
            inspect: { self.failed },
            ensureRunning: { _ in
                await reconciles.increment()
                return .remediated(restarted: true)
            })
        let manager = try NodeDependencyManager(
            modules: [module], policy: .init(functionalFailureThreshold: 1),
            logger: Logger(label: "test"))

        await manager.refresh(allowRemediation: true)
        #expect(await reconciles.value == 0)
    }

    @Test("Authorized restarts stop at the restart budget")
    func restartBudget() async throws {
        let reconciles = CallCounter()
        let module = ClosureNodeDependencyModule(
            id: .libvirt, role: .compute, desiredState: .required,
            ownership: .ensureRunning, affectedCapabilities: [.qemuPlacement],
            inspect: { self.failed },
            ensureRunning: { _ in
                await reconciles.increment()
                return .remediated(restarted: true)
            })
        let manager = try NodeDependencyManager(
            modules: [module],
            policy: .init(
                functionalFailureThreshold: 1, remediationCooldown: 0,
                remediationBackoffBase: 0, restartBudget: 1,
                restartBudgetWindow: 3600),
            logger: Logger(label: "test"))

        await manager.refresh(allowRemediation: true)
        let second = await manager.refresh(allowRemediation: true).first
        #expect(await reconciles.value == 1)
        #expect(second?.restartCount == 1)
        #expect((await manager.observations().first)?.reason?.code == .remediationBudgetExhausted)
    }

    @Test("Reconcile ownership uses the configuration path, not ensure-running")
    func reconcileOwnershipUsesConfigurationPath() async throws {
        let ensureCalls = CallCounter()
        let reconcileCalls = CallCounter()
        let module = ClosureNodeDependencyModule(
            id: .libvirt, role: .compute, desiredState: .required,
            ownership: .reconcile, affectedCapabilities: [.qemuPlacement],
            inspect: { self.failed },
            ensureRunning: { _ in
                await ensureCalls.increment()
                return .remediated(restarted: true)
            },
            reconcile: { _ in
                await reconcileCalls.increment()
                return .remediated(restarted: false)
            })
        let manager = try NodeDependencyManager(
            modules: [module], policy: .init(functionalFailureThreshold: 1),
            logger: Logger(label: "test"))

        await manager.refresh(allowRemediation: true)
        #expect(await ensureCalls.value == 0)
        #expect(await reconcileCalls.value == 1)
    }

    @Test("Receipt freshness, not the agent check clock, gates new work")
    func stalenessAndDegradedEligibility() {
        let checked = Date(timeIntervalSince1970: 10_000)
        let received = Date(timeIntervalSince1970: 20_000)
        let observation = NodeDependencyObservation(
            id: .libvirt, role: .compute, desiredState: .required,
            ownership: .observeOnly, supervisorState: .active,
            compatibility: .compatible, functionalState: .degraded,
            checkedAt: checked, affectedCapabilities: [.qemuPlacement])
        #expect(
            observation.allowsNewWork(
                receivedAt: received, at: received.addingTimeInterval(59), staleAfter: 60))
        #expect(
            !observation.allowsNewWork(
                receivedAt: received, at: received.addingTimeInterval(61), staleAfter: 60))
    }

    @Test("Dependency commands require absolute paths and systemd output is typed")
    func hostAdapterSafety() throws {
        #expect(throws: BoundedHostCommandError.self) {
            try BoundedHostCommand(executable: "systemctl", arguments: [])
        }
        let parsed = SystemdHostAdapter.parse(
            unit: "libvirtd.socket",
            output: "LoadState=loaded\nActiveState=active\nSubState=listening\nUnitFileState=enabled\n")
        #expect(parsed?.supervisorState == .active)
        #expect(SystemdHostAdapter.parse(unit: "bad", output: "garbage") == nil)
    }

    @Test("Systemd discovery prefers an active alternative over the first loaded unit")
    func systemdDiscoveryPrefersActiveAlternative() async {
        let executor = SystemctlOutputExecutor(outputs: [
            "virtqemud.socket":
                "LoadState=loaded\nActiveState=inactive\nSubState=dead\nUnitFileState=enabled\n",
            "libvirtd.socket":
                "LoadState=loaded\nActiveState=active\nSubState=listening\nUnitFileState=enabled\n",
        ])
        let adapter = SystemdHostAdapter(executor: executor)

        let observation = await adapter.discoverFirst(
            units: ["virtqemud.socket", "libvirtd.socket"])

        #expect(observation.name == "libvirtd.socket")
        #expect(observation.supervisorState == .active)
    }

    @Test("Systemd discovery preserves inspection failure instead of reporting a missing unit")
    func systemdDiscoveryPreservesInspectionFailure() async {
        let executor = SystemctlOutputExecutor(outputs: [
            "virtqemud.socket": "garbage",
            "libvirtd.socket": "garbage",
        ])
        let adapter = SystemdHostAdapter(executor: executor)

        let observation = await adapter.discoverFirst(
            units: ["virtqemud.socket", "libvirtd.socket"])

        #expect(observation.loadState == "unknown")
        #expect(observation.supervisorState == .unknown)
    }

    @Test(
        "Definitive systemd load failures are categorical",
        arguments: ["masked", "bad-setting", "error"])
    func definitiveSystemdLoadFailure(_ loadState: String) {
        let observation = SystemdUnitObservation(
            name: "spire-agent.service", loadState: loadState, activeState: "inactive",
            subState: "dead", unitFileState: "masked")

        #expect(observation.supervisorState == .failed)
    }

    @Test(
        "Inconclusive systemd load states remain unknown",
        arguments: ["unknown", "stub", "merged"])
    func inconclusiveSystemdLoadState(_ loadState: String) {
        let observation = SystemdUnitObservation(
            name: "spire-agent.service", loadState: loadState, activeState: "inactive",
            subState: "dead", unitFileState: "unknown")

        #expect(observation.supervisorState == .unknown)
    }

    @Test("Systemd discovery preserves a masked unit")
    func systemdDiscoveryPreservesMaskedUnit() async {
        let executor = SystemctlOutputExecutor(outputs: [
            "virtqemud.socket":
                "LoadState=masked\nActiveState=inactive\nSubState=dead\nUnitFileState=masked\n",
            "libvirtd.socket": "LoadState=not-found\nActiveState=inactive\n",
        ])
        let adapter = SystemdHostAdapter(executor: executor)

        let observation = await adapter.discoverFirst(
            units: ["virtqemud.socket", "libvirtd.socket"])

        #expect(observation.name == "virtqemud.socket")
        #expect(observation.loadState == "masked")
        #expect(observation.supervisorState == .failed)
    }

    private func module(
        _ id: NodeDependencyID,
        dependencies: [NodeDependencyID] = [],
        inspection: NodeDependencyInspection
    ) -> any NodeDependencyModule {
        ClosureNodeDependencyModule(
            id: id, role: id == .spire ? .identity : .compute,
            dependencies: dependencies, desiredState: .required,
            ownership: .observeOnly, affectedCapabilities: []
        ) { inspection }
    }
}

@Suite("Initial dependency modules")
struct InitialNodeDependencyModuleTests {
    private let active = SystemdUnitObservation(
        name: "unit", loadState: "loaded", activeState: "active",
        subState: "running", unitFileState: "enabled")

    @Test("SPIRE distinguishes a missing unit and near-expiry SVID")
    func spireStates() async {
        let missing = SPIRENodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: .missing("spire-agent.service")),
            version: { "1.12.4" },
            svid: { .unavailable("Workload API socket is unavailable") })
        #expect(await missing.inspect().reason?.code == .missingUnit)

        let missingBinary = SPIRENodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: active),
            version: { nil },
            svid: { .ready(expiresAt: Date().addingTimeInterval(3600)) })
        #expect(await missingBinary.inspect().reason?.code == .missingBinary)

        let now = Date(timeIntervalSince1970: 20_000)
        let expiring = SPIRENodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: active),
            version: { "1.12.4" },
            svid: { .ready(expiresAt: now.addingTimeInterval(120)) },
            now: { now })
        let observation = await expiring.inspect()
        #expect(observation.functionalState == .degraded)
        #expect(observation.reason?.code == .functionalProbeFailed)
    }

    @Test("Externally supervised Workload API does not require a local SPIRE installation")
    func externalWorkloadAPIState() async throws {
        let externalIdentity = SPIRENodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: .missing("spire-agent.service")),
            source: .workloadAPI,
            version: { nil },
            svid: { .ready(expiresAt: Date().addingTimeInterval(3600)) })
        let manager = try NodeDependencyManager(
            modules: [externalIdentity], logger: Logger(label: "test"))

        let observation = try #require(await manager.refresh().first)
        #expect(observation.supervisorState == .notApplicable)
        #expect(observation.installedVersion == nil)
        #expect(observation.compatibility == .compatible)
        #expect(observation.functionalState == .healthy)
        #expect(observation.reason == nil)
        #expect(observation.permitsDependentWork)
    }

    @Test("Container install mode makes the Workload API authoritative without systemd")
    func containerWorkloadAPIState() async throws {
        let unavailableSystemd = SystemdUnitObservation(
            name: "spire-agent.service", loadState: "unknown", activeState: "unknown",
            subState: "unknown", unitFileState: "unknown")
        let containerIdentity = SPIRENodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: unavailableSystemd),
            source: .workloadAPI,
            installMode: .container(marker: "STRATO_INSTALL_MODE"),
            version: { nil },
            svid: { .ready(expiresAt: Date().addingTimeInterval(3600)) })
        let manager = try NodeDependencyManager(
            modules: [containerIdentity], logger: Logger(label: "test"))

        let observation = try #require(await manager.refresh().first)
        #expect(observation.supervisorState == .notApplicable)
        #expect(observation.installedVersion == nil)
        #expect(observation.compatibility == .compatible)
        #expect(observation.functionalState == .healthy)
        #expect(observation.reason == nil)
        #expect(observation.permitsDependentWork)
    }

    @Test("A disabled SPIRE unit remains systemd-owned when it becomes inactive")
    func disabledSPIREUnitRemainsSystemdOwned() async throws {
        let inactive = SystemdUnitObservation(
            name: "spire-agent.service", loadState: "loaded", activeState: "inactive",
            subState: "dead", unitFileState: "disabled")
        let cachedIdentity = SPIRENodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: inactive),
            source: .workloadAPI,
            version: { "1.12.4" },
            svid: { .ready(expiresAt: Date().addingTimeInterval(3600)) })
        let manager = try NodeDependencyManager(
            modules: [cachedIdentity], logger: Logger(label: "test"))

        let observation = try #require(await manager.refresh().first)
        #expect(observation.ownership == .observeOnly)
        #expect(observation.supervisorState == .inactive)
        #expect(observation.compatibility == .compatible)
        #expect(observation.functionalState == .unhealthy)
        #expect(observation.reason?.code == .inactiveUnit)
        #expect(!observation.permitsDependentWork)
    }

    @Test("Systemd-managed SPIRE requires both its unit and Workload API")
    func systemdManagedSPIREState() async throws {
        let healthy = SPIRENodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: active),
            version: { "1.12.4" },
            svid: { .ready(expiresAt: Date().addingTimeInterval(3600)) })
        let healthyManager = try NodeDependencyManager(
            modules: [healthy], logger: Logger(label: "test"))

        let healthyObservation = try #require(await healthyManager.refresh().first)
        #expect(healthyObservation.supervisorState == .active)
        #expect(healthyObservation.functionalState == .healthy)
        #expect(healthyObservation.permitsDependentWork)

        let stoppedUnits: [(SystemdUnitObservation, NodeDependencyFailureCode)] = [
            (
                SystemdUnitObservation(
                    name: "spire-agent.service", loadState: "loaded", activeState: "inactive",
                    subState: "dead", unitFileState: "enabled"),
                .inactiveUnit
            ),
            (
                SystemdUnitObservation(
                    name: "spire-agent.service", loadState: "loaded", activeState: "failed",
                    subState: "failed", unitFileState: "enabled"),
                .failedUnit
            ),
        ]
        for (unit, expectedReason) in stoppedUnits {
            let cachedIdentity = SPIRENodeDependencyModule(
                systemd: FakeSystemd(defaultObservation: unit),
                version: { "1.12.4" },
                svid: { .ready(expiresAt: Date().addingTimeInterval(3600)) })
            let stoppedManager = try NodeDependencyManager(
                modules: [cachedIdentity], logger: Logger(label: "test"))

            let stoppedObservation = try #require(await stoppedManager.refresh().first)
            #expect(stoppedObservation.functionalState == .unhealthy)
            #expect(stoppedObservation.reason?.code == expectedReason)
            #expect(!stoppedObservation.permitsDependentWork)
        }
    }

    @Test("Failed systemd inspection does not classify SPIRE as externally supervised")
    func failedSystemdInspectionDoesNotBypassSPIRESupervision() async throws {
        let systemd = SystemdHostAdapter(
            executor: SystemctlOutputExecutor(outputs: [
                "spire-agent.service": "garbage"
            ]))
        let cachedIdentity = SPIRENodeDependencyModule(
            systemd: systemd,
            version: { "1.12.4" },
            svid: { .ready(expiresAt: Date().addingTimeInterval(3600)) })

        let inspection = await cachedIdentity.inspect()
        #expect(inspection.supervisorState == .unknown)
        #expect(inspection.functionalState == .unhealthy)
        #expect(inspection.reason?.code == .functionalProbeFailed)

        let manager = try NodeDependencyManager(
            modules: [cachedIdentity], logger: Logger(label: "test"))
        _ = await manager.refresh()
        let observation = try #require(await manager.refresh().first)
        #expect(observation.functionalState == .unhealthy)
        #expect(!observation.permitsDependentWork)
    }

    @Test("Masked systemd units gate SPIRE identity and libvirt placement immediately")
    func maskedSystemdUnitsGateDependentWork() async throws {
        let maskedSPIRE = SystemdUnitObservation(
            name: "spire-agent.service", loadState: "masked", activeState: "inactive",
            subState: "dead", unitFileState: "masked")
        let identity = SPIRENodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: maskedSPIRE),
            version: { "1.12.4" },
            svid: { .ready(expiresAt: Date().addingTimeInterval(3600)) })
        let identityManager = try NodeDependencyManager(
            modules: [identity], logger: Logger(label: "test"))

        let identityObservation = try #require(await identityManager.refresh().first)
        #expect(identityObservation.supervisorState == .failed)
        #expect(identityObservation.functionalState == .unhealthy)
        #expect(identityObservation.reason?.code == .failedUnit)
        #expect(!identityObservation.permitsDependentWork)

        let systemd = SystemdHostAdapter(
            executor: SystemctlOutputExecutor(outputs: [
                "virtqemud.socket":
                    "LoadState=masked\nActiveState=inactive\nSubState=dead\nUnitFileState=masked\n",
                "libvirtd.socket": "LoadState=not-found\nActiveState=inactive\n",
            ]))
        let libvirt = LibvirtNodeDependencyModule(
            systemd: systemd,
            probe: { .reachable(.init(major: 11, minor: 5, patch: 0)) })
        let libvirtManager = try NodeDependencyManager(
            modules: [libvirt], logger: Logger(label: "test"))

        let libvirtObservation = try #require(await libvirtManager.refresh().first)
        #expect(libvirtObservation.supervisorState == .failed)
        #expect(libvirtObservation.functionalState == .unhealthy)
        #expect(libvirtObservation.reason?.code == .failedUnit)
        #expect(!libvirtObservation.permitsDependentWork)
    }

    @Test("File-based SPIFFE does not require a local SPIRE service or binary")
    func fileSPIFFEState() async {
        let fileIdentity = SPIRENodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: .missing("spire-agent.service")),
            source: .files,
            version: { nil },
            svid: { .ready(expiresAt: Date().addingTimeInterval(3600)) })

        let observation = await fileIdentity.inspect()
        #expect(observation.supervisorState == .notApplicable)
        #expect(observation.installedVersion == nil)
        #expect(observation.compatibility == .compatible)
        #expect(observation.functionalState == .healthy)
        #expect(observation.reason == nil)
    }

    @Test("Libvirt enforces the exact version boundary")
    func libvirtVersionBoundary() async {
        let systemd = FakeSystemd(defaultObservation: active)
        let compatible = LibvirtNodeDependencyModule(
            systemd: systemd,
            probe: {
                .reachable(.init(major: 11, minor: 5, patch: 0))
            })
        #expect(await compatible.inspect().compatibility == .compatible)

        let old = LibvirtNodeDependencyModule(
            systemd: systemd,
            probe: {
                .reachable(.init(major: 11, minor: 4, patch: 99))
            })
        let oldInspection = await old.inspect()
        #expect(oldInspection.compatibility == .incompatible)
        #expect(oldInspection.reason?.code == .incompatibleVersion)
    }

    @Test("Reachable externally supervised libvirt remains placement eligible")
    func externallySupervisedLibvirt() async throws {
        let module = LibvirtNodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: .missing("virtqemud.socket")),
            probe: { .reachable(.init(major: 11, minor: 5, patch: 0)) })
        let manager = try NodeDependencyManager(
            modules: [module], logger: Logger(label: "test"))

        let observation = await manager.refresh().first
        #expect(observation?.supervisorState == .notApplicable)
        #expect(observation?.compatibility == .compatible)
        #expect(observation?.functionalState == .healthy)
        #expect(observation?.permitsDependentWork == true)
    }

    @Test("Systemd-managed libvirt requires its enabled socket unit to be active")
    func systemdManagedLibvirtState() async throws {
        let stoppedUnits: [(SystemdUnitObservation, NodeDependencyFailureCode)] = [
            (
                SystemdUnitObservation(
                    name: "virtqemud.socket", loadState: "loaded", activeState: "inactive",
                    subState: "dead", unitFileState: "enabled"),
                .inactiveUnit
            ),
            (
                SystemdUnitObservation(
                    name: "virtqemud.socket", loadState: "loaded", activeState: "failed",
                    subState: "failed", unitFileState: "enabled"),
                .failedUnit
            ),
        ]

        for (unit, expectedReason) in stoppedUnits {
            let locallyStopped = LibvirtNodeDependencyModule(
                systemd: FakeSystemd(defaultObservation: unit),
                probe: { .reachable(.init(major: 11, minor: 5, patch: 0)) })
            let manager = try NodeDependencyManager(
                modules: [locallyStopped], logger: Logger(label: "test"))

            let observation = try #require(await manager.refresh().first)
            #expect(observation.supervisorState == unit.supervisorState)
            #expect(observation.functionalState == .unhealthy)
            #expect(observation.reason?.code == expectedReason)
            #expect(!observation.permitsDependentWork)
        }
    }

    @Test("Libvirt distinguishes malformed output and an inactive supervisor")
    func libvirtFailures() async {
        let malformed = LibvirtNodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: active),
            probe: { .unrecognizedOutput("not a version") })
        #expect(await malformed.inspect().reason?.code == .malformedOutput)

        let inactive = SystemdUnitObservation(
            name: "virtqemud.socket", loadState: "loaded", activeState: "inactive",
            subState: "dead", unitFileState: "enabled")
        let stopped = LibvirtNodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: inactive),
            probe: { .unreachable("connection refused") })
        #expect(await stopped.inspect().reason?.code == .inactiveUnit)
    }

    @Test("OVN and OVS require both versions, units, and functional health")
    func ovnAggregate() async {
        let missingBinary = OVNOVSNodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: active),
            ovsVersion: { "3.5.0" }, ovnVersion: { nil },
            functional: { .healthy })
        #expect(await missingBinary.inspect().reason?.code == .missingBinary)

        let timeout = OVNOVSNodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: active),
            ovsVersion: { "3.5.0" }, ovnVersion: { "25.03.0" },
            functional: { .unhealthy("controller timed out", code: .commandTimedOut) })
        let timeoutInspection = await timeout.inspect()
        #expect(timeoutInspection.functionalState == .unhealthy)
        #expect(timeoutInspection.reason?.code == .commandTimedOut)
    }

    @Test("A missing optional OVN diagnostic remains healthy and visible")
    func missingOVNDiagnosticIsAdvisory() async {
        let module = OVNOVSNodeDependencyModule(
            systemd: FakeSystemd(defaultObservation: active),
            ovsVersion: { "3.5.0" }, ovnVersion: { "25.03.0" },
            functional: {
                .advisory(
                    "ovn-appctl is missing; ovn-controller connection status cannot be verified",
                    code: .missingBinary)
            })

        let inspection = await module.inspect()

        #expect(inspection.functionalState == .healthy)
        #expect(inspection.reason?.code == .missingBinary)
        #expect(inspection.isHealthy)
    }
}

@Suite("Dependency probe descriptor stress", .serialized)
struct DependencyProbeDescriptorStressTests {
    // Each refresh launches three libvirt and five OVN/OVS commands. This runs
    // 1,200 subprocesses, well past the old 1024-descriptor failure point.
    private let refreshIterations = 150

    @Test("Libvirt and OVN observations stay healthy across repeated commands")
    func repeatedCommandObservationsRemainHealthy() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("strato-dependency-probe-stress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let systemctl = directory.appendingPathComponent("systemctl")
        try makeExecutable(
            at: systemctl,
            body: """
                printf 'LoadState=loaded\\nActiveState=active\\nSubState=running\\nUnitFileState=enabled\\n'
                """)
        try makeExecutable(
            at: directory.appendingPathComponent("virsh"),
            body: "printf 'Running against daemon: 12.0.0\\n'")

        let executor = NodeDependencyCommandExecutor()
        let systemd = SystemdHostAdapter(executor: executor, executable: systemctl.path)
        let libvirt = LibvirtNodeDependencyModule(
            systemd: systemd,
            installedVersion: { await commandOutput(executor, value: "12.0.0") },
            probe: {
                await LibvirtProbe.probe(
                    searchPath: directory.path, timeout: .seconds(2))
            })
        let networking = OVNOVSNodeDependencyModule(
            systemd: systemd,
            ovsVersion: { await commandOutput(executor, value: "3.5.0") },
            ovnVersion: { await commandOutput(executor, value: "25.03.0") },
            functional: { await commandHealth(executor) })
        let manager = try NodeDependencyManager(
            modules: [libvirt, networking],
            policy: .init(functionalFailureThreshold: 1),
            logger: Logger(label: "test.dependency-probe-descriptor-stress"))

        for iteration in 0..<refreshIterations {
            let observations = await manager.refresh()
            let libvirtObservation = try #require(
                observations.first { $0.id == .libvirt })
            let networkingObservation = try #require(
                observations.first { $0.id == .ovnOvs })

            try #require(
                libvirtObservation.functionalState == .healthy,
                "libvirt became unhealthy after refresh \(iteration + 1)")
            try #require(
                networkingObservation.functionalState == .healthy,
                "OVN/OVS became unhealthy after refresh \(iteration + 1)")
            #expect(libvirtObservation.permitsDependentWork)
            #expect(networkingObservation.permitsDependentWork)
        }
    }

    private func makeExecutable(at url: URL, body: String) throws {
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private func commandOutput(
    _ executor: NodeDependencyCommandExecutor,
    value: String
) async -> String? {
    do {
        let result = try await executor.execute(
            try BoundedHostCommand(executable: "/bin/echo", arguments: [value]))
        guard result.terminationStatus == 0 else { return nil }
        return String(data: result.standardOutput, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}

private func commandHealth(
    _ executor: NodeDependencyCommandExecutor
) async -> NodeDependencyFunctionalHealth {
    do {
        let result = try await executor.execute(
            try BoundedHostCommand(executable: "/bin/echo", arguments: ["healthy"]))
        guard result.terminationStatus == 0 else {
            return .unhealthy("functional probe exited \(result.terminationStatus)")
        }
        return .healthy
    } catch {
        return .unhealthy("functional probe failed: \(error)")
    }
}

private actor CallCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor InspectionSequence {
    private var values: [NodeDependencyInspection]
    init(_ values: [NodeDependencyInspection]) { self.values = values }
    func next() -> NodeDependencyInspection { values.removeFirst() }
}

private struct SystemctlOutputExecutor: NodeDependencyCommandExecuting {
    let outputs: [String: String]

    func execute(_ command: BoundedHostCommand) async throws -> ProcessResult {
        let unit = command.arguments.count > 1 ? command.arguments[1] : ""
        let output = outputs[unit] ?? "LoadState=not-found\nActiveState=inactive\n"
        return ProcessResult(
            terminationStatus: 0,
            standardOutput: Data(output.utf8),
            standardError: Data())
    }
}

private struct FakeSystemd: SystemdControlling {
    let observations: [String: SystemdUnitObservation]
    let defaultObservation: SystemdUnitObservation

    init(
        observations: [String: SystemdUnitObservation] = [:],
        defaultObservation: SystemdUnitObservation
    ) {
        self.observations = observations
        self.defaultObservation = defaultObservation
    }

    func inspect(unit: String) async -> SystemdUnitObservation {
        observations[unit] ?? defaultObservation
    }

    func discoverFirst(units: [String]) async -> SystemdUnitObservation {
        for unit in units {
            let value = observations[unit] ?? defaultObservation
            if value.loadState == "loaded" { return value }
        }
        return .missing(units.first ?? "unknown")
    }

    func enable(unit: String) async throws {}
    func start(unit: String) async throws {}
    func restart(unit: String) async throws {}
}

extension SystemdUnitObservation {
    fileprivate static func missing(_ name: String) -> SystemdUnitObservation {
        SystemdUnitObservation(
            name: name, loadState: "not-found", activeState: "inactive",
            subState: "dead", unitFileState: "unknown")
    }
}
