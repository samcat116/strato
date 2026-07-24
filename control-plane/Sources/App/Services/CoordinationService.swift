import Foundation
import Valkey
import Vapor

/// Errors thrown at startup when the coordination layer cannot be configured.
/// Valkey is required for control-plane coordination (issue #258): without a
/// shared store, replicas disagree about agent liveness, background sweeps
/// double-act, and concurrent placements race on capacity.
enum CoordinationConfigurationError: Error, CustomStringConvertible {
    case valkeyNotConfigured
    case valkeyUnreachable(host: String, port: Int, underlying: String)

    var description: String {
        switch self {
        case .valkeyNotConfigured:
            return
                "Valkey is required for control-plane coordination but VALKEY_HOST is not set. "
                + "Point VALKEY_HOST (and optionally VALKEY_PORT/VALKEY_PASSWORD) at a Valkey or Redis-compatible instance."
        case .valkeyUnreachable(let host, let port, let underlying):
            return "Valkey at \(host):\(port) is not reachable: \(underlying)"
        }
    }
}

/// Resource amounts held by a placement reservation: what a VM being scheduled
/// will consume on its agent before the agent's own resource reports reflect it.
struct ReservationAmounts: Sendable, Equatable {
    let cpu: Int
    let memory: Int64
    let disk: Int64

    static let zero = ReservationAmounts(cpu: 0, memory: 0, disk: 0)
}

/// Backend primitives for the coordination layer. Two implementations exist: a
/// Valkey-backed store shared by every control-plane process, and an in-process
/// actor used by tests (which run without external services).
///
/// Every key written through this protocol must pass the test: flushing the
/// store degrades to slower convergence, never to incorrect state. Presence
/// keys are rewritten by the next heartbeat, sweep locks only gate work that is
/// idempotent, and reservations exist to narrow a race — losing one reopens the
/// race window, it does not corrupt state.
protocol CoordinationStore: Sendable {
    /// Write `key` with a TTL, unconditionally refreshing both (SETEX semantics).
    func setKey(_ key: String, ttlSeconds: Int) async throws

    /// Whether `key` currently exists (i.e. was written and has not expired).
    func keyExists(_ key: String) async throws -> Bool

    /// Acquire an expiring lock (`SET NX EX` semantics). Returns false when the
    /// lock is already held. There is deliberately no release: holders let the
    /// TTL expire so a lock outlives exactly one pass of the work it gates.
    func acquireLock(_ key: String, ttlSeconds: Int) async throws -> Bool

    /// Atomically reserve `amounts` for `vmId` under `agentKey` if the agent's
    /// existing (unexpired) reservations plus `amounts` fit within `capacity`.
    /// Re-reserving the same `vmId` replaces its previous amounts rather than
    /// double-counting, so a retried placement is idempotent.
    func tryReserve(
        agentKey: String,
        vmId: String,
        amounts: ReservationAmounts,
        capacity: ReservationAmounts,
        ttlSeconds: Int
    ) async throws -> Bool

    /// Release the reservation held by `vmId` under `agentKey` (no-op if absent).
    func releaseReservation(agentKey: String, vmId: String) async throws

    /// VM IDs that currently hold (or recently held — expired entries may
    /// linger until the next prune) reservations under `agentKey`.
    func reservedVMIds(agentKey: String) async throws -> [String]

    /// Sum of all unexpired reservations under `agentKey`.
    func reservedTotal(agentKey: String) async throws -> ReservationAmounts

    /// Write `key` = `value` with a TTL (SET EX semantics), replacing any
    /// existing value and TTL.
    func setValue(_ key: String, value: String, ttlSeconds: Int) async throws

    /// Refresh the paired presence and socket-route keys in one backend
    /// round trip. They share a TTL and are always advanced together.
    func setAgentLiveness(
        presenceKey: String,
        routeKey: String,
        replicaId: String,
        ttlSeconds: Int
    ) async throws

    /// Current value of `key`, or nil when the key is absent or expired.
    func getValue(_ key: String) async throws -> String?

    /// Atomically delete `key` only if it currently holds `value`. Lets a
    /// stale owner (e.g. a replica processing a delayed socket close) clear
    /// its own claim without tearing down a successor's.
    func deleteValue(_ key: String, ifEquals value: String) async throws

    /// Publish `message` to `channel` — fire-and-forget fan-out to current
    /// subscribers, no persistence. Losing a message must always be safe for
    /// callers (pub/sub here carries latency optimizations, never truth).
    func publish(channel: String, message: String) async throws

