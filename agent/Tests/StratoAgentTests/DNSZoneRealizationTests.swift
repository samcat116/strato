import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("DNS Zone Realization")
struct DNSZoneRealizationTests {

    private let zoneID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let networkID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let otherNetworkID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    private var switchName: String { OVNNaming.switchName(networkId: networkID) }
    private var otherSwitchName: String { OVNNaming.switchName(networkId: otherNetworkID) }

    private func zone(
        id: UUID? = nil,
        name: String = "acme.internal",
        networkIds: [UUID]? = nil,
        records: [DesiredDNSRecord],
        hash: String = "hash-1"
    ) -> DesiredDNSZone {
        DesiredDNSZone(
            zoneId: id ?? zoneID,
            zoneName: name,
            networkIds: networkIds ?? [networkID],
            records: records,
            recordsHash: hash)
    }

    private func record(_ name: String, _ type: String, _ values: [String]) -> DesiredDNSRecord {
        DesiredDNSRecord(name: name, type: type, values: values)
    }

    // MARK: - Flattening

    @Test("A dual-stack host's A and AAAA records become one space-separated entry")
    func flattensForwardRecords() {
        let flattened = OVNDNSRecords.flatten([
            record("web.acme.internal", "A", ["10.0.0.5"]),
            record("web.acme.internal", "AAAA", ["fd00::5"]),
        ])
        #expect(flattened.records == ["web.acme.internal": "10.0.0.5 fd00::5"])
        #expect(flattened.unsupportedTypes.isEmpty)
    }

    @Test("A round-robin name keeps every value, IPv4 first")
    func flattensMultiValuedRRset() {
        let flattened = OVNDNSRecords.flatten([
            record("web.acme.internal", "A", ["10.0.0.5", "10.0.0.6"]),
            record("web.acme.internal", "AAAA", ["fd00::5"]),
        ])
        #expect(flattened.records["web.acme.internal"] == "10.0.0.5 10.0.0.6 fd00::5")
    }

    @Test("PTR records become reverse-name entries pointing at the host")
    func flattensReverseRecords() {
        let flattened = OVNDNSRecords.flatten([
            record("5.0.0.10.in-addr.arpa", "PTR", ["web.acme.internal"])
        ])
        #expect(flattened.records == ["5.0.0.10.in-addr.arpa": "web.acme.internal"])
    }

    @Test("Record types the OVN resolver cannot answer are reported, not realized")
    func reportsUnsupportedTypes() {
        let flattened = OVNDNSRecords.flatten([
            record("web.acme.internal", "A", ["10.0.0.5"]),
            record("www.acme.internal", "CNAME", ["web.acme.internal"]),
            record("acme.internal", "TXT", ["v=spf1 -all"]),
        ])
        #expect(flattened.records == ["web.acme.internal": "10.0.0.5"])
        #expect(flattened.unsupportedTypes == ["CNAME", "TXT"])
    }

    @Test("A value that isn't the shape its type requires is dropped, not the zone")
    func dropsMalformedValues() {
        let flattened = OVNDNSRecords.flatten([
            record("web.acme.internal", "A", ["10.0.0.5"]),
            record("broken.acme.internal", "A", ["not-an-address"]),
            record("bad name.acme.internal", "A", ["10.0.0.9"]),
        ])
        #expect(flattened.records == ["web.acme.internal": "10.0.0.5"])
        #expect(flattened.malformedNames == ["bad name.acme.internal", "broken.acme.internal"])
    }

    @Test("A reverse name with more than one target reports what it could not publish")
    func reportsTruncatedReverseTargets() {
        // OVN's value for a reverse name is one name, not a list. Reachable
        // both ways: several authored PTR rows union into one RRset, and two
        // VMs on overlapping subnets derive a PTR at the same address.
        let flattened = OVNDNSRecords.flatten([
            record("5.0.0.10.in-addr.arpa", "PTR", ["a.acme.internal", "b.acme.internal"]),
            record("6.0.0.10.in-addr.arpa", "PTR", ["c.acme.internal"]),
        ])
        #expect(flattened.records["5.0.0.10.in-addr.arpa"] == "a.acme.internal")
        #expect(flattened.records["6.0.0.10.in-addr.arpa"] == "c.acme.internal")
        #expect(flattened.truncatedNames == ["5.0.0.10.in-addr.arpa"])
    }

    @Test("Two records claiming one reverse name keep the first and report the clash")
    func reportsCollidingReverseNames() {
        let flattened = OVNDNSRecords.flatten([
            record("5.0.0.10.in-addr.arpa", "PTR", ["a.acme.internal"]),
            record("5.0.0.10.in-addr.arpa", "PTR", ["b.acme.internal"]),
        ])
        #expect(flattened.records["5.0.0.10.in-addr.arpa"] == "a.acme.internal")
        #expect(flattened.truncatedNames == ["5.0.0.10.in-addr.arpa"])
    }

