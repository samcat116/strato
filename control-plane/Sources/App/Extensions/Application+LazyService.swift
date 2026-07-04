import Vapor

extension Application {
    /// Thread-safe get-or-create for a service lazily held in `Application.storage`.
    ///
    /// Vapor's `storage` subscript is internally locked, but the bare
    /// `if let existing = storage[Key.self] { ... } else { create; store }` pattern
    /// is still a read-modify-write race: two threads racing on first access can both
    /// miss and each create a separate instance, silently discarding one. For services
    /// that spawn background loops in `init` (e.g. ``AgentService``'s heartbeat and
    /// VM-reconciliation tasks) this produces duplicate loops with divergent in-memory
    /// state. Guarding the whole get-or-create with a per-key lock makes it atomic.
    ///
    /// See issue #180.
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
        storage[Key.self] = new
        return new
    }
}