    /// Subscribe to `channel`, invoking `handler` for every message for the
    /// lifetime of the process.
    func subscribe(channel: String, handler: @escaping @Sendable (String) -> Void) async throws
}

// MARK: - Valkey backend

/// Valkey/Redis-backed coordination store. Reservation accounting runs as Lua
/// scripts so the read-sum-check-write cycle is atomic: two control-plane
/// processes (or two concurrent requests in one process) reserving against the
/// same agent serialize inside Valkey, which is what closes the scheduler's
/// read-decide-write placement race.
///
/// Keyspace layout per agent: `<agentKey>:index` is a set of VM IDs with active
/// reservations, and `<agentKey>:vm:<vmId>` holds that VM's amounts as
/// "cpu:memory:disk" with the reservation TTL. Expired per-VM keys are pruned
/// from the index lazily by the scripts. Keys are derived dynamically inside
/// the scripts, which is fine for standalone Valkey (cluster mode would need
/// hash tags to co-locate them).
struct ValkeyCoordinationStore: CoordinationStore {
    let app: Application

    private static let setAgentLivenessScript = """
        local ttl = tonumber(ARGV[2])
        redis.call('SET', KEYS[1], '1', 'EX', ttl)
        redis.call('SET', KEYS[2], ARGV[1], 'EX', ttl)
        return 1
        """

    /// Sum unexpired reservations (pruning expired index entries), check the
    /// new reservation fits `capacity`, and write it — all atomically. A VM's
    /// own existing reservation is excluded from the sum so re-reserving is a
    /// replace, not a double-count. Returns 1 on success, 0 when full.
    private static let reserveScript = """
        local index = KEYS[1]
        local prefix = ARGV[1]
        local vmId = ARGV[2]
        local cpu = tonumber(ARGV[3])
        local mem = tonumber(ARGV[4])
        local disk = tonumber(ARGV[5])
        local capCpu = tonumber(ARGV[6])
        local capMem = tonumber(ARGV[7])
        local capDisk = tonumber(ARGV[8])
        local ttl = tonumber(ARGV[9])
        local usedCpu, usedMem, usedDisk = 0, 0, 0
        for _, id in ipairs(redis.call('SMEMBERS', index)) do
            local value = redis.call('GET', prefix .. id)
            if value == false then
                redis.call('SREM', index, id)
            elseif id ~= vmId then
                local c, m, d = string.match(value, '^(%d+):(%d+):(%d+)$')
                if c then
                    usedCpu = usedCpu + tonumber(c)
                    usedMem = usedMem + tonumber(m)
                    usedDisk = usedDisk + tonumber(d)
                end
            end
        end
        if usedCpu + cpu > capCpu or usedMem + mem > capMem or usedDisk + disk > capDisk then
            return 0
        end
        redis.call('SET', prefix .. vmId, cpu .. ':' .. mem .. ':' .. disk, 'EX', ttl)
        redis.call('SADD', index, vmId)
        redis.call('EXPIRE', index, ttl * 2)
        return 1
        """

    /// Sum unexpired reservations, pruning expired index entries as a side
    /// effect. Returns {cpu, memory, disk}.
    private static let reservedTotalScript = """
        local index = KEYS[1]
        local prefix = ARGV[1]
        local usedCpu, usedMem, usedDisk = 0, 0, 0
        for _, id in ipairs(redis.call('SMEMBERS', index)) do
            local value = redis.call('GET', prefix .. id)
            if value == false then
                redis.call('SREM', index, id)
            else
                local c, m, d = string.match(value, '^(%d+):(%d+):(%d+)$')
                if c then
                    usedCpu = usedCpu + tonumber(c)
                    usedMem = usedMem + tonumber(m)
                    usedDisk = usedDisk + tonumber(d)
                end
            end
        end
        return {usedCpu, usedMem, usedDisk}
        """

    func setKey(_ key: String, ttlSeconds: Int) async throws {
        _ = try await app.valkey.set(
            ValkeyKey(key), value: "1", expiration: .seconds(max(1, ttlSeconds)))
    }

    func keyExists(_ key: String) async throws -> Bool {
        try await app.valkey.exists(keys: [ValkeyKey(key)]) == 1
    }

    func acquireLock(_ key: String, ttlSeconds: Int) async throws -> Bool {
        // SET ... NX replies +OK when the key was set and Null when it existed.
        let response = try await app.valkey.set(
            ValkeyKey(key), value: "1", condition: .nx, expiration: .seconds(max(1, ttlSeconds)))
        return response != nil
    }

