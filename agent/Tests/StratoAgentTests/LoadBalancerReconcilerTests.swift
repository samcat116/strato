import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Load Balancer Reconciler")
struct LoadBalancerReconcilerTests {
    private let vipNetworkID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private let backendNetworkID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private let loadBalancerID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    private let backendID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    private let vmID = UUID(uuidString: "00000000-0000-0000-0000-000000000401")!

    private func desired(
        healthCheckEnabled: Bool = true,
        listeners: [DesiredLoadBalancerListener]? = nil,
        backends: [DesiredLoadBalancerBackend]? = nil
    ) -> DesiredLoadBalancer {
        DesiredLoadBalancer(
            id: loadBalancerID,
            name: "api",
            vip: "10.0.0.10",
            protocolName: "tcp",
            generation: 7,
            healthCheck: DesiredLoadBalancerHealthCheck(
                enabled: healthCheckEnabled,
                intervalSeconds: 5,
                timeoutSeconds: 2,
                successThreshold: 2,
                failureThreshold: 3),
            listeners: listeners ?? [
                DesiredLoadBalancerListener(id: UUID(), port: 443, backendPort: 6443)
            ],
            backends: backends ?? [
                DesiredLoadBalancerBackend(
                    id: backendID,
                    ipAddress: "10.1.0.20",
                    vmId: vmID,
                    nicIndex: 1,
                    networkId: backendNetworkID,
                    healthCheckSourceIP: "10.1.0.1")
            ])
    }

    private func network(loadBalancers: [DesiredLoadBalancer]?) -> DesiredNetworkState {
        DesiredNetworkState(
            networkId: vipNetworkID,
            name: "frontend",
            subnet: "10.0.0.0/24",
            gateway: "10.0.0.1",
            routerKey: "project-1",
            externalAccess: true,
            generation: 1,
            loadBalancers: loadBalancers)
    }

    @Test("Southbound service monitors report online and offline backend health")
    func mapsServiceMonitorHealth() throws {
        let firstBackendID = UUID()
        let secondBackendID = UUID()
        let listenerA = DesiredLoadBalancerListener(id: UUID(), port: 80, backendPort: 8080)
        let listenerB = DesiredLoadBalancerListener(id: UUID(), port: 443, backendPort: 8443)
        let loadBalancer = desired(
            listeners: [listenerA, listenerB],
            backends: [
                DesiredLoadBalancerBackend(
                    id: firstBackendID,
                    ipAddress: "10.1.0.20",
                    vmId: vmID,
                    nicIndex: 1,
                    networkId: backendNetworkID,
                    healthCheckSourceIP: "10.1.0.1"),
                DesiredLoadBalancerBackend(
                    id: secondBackendID,
                    ipAddress: "192.0.2.40"),
            ])
        let logicalPort = OVNNaming.vmPortName(vmId: vmID.uuidString, nicIndex: 1)
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let result = LoadBalancerBackendHealthMapper.map(
            desired: loadBalancer,
            monitors: [
                LoadBalancerServiceMonitorObservation(
                    monitorType: "load-balancer",
                    ipAddress: "10.1.0.20",
                    port: 8080,
                    protocolName: "tcp",
                    logicalPort: logicalPort,
                    sourceIP: "10.1.0.1",
                    status: "online"),
                LoadBalancerServiceMonitorObservation(
                    monitorType: "load-balancer",
                    ipAddress: "10.1.0.20",
                    port: 8443,
                    protocolName: "tcp",
                    logicalPort: logicalPort,
                    sourceIP: "10.1.0.1",
                    status: "online"),
                LoadBalancerServiceMonitorObservation(
                    monitorType: "load-balancer",
                    ipAddress: "192.0.2.40",
                    port: 8080,
                    protocolName: "tcp",
                    status: "offline"),
                // A monitor for another protocol must not make this backend
                // look healthy.
                LoadBalancerServiceMonitorObservation(
                    monitorType: "load-balancer",
                    ipAddress: "192.0.2.40",
                    port: 8443,
                    protocolName: "udp",
                    status: "online"),
            ],
            observedAt: checkedAt)

        #expect(result.count == 2)
        #expect(result[0].id == firstBackendID)
        #expect(result[0].healthStatus == .online)
        #expect(result[0].lastCheckedAt == checkedAt)
        #expect(result[1].id == secondBackendID)
        #expect(result[1].healthStatus == .offline)
        #expect(result[1].lastCheckedAt == checkedAt)
    }

    @Test("A missing service monitor remains unknown without a fabricated timestamp")
    func missingServiceMonitorIsUnknown() throws {
        let result = LoadBalancerBackendHealthMapper.map(
            desired: desired(),
            monitors: [],
            observedAt: Date())

        let backend = try #require(result.first)
        #expect(backend.healthStatus == .unknown)
        #expect(backend.lastCheckedAt == nil)
    }

