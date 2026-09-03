import Vapor

extension Application {
    /// Serializes this module's read-modify-write updates to Vapor's value-typed storage.
    private struct StorageWriteLockKey: LockKey {}

    func setStorageValue<Key: StorageKey>(_ key: Key.Type, to value: Key.Value?) {
        let lock = locks.lock(for: StorageWriteLockKey.self)
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    /// Replaces a lazily-created service without racing the getter's first
    /// construction. Both paths take the service key lock before touching
    /// application storage, so a test or bootstrap injection cannot be
    /// overwritten by a getter that observed the old empty value.
    func setService<Key: StorageKey & LockKey>(_ key: Key.Type, to value: Key.Value?) {
        let lock = locks.lock(for: Key.self)
        lock.lock()
        defer { lock.unlock() }
        setStorageValue(Key.self, to: value)
    }

    /// Constructs each lazy service once and stores it without clobbering another key.
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