    func tryReserve(
        agentKey: String,
        vmId: String,
        amounts: ReservationAmounts,
        capacity: ReservationAmounts,
        ttlSeconds: Int
    ) async throws -> Bool {
        let response = try await app.valkey.eval(
            script: Self.reserveScript,
            keys: [ValkeyKey(Self.indexKey(agentKey))],
            args: [
                Self.vmKeyPrefix(agentKey),
                vmId,
                String(amounts.cpu),
                String(amounts.memory),
                String(amounts.disk),
                String(capacity.cpu),
                String(capacity.memory),
                String(capacity.disk),
                String(max(1, ttlSeconds)),
            ]
        )
        return try response.decode(as: Int.self) == 1
    }

    func releaseReservation(agentKey: String, vmId: String) async throws {
        _ = try await app.valkey.del(keys: [ValkeyKey(Self.vmKeyPrefix(agentKey) + vmId)])
        _ = try await app.valkey.srem(ValkeyKey(Self.indexKey(agentKey)), members: [vmId])
    }

    func reservedVMIds(agentKey: String) async throws -> [String] {
        let response = try await app.valkey.smembers(ValkeyKey(Self.indexKey(agentKey)))
        return response.compactMap { try? $0.decode(as: String.self) }
    }

    func reservedTotal(agentKey: String) async throws -> ReservationAmounts {
        let response = try await app.valkey.eval(
            script: Self.reservedTotalScript,
            keys: [ValkeyKey(Self.indexKey(agentKey))],
            args: [Self.vmKeyPrefix(agentKey)]
        )

        guard let values = try? response.decode(as: [Int].self), values.count == 3 else {
            throw CoordinationStoreError.unexpectedResponse
        }

        return ReservationAmounts(cpu: values[0], memory: Int64(values[1]), disk: Int64(values[2]))
    }

    func setValue(_ key: String, value: String, ttlSeconds: Int) async throws {
        _ = try await app.valkey.set(
            ValkeyKey(key), value: value, expiration: .seconds(max(1, ttlSeconds)))
    }

    func setAgentLiveness(
        presenceKey: String,
        routeKey: String,
        replicaId: String,
        ttlSeconds: Int
    ) async throws {
        _ = try await app.valkey.eval(
            script: Self.setAgentLivenessScript,
            keys: [ValkeyKey(presenceKey), ValkeyKey(routeKey)],
            args: [replicaId, String(max(1, ttlSeconds))]
        )
    }

    func getValue(_ key: String) async throws -> String? {
        try await app.valkey.get(ValkeyKey(key)).map(String.init)
    }

    /// GET-compare-DEL as a Lua script so the check and the delete are atomic:
    /// a replica clearing its own stale claim can never race a successor's
    /// fresh write in between.
    private static let deleteIfEqualsScript = """
        if redis.call('GET', KEYS[1]) == ARGV[1] then
            return redis.call('DEL', KEYS[1])
        end
        return 0
        """

    func deleteValue(_ key: String, ifEquals value: String) async throws {
        _ = try await app.valkey.eval(
            script: Self.deleteIfEqualsScript,
            keys: [ValkeyKey(key)],
            args: [value]
        )
    }

    func publish(channel: String, message: String) async throws {
        _ = try await app.valkey.publish(channel: channel, message: message)
    }

