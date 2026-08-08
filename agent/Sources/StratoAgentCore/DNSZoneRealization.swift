import Foundation
import Logging
import StratoShared

// Internal name resolution in the datapath (STR-39, roadmap #769).
//
// The control plane owns zones and records — it is the only component that
// knows every name → address mapping, because it owns IPAM — and ships each
// zone's effective contents on the desired-state sync. This file is the pure,
// unit-testable core that turns those zones into OVN Northbound `DNS` rows and
// their `Logical_Switch.dns_records` attachments, and computes teardown as
// observed − desired. The live OVSDB side effects live in `NetworkServiceLinux`
// behind `NetworkActuator`, exactly like `NetworkReconciler` before it.
//
// Only the site's topology authority realizes zones: `Logical_Switch` is
// switch-scoped topology, so a zone's rows belong to the same single writer
// that authors routers and NAT. The *records* come from every agent's VMs,
// which is why the control plane assembles them fleet-wide rather than from
// the receiving agent's own workloads.
//
// There is no server process and no failure domain here: `ovn-controller`
// answers `dns_lookup()` in the datapath from these rows, so losing an agent
// costs the names on that chassis and nothing else.

// MARK: - Row ownership

/// Which OVN `DNS` row belongs to which zone.
///
/// Rows are matched on `(strato-managed, dns-zone-id)` — never on their
/// contents and never on the zone *name*, which is unique only within a
/// project (two tenants may both serve `corp.example.com`). Operator-created
/// rows carry no managed marker and are therefore never adopted, never
/// rewritten, and never torn down: the `DNS` table is shared with whatever else
/// an operator runs against the same northbound database. Same convention as
/// `DHCPRowIdentity`.
public enum DNSRowIdentity {
    public static let managedKey = "strato-managed"
    public static let managedValue = "true"
    public static let zoneIDKey = "dns-zone-id"
    /// Write-only human label, so `ovn-nbctl list dns` stays legible when every
    /// other column is a UUID or a record blob. Nothing reads it.
    public static let zoneNameKey = "dns-zone-name"
    /// The control plane's digest of the records this row was written from.
    /// Compared on the next sync to skip an unchanged zone's transaction.
    public static let recordsHashKey = "dns-records-hash"

    /// The external-ids a managed row carries.
    public static func externalIDs(zoneId: UUID, zoneName: String, recordsHash: String) -> [String: String] {
        [
            zoneIDKey: canonical(zoneId),
            zoneNameKey: zoneName,
            recordsHashKey: recordsHash,
            managedKey: managedValue,
        ]
    }

    /// Whether a row is a Strato-managed one, and if so which zone's.
    /// Nil for every row this agent must not touch.
    public static func ownedZoneID(_ externalIDs: [String: String]?) -> UUID? {
        guard externalIDs?[managedKey] == managedValue,
            let raw = externalIDs?[zoneIDKey],
            let id = UUID(uuidString: raw)
        else { return nil }
        return id
    }

    /// Lowercased, matching `OVNNaming`'s treatment of ids in object names.
    private static func canonical(_ zoneId: UUID) -> String {
        zoneId.uuidString.lowercased()
    }
}

// MARK: - Flattening records for OVN

/// Turns a zone's typed record set into the `name → value` map OVN's `DNS.records`
/// column takes.
///
/// OVN answers A/AAAA/PTR and nothing else: a forward name maps to a
/// space-separated list of addresses (both families in one entry — OVN picks
/// the ones matching the query type), and a reverse `in-addr.arpa` / `ip6.arpa`
/// name maps to the domain name it points at. Everything else in the model's
/// vocabulary — CNAME, TXT, SRV — is left for the per-network resolver on the
/// roadmap, and reported rather than dropped in silence.
public enum OVNDNSRecords {
    /// The record types the OVN backend can express.
    public static let supportedTypes: Set<String> = ["A", "AAAA", "PTR"]

