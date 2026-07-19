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
    /// Registered writers (the stdio pumps) that have not finished yet.
    open_writers: usize,
    /// True once at least one writer registered and all of them finished —
    /// no record will ever be appended again.
    closed: bool,
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
                open_writers: 0,
                closed: false,
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

    /// Announce a writer (a stdio pump) that will append records. Register
    /// EVERY writer before any of them can finish — otherwise the first one
    /// completing would transiently drop the count to zero and close the
    /// buffer early.
    pub fn register_writer(&self) {
        let mut inner = self.inner.lock().expect("log buffer poisoned");
        inner.open_writers += 1;
    }

    /// A registered writer finished (its pipe hit EOF, or its pump never
    /// started). When the last one finishes the buffer closes: no record will
    /// ever be appended again, and blocked followers are woken so they can
    /// signal end-of-stream.
    pub fn writer_done(&self) {
        let mut inner = self.inner.lock().expect("log buffer poisoned");
        inner.open_writers = inner.open_writers.saturating_sub(1);
        if inner.open_writers == 0 {
            inner.closed = true;
            self.appended.notify_all();
        }
    }

    /// True once every registered writer has finished — the record stream is
    /// complete and a follower that has drained it can stop following.
    pub fn is_closed(&self) -> bool {
        self.inner.lock().expect("log buffer poisoned").closed
    }

    /// Drop retained history without resetting the sequence or writer state.
    /// Fork re-identification uses this boundary so the destination's log
    /// stream cannot replay output captured under the source sandbox identity.
    pub fn discard_retained(&self) {
        let mut inner = self.inner.lock().expect("log buffer poisoned");
        inner.records.clear();
        inner.total_payload = 0;
        self.appended.notify_all();
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
            if inner.closed {
                // Nothing pending and nothing will ever arrive: don't sit out
                // the timeout, let the follower notice closure immediately.
                return Vec::new();
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
    fn discard_retained_preserves_sequence_and_accepts_future_output() {
        let buf = LogBuffer::new();
        buf.append("stdout", b"source");
        buf.discard_retained();
        assert!(buf.snapshot_since(1).is_empty());
        assert_eq!(buf.append("stdout", b"fork"), 2);
        assert_eq!(buf.snapshot_since(1)[0].data, b"fork");
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
    fn closes_only_after_every_registered_writer_finishes() {
        let buf = LogBuffer::new();
        buf.register_writer();
        buf.register_writer();
        assert!(!buf.is_closed());
        buf.writer_done();
        assert!(!buf.is_closed(), "one writer still open");
        buf.writer_done();
        assert!(buf.is_closed());
    }

    #[test]
    fn wait_since_returns_promptly_once_closed() {
        let buf = LogBuffer::new();
        buf.register_writer();
        buf.writer_done();
        let start = std::time::Instant::now();
        let got = buf.wait_since(1, Duration::from_secs(10));
        assert!(got.is_empty());
        assert!(
            start.elapsed() < Duration::from_secs(1),
            "closed buffer must not sit out the timeout"
        );
    }

    #[test]
    fn close_wakes_a_blocked_waiter() {
        use std::sync::Arc;
        let buf = Arc::new(LogBuffer::new());
        buf.register_writer();
        let waiter = {
            let buf = buf.clone();
            std::thread::spawn(move || buf.wait_since(1, Duration::from_secs(10)))
        };
        std::thread::sleep(Duration::from_millis(50));
        buf.writer_done();
        let got = waiter.join().expect("waiter thread");
        assert!(got.is_empty(), "woken by closure, not by a record");
    }

    #[test]
    fn retained_records_still_deliver_after_close() {
        let buf = LogBuffer::new();
        buf.register_writer();
        buf.append("stdout", b"tail without newline");
        buf.writer_done();
        let got = buf.wait_since(1, Duration::from_millis(10));
        assert_eq!(got.len(), 1, "closure must not swallow retained records");
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
