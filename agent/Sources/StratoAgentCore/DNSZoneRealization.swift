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
        /// Reverse names whose extra targets could not be published, because
        /// OVN's value for a reverse name is one name rather than a list.
        /// Reachable both ways — several authored `PTR` rows union into one
        /// RRset, and two VMs may derive a PTR at one address across
        /// overlapping subnets — so the truncation is reported rather than
        /// only commented on.
        public let truncatedNames: [String]
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
        var truncated: Set<String> = []

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
                let valid = record.values.filter(IPFamily.ipv4.matches)
                if valid.count != record.values.count { malformed.insert(record.name) }
                v4[name, default: []].append(contentsOf: valid)
            case "AAAA":
                let valid = record.values.filter(IPFamily.ipv6.matches)
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
                // Two ways to lose a target here, and both are the operator's
                // to know about: values this call dropped, and a name a
                // previous record already claimed.
                if targets.count > 1 || (reverse[name] != nil && reverse[name] != target) {
                    truncated.insert(name)
                }
                reverse[name] = reverse[name] ?? target
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
            malformedNames: malformed.sorted(),
            truncatedNames: truncated.sorted())
    }
}

// MARK: - Plan and observation

/// One OVN `DNS` row the plan wants: a zone's realizable records and the
/// switches that should answer from them.
public struct DNSZonePlan: Equatable, Sendable {
    public let zoneId: UUID
    public let zoneName: String
    /// The control plane's digest of every record it sent, including the ones
    /// this backend cannot express — so a zone whose only change was a TTL or a
    /// TXT record still restamps the row, and the stamp keeps meaning "written
    /// from this version of the zone". (What it does *not* cover is the
    /// `.external`-view records the control plane withheld, which no agent ever
    /// sees.)
    public let recordsHash: String
    /// The flattened OVN map.
    public let records: [String: String]
    /// The logical switches this row attaches to, sorted and deduplicated.
    public let switchNames: [String]
    /// What this zone asked for that the OVN backend could not realize, in
    /// operator-readable form.
    ///
    /// Carried on the *plan* rather than returned beside it so the caller can
    /// log it exactly when it writes the zone. A diagnostic re-emitted on every
    /// sync — and every sync assembles every zone — would undo the hash-skip's
    /// whole point one layer up, and steady-state noise is what makes a real
    /// diagnostic unreadable.
    public let diagnostics: [String]

