//! Ring buffer for captured workload stdout/stderr (issue #423).
//!
//! The init captures the workload's stdio via pipes and appends every chunk
//! here as a `(seq, stream, bytes)` record. Sequence numbers start at 1 and
//! are monotonic **across both streams**, so the host can resume a follow
//! stream after a reconnect with `since_seq = last_seen + 1` and never see a
//! record twice.
//!
//! The buffer is bounded by total **payload** bytes ([`MAX_PAYLOAD_BYTES`]):
//! when an append pushes it over, the oldest records are evicted from the
//! front. A host asking for an already-evicted seq simply gets the oldest
//! retained record onward — losing old output is acceptable; blocking the
//! workload or growing without bound is not.
//!
//! Followers block on a condvar ([`LogBuffer::wait_since`]) rather than
//! polling, so a quiet workload costs nothing. This module is portable and
//! unit-tested on any host; only the vsock plumbing around it is Linux-only.

use std::collections::VecDeque;
use std::sync::{Condvar, Mutex};
use std::time::Duration;

/// Cap on the total payload bytes retained across all records (256 KiB).
pub const MAX_PAYLOAD_BYTES: usize = 256 * 1024;

/// One captured chunk of workload output.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LogRecord {
    /// Monotonic sequence number, starting at 1, shared across streams.
    pub seq: u64,
    /// `"stdout"` or `"stderr"`.
    pub stream: &'static str,
    /// The raw chunk bytes, exactly as read from the workload's pipe.
    pub data: Vec<u8>,
}

struct Inner {
    records: VecDeque<LogRecord>,
    /// Seq the next appended record receives; starts at 1.
    next_seq: u64,
    /// Sum of `data.len()` over `records`.
    total_payload: usize,
}

/// Bounded, condvar-notified ring buffer of workload output records.
pub struct LogBuffer {
    inner: Mutex<Inner>,
    appended: Condvar,
    capacity: usize,
}

impl LogBuffer {
    /// A buffer with the production capacity ([`MAX_PAYLOAD_BYTES`]).
    pub fn new() -> Self {
        Self::with_capacity(MAX_PAYLOAD_BYTES)
    }

    /// A buffer bounded to `capacity` payload bytes (tests use small caps).
    pub fn with_capacity(capacity: usize) -> Self {
        LogBuffer {
            inner: Mutex::new(Inner {
                records: VecDeque::new(),
                next_seq: 1,
                total_payload: 0,
            }),
            appended: Condvar::new(),
            capacity,
        }
    }

    /// Append one chunk, assigning it the next sequence number (returned).
    /// Evicts from the front until the payload fits the capacity again; the
    /// newest record is always retained even if it alone exceeds the cap.
    pub fn append(&self, stream: &'static str, data: &[u8]) -> u64 {
        let mut inner = self.inner.lock().expect("log buffer poisoned");
        let seq = inner.next_seq;
        inner.next_seq += 1;
        inner.total_payload += data.len();
        inner.records.push_back(LogRecord {
            seq,
            stream,
            data: data.to_vec(),
        });
        while inner.total_payload > self.capacity && inner.records.len() > 1 {
            if let Some(evicted) = inner.records.pop_front() {
                inner.total_payload -= evicted.data.len();
            }
        }
        self.appended.notify_all();
        seq
    }

    /// All retained records with `seq >= since`. Evicted records are silently
    /// skipped — the result starts at the oldest retained matching record.
    pub fn snapshot_since(&self, since: u64) -> Vec<LogRecord> {
        let inner = self.inner.lock().expect("log buffer poisoned");
        inner
            .records
            .iter()
            .filter(|r| r.seq >= since)
            .cloned()
            .collect()
    }

