import Vapor

extension Application {
    /// The single lock every write this module makes into ``Application``'s
    /// storage is taken under.
    ///
    /// `Application.storage` is a *struct* held in a lock box: the getter copies
    /// the whole container out, the setter puts a whole container back. So
    /// `storage[Key.self] = value` is a read-modify-write of the entire
    /// container, and the box's lock — which spans the get and the set
    /// individually, not the pair — does nothing to make it atomic. Two tasks
    /// writing *different* keys at the same time each mutate their own copy of
    /// the container, and whichever writes back last silently discards the
    /// other's key.
    ///
    /// That is not a theoretical race. `AgentService.init` spawns a task that
    /// creates `app.replicaBridge` (a lazy service, so: a storage write), and a
    /// test that assigned a stub seam on the very next line lost the assignment
    /// to it — leaving the seam unset and its getter's default in force. That
    /// was the `AgentAutoUpdateTests.staleTargetIsReset` CI flake.
    ///
    /// One process-wide lock across all keys is what makes the read-modify-write
    /// atomic; per-key locks cannot, because the hazard is between *different*
    /// keys. It is a leaf lock — no caller-supplied code runs inside it — so it
    /// cannot deadlock against the per-key locks ``lazyService(_:create:)``
    /// takes.
    ///
    /// Writes Vapor itself makes (lazily creating `app.client`, say) don't take
    /// this lock and so can still clobber a concurrent write. Storage writes
    /// therefore belong in `configure`, or behind ``lazyService(_:create:)``;
    /// they are not something to do casually from a request or a background tick.
    private struct StorageWriteLockKey: LockKey {}

    /// Atomically write a value into `Application.storage`.
    ///
    /// Use this in place of `storage[Key.self] = value` for anything hanging off
    /// `Application` — the bare subscript assignment is a read-modify-write of
    /// the whole storage container and drops concurrent writes to other keys.
    /// (`Request.storage` is not affected: a request is handled by one task.)
    func setStorageValue<Key: StorageKey>(_ key: Key.Type, to value: Key.Value?) {
        let lock = locks.lock(for: StorageWriteLockKey.self)
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    /// Thread-safe get-or-create for a service lazily held in `Application.storage`.
    ///
    /// The bare `if let existing = storage[Key.self] { ... } else { create; store }`
    /// pattern races two ways. Two threads racing on first access can both miss and
    /// each create a separate instance, silently discarding one — for services that
    /// spawn background loops in `init` (e.g. ``AgentService``'s heartbeat and
    /// VM-reconciliation tasks) that produces duplicate loops with divergent
    /// in-memory state (issue #180). And the store itself can drop an unrelated
    /// key written concurrently — the `AgentAutoUpdateTests.staleTargetIsReset`
    /// CI flake. The per-key lock closes the first; writing through
    /// ``setStorageValue(_:to:)`` closes the second.
    func lazyService<Key: StorageKey & LockKey>(
        _ key: Key.Type,
        create: () -> Key.Value
    ) -> Key.Value {
        let lock = locks.lock(for: Key.self)
        lock.lock()
        defer { lock.unlock() }
        if let existing = storage[Key.self] {
            return existing
        }
        let new = create()
        setStorageValue(Key.self, to: new)
        return new
    }
}