    /// The flattened map, plus the types that had to be skipped.
    public struct Flattened: Equatable, Sendable {
        public let records: [String: String]
        /// Types present in the zone that this backend cannot express, sorted
        /// and deduplicated — a diagnostic, never a failure.
        public let unsupportedTypes: [String]
        /// Entries dropped because a value was not the shape its type requires.
        /// The control plane validates on write, so this is a row that predates
        /// the validation — worth a warning, not a refusal.
        public let malformedNames: [String]
    }

    /// Flatten `records`, dropping what OVN cannot answer with.
    ///
    /// Values are re-validated rather than trusted, on `DHCPOptions`'
    /// `wellFormedDomain` reasoning: the whole zone travels as one OVSDB row,
    /// so a single unparseable value can cost every name in it. Degrading to
    /// "this record doesn't resolve" is the failure worth having; "the zone
    /// doesn't resolve" is not.
    public static func flatten(_ records: [DesiredDNSRecord]) -> Flattened {
        // Forward names accumulate across the A and AAAA entries for one name:
        // OVN keeps one value per key, so a dual-stack host's two RRsets have
        // to become one space-separated list. v4 first, then v6, each in the
        // control plane's order, so a replayed sync produces byte-identical
        // records.
        var v4: [String: [String]] = [:]
        var v6: [String: [String]] = [:]
        var reverse: [String: String] = [:]
        var unsupported: Set<String> = []
        var malformed: Set<String> = []

        for record in records {
            let type = record.type.uppercased()
            guard supportedTypes.contains(type) else {
                unsupported.insert(type)
                continue
            }
            let name = record.name.lowercased()
            guard DNSNameSyntax.isValidDomainName(name) else {
                malformed.insert(record.name)
                continue
            }
            switch type {
            case "A":
                let valid = record.values.filter { IPv4Address($0) != nil }
                if valid.count != record.values.count { malformed.insert(record.name) }
                v4[name, default: []].append(contentsOf: valid)
            case "AAAA":
                let valid = record.values.filter { IPv6Address($0) != nil }
                if valid.count != record.values.count { malformed.insert(record.name) }
                v6[name, default: []].append(contentsOf: valid)
            default:
                // PTR. A reverse name answers with exactly one target — OVN's
                // value is a single name, not a list — so a multi-valued PTR
                // publishes its first target and the rest are unrepresentable.
                // The control plane sorts the values, so which one wins is at
                // least stable rather than assembly-order dependent.
                let targets = record.values.map { $0.lowercased() }.filter(DNSNameSyntax.isValidDomainName)
                if targets.count != record.values.count { malformed.insert(record.name) }
                guard let target = targets.first else { continue }
                reverse[name] = target
            }
        }

        var flattened = reverse
        for name in Set(v4.keys).union(v6.keys) {
            let addresses = (v4[name] ?? []) + (v6[name] ?? [])
            guard !addresses.isEmpty else { continue }
            // A forward name that also appeared as a reverse name would be a
            // zone containing an `in-addr.arpa` host, which the control plane's
            // grammar permits and OVN cannot represent twice. The address wins:
            // it is the answer a guest's lookup of that name expects.
            flattened[name] = addresses.joined(separator: " ")
        }
        return Flattened(
            records: flattened,
            unsupportedTypes: unsupported.sorted(),
            malformedNames: malformed.sorted())
    }
}

// MARK: - Plan and observation

/// One OVN `DNS` row the plan wants: a zone's realizable records and the
/// switches that should answer from them.
public struct DNSZonePlan: Equatable, Sendable {
    public let zoneId: UUID
    public let zoneName: String
    /// The control plane's digest of the *whole* zone, including the records
    /// this backend cannot express — so a zone whose only change was a TTL or a
    /// TXT record still restamps the row, and the stamp keeps meaning "written
    /// from this version of the zone".
    public let recordsHash: String
    /// The flattened OVN map.
    public let records: [String: String]
    /// The logical switches this row attaches to, sorted and deduplicated.
    public let switchNames: [String]

    public init(
        zoneId: UUID, zoneName: String, recordsHash: String, records: [String: String],
        switchNames: [String]
    ) {
        self.zoneId = zoneId
        self.zoneName = zoneName
        self.recordsHash = recordsHash
        self.records = records
        self.switchNames = switchNames
    }