    /// valkey-swift subscriptions are scoped (`subscribe(to:)` runs a closure
    /// over an AsyncSequence and unsubscribes when it returns), so the
    /// process-lifetime semantics this protocol promises are built here: a
    /// tracked background task re-subscribes whenever the subscription ends —
    /// with backoff on errors — until shutdown cancels it. Messages published
    /// while re-subscribing are lost, which is fine: pub/sub here is a latency
    /// optimization and the periodic sync is the correctness backstop.
    func subscribe(channel: String, handler: @escaping @Sendable (String) -> Void) async throws {
        let client = app.valkey
        let logger = app.logger
        app.valkeyTasks.spawn {
            while !Task.isCancelled {
                do {
                    try await client.subscribe(to: [channel]) { subscription in
                        for try await item in subscription {
                            handler(String(item.message))
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    logger.warning(
                        "Valkey subscription dropped; resubscribing",
                        metadata: ["channel": .string(channel), "error": .string("\(error)")])
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private static func indexKey(_ agentKey: String) -> String { agentKey + ":index" }
    private static func vmKeyPrefix(_ agentKey: String) -> String { agentKey + ":vm:" }
}

enum CoordinationStoreError: Error {
    case unexpectedResponse
}

// MARK: - In-memory backend

/// In-process coordination store used by tests, which run without external
/// services. Semantics mirror the Valkey store: TTL-expired entries behave as
/// absent, lock acquisition is first-writer-wins, and `tryReserve` is atomic
/// (the actor serializes it).
actor InMemoryCoordinationStore: CoordinationStore {
    private struct Reservation {
        let amounts: ReservationAmounts
        let expiresAt: Date
    }

    private var keys: [String: Date] = [:]
    private var locks: [String: Date] = [:]
    private var reservations: [String: [String: Reservation]] = [:]
    private var values: [String: (value: String, expiresAt: Date)] = [:]
    private var subscribers: [String: [@Sendable (String) -> Void]] = [:]

    func setKey(_ key: String, ttlSeconds: Int) {
        keys[key] = Date().addingTimeInterval(TimeInterval(max(1, ttlSeconds)))
    }

    func keyExists(_ key: String) -> Bool {
        guard let expiresAt = keys[key] else { return false }
        guard expiresAt > Date() else {
            keys.removeValue(forKey: key)
            return false
        }
        return true
    }

    func acquireLock(_ key: String, ttlSeconds: Int) -> Bool {
        let now = Date()
        if let expiresAt = locks[key], expiresAt > now {
            return false
        }
        locks[key] = now.addingTimeInterval(TimeInterval(max(1, ttlSeconds)))
        return true
    }

    func tryReserve(
        agentKey: String,
        vmId: String,
        amounts: ReservationAmounts,
        capacity: ReservationAmounts,
        ttlSeconds: Int
    ) -> Bool {
        let active = activeReservations(agentKey: agentKey)
        let others = active.filter { $0.key != vmId }
        let usedCPU = others.values.reduce(0) { $0 + $1.amounts.cpu }
        let usedMemory = others.values.reduce(Int64(0)) { $0 + $1.amounts.memory }
        let usedDisk = others.values.reduce(Int64(0)) { $0 + $1.amounts.disk }

        guard usedCPU + amounts.cpu <= capacity.cpu,
            usedMemory + amounts.memory <= capacity.memory,
            usedDisk + amounts.disk <= capacity.disk
        else {
            return false
        }

        var updated = others
        updated[vmId] = Reservation(
            amounts: amounts,
            expiresAt: Date().addingTimeInterval(TimeInterval(max(1, ttlSeconds)))
        )
        reservations[agentKey] = updated
        return true
    }

    func releaseReservation(agentKey: String, vmId: String) {
        reservations[agentKey]?.removeValue(forKey: vmId)
    }

    func reservedVMIds(agentKey: String) -> [String] {
        Array(activeReservations(agentKey: agentKey).keys)
    }

    func reservedTotal(agentKey: String) -> ReservationAmounts {
        let active = activeReservations(agentKey: agentKey)
        return ReservationAmounts(
            cpu: active.values.reduce(0) { $0 + $1.amounts.cpu },
            memory: active.values.reduce(Int64(0)) { $0 + $1.amounts.memory },
            disk: active.values.reduce(Int64(0)) { $0 + $1.amounts.disk }
        )
    }

    func setValue(_ key: String, value: String, ttlSeconds: Int) {
        values[key] = (value, Date().addingTimeInterval(TimeInterval(max(1, ttlSeconds))))
    }

    func setAgentLiveness(
        presenceKey: String,
        routeKey: String,
        replicaId: String,
        ttlSeconds: Int
    ) {
        let expiresAt = Date().addingTimeInterval(TimeInterval(max(1, ttlSeconds)))
        keys[presenceKey] = expiresAt
        values[routeKey] = (replicaId, expiresAt)
    }

    func getValue(_ key: String) -> String? {
        guard let entry = values[key] else { return nil }
        guard entry.expiresAt > Date() else {
            values.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func deleteValue(_ key: String, ifEquals value: String) {
        guard getValue(key) == value else { return }
        values.removeValue(forKey: key)
    }

    func publish(channel: String, message: String) {
        // Deliver off the actor, mirroring Valkey's asynchronous fan-out, so a
        // handler that re-enters this store never deadlocks the publisher.
        for handler in subscribers[channel] ?? [] {
            Task { handler(message) }
        }
    }

    func subscribe(channel: String, handler: @escaping @Sendable (String) -> Void) {
        subscribers[channel, default: []].append(handler)
    }

    /// Prune and return the unexpired reservations for an agent.
    private func activeReservations(agentKey: String) -> [String: Reservation] {
        let now = Date()
        let active = (reservations[agentKey] ?? [:]).filter { $0.value.expiresAt > now }
        reservations[agentKey] = active.isEmpty ? nil : active
        return active
    }
}

// MARK: - Coordination service

/// Thin coordination layer over Valkey (issue #258, reconciliation phase 0;
/// routing and nudges added in phase 3, issue #261).
///
/// The key families:
/// - `agent:{name}:presence` — agent liveness visible to every control-plane
///   process, written on registration and refreshed on every heartbeat.
/// - `agent:{name}:replica` — which replica holds the agent's WebSocket,
///   written on socket accept and refreshed with presence. Lets any replica
///   route a sync nudge to the process that can actually reach the agent.
/// - `imggrant:agent:{agentId}:image:{imageId}` — the images an agent has been
///   handed download URLs for, written at sync assembly and volume create; the
///   image-download route authorizes an agent's fetch against them (#562).
/// - `lock:sweep:{name}` — expiring locks that make the background sweeps
///   cluster-singletons without leader election.
/// - `resv:agent:{agentId}:*` — placement reservations the scheduler holds
///   between selecting an agent and the agent's resource reports catching up.
///
/// And the channel families (pub/sub, latency optimization only — the agent's
/// periodic sync is the correctness backstop, so lost messages are safe):
/// - `replica:{id}:nudges` — agent names whose desired state changed; the
///   subscribing replica pushes a sync over its local socket.
/// - `replica:{id}:rpc` / `replica:{id}:rpc-replies` — correlated
///   request/response forwarding for the few remaining imperative exchanges
///   (volume operations, reboot) when the caller doesn't hold the socket.
///
/// Degradation policy: coordination improves correctness but must never make
/// the control plane less available than it was without it. Store errors are
/// logged and fail *open* — presence reads return nil (caller falls back to
/// its in-memory view), sweep locks grant (sweeps are idempotent, duplicate
/// passes are harmless), and reservations grant (reopening the placement race
/// is the pre-coordination status quo, while refusing would take VM creation
/// down with Valkey).
actor CoordinationService {
    /// Presence TTL. Agents heartbeat far more often than this, so an expired
    /// presence key means several consecutive heartbeats were missed.
    static let presenceTTLSeconds = 60

    /// Sweep-lock TTL: slightly under the 30s sweep interval so the current
    /// holder's next tick can reacquire, while any other process's tick inside
    /// the same window is excluded.
    static let sweepLockTTLSeconds = 25

    /// Reservation TTL: the backstop when neither a status update nor an
    /// explicit release arrives (e.g. control plane restarts mid-create).
    /// Generous enough to cover a slow create, short enough that leaked
    /// reservations don't wedge placement.
    static let reservationTTLSeconds = 120

    /// Image-download grant TTL (issue #562). This is the grace window: an
    /// agent whose placement is revoked mid-pull keeps fetching until the
    /// grant expires, rather than failing an in-progress download. Long enough
    /// to cover a slow multi-gigabyte pull and its retries, and refreshed by
    /// every periodic sync (~60s) for as long as the placement stands.
    static let imageDownloadGrantTTLSeconds = 30 * 60

    private let store: any CoordinationStore
    private let logger: Logger

    init(store: any CoordinationStore, logger: Logger) {
        self.store = store
        self.logger = logger
    }

    // MARK: Agent presence

    nonisolated static func presenceKey(agentKey: String) -> String {
        "agent:\(agentKey):presence"
    }

    /// Record (or refresh) an agent's presence. Failures are logged, not
    /// thrown: a missed refresh costs one TTL window of cross-process
    /// visibility and the next heartbeat repairs it.
    func recordAgentPresence(agentKey: String, ttlSeconds: Int = CoordinationService.presenceTTLSeconds) async {
        do {
            try await store.setKey(Self.presenceKey(agentKey: agentKey), ttlSeconds: ttlSeconds)
        } catch {
            logger.warning(
                "Failed to record agent presence in coordination store",
                metadata: ["agentKey": .string(agentKey), "error": .string("\(error)")])
        }
    }

    /// Refresh presence and route as one logical liveness record. The Valkey
    /// backend performs both writes in one Lua invocation; callers can safely
    /// throttle this to half the TTL without the two keys drifting apart.
    @discardableResult
    func recordAgentLiveness(
        agentKey: String,
        replicaId: String,
        ttlSeconds: Int = CoordinationService.presenceTTLSeconds
    ) async -> Bool {
        do {
            try await store.setAgentLiveness(
                presenceKey: Self.presenceKey(agentKey: agentKey),
                routeKey: Self.routeKey(agentKey: agentKey),
                replicaId: replicaId,
                ttlSeconds: ttlSeconds
            )
            return true
        } catch {
            logger.warning(
                "Failed to record agent liveness in coordination store",
                metadata: ["agentKey": .string(agentKey), "error": .string("\(error)")])
            return false
        }
    }

    /// Whether the agent's presence key is live. Returns nil when the store
    /// can't answer, so callers can fall back to their in-memory view instead
    /// of treating an outage as universal agent death.
    func isAgentPresent(agentKey: String) async -> Bool? {
        do {
            return try await store.keyExists(Self.presenceKey(agentKey: agentKey))
        } catch {
            logger.warning(
                "Failed to read agent presence from coordination store",
                metadata: ["agentKey": .string(agentKey), "error": .string("\(error)")])
            return nil
        }
    }

    /// Round-trip the store so `/health/ready` can report coordination
    /// reachability. Deliberately the one method here that **rethrows**: every
    /// other caller wants the fail-open degradation described above, but the
    /// health endpoint's whole job is to surface the failure rather than paper
    /// over it. Readiness grades the result as degraded, not fatal, so the
    /// fail-open policy still holds where it matters.
    func probe() async throws {
        _ = try await store.keyExists("health:probe")
    }

    // MARK: Image download grants (issue #562)

    nonisolated static func imageDownloadGrantKey(agentId: String, imageId: UUID) -> String {
        "imggrant:agent:\(agentId):image:\(imageId.uuidString.lowercased())"
    }

    /// Record that the agent was handed download URLs for `imageId` — by a
    /// desired-state sync carrying a VM that boots from it, or by a volume
    /// create that clones it. Written as the URLs are produced, so the grant
    /// is never later than the URL the agent is about to fetch.
    ///
    /// Failures are logged, not thrown: the fetch it authorizes fails open on
    /// the read side, and the next periodic sync rewrites the grant anyway.
    func grantImageDownload(
        agentId: String, imageId: UUID, ttlSeconds: Int = CoordinationService.imageDownloadGrantTTLSeconds
    ) async {
        do {
            try await store.setKey(
                Self.imageDownloadGrantKey(agentId: agentId, imageId: imageId), ttlSeconds: ttlSeconds)
        } catch {
            logger.warning(
                "Failed to record image download grant in coordination store",
                metadata: [
                    "agentId": .string(agentId),
                    "imageId": .string(imageId.uuidString),
                    "error": .string("\(error)"),
                ])
        }
    }

    /// Whether the agent currently holds a grant for `imageId`. Returns nil
    /// when the store can't answer, so the caller can fail open rather than
    /// turn a Valkey outage into a fleet-wide image-pull outage.
    func hasImageDownloadGrant(agentId: String, imageId: UUID) async -> Bool? {
        do {
            return try await store.keyExists(Self.imageDownloadGrantKey(agentId: agentId, imageId: imageId))
        } catch {
            logger.warning(
                "Failed to read image download grant from coordination store",
                metadata: [
                    "agentId": .string(agentId),
                    "imageId": .string(imageId.uuidString),
                    "error": .string("\(error)"),
                ])
            return nil
        }
    }

    // MARK: Singleton sweeps

    /// Acquire the expiring lock for one pass of a background sweep. Returns
    /// false when another process (or an earlier pass) holds it — skip the
    /// pass. Fails open on store errors: the sweeps are the correctness
    /// backstop, and a duplicate idempotent pass beats no pass at all.
    func acquireSweepLock(_ sweepName: String, ttlSeconds: Int = CoordinationService.sweepLockTTLSeconds) async
        -> Bool
    {
        do {
            return try await store.acquireLock("lock:sweep:\(sweepName)", ttlSeconds: ttlSeconds)
        } catch {
            logger.warning(
                "Failed to acquire sweep lock; proceeding without cluster exclusion",
                metadata: ["sweep": .string(sweepName), "error": .string("\(error)")])
            return true
        }
    }

    // MARK: Placement reservations

    nonisolated static func reservationKey(agentId: String) -> String {
        "resv:agent:\(agentId)"
    }

    /// Atomically reserve capacity for a VM on an agent. `capacity` is the
    /// agent's last-reported *available* resources; the store checks that all
    /// active reservations plus this one fit inside it. Returns false when the
    /// agent is (now) full — the caller re-runs selection with fresh data.
    /// Fails open on store errors: an unreserved placement is the
    /// pre-coordination behavior, while refusing would couple VM creation
    /// availability to Valkey.
    func reserveCapacity(
        agentId: String,
        vmId: String,
        amounts: ReservationAmounts,
        capacity: ReservationAmounts,
        ttlSeconds: Int = CoordinationService.reservationTTLSeconds
    ) async -> Bool {
        do {
            return try await store.tryReserve(
                agentKey: Self.reservationKey(agentId: agentId),
                vmId: vmId,
                amounts: amounts,
                capacity: capacity,
                ttlSeconds: ttlSeconds
            )
        } catch {
            logger.warning(
                "Failed to write placement reservation; placing without one",
                metadata: [
                    "agentId": .string(agentId),
                    "vmId": .string(vmId),
                    "error": .string("\(error)"),
                ])
            return true
        }
    }

    /// Release a VM's placement reservation (no-op if it never existed or
    /// already expired). Best-effort: the TTL is the backstop.
    func releaseReservation(agentId: String, vmId: String) async {
        do {
            try await store.releaseReservation(agentKey: Self.reservationKey(agentId: agentId), vmId: vmId)
        } catch {
            logger.warning(
                "Failed to release placement reservation; TTL will reclaim it",
                metadata: [
                    "agentId": .string(agentId),
                    "vmId": .string(vmId),
                    "error": .string("\(error)"),
                ])
        }
    }

    /// Release any reservations held for VMs in `vmIds` — the agent's own
    /// reports now cover them, so keeping the reservation would double-count
    /// their resources until the TTL. Called on every heartbeat with the
    /// agent's reported VM list; reads the (usually empty) reservation index
    /// first so the common case costs one round trip and no deletes.
    /// Best-effort: the TTL is the backstop.
    func releaseReservations(agentId: String, vmIds: [String]) async {
        guard !vmIds.isEmpty else { return }
        do {
            let reserved = try await store.reservedVMIds(agentKey: Self.reservationKey(agentId: agentId))
            guard !reserved.isEmpty else { return }
            for vmId in Set(reserved).intersection(vmIds) {
                try await store.releaseReservation(agentKey: Self.reservationKey(agentId: agentId), vmId: vmId)
            }
        } catch {
            logger.warning(
                "Failed to release reported VMs' reservations; TTL will reclaim them",
                metadata: ["agentId": .string(agentId), "error": .string("\(error)")])
        }
    }

    // MARK: Socket routing (issue #261)

    /// Route TTL matches the presence TTL: both are refreshed together by the
    /// heartbeat path, and a crashed replica's stale route expires in one
    /// window (the agent is effectively offline until it reconnects anyway).
    static let routeTTLSeconds = presenceTTLSeconds

    nonisolated static func routeKey(agentKey: String) -> String {
        "agent:\(agentKey):replica"
    }

    nonisolated static func nudgeChannel(replicaId: String) -> String {
        "replica:\(replicaId):nudges"
    }

    nonisolated static func rpcChannel(replicaId: String) -> String {
        "replica:\(replicaId):rpc"
    }

    nonisolated static func rpcReplyChannel(replicaId: String) -> String {
        "replica:\(replicaId):rpc-replies"
    }

    /// Record (or refresh) which replica holds an agent's WebSocket. Failures
    /// are logged, not thrown: without the route, cross-replica mutations lose
    /// only their nudge latency — the periodic sync converges the agent.
    func recordAgentRoute(
        agentKey: String, replicaId: String, ttlSeconds: Int = CoordinationService.routeTTLSeconds
    ) async {
        do {
            try await store.setValue(
                Self.routeKey(agentKey: agentKey), value: replicaId, ttlSeconds: ttlSeconds)
        } catch {
            logger.warning(
                "Failed to record agent socket route in coordination store",
                metadata: ["agentKey": .string(agentKey), "error": .string("\(error)")])
        }
    }

    /// The replica currently holding the agent's socket, or nil when unknown
    /// (agent offline, route expired, or store unavailable).
    func agentRoute(agentKey: String) async -> String? {
        do {
            return try await store.getValue(Self.routeKey(agentKey: agentKey))
        } catch {
            logger.warning(
                "Failed to read agent socket route from coordination store",
                metadata: ["agentKey": .string(agentKey), "error": .string("\(error)")])
            return nil
        }
    }

    /// Clear the agent's route only if this replica still owns it, so a
    /// delayed close after the agent reconnected elsewhere cannot erase the
    /// successor's claim. Best-effort: the TTL is the backstop.
    func clearAgentRoute(agentKey: String, replicaId: String) async {
        do {
            try await store.deleteValue(Self.routeKey(agentKey: agentKey), ifEquals: replicaId)
        } catch {
            logger.warning(
                "Failed to clear agent socket route; TTL will reclaim it",
                metadata: ["agentKey": .string(agentKey), "error": .string("\(error)")])
        }
    }

    // MARK: Replica pub/sub (issue #261)

    /// Publish a sync nudge for `agentKey` to the replica holding its socket.
    /// Best-effort by design: a lost nudge costs one periodic-sync interval of
    /// latency, never correctness.
    func publishNudge(agentKey: String, toReplica replicaId: String) async {
        do {
            try await store.publish(channel: Self.nudgeChannel(replicaId: replicaId), message: agentKey)
        } catch {
            logger.warning(
                "Failed to publish sync nudge; periodic sync will converge the agent",
                metadata: [
                    "agentKey": .string(agentKey),
                    "replicaId": .string(replicaId),
                    "error": .string("\(error)"),
                ])
        }
    }

    /// Publish on an arbitrary replica channel. Unlike nudges this throws:
    /// RPC callers must learn that their request never left the process.
    func publish(channel: String, message: String) async throws {
        try await store.publish(channel: channel, message: message)
    }

    /// Subscribe to a replica channel for the lifetime of the process.
    func subscribe(channel: String, handler: @escaping @Sendable (String) -> Void) async throws {
        try await store.subscribe(channel: channel, handler: handler)
    }

    /// Sum of the agent's active reservations, for subtracting from its
    /// reported availability before selection. Returns zero on store errors —
    /// selection then sees optimistic numbers, and the atomic reserve step is
    /// still the gate when the store is healthy.
    func activeReservations(agentId: String) async -> ReservationAmounts {
        do {
            return try await store.reservedTotal(agentKey: Self.reservationKey(agentId: agentId))
        } catch {
            logger.warning(
                "Failed to read placement reservations; treating as none",
                metadata: ["agentId": .string(agentId), "error": .string("\(error)")])
            return .zero
        }
    }
}

// MARK: - Application extension

extension Application {
    private struct ReplicaIDKey: StorageKey, LockKey {
        typealias Value = String
    }

    /// This control-plane process's identity for socket routing (issue #261).
    /// Generated fresh at every process start — a restarted replica is a new
    /// replica, and any routes naming the old identity expire by TTL.
    var replicaID: String {
        lazyService(ReplicaIDKey.self) { UUID().uuidString }
    }

    private struct CoordinationServiceKey: StorageKey, LockKey {
        typealias Value = CoordinationService
    }

    /// The coordination service. `configure` installs the Valkey-backed
    /// service (or the in-memory one under `.testing`); the lazy in-memory
    /// fallback exists so unit tests that exercise services without running
    /// `configure` still get working coordination semantics.
    var coordination: CoordinationService {
        get {
            lazyService(CoordinationServiceKey.self) {
                CoordinationService(store: InMemoryCoordinationStore(), logger: logger)
            }
        }
        set {
            setStorageValue(CoordinationServiceKey.self, to: newValue)
        }
    }
}

/// Verifies at boot that Valkey — required for coordination — is actually
/// reachable, so a misconfigured deployment fails fast with a clear error
/// instead of limping along and failing on the first coordinated operation.
/// Runs in `didBootAsync` because the Valkey client's run loop is started
/// during boot (by `ValkeyLifecycleHandler`, registered first), after
/// `configure` returns.
struct CoordinationLifecycleHandler: LifecycleHandler {
    let hostname: String
    let port: Int

    func didBootAsync(_ application: Application) async throws {
        do {
            _ = try await application.valkey.ping()
            application.logger.info(
                "Valkey coordination layer ready",
                metadata: ["hostname": .string(hostname), "port": .stringConvertible(port)])
        } catch {
            let configError = CoordinationConfigurationError.valkeyUnreachable(
                host: hostname, port: port, underlying: "\(error)")
            application.logger.critical("\(configError.description)")
            throw configError
        }
    }
}