    /// Like [`snapshot_since`](Self::snapshot_since), but when nothing
    /// matches yet, block up to `timeout` for a new append. Returns an empty
    /// vec on timeout so callers can interleave liveness checks (e.g. probing
    /// whether the follower's connection is still open).
    pub fn wait_since(&self, since: u64, timeout: Duration) -> Vec<LogRecord> {
        let deadline = std::time::Instant::now() + timeout;
        let mut inner = self.inner.lock().expect("log buffer poisoned");
        loop {
            let matching: Vec<LogRecord> = inner
                .records
                .iter()
                .filter(|r| r.seq >= since)
                .cloned()
                .collect();
            if !matching.is_empty() {
                return matching;
            }
            let now = std::time::Instant::now();
            let Some(remaining) = deadline
                .checked_duration_since(now)
                .filter(|d| !d.is_zero())
            else {
                return Vec::new();
            };
            let (guard, result) = self
                .appended
                .wait_timeout(inner, remaining)
                .expect("log buffer poisoned");
            inner = guard;
            if result.timed_out() {
                // Re-check once in case the append raced the timeout.
                return inner
                    .records
                    .iter()
                    .filter(|r| r.seq >= since)
                    .cloned()
                    .collect();
            }
        }
    }
}

impl Default for LogBuffer {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seq_starts_at_one_and_is_monotonic_across_streams() {
        let buf = LogBuffer::new();
        assert_eq!(buf.append("stdout", b"a"), 1);
        assert_eq!(buf.append("stderr", b"b"), 2);
        assert_eq!(buf.append("stdout", b"c"), 3);
    }

    #[test]
    fn snapshot_since_filters_by_seq() {
        let buf = LogBuffer::new();
        buf.append("stdout", b"one");
        buf.append("stderr", b"two");
        buf.append("stdout", b"three");

        let all = buf.snapshot_since(1);
        assert_eq!(all.len(), 3);
        assert_eq!(all[0].data, b"one");

        let tail = buf.snapshot_since(3);
        assert_eq!(tail.len(), 1);
        assert_eq!(tail[0].seq, 3);
        assert_eq!(tail[0].stream, "stdout");
        assert_eq!(tail[0].data, b"three");

        assert!(
            buf.snapshot_since(4).is_empty(),
            "future seq matches nothing"
        );
    }

    #[test]
    fn eviction_drops_oldest_when_over_capacity() {
        let buf = LogBuffer::with_capacity(10);
        buf.append("stdout", b"aaaa"); // seq 1, 4 bytes
        buf.append("stdout", b"bbbb"); // seq 2, 8 bytes
        buf.append("stdout", b"cccc"); // seq 3, 12 bytes -> evict seq 1

        let retained = buf.snapshot_since(1);
        assert_eq!(
            retained.iter().map(|r| r.seq).collect::<Vec<_>>(),
            vec![2, 3],
            "oldest record evicted from the front"
        );
    }

    #[test]
    fn snapshot_since_evicted_seq_starts_at_oldest_retained() {
        let buf = LogBuffer::with_capacity(8);
        buf.append("stdout", b"aaaa");
        buf.append("stdout", b"bbbb");
        buf.append("stdout", b"cccc"); // evicts seq 1 (and seq 2: 12 > 8, then 8 <= 8)

        let retained = buf.snapshot_since(1);
        assert!(!retained.is_empty());
        assert_eq!(retained[0].seq, 2, "delivery starts at oldest retained");
    }

    #[test]
    fn oversized_record_is_still_retained_alone() {
        let buf = LogBuffer::with_capacity(4);
        buf.append("stdout", b"tiny");
        buf.append("stdout", b"this is far too large for the cap");
        let retained = buf.snapshot_since(1);
        assert_eq!(
            retained.len(),
            1,
            "newest record survives even when oversized"
        );
        assert_eq!(retained[0].seq, 2);
    }

    #[test]
    fn wait_since_returns_immediately_when_records_exist() {
        let buf = LogBuffer::new();
        buf.append("stdout", b"hello");
        let got = buf.wait_since(1, Duration::from_secs(5));
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].data, b"hello");
    }

    #[test]
    fn wait_since_times_out_empty_when_nothing_arrives() {
        let buf = LogBuffer::new();
        let got = buf.wait_since(1, Duration::from_millis(10));
        assert!(got.is_empty());
    }

    #[test]
    fn wait_since_wakes_on_append() {
        use std::sync::Arc;
        let buf = Arc::new(LogBuffer::new());
        let waiter = {
            let buf = buf.clone();
            std::thread::spawn(move || buf.wait_since(1, Duration::from_secs(10)))
        };
        // Give the waiter a moment to block, then append.
        std::thread::sleep(Duration::from_millis(50));
        buf.append("stderr", b"woken");
        let got = waiter.join().expect("waiter thread");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].stream, "stderr");
        assert_eq!(got[0].data, b"woken");
    }
}