    public var externalIDs: [String: String] {
        DNSRowIdentity.externalIDs(zoneId: zoneId, zoneName: zoneName, recordsHash: recordsHash)
    }
}

/// A Strato-managed `DNS` row as observed in the northbound database, with the
/// switches currently referencing it. Rows without the managed marker never
/// become one of these.
public struct ObservedDNSZone: Equatable, Sendable {
    public let uuid: String
    public let zoneId: UUID
    /// The stamp the row carries, or nil for a row written before stamping (or
    /// by a crash between the write and the stamp) — which forces a rewrite.
    public let recordsHash: String?
    public let zoneName: String?
    public let records: [String: String]
    public let switchNames: Set<String>

    public init(
        uuid: String, zoneId: UUID, recordsHash: String?, zoneName: String? = nil,
        records: [String: String], switchNames: Set<String>
    ) {
        self.uuid = uuid
        self.zoneId = zoneId
        self.recordsHash = recordsHash
        self.zoneName = zoneName
        self.records = records
        self.switchNames = switchNames
    }
}

/// One zone's convergence, fully decided: what to write, and where to attach or
/// detach it. The actuator executes this without deciding anything, so the
/// hash-skip and the attachment diff stay unit-testable.
public struct DNSZoneWrite: Equatable, Sendable {
    public let plan: DNSZonePlan
    /// The row to update, or nil to create one.
    public let existingUUID: String?
    /// Whether the row's `records`/`external_ids` need writing at all. False
    /// when the stamp and the contents already match — the skip that keeps a
    /// zone's O(VMs) record map from being rewritten on every sync.
    public let rewriteRecords: Bool
    public let attach: [String]
    public let detach: [String]

    public init(
        plan: DNSZonePlan, existingUUID: String?, rewriteRecords: Bool, attach: [String],
        detach: [String]
    ) {
        self.plan = plan
        self.existingUUID = existingUUID
        self.rewriteRecords = rewriteRecords
        self.attach = attach
        self.detach = detach
    }

    /// Whether this write has anything to do at all.
    public var isNoop: Bool {
        existingUUID != nil && !rewriteRecords && attach.isEmpty && detach.isEmpty
    }
}

// MARK: - Reconciler

/// Pure planning for DNS zone realization. No side effects, fully testable.
public enum DNSZoneReconciler {

    /// The rows the desired zones imply, in a deterministic order.
    ///
    /// A zone attached to no network still yields a row: `DNS` is a root table,
    /// an unattached row answers nothing, and keeping it means an attach later
    /// is one mutation rather than a create. Diagnostics for unrealizable
    /// record types ride the result so the caller can log once per pass.
    public static func plan(zones: [DesiredDNSZone]) -> (plans: [DNSZonePlan], diagnostics: [String]) {
        var plans: [DNSZonePlan] = []
        var diagnostics: [String] = []
        for zone in zones.sorted(by: { $0.zoneId.uuidString < $1.zoneId.uuidString }) {
            let flattened = OVNDNSRecords.flatten(zone.records)
            if !flattened.unsupportedTypes.isEmpty {
                diagnostics.append(
                    "zone '\(zone.zoneName)' contains \(flattened.unsupportedTypes.joined(separator: ", ")) "
                        + "records, which the OVN resolver cannot answer; they are not realized")
            }
            if !flattened.malformedNames.isEmpty {
                diagnostics.append(
                    "zone '\(zone.zoneName)' contains records whose values are not valid for their type "
                        + "(\(flattened.malformedNames.joined(separator: ", "))); they are not realized")
            }
            plans.append(
                DNSZonePlan(
                    zoneId: zone.zoneId,
                    zoneName: zone.zoneName,
                    recordsHash: zone.recordsHash,
                    records: flattened.records,
                    switchNames: Set(zone.networkIds.map { OVNNaming.switchName(networkId: $0) }).sorted()))
        }
        return (plans, diagnostics)
    }