    public init(
        zoneId: UUID, zoneName: String, recordsHash: String, records: [String: String],
        switchNames: [String], diagnostics: [String] = []
    ) {
        self.zoneId = zoneId
        self.zoneName = zoneName
        self.recordsHash = recordsHash
        self.records = records
        self.switchNames = switchNames
        self.diagnostics = diagnostics
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
    /// Whether the rewrite is driven by the row's *contents* disagreeing with
    /// the plan while its stamp matched — a hand-edited row, or an agent whose
    /// flattening changed across an upgrade.
    ///
    /// Reported so the repair is visible rather than silent, because there is
    /// one way for it to be permanent: if any value round-trips through OVSDB
    /// non-identically (IPv6 compression, hex case, whitespace in the joined
    /// address list), the stamp matches forever while the contents never do,
    /// and the zone is rewritten on every sync. A drift heal is a one-off; a
    /// heal logged on every pass is that bug, and this is what makes the
    /// difference legible from the logs alone.
    public let healsDrift: Bool
    public let attach: [String]
    public let detach: [String]

    public init(
        plan: DNSZonePlan, existingUUID: String?, rewriteRecords: Bool, healsDrift: Bool = false,
        attach: [String], detach: [String]
    ) {
        self.plan = plan
        self.existingUUID = existingUUID
        self.rewriteRecords = rewriteRecords
        self.healsDrift = healsDrift
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
    /// is one mutation rather than a create. Each plan carries its own
    /// diagnostics, so the caller logs them for the zones it actually writes
    /// rather than on every pass.
    public static func plan(zones: [DesiredDNSZone]) -> [DNSZonePlan] {
        zones.sorted(by: { $0.zoneId.uuidString < $1.zoneId.uuidString }).map { zone in
            let flattened = OVNDNSRecords.flatten(zone.records)
            var diagnostics: [String] = []
            if !flattened.unsupportedTypes.isEmpty {
                diagnostics.append(
                    "\(flattened.unsupportedTypes.joined(separator: ", ")) records, which the OVN resolver "
                        + "cannot answer")
            }
            if !flattened.malformedNames.isEmpty {
                diagnostics.append(
                    "records whose values are not valid for their type "
                        + "(\(flattened.malformedNames.joined(separator: ", ")))")
            }
            if !flattened.truncatedNames.isEmpty {
                diagnostics.append(
                    "reverse names with more than one target, of which OVN publishes only the first "
                        + "(\(flattened.truncatedNames.joined(separator: ", ")))")
            }
            return DNSZonePlan(
                zoneId: zone.zoneId,
                zoneName: zone.zoneName,
                recordsHash: zone.recordsHash,
                records: flattened.records,
                switchNames: Set(zone.networkIds.map { OVNNaming.switchName(networkId: $0) }).sorted(),
                diagnostics: diagnostics)
        }
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
            let stampMoved = existing.recordsHash != plan.recordsHash
            let contentsDiffer = existing.records != plan.records || existing.zoneName != plan.zoneName
            let write = DNSZoneWrite(
                plan: plan,
                existingUUID: existing.uuid,
                rewriteRecords: stampMoved || contentsDiffer,
                healsDrift: !stampMoved && contentsDiffer,
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
    @discardableResult
    public static func reconcile(
        zones: [DesiredDNSZone],
        networkIDsBySwitchName: [String: UUID] = [:],
        actuator: any NetworkActuator,
        logger: Logger
    ) async throws -> [ReconcileStepFailure] {
        let plans = plan(zones: zones)
        let observed = try await actuator.observeDNSZones()
        let networkIDsByZone = Dictionary(
            uniqueKeysWithValues: zones.map { ($0.zoneId, Set($0.networkIds)) })
        var failures: [ReconcileStepFailure] = []

        for write in writes(desired: plans, observed: observed) {
            // Logged per write rather than per pass: every sync assembles every
            // zone, so a zone holding one TXT record would otherwise warn
            // forever on the authority agent. Tied to the write, it fires when
            // the zone changes — which is when an operator can act on it.
            for diagnostic in write.plan.diagnostics where write.rewriteRecords {
                logger.warning(
                    "Part of a DNS zone is not realized",
                    metadata: [
                        "zone": .string(write.plan.zoneName),
                        "unrealized": .string(diagnostic),
                    ])
            }
            // A one-off heal is the feature; the same zone healing on every
            // pass is the OVSDB round-trip bug this makes visible.
            if write.healsDrift {
                logger.info(
                    "Rewriting a DNS zone whose row drifted from its stamp",
                    metadata: ["zone": .string(write.plan.zoneName)])
            }
            if let failure = await observeAttempt(
                logger,
                "converge DNS zone \(write.plan.zoneName)",
                affectedNetworkIds: networkIDsByZone[write.plan.zoneId] ?? [],
                { try await actuator.ensureDNSZone(write) })
            {
                failures.append(failure)
            }
        }

        let observedByUUID = Dictionary(uniqueKeysWithValues: observed.map { ($0.uuid, $0) })
        for uuid in teardownUUIDs(desired: plans, observed: observed) {
            let affectedNetworkIDs = Set(
                observedByUUID[uuid]?.switchNames.compactMap { networkIDsBySwitchName[$0] } ?? [])
            if let failure = await observeAttempt(
                logger,
                "tear down DNS zone row \(uuid)",
                affectedNetworkIds: affectedNetworkIDs,
                { try await actuator.removeDNSZone(uuid: uuid) })
            {
                failures.append(failure)
            }
        }
        return failures
    }
}