    @Test("Flattening is order-independent, so a replayed sync writes identical records")
    func flatteningIsStable() {
        let records = [
            record("db.acme.internal", "AAAA", ["fd00::9"]),
            record("web.acme.internal", "A", ["10.0.0.5"]),
            record("5.0.0.10.in-addr.arpa", "PTR", ["web.acme.internal"]),
        ]
        #expect(OVNDNSRecords.flatten(records).records == OVNDNSRecords.flatten(records.reversed()).records)
    }

    // MARK: - Planning

    @Test("A zone plans one row attached to each of its networks' switches")
    func plansSwitchAttachments() {
        let plans = DNSZoneReconciler.plan(zones: [
            zone(networkIds: [otherNetworkID, networkID], records: [record("web.acme.internal", "A", ["10.0.0.5"])])
        ])
        #expect(plans[0].diagnostics.isEmpty)
        #expect(plans.count == 1)
        #expect(plans[0].switchNames == [switchName, otherSwitchName].sorted())
        #expect(plans[0].records == ["web.acme.internal": "10.0.0.5"])
    }

    @Test("Unrealizable record types produce a diagnostic rather than a failed plan")
    func plansWithDiagnostics() {
        let plans = DNSZoneReconciler.plan(zones: [
            zone(records: [record("www.acme.internal", "CNAME", ["web.acme.internal"])])
        ])
        #expect(plans.count == 1)
        #expect(plans[0].records.isEmpty)
        #expect(plans[0].diagnostics.count == 1)
        #expect(plans[0].diagnostics[0].contains("CNAME"))
    }

    // MARK: - Writes

    @Test("A zone with no row yet is created and attached")
    func createsMissingZone() {
        let plans = DNSZoneReconciler.plan(zones: [
            zone(records: [record("web.acme.internal", "A", ["10.0.0.5"])])
        ])
        let writes = DNSZoneReconciler.writes(desired: plans, observed: [])
        #expect(writes.count == 1)
        #expect(writes[0].existingUUID == nil)
        #expect(writes[0].rewriteRecords)
        #expect(writes[0].attach == [switchName])
        #expect(writes[0].detach.isEmpty)
    }

    @Test("An unchanged zone costs no OVSDB transaction at all")
    func skipsUnchangedZone() {
        let plans = DNSZoneReconciler.plan(zones: [
            zone(records: [record("web.acme.internal", "A", ["10.0.0.5"])])
        ])
        let observed = ObservedDNSZone(
            uuid: "row-1", zoneId: zoneID, recordsHash: "hash-1", zoneName: "acme.internal",
            records: ["web.acme.internal": "10.0.0.5"], switchNames: [switchName])
        #expect(DNSZoneReconciler.writes(desired: plans, observed: [observed]).isEmpty)
    }

    @Test("A converged zone carrying unrealizable records plans no write, so it stays quiet")
    func convergedZoneWithDiagnosticsPlansNoWrite() {
        // The diagnostic is logged per write, so this is what keeps a zone
        // holding one TXT record from warning on every sync forever: it has
        // something to say, and nothing to do.
        let plans = DNSZoneReconciler.plan(zones: [
            zone(records: [
                record("web.acme.internal", "A", ["10.0.0.5"]),
                record("acme.internal", "TXT", ["v=spf1 -all"]),
            ])
        ])
        #expect(!plans[0].diagnostics.isEmpty)
        let observed = ObservedDNSZone(
            uuid: "row-1", zoneId: zoneID, recordsHash: "hash-1", zoneName: "acme.internal",
            records: ["web.acme.internal": "10.0.0.5"], switchNames: [switchName])
        #expect(DNSZoneReconciler.writes(desired: plans, observed: [observed]).isEmpty)
    }

    @Test("A changed hash rewrites the row in place, keeping its attachments")
    func rewritesOnHashChange() {
        let plans = DNSZoneReconciler.plan(zones: [
            zone(records: [record("web.acme.internal", "A", ["10.0.0.6"])], hash: "hash-2")
        ])
        let observed = ObservedDNSZone(
            uuid: "row-1", zoneId: zoneID, recordsHash: "hash-1", zoneName: "acme.internal",
            records: ["web.acme.internal": "10.0.0.5"], switchNames: [switchName])
        let writes = DNSZoneReconciler.writes(desired: plans, observed: [observed])
        #expect(writes.count == 1)
        #expect(writes[0].existingUUID == "row-1")
        #expect(writes[0].rewriteRecords)
        #expect(writes[0].attach.isEmpty)
        #expect(writes[0].detach.isEmpty)
    }