    /// What to do with each planned zone, given what the northbound database
    /// currently holds. Zones needing nothing are omitted entirely.
    ///
    /// A zone with two managed rows (two creates that raced a crash) converges
    /// on the lowest-UUID one and leaves the other to `teardownUUIDs`, so the
    /// duplicate is removed rather than fought over.
    public static func writes(desired: [DNSZonePlan], observed: [ObservedDNSZone]) -> [DNSZoneWrite] {
        let rows = canonicalRows(observed)
        var writes: [DNSZoneWrite] = []
        for plan in desired {
            guard let existing = rows[plan.zoneId] else {
                writes.append(
                    DNSZoneWrite(
                        plan: plan, existingUUID: nil, rewriteRecords: true,
                        attach: plan.switchNames, detach: []))
                continue
            }
            // Both halves matter. The stamp is the cheap primary signal, and
            // comparing the contents is what heals a row somebody hand-edited
            // or an agent whose flattening changed across an upgrade — neither
            // of which moves the control plane's digest.
            let rewrite =
                existing.recordsHash != plan.recordsHash || existing.records != plan.records
                || existing.zoneName != plan.zoneName
            let write = DNSZoneWrite(
                plan: plan,
                existingUUID: existing.uuid,
                rewriteRecords: rewrite,
                attach: plan.switchNames.filter { !existing.switchNames.contains($0) },
                detach: existing.switchNames.subtracting(plan.switchNames).sorted())
            guard !write.isNoop else { continue }
            writes.append(write)
        }
        return writes
    }

    /// Managed rows in the northbound database the plan no longer wants:
    /// zones that no longer reach any network this agent authors, plus
    /// duplicate rows for a zone that does. Deleting a `DNS` row is enough to
    /// unpublish it — `Logical_Switch.dns_records` is a weak reference set, so
    /// ovsdb-server drops the UUID from every switch still naming it.
    public static func teardownUUIDs(desired: [DNSZonePlan], observed: [ObservedDNSZone]) -> [String] {
        let wanted = Set(desired.map(\.zoneId))
        let keep = Set(canonicalRows(observed).values.map(\.uuid))
        return
            observed
            .filter { !wanted.contains($0.zoneId) || !keep.contains($0.uuid) }
            .map(\.uuid)
            .sorted()
    }

    /// One row per zone, choosing the lowest UUID when a zone somehow has more.
    private static func canonicalRows(_ observed: [ObservedDNSZone]) -> [UUID: ObservedDNSZone] {
        observed.reduce(into: [:]) { rows, row in
            guard let existing = rows[row.zoneId] else {
                rows[row.zoneId] = row
                return
            }
            if row.uuid < existing.uuid { rows[row.zoneId] = row }
        }
    }
}

extension DNSZoneReconciler {
    /// Converge the northbound database's `DNS` rows toward `zones`.
    ///
    /// Best-effort per zone, like every other reconcile step here: a failing
    /// zone is logged and left for the next level-triggered sync rather than
    /// stalling the rest. Throws only when the row snapshot itself can't be
    /// read, since teardown can't be computed safely without it.
    ///
    /// Callers must not reach this with a nil `dnsZones` field: absence is "no
    /// opinion", and converging an empty list against it would tear down every
    /// live row (see `DesiredStateMessage.dnsZones`).
    public static func reconcile(
        zones: [DesiredDNSZone],
        actuator: any NetworkActuator,
        logger: Logger
    ) async throws {
        let (plans, diagnostics) = plan(zones: zones)
        for diagnostic in diagnostics {
            logger.warning("DNS record not realized: \(diagnostic)")
        }

        let observed = try await actuator.observeDNSZones()

        for write in writes(desired: plans, observed: observed) {
            do {
                try await actuator.ensureDNSZone(write)
            } catch {
                logger.error(
                    "Failed to converge DNS zone",
                    metadata: [
                        "zone": .string(write.plan.zoneName),
                        "zoneId": .string(write.plan.zoneId.uuidString),
                        "error": .string(error.localizedDescription),
                    ])
            }
        }

        for uuid in teardownUUIDs(desired: plans, observed: observed) {
            do {
                try await actuator.removeDNSZone(uuid: uuid)
            } catch {
                logger.error(
                    "Failed to tear down DNS zone row",
                    metadata: ["row": .string(uuid), "error": .string(error.localizedDescription)])
            }
        }
    }
}