    @Test("A backend stays unknown until every listener monitor has reported")
    func partialServiceMonitorIsUnknown() throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let result = LoadBalancerBackendHealthMapper.map(
            desired: desired(
                listeners: [
                    DesiredLoadBalancerListener(id: UUID(), port: 80, backendPort: 8080),
                    DesiredLoadBalancerListener(id: UUID(), port: 443, backendPort: 8443),
                ]),
            monitors: [
                LoadBalancerServiceMonitorObservation(
                    monitorType: "load-balancer",
                    ipAddress: "10.1.0.20",
                    port: 8080,
                    protocolName: "tcp",
                    logicalPort: OVNNaming.vmPortName(
                        vmId: vmID.uuidString, nicIndex: 1),
                    sourceIP: "10.1.0.1",
                    status: "online")
            ],
            observedAt: checkedAt)

        let backend = try #require(result.first)
        #expect(backend.healthStatus == .unknown)
        #expect(backend.lastCheckedAt == checkedAt)
    }

    @Test("Reconciliation is idempotent, preserves observed health, and removes stale rows")
    func reconcilesAuthoritatively() async throws {
        let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let actuator = FakeLoadBalancerActuator(
            backendHealth: [
                ObservedLoadBalancerBackend(
                    id: backendID,
                    healthStatus: .offline,
                    lastCheckedAt: checkedAt)
            ])
        let logger = Logger(label: "LoadBalancerReconcilerTests")
        let wanted = desired()

        let first = try #require(
            await LoadBalancerReconciler.reconcile(
                networks: [network(loadBalancers: [wanted])],
                actuator: actuator,
                logger: logger))
        let second = try #require(
            await LoadBalancerReconciler.reconcile(
                networks: [network(loadBalancers: [wanted])],
                actuator: actuator,
                logger: logger))

        #expect(first == second)
        #expect(first.first?.status == .active)
        #expect(first.first?.backends.first?.healthStatus == .offline)
        #expect(first.first?.backends.first?.lastCheckedAt == checkedAt)
        #expect(await actuator.createCount() == 1)
        #expect(await actuator.rowCount() == 1)
        #expect(
            await actuator.attachedSwitches()
                == [
                    OVNNaming.switchName(networkId: vipNetworkID),
                    OVNNaming.switchName(networkId: backendNetworkID),
                ])
        #expect(await actuator.attachedRouters() == ["lr-project-1"])

        let deleted = try #require(
            await LoadBalancerReconciler.reconcile(
                networks: [network(loadBalancers: [])],
                actuator: actuator,
                logger: logger))
        #expect(deleted.isEmpty)
        #expect(await actuator.rowCount() == 0)
        #expect(await actuator.removedCount() == 1)
    }

    @Test("A pre-v43 nil collection has no deletion opinion")
    func nilCollectionDoesNotDelete() async throws {
        let actuator = FakeLoadBalancerActuator(backendHealth: [])
        await actuator.seed(
            ManagedLoadBalancerObservation(
                rowUUID: "existing-row",
                ownerID: loadBalancerID,
                switchNames: ["ls-existing"],
                routerNames: ["lr-existing"]))

        let result = await LoadBalancerReconciler.reconcile(
            networks: [network(loadBalancers: nil)],
            actuator: actuator,
            logger: Logger(label: "LoadBalancerReconcilerTests"))

        #expect(result == nil)
        #expect(await actuator.rowCount() == 1)
        #expect(await actuator.removedCount() == 0)
    }
}

private actor FakeLoadBalancerActuator: LoadBalancerActuator {
    private var rows: [String: ManagedLoadBalancerObservation] = [:]
    private var creations = 0
    private var removals = 0
    private let backendHealth: [ObservedLoadBalancerBackend]

    init(backendHealth: [ObservedLoadBalancerBackend]) {
        self.backendHealth = backendHealth
    }

    func seed(_ observation: ManagedLoadBalancerObservation) {
        rows[observation.rowUUID] = observation
    }

    func observeManagedLoadBalancers() -> [ManagedLoadBalancerObservation] {
        Array(rows.values)
    }

    func ensureLoadBalancer(
        _ desired: DesiredLoadBalancer,
        routerName: String,
        switchNames: Set<String>,
        existing: ManagedLoadBalancerObservation?
    ) -> String {
        let rowUUID: String
        if let existing {
            rowUUID = existing.rowUUID
        } else {
            creations += 1
            rowUUID = "row-\(creations)"
        }
        rows[rowUUID] = ManagedLoadBalancerObservation(
            rowUUID: rowUUID,
            ownerID: desired.id,
            switchNames: switchNames,
            routerNames: [routerName])
        return rowUUID
    }

    func observeBackendHealth(
        for desired: DesiredLoadBalancer
    ) -> [ObservedLoadBalancerBackend] {
        backendHealth
    }

    func removeLoadBalancer(_ observed: ManagedLoadBalancerObservation) {
        rows[observed.rowUUID] = nil
        removals += 1
    }

    func createCount() -> Int { creations }
    func rowCount() -> Int { rows.count }
    func removedCount() -> Int { removals }
    func attachedSwitches() -> Set<String> {
        rows.values.first?.switchNames ?? []
    }
    func attachedRouters() -> Set<String> {
        rows.values.first?.routerNames ?? []
    }
}