    @Test("A row whose contents drifted under a matching stamp is still healed")
    func healsDriftedRecords() {
        let plans = DNSZoneReconciler.plan(zones: [
            zone(records: [record("web.acme.internal", "A", ["10.0.0.5"])])
        ])
        let observed = ObservedDNSZone(
            uuid: "row-1", zoneId: zoneID, recordsHash: "hash-1", zoneName: "acme.internal",
            records: ["web.acme.internal": "10.9.9.9"], switchNames: [switchName])
        let writes = DNSZoneReconciler.writes(desired: plans, observed: [observed])
        #expect(writes.count == 1)
        #expect(writes[0].rewriteRecords)
        // Flagged as a drift heal, so the same zone healing on every pass —
        // which is what an OVSDB value that does not round-trip identically
        // would look like — shows up in the logs instead of being silent.
        #expect(writes[0].healsDrift)
    }

    @Test("A rewrite the stamp asked for is not reported as drift")
    func stampDrivenRewriteIsNotDrift() {
        let plans = DNSZoneReconciler.plan(zones: [
            zone(records: [record("web.acme.internal", "A", ["10.0.0.6"])], hash: "hash-2")
        ])
        let observed = ObservedDNSZone(
            uuid: "row-1", zoneId: zoneID, recordsHash: "hash-1", zoneName: "acme.internal",
            records: ["web.acme.internal": "10.0.0.5"], switchNames: [switchName])
        #expect(!DNSZoneReconciler.writes(desired: plans, observed: [observed])[0].healsDrift)
    }

    @Test("A row written before stamping is rewritten rather than trusted")
    func rewritesUnstampedRow() {
        let plans = DNSZoneReconciler.plan(zones: [zone(records: [])])
        let observed = ObservedDNSZone(
            uuid: "row-1", zoneId: zoneID, recordsHash: nil, zoneName: "acme.internal",
            records: [:], switchNames: [switchName])
        #expect(DNSZoneReconciler.writes(desired: plans, observed: [observed])[0].rewriteRecords)
    }

    @Test("A newly attached network is attached without rewriting the records")
    func attachesNewNetworkOnly() {
        let plans = DNSZoneReconciler.plan(zones: [
            zone(
                networkIds: [networkID, otherNetworkID],
                records: [record("web.acme.internal", "A", ["10.0.0.5"])])
        ])
        let observed = ObservedDNSZone(
            uuid: "row-1", zoneId: zoneID, recordsHash: "hash-1", zoneName: "acme.internal",
            records: ["web.acme.internal": "10.0.0.5"], switchNames: [switchName])
        let writes = DNSZoneReconciler.writes(desired: plans, observed: [observed])
        #expect(writes.count == 1)
        #expect(!writes[0].rewriteRecords)
        #expect(writes[0].attach == [otherSwitchName])
    }

    @Test("A detached network's switch stops answering from the zone")
    func detachesRemovedNetwork() {
        let plans = DNSZoneReconciler.plan(zones: [zone(networkIds: [networkID], records: [])])
        let observed = ObservedDNSZone(
            uuid: "row-1", zoneId: zoneID, recordsHash: "hash-1", zoneName: "acme.internal",
            records: [:], switchNames: [switchName, otherSwitchName])
        let writes = DNSZoneReconciler.writes(desired: plans, observed: [observed])
        #expect(writes[0].detach == [otherSwitchName])
        #expect(writes[0].attach.isEmpty)
    }

    // MARK: - Teardown and ownership

    @Test("A zone that no longer reaches this agent's networks has its row removed")
    func tearsDownUnwantedZone() {
        let plans = DNSZoneReconciler.plan(zones: [])
        let observed = ObservedDNSZone(
            uuid: "row-1", zoneId: zoneID, recordsHash: "hash-1", zoneName: "acme.internal",
            records: [:], switchNames: [switchName])
        #expect(DNSZoneReconciler.teardownUUIDs(desired: plans, observed: [observed]) == ["row-1"])
    }

    @Test("A duplicate row for one zone is torn down while the other converges")
    func tearsDownDuplicateRows() {
        let plans = DNSZoneReconciler.plan(zones: [zone(records: [])])
        let rows = [
            ObservedDNSZone(
                uuid: "row-b", zoneId: zoneID, recordsHash: "hash-1", zoneName: "acme.internal",
                records: [:], switchNames: [switchName]),
            ObservedDNSZone(
                uuid: "row-a", zoneId: zoneID, recordsHash: "hash-1", zoneName: "acme.internal",
                records: [:], switchNames: [switchName]),
        ]
        #expect(DNSZoneReconciler.teardownUUIDs(desired: plans, observed: rows) == ["row-b"])
        #expect(DNSZoneReconciler.writes(desired: plans, observed: rows).isEmpty)
    }

