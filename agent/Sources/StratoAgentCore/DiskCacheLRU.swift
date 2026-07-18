import Foundation
import Logging

/// Size-budgeted LRU sweeping for directory-per-entry disk caches.
///
/// Both agent-side image caches (the VM image cache and the sandbox rootfs
/// cache) share the same shape: each cached image is one directory, the
/// directory's mtime is its last-use marker (touched on every cache hit), and
/// the cache must stay under an operator-configured byte budget. This helper
/// owns the shared mechanics — measuring entries, picking LRU victims, and
/// deleting them — so both caches enforce the budget identically and the
/// logic stays testable without either service.
///
/// Entries used within the grace window are never evicted, even when that
/// keeps the cache over budget: a consumer that just resolved an entry's path
/// may still be copying from it outside the cache actor, and correctness
/// beats the budget. Over-budget-after-sweep is reported so callers can log
/// it rather than silently exceeding the limit.
public enum DiskCacheLRU {

    /// One cache entry: a directory, its recursive size, and when it was
    /// last used (directory mtime).
    public struct Entry: Sendable, Equatable {
        public let path: String
        public let sizeBytes: Int64
        public let lastUsed: Date

        public init(path: String, sizeBytes: Int64, lastUsed: Date) {
            self.path = path
            self.sizeBytes = sizeBytes
            self.lastUsed = lastUsed
        }
    }

    /// Outcome of a sweep, for callers to log and act on.
    public struct SweepResult: Sendable {
        public let evicted: [Entry]
        public let freedBytes: Int64
        /// Total size of the entries that remain after eviction.
        public let remainingBytes: Int64
        /// True when grace-protected entries kept the cache above the target;
        /// the budget is temporarily exceeded rather than risking eviction of
        /// an entry a consumer may still be reading.
        public let stillOverBudget: Bool
    }

    /// Entries newer than this are never evicted. Wide enough to cover a
    /// large image being copied/converted out of the cache after its path
    /// was handed to a consumer.
    public static let defaultGraceInterval: TimeInterval = 30 * 60

    /// Measures each directory as one cache entry: recursive file-size sum,
    /// last-use taken from the directory's own mtime. Directories that
    /// vanish mid-scan are skipped.
    public static func measure(entryDirectories: [String]) -> [Entry] {
        entryDirectories.compactMap { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                attributes[.type] as? FileAttributeType == .typeDirectory
            else { return nil }
            let lastUsed = attributes[.modificationDate] as? Date ?? Date.distantPast
            return Entry(path: path, sizeBytes: directorySize(atPath: path), lastUsed: lastUsed)
        }
    }

    /// Recursive sum of regular-file sizes under a directory.
    public static func directorySize(atPath path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let relative = enumerator.nextObject() as? String {
            let itemPath = path + "/" + relative
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: itemPath),
                attributes[.type] as? FileAttributeType == .typeRegular
            else { continue }
            total += (attributes[.size] as? Int64) ?? 0
        }
        return total
    }

    /// Pure LRU victim selection: oldest-first until the surviving entries
    /// (plus `incomingBytes` about to be added) fit `budgetBytes`. Entries
    /// last used at or after `protectedAfter` are skipped. Ties on last-use
    /// break by path for determinism.
    public static func victims(
        entries: [Entry],
        budgetBytes: Int64,
        incomingBytes: Int64 = 0,
        protectedAfter: Date? = nil
    ) -> [Entry] {
        let target = max(0, budgetBytes - incomingBytes)
        var remaining = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        guard remaining > target else { return [] }

        let byAge = entries.sorted {
            ($0.lastUsed, $0.path) < ($1.lastUsed, $1.path)
        }
        var selected: [Entry] = []
        for entry in byAge {
            if remaining <= target { break }
            if let protectedAfter, entry.lastUsed >= protectedAfter { continue }
            selected.append(entry)
            remaining -= entry.sizeBytes
        }
        return selected
    }

    /// Measures `entryDirectories`, selects LRU victims so the cache (plus
    /// `incomingBytes` about to be downloaded into it) fits `budgetBytes`,
    /// and deletes them. Entries used within `graceInterval` of `now` are
    /// never deleted.
    @discardableResult
    public static func sweep(
        entryDirectories: [String],
        budgetBytes: Int64,
        incomingBytes: Int64 = 0,
        graceInterval: TimeInterval = DiskCacheLRU.defaultGraceInterval,
        now: Date = Date(),
        logger: Logger
    ) -> SweepResult {
        let entries = measure(entryDirectories: entryDirectories)
        let selected = victims(
            entries: entries,
            budgetBytes: budgetBytes,
            incomingBytes: incomingBytes,
            protectedAfter: now.addingTimeInterval(-graceInterval)
        )

        var evicted: [Entry] = []
        var freedBytes: Int64 = 0
        for victim in selected {
            do {
                try FileManager.default.removeItem(atPath: victim.path)
                evicted.append(victim)
                freedBytes += victim.sizeBytes
                logger.info(
                    "Evicted cache entry to stay within the cache size budget",
                    metadata: [
                        "entry": .string(victim.path),
                        "sizeBytes": .stringConvertible(victim.sizeBytes),
                        "lastUsed": .stringConvertible(victim.lastUsed),
                    ])
            } catch {
                // A failed delete (permissions, concurrent removal) must not
                // abort the sweep; the entry simply still counts against the
                // budget next time.
                logger.warning(
                    "Failed to evict cache entry",
                    metadata: [
                        "entry": .string(victim.path),
                        "error": .string(String(describing: error)),
                    ])
            }
        }

        let evictedPaths = Set(evicted.map(\.path))
        let remainingBytes = entries.filter { !evictedPaths.contains($0.path) }
            .reduce(Int64(0)) { $0 + $1.sizeBytes }
        let stillOverBudget = remainingBytes + incomingBytes > budgetBytes
        if stillOverBudget {
            logger.warning(
                "Cache exceeds its size budget; recently used entries are protected from eviction",
                metadata: [
                    "remainingBytes": .stringConvertible(remainingBytes),
                    "incomingBytes": .stringConvertible(incomingBytes),
                    "budgetBytes": .stringConvertible(budgetBytes),
                ])
        }
        return SweepResult(
            evicted: evicted,
            freedBytes: freedBytes,
            remainingBytes: remainingBytes,
            stillOverBudget: stillOverBudget
        )
    }

    /// Marks an entry directory as just-used (mtime = now) so LRU ordering
    /// and the eviction grace window see cache hits, not only downloads.
    public static func touch(entryDirectory: String, now: Date = Date()) {
        try? FileManager.default.setAttributes(
            [.modificationDate: now], ofItemAtPath: entryDirectory)
    }
}
