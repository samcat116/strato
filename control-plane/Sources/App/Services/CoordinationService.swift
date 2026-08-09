import Foundation
import Valkey
import Vapor

/// Errors thrown at startup when a Valkey-backed store cannot be configured.
/// Valkey is required for control-plane coordination (issue #258): without a
/// shared store, replicas disagree about agent liveness, background sweeps
/// double-act, and concurrent placements race on capacity. It is equally
/// required for session storage, which cannot fail open at all.
enum ValkeyConfigurationError: Error, CustomStringConvertible {
    case notConfigured
    case unreachable(role: ValkeyRole, host: String, port: Int, underlying: String)

    var description: String {
        switch self {
        case .notConfigured:
            return
                "Valkey is required for control-plane coordination but VALKEY_HOST is not set. "
                + "Point VALKEY_HOST (and optionally VALKEY_PORT/VALKEY_PASSWORD) at a Valkey or Redis-compatible instance. "
                + "Session storage follows the same endpoint unless SESSION_VALKEY_HOST names another."
        case .unreachable(let role, let host, let port, let underlying):
            return "Valkey (\(role.rawValue) store) at \(host):\(port) is not reachable: \(underlying)"
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
/// store keeps durable state correct. Presence keys are rewritten by the next
/// heartbeat, sweep locks only gate idempotent work, and reservations reduce
/// placement races. Losing one can send a create to a node that filled since
/// selection; the node admission gate refuses it instead of overcommitting.
protocol CoordinationStore: Sendable {
    /// Write `key` with a TTL, unconditionally refreshing both (SETEX semantics).
    func setKey(_ key: String, ttlSeconds: Int) async throws

    /// Whether `key` currently exists (i.e. was written and has not expired).
    func keyExists(_ key: String) async throws -> Bool

    /// Remove `key` now rather than waiting out its TTL.
    func deleteKey(_ key: String) async throws

    /// Presence of every key, in input order, fetched in one store round trip.
    func keysExist(_ keys: [String]) async throws -> [Bool]

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

    /// Sum reservations for every agent key in one pipelined store round trip.
    func reservedTotals(agentKeys: [String]) async throws -> [ReservationAmounts]

    // The value primitives — `setValue`/`getValue`/`deleteValue(_:ifEquals:)`
    // and the paired `setAgentLiveness` write — existed for the
    // `agent:{name}:replica` socket-route key and went with it (STR-152). Every
    // key this store writes now is a presence/lock/grant marker whose *value*
    // carries nothing, which is what `setKey`/`keyExists` are for.

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
    /// Resolved once: this store talks only to the coordination endpoint, which
    /// is a different server from session storage whenever an operator split
    /// them. `app` is still held for the logger and the subscription-task box.
    private let client: ValkeyClient
    /// One script executor per client. Its digest cache is keyed by script name
    /// only, so an executor shared across two clients could `EVALSHA` a digest
    /// against a server that never loaded it.
    private let scripts: ValkeyScriptExecutor

    init(app: Application) {
        self.app = app
        self.client = app.coordinationValkey
        self.scripts = ValkeyScriptExecutor(client: app.coordinationValkey)
    }

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
        _ = try await client.set(
            ValkeyKey(key), value: "1", expiration: .seconds(max(1, ttlSeconds)))
    }

    func deleteKey(_ key: String) async throws {
        _ = try await client.del(keys: [ValkeyKey(key)])
    }

    func keyExists(_ key: String) async throws -> Bool {
        try await client.exists(keys: [ValkeyKey(key)]) == 1
    }

    func keysExist(_ keys: [String]) async throws -> [Bool] {
        guard !keys.isEmpty else { return [] }
        let response = try await client.mget(keys: keys.map { ValkeyKey($0) })
        guard response.count == keys.count else {
            throw CoordinationStoreError.unexpectedResponse
        }
        return response.map {
            if case .null = $0.value { return false }
            return true
        }
    }

    func acquireLock(_ key: String, ttlSeconds: Int) async throws -> Bool {
        // SET ... NX replies +OK when the key was set and Null when it existed.
        let response = try await client.set(
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
        let response = try await scripts.execute(
            name: "coordination.reserve",
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
        _ = try await client.del(keys: [ValkeyKey(Self.vmKeyPrefix(agentKey) + vmId)])
        _ = try await client.srem(ValkeyKey(Self.indexKey(agentKey)), members: [vmId])
    }

    func reservedVMIds(agentKey: String) async throws -> [String] {
        let response = try await client.smembers(ValkeyKey(Self.indexKey(agentKey)))
        return response.compactMap { try? $0.decode(as: String.self) }
    }

    func reservedTotals(agentKeys: [String]) async throws -> [ReservationAmounts] {
        let responses = try await scripts.execute(
            name: "coordination.reserved-total",
            script: Self.reservedTotalScript,
            invocations: agentKeys.map {
                ValkeyScriptExecutor.Invocation(
                    keys: [ValkeyKey(Self.indexKey($0))],
                    args: [Self.vmKeyPrefix($0)]
                )
            }
        )
        return try responses.map(Self.decodeReservationTotal)
    }

    func publish(channel: String, message: String) async throws {
        _ = try await client.publish(channel: channel, message: message)
    }

    /// valkey-swift subscriptions are scoped (`subscribe(to:)` runs a closure
    /// over an AsyncSequence and unsubscribes when it returns), so the
    /// process-lifetime semantics this protocol promises are built here: a
    /// tracked background task re-subscribes whenever the subscription ends —
    /// with backoff on errors — until shutdown cancels it. Messages published
    /// while re-subscribing are lost, which is fine: pub/sub here is a latency
    /// optimization and the periodic sync is the correctness backstop.
    func subscribe(channel: String, handler: @escaping @Sendable (String) -> Void) async throws {
        let client = self.client
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

    private static func decodeReservationTotal(_ response: RESPToken) throws -> ReservationAmounts {
        guard let values = try? response.decode(as: [Int].self), values.count == 3 else {
            throw CoordinationStoreError.unexpectedResponse
        }
        return ReservationAmounts(cpu: values[0], memory: Int64(values[1]), disk: Int64(values[2]))
    }
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
    private var subscribers: [String: [@Sendable (String) -> Void]] = [:]

    func setKey(_ key: String, ttlSeconds: Int) {
        keys[key] = Date().addingTimeInterval(TimeInterval(max(1, ttlSeconds)))
    }

    func deleteKey(_ key: String) {
        keys.removeValue(forKey: key)
    }

    func keyExists(_ key: String) -> Bool {
        guard let expiresAt = keys[key] else { return false }
        guard expiresAt > Date() else {
            keys.removeValue(forKey: key)
            return false
        }
        return true
    }

    func keysExist(_ keys: [String]) -> [Bool] {
        keys.map(keyExists)
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

    func reservedTotals(agentKeys: [String]) -> [ReservationAmounts] {
        agentKeys.map(reservedTotal)
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
/// routing and cross-replica signalling added in phase 3, issue #261; the
/// desired-state doorbell made broadcast in STR-146).
///
/// Since STR-152 nothing here is the final authority for durable state or host
/// capacity: every key and channel below is a latency optimization or a
/// duplicate-work/race guard, and the
/// paths that genuinely needed a distributed directory — the socket-route key
/// `agent:{name}:replica` and the `replica:{id}:rpc` forwarding channels — went
/// with the imperative exchanges that read them.
///
/// The key families:
/// - `agent:{name}:presence` — agent liveness visible to every control-plane
///   process, written on registration and refreshed on every heartbeat.
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
/// - `agent:doorbell` — a fleet-wide broadcast of agent keys whose desired
///   state changed (STR-146). Every replica subscribes and asks its own parked
///   polls and sockets whether it can reach that agent; at most one can, and
///   the rest no-op. Contentless and unrouted on purpose — over-ringing is
///   free, and under-ringing costs only latency because the agent re-fetches
///   unconditionally on its own timer.
///
/// Degradation policy: coordination narrows races but must never make the
/// control plane less available than it was without it. Store errors are
/// logged and fail *open* — presence reads return nil (caller falls back to
/// its in-memory view), sweep locks grant (sweeps are idempotent, duplicate
/// passes are harmless), and reservations grant (reopening the placement race
/// may make one selected node refuse a create, while refusing here would take
/// all VM creation down with Valkey; agent admission prevents overcommit).
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
    /// visibility and the next heartbeat repairs it. Returns whether the write
    /// landed, so a caller throttling refreshes can decline to record a failed
    /// attempt as one and retry on the next frame.
    ///
    /// This used to write presence and the socket-route key together in one Lua
    /// invocation, so the pair could never drift apart under a throttle. The
    /// route key went with the cross-replica RPC bridge (STR-152), leaving one
    /// key and one `SET`.
    @discardableResult
    func recordAgentPresence(
        agentKey: String, ttlSeconds: Int = CoordinationService.presenceTTLSeconds
    ) async -> Bool {
        do {
            try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.setKey(Self.presenceKey(agentKey: agentKey), ttlSeconds: ttlSeconds)
            }
            return true
        } catch {
            logger.warning(
                "Failed to record agent presence in coordination store",
                metadata: ["agentKey": .string(agentKey), "error": .string("\(error)")])
            return false
        }
    }

    /// Drop the agent's presence key immediately, instead of leaving it to
    /// expire. Used by operator teardown (deregister, force-offline): a node
    /// an operator has just torn down must not keep advertising itself as live
    /// for up to a TTL, because the stale-agent sweep skips anything with a
    /// live presence key. Best-effort, like every write here.
    func clearAgentPresence(agentKey: String) async {
        do {
            try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.deleteKey(Self.presenceKey(agentKey: agentKey))
            }
        } catch {
            logger.warning(
                "Failed to clear agent presence in coordination store; TTL will reclaim it",
                metadata: ["agentKey": .string(agentKey), "error": .string("\(error)")])
        }
    }

    /// Whether the agent's presence key is live. Returns nil when the store
    /// can't answer, so callers can fall back to their in-memory view instead
    /// of treating an outage as universal agent death.
    func isAgentPresent(agentKey: String) async -> Bool? {
        do {
            return try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.keyExists(Self.presenceKey(agentKey: agentKey))
            }
        } catch {
            logger.warning(
                "Failed to read agent presence from coordination store",
                metadata: ["agentKey": .string(agentKey), "error": .string("\(error)")])
            return nil
        }
    }

    /// Presence for every agent key, in input order, using one batched store
    /// read. Returns nil when the store is unavailable so placement can keep
    /// the database's online rows under the fail-open policy.
    func agentPresence(agentKeys: [String]) async -> [Bool]? {
        do {
            return try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.keysExist(
                    agentKeys.map { Self.presenceKey(agentKey: $0) })
            }
        } catch {
            logger.warning(
                "Failed to batch-read agent presence from coordination store",
                metadata: ["agentCount": .stringConvertible(agentKeys.count), "error": .string("\(error)")])
            return nil
        }
    }

    /// Deadline for every coordination-store operation. A same-cluster command
    /// round-trips in well under a millisecond, so an operation still outstanding
    /// after this has hit a dropped or stalling connection, not a slow-but-healthy
    /// one. Fail-open behavior must be prompt enough for the caller to continue;
    /// catching valkey-swift's 30-second command timeout is too late for an HTTP
    /// request or an agent's desired-state poll (STR-206).
    static let storeDeadline: Duration = .seconds(2)

    /// Round-trip the store so `/health/ready` can report coordination
    /// reachability. Deliberately the one method here that **rethrows**: every
    /// other caller wants the fail-open degradation described above, but the
    /// health endpoint's whole job is to surface the failure rather than paper
    /// over it. Readiness grades the result as degraded, not fatal, so the
    /// fail-open policy still holds where it matters.
    ///
    /// Bounded by ``storeDeadline``: the underlying client's `commandTimeout`
    /// defaults to 30s (valkey-swift), so a probe issued while the connection is
    /// being torn down would otherwise block for 30s and stall `/health/ready`
    /// long past `timeoutSeconds: 5` — the exact 30s-tail latency behind #731.
    /// Reaching a fail-open verdict must be fast, so cap it here. The timeout
    /// surfaces as the thrown error readiness grades as `degraded` (still 200).
    func probe() async throws {
        let store = self.store
        try await withStoreTimeout(Self.storeDeadline) {
            _ = try await store.keyExists("health:probe")
        }
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
            try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.setKey(
                    Self.imageDownloadGrantKey(agentId: agentId, imageId: imageId), ttlSeconds: ttlSeconds)
            }
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
            return try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.keyExists(Self.imageDownloadGrantKey(agentId: agentId, imageId: imageId))
            }
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
            return try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.acquireLock("lock:sweep:\(sweepName)", ttlSeconds: ttlSeconds)
            }
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
    /// Fails open on store errors: an unreserved placement may be refused by
    /// the selected node if capacity raced away, while refusing here would
    /// couple all VM creation availability to Valkey. Agent admission is the
    /// physical-capacity authority.
    func reserveCapacity(
        agentId: String,
        vmId: String,
        amounts: ReservationAmounts,
        capacity: ReservationAmounts,
        ttlSeconds: Int = CoordinationService.reservationTTLSeconds
    ) async -> Bool {
        do {
            return try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.tryReserve(
                    agentKey: Self.reservationKey(agentId: agentId),
                    vmId: vmId,
                    amounts: amounts,
                    capacity: capacity,
                    ttlSeconds: ttlSeconds
                )
            }
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
            try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.releaseReservation(
                    agentKey: Self.reservationKey(agentId: agentId), vmId: vmId)
            }
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
            try await withStoreTimeout(Self.storeDeadline) {
                let reserved = try await self.store.reservedVMIds(
                    agentKey: Self.reservationKey(agentId: agentId))
                guard !reserved.isEmpty else { return }
                for vmId in Set(reserved).intersection(vmIds) {
                    try await self.store.releaseReservation(
                        agentKey: Self.reservationKey(agentId: agentId), vmId: vmId)
                }
            }
        } catch {
            logger.warning(
                "Failed to release reported VMs' reservations; TTL will reclaim them",
                metadata: ["agentId": .string(agentId), "error": .string("\(error)")])
        }
    }

    // MARK: Replica pub/sub (issue #261)

    /// The one channel every replica listens on for "this agent's desired
    /// state changed" (STR-146). Not `replica:{id}:`-scoped, and deliberately
    /// so: the point of the broadcast doorbell is that a mutation does not have
    /// to know which replica can reach the agent. Each replica decides for
    /// itself whether it holds that agent's parked poll or socket; at most one
    /// does, and the rest no-op.
    ///
    /// Follows the `policy-set:version` precedent, which is the other
    /// fleet-wide broadcast here.
    nonisolated static let doorbellChannel = "agent:doorbell"

    /// Doorbell agent key meaning "every agent". Used by the fleet-wide
    /// callers — a security-group edit, a network change, a site
    /// reconfiguration — whose blast radius is the whole fleet rather than one
    /// placement, so enumerating agent keys to ring them individually would be
    /// a database read that tells the recipients nothing they can't work out
    /// themselves. Not a legal SPIFFE ID, so it cannot collide with a real key.
    nonisolated static let doorbellAllAgents = "*"

    /// Encode a doorbell payload. The publisher's replica id rides along so
    /// subscribers can drop their own echo — every replica receives what it
    /// publishes, and the publisher has already run the local half inline.
    ///
    /// `agentKey` is a SPIFFE ID and contains no `|`, so a single separator is
    /// unambiguous.
    nonisolated static func doorbellPayload(agentKey: String, fromReplica replicaId: String) -> String {
        "\(replicaId)|\(agentKey)"
    }

    /// Split a doorbell payload into its publisher and agent key, or nil if it
    /// is malformed.
    nonisolated static func parseDoorbell(_ payload: String) -> (replicaId: String, agentKey: String)? {
        guard let separator = payload.firstIndex(of: "|") else { return nil }
        let replicaId = String(payload[payload.startIndex..<separator])
        let agentKey = String(payload[payload.index(after: separator)...])
        guard !replicaId.isEmpty, !agentKey.isEmpty else { return nil }
        return (replicaId, agentKey)
    }

    /// Ring the broadcast doorbell for `agentKey`. Best-effort by design: a
    /// lost doorbell costs one poll interval of latency and never correctness,
    /// because the agent re-fetches unconditionally on its own timer regardless
    /// of whether anything rang.
    func publishDoorbell(agentKey: String, fromReplica replicaId: String) async {
        do {
            try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.publish(
                    channel: Self.doorbellChannel,
                    message: Self.doorbellPayload(agentKey: agentKey, fromReplica: replicaId))
            }
        } catch {
            logger.warning(
                "Failed to publish desired-state doorbell; the agent's own re-fetch will converge it",
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

    /// Reservation totals keyed by agent ID, fetched as a single pipeline.
    /// Store failures preserve fail-open behavior by returning zero for every
    /// requested agent. The node remains the final capacity gate; while the
    /// store is healthy these totals avoid predictable API and placement races.
    func activeReservations(agentIds: [String]) async -> [String: ReservationAmounts] {
        guard !agentIds.isEmpty else { return [:] }
        do {
            let totals = try await withStoreTimeout(Self.storeDeadline) {
                try await self.store.reservedTotals(
                    agentKeys: agentIds.map { Self.reservationKey(agentId: $0) })
            }
            guard totals.count == agentIds.count else {
                throw CoordinationStoreError.unexpectedResponse
            }
            return Dictionary(uniqueKeysWithValues: zip(agentIds, totals))
        } catch {
            logger.warning(
                "Failed to batch-read placement reservations; treating as none",
                metadata: ["agentCount": .stringConvertible(agentIds.count), "error": .string("\(error)")])
            return Dictionary(uniqueKeysWithValues: agentIds.map { ($0, .zero) })
        }
    }
}

// MARK: - Application extension

extension Application {
    private struct ReplicaIDKey: StorageKey, LockKey {
        typealias Value = String
    }

    /// This control-plane process's identity, stamped on doorbell broadcasts
    /// (so a replica can ignore its own probe echoes) and on telemetry.
    /// Generated fresh at every process start — a restarted replica is a new
    /// replica.
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

/// Verifies at boot that every Valkey endpoint this process depends on is
/// actually reachable, so a misconfigured deployment fails fast with a clear
/// error instead of limping along and failing on the first coordinated
/// operation — or, for the session store, on the first login.
///
/// Both roles are fatal. Coordination is fail-open *at runtime* (a blip
/// degrades convergence, it does not corrupt state), but an endpoint that is
/// wrong at boot is a configuration error, not a blip, and the session store
/// cannot fail open at all.
///
/// Runs in `didBootAsync` because the clients' run loops are started during
/// boot (by `ValkeyLifecycleHandler`, registered first), after `configure`
/// returns. Pings each *distinct* client once: when both roles share an
/// endpoint they share the instance, and one ping settles both.
struct ValkeyReachabilityLifecycleHandler: LifecycleHandler {
    let configuration: ValkeyStoreConfiguration

    func didBootAsync(_ application: Application) async throws {
        for (role, client) in application.valkeyClients.distinctClients {
            let endpoint = configuration.configuration(for: role)
            do {
                _ = try await client.ping()
                application.logger.info(
                    "Valkey ready",
                    metadata: [
                        "role": .string(
                            configuration.sharesOneInstance ? "coordination+session" : role.rawValue),
                        "hostname": .string(endpoint.hostname),
                        "port": .stringConvertible(endpoint.port),
                    ])
            } catch {
                let configError = ValkeyConfigurationError.unreachable(
                    role: role, host: endpoint.hostname, port: endpoint.port, underlying: "\(error)")
                application.logger.critical("\(configError.description)")
                throw configError
            }
        }
    }
}

/// Thrown by a readiness probe whose round-trip does not complete within its
/// deadline. How it is graded depends on which store timed out: coordination is
/// `degraded` (still 200) under the fail-open policy, session storage is fatal.
/// Either way the point is that the verdict arrives fast rather than after the
/// client's 30s `commandTimeout`.
struct StoreTimeoutError: Error, CustomStringConvertible {
    let deadline: Duration
    var description: String { "store operation exceeded its \(deadline) deadline" }
}

/// Run `operation`, throwing `StoreTimeoutError` if it has not finished
/// within `deadline`. Whichever child finishes first decides the result; the
/// loser is cancelled. valkey-swift honors task cancellation, so a timed-out
/// command stops awaiting the connection instead of running to the client's
/// `commandTimeout`.
///
/// Internal rather than private so the timeout behavior is unit-testable without
/// standing up a Valkey. Production callers include every fail-open coordination
/// operation and the session-store readiness check in `HealthController`.
func withStoreTimeout<Value: Sendable>(
    _ deadline: Duration,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: deadline)
            throw StoreTimeoutError(deadline: deadline)
        }
        // Propagate the first outcome (the operation's success/failure or the
        // timeout), then cancel the loser on the way out.
        defer { group.cancelAll() }
        guard let value = try await group.next() else {
            preconditionFailure("store deadline group had no tasks")
        }
        return value
    }
}