    @Test("Only rows carrying the managed marker and a zone id are ever adopted")
    func ownershipPredicateRejectsForeignRows() {
        #expect(DNSRowIdentity.ownedZoneID(nil) == nil)
        // An operator's own row: no marker at all.
        #expect(DNSRowIdentity.ownedZoneID(["dns-zone-id": zoneID.uuidString]) == nil)
        // Marked, but by something that isn't a Strato DNS zone.
        #expect(DNSRowIdentity.ownedZoneID(["strato-managed": "true"]) == nil)
        #expect(DNSRowIdentity.ownedZoneID(["strato-managed": "true", "dns-zone-id": "nonsense"]) == nil)

        let ids = DNSRowIdentity.externalIDs(zoneId: zoneID, zoneName: "acme.internal", recordsHash: "hash-1")
        #expect(DNSRowIdentity.ownedZoneID(ids) == zoneID)
        #expect(ids[DNSRowIdentity.recordsHashKey] == "hash-1")
    }

    // MARK: - Orchestration

    @Test("Reconcile ensures the changed zones and tears down the unwanted rows")
    func reconcileDrivesTheActuator() async throws {
        let actuator = RecordingDNSActuator(observed: [
            ObservedDNSZone(
                uuid: "row-stale", zoneId: UUID(), recordsHash: "hash-9", zoneName: "old.internal",
                records: [:], switchNames: [])
        ])
        try await DNSZoneReconciler.reconcile(
            zones: [zone(records: [record("web.acme.internal", "A", ["10.0.0.5"])])],
            actuator: actuator,
            logger: Logger(label: "test"))
        #expect(await actuator.calls == ["ensureDNSZone(acme.internal)", "removeDNSZone(row-stale)"])
    }

    @Test("A zone whose row fails to converge does not stop the rest of the pass")
    func reconcileToleratesOneFailingZone() async throws {
        let failing = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let actuator = RecordingDNSActuator(observed: [], failingZones: [failing])
        try await DNSZoneReconciler.reconcile(
            zones: [
                zone(id: failing, name: "broken.internal", records: []),
                zone(name: "acme.internal", records: []),
            ],
            actuator: actuator,
            logger: Logger(label: "test"))
        #expect(await actuator.calls.contains("ensureDNSZone(acme.internal)"))
    }
}

/// Records the DNS calls the reconciler drives. Only the DNS half of
/// `NetworkActuator` is exercised; the L3 methods are unreachable here.
private actor RecordingDNSActuator: NetworkActuator {
    private(set) var calls: [String] = []
    private let observed: [ObservedDNSZone]
    private let failingZones: Set<UUID>

    init(observed: [ObservedDNSZone], failingZones: Set<UUID> = []) {
        self.observed = observed
        self.failingZones = failingZones
    }

    struct Failure: Error {}

    func observeDNSZones() async throws -> [ObservedDNSZone] { observed }
    func ensureDNSZone(_ write: DNSZoneWrite) async throws {
        guard !failingZones.contains(write.plan.zoneId) else { throw Failure() }
        calls.append("ensureDNSZone(\(write.plan.zoneName))")
    }
    func removeDNSZone(uuid: String) async throws { calls.append("removeDNSZone(\(uuid))") }

    func observeTopology() async throws -> ObservedNetworkTopology { ObservedNetworkTopology() }
    func ensureSwitch(_ desired: DesiredSwitch) async throws {}
    func ensureServiceLocalPort(_ port: DesiredServiceLocalPort) async throws {}
    func removeServiceLocalPort(name: String) async throws {}
    func ensureRouter(_ router: DesiredRouter) async throws {}
    func ensureRouterPort(_ port: DesiredRouterPort, onRouter routerName: String) async throws {}
    func ensureUplink(for router: DesiredRouter) async throws -> Bool { false }
    func ensureSNAT(router routerName: String, logicalIP: String) async throws {}
    func removeSNAT(router routerName: String, logicalIP: String) async throws {}
    func ensureDNAT(router routerName: String, rule: DesiredDNATRule) async throws {}
    func removeDNAT(router routerName: String, externalIP: String) async throws {}
    func ensureDynamicRouting(for router: DesiredRouter, uplinkReady: Bool) async throws {}
    func removeSwitchRouterPort(name: String) async throws {}
    func removeRouterPort(name: String) async throws {}
    func removeExternalSwitch(name: String) async throws {}
    func removeRouter(name: String) async throws {}
}
