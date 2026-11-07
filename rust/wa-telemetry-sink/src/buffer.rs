//! The bounded buffer between a producer and the export edges.
//!
//! The producer's side is a `Mutex<VecDeque>` push-and-maybe-pop: no I/O, no allocation beyond the
//! record it already owns, no waiting for the exporter. The budget is counted in **encoded bytes**
//! (`Record::encoded_len`), so "bounded" means the same number the wire and the JSONL file use, not a
//! guess multiplied by a struct size.
//!
//! Overflow is `drop-oldest`: the newest fact is the one an operator is asking about, and the loss is
//! counted in `telemetry_dropped` rather than reported as a shorter queue.
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard};

use crate::record::Record;
use crate::stats::Counters;

/// How much the buffer keeps. `max_record_bytes` refuses a single record instead of letting one
/// huge record flush the whole queue.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Bounds {
    pub max_records: usize,
    pub max_bytes: usize,
    pub max_record_bytes: usize,
}

impl Default for Bounds {
    fn default() -> Bounds {
        Bounds {
            max_records: 4096,
            max_bytes: 4 << 20,
            max_record_bytes: 64 << 10,
        }
    }
}

impl Bounds {
    /// The small one the tests use: enough records to prove ordering, small enough to fill with one
    /// burst.
    pub fn for_tests() -> Bounds {
        Bounds { max_records: 256, max_bytes: 1 << 20, max_record_bytes: 4 << 10 }
    }

    /// Worst-case resident bytes the queue can hold. This is what the optimization check compares a
    /// measured RSS delta against (`tests/optimization.rs`).
    pub fn worst_case_bytes(&self) -> usize {
        self.max_bytes.min(self.max_records.saturating_mul(self.max_record_bytes))
    }
}

#[derive(Debug, Default)]
struct Queued {
    items: VecDeque<Record>,
    bytes: usize,
}

/// The ring itself. Cheap to share; the counters live beside it so the exporter and the producer
/// report the same numbers.
#[derive(Debug)]
pub struct Ring {
    bounds: Bounds,
    queued: Mutex<Queued>,
    counters: Arc<Counters>,
}

impl Ring {
    pub fn new(bounds: Bounds, counters: Arc<Counters>) -> Ring {
        Ring { bounds, queued: Mutex::new(Queued::default()), counters }
    }

    pub fn bounds(&self) -> Bounds {
        self.bounds
    }

    fn lock(&self) -> MutexGuard<'_, Queued> {
        // A poisoned lock is a bug in this crate; recovering the data is still better than dropping
        // every later record, and the counters keep the evidence.
        self.queued.lock().unwrap_or_else(|poison| poison.into_inner())
    }

    /// Offer one record. Returns `false` only when the record alone is oversized (it is counted in
    /// both `oversized` and `telemetry_dropped`). Never blocks on I/O and never waits for a drain.
    pub fn push(&self, record: Record) -> bool {
        let size = record.encoded_len();
        if size > self.bounds.max_record_bytes
            || size > self.bounds.max_bytes
            || self.bounds.max_records == 0
            || self.bounds.max_bytes == 0
        {
            self.counters.oversized(1);
            self.counters.dropped(1);
            return false;
        }
        self.counters.inspect(&record);
        let mut queued = self.lock();
        let mut evicted = 0u64;
        while let Some(front) = queued.items.front() {
            let full = queued.items.len() >= self.bounds.max_records || queued.bytes + size > self.bounds.max_bytes;
            if !full {
                break;
            }
            queued.bytes -= front.encoded_len();
            queued.items.pop_front();
            evicted += 1;
        }
        queued.bytes += size;
        queued.items.push_back(record);
        drop(queued);
        self.counters.dropped(evicted);
        self.counters.accepted(1);
        true
    }

    /// Take up to `max` records, oldest first. The caller owns them from here: the sink never
    /// re-queues, so a slow exporter cannot make the queue grow.
    pub fn drain(&self, max: usize) -> Vec<Record> {
        if max == 0 {
            return Vec::new();
        }
        let mut queued = self.lock();
        let count = max.min(queued.items.len());
        let mut out = Vec::with_capacity(count);
        for _ in 0..count {
            if let Some(record) = queued.items.pop_front() {
                queued.bytes -= record.encoded_len();
                out.push(record);
            }
        }
        out
    }

    pub fn len(&self) -> usize {
        self.lock().items.len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn bytes(&self) -> usize {
        self.lock().bytes
    }

    pub fn counters(&self) -> &Arc<Counters> {
        &self.counters
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::{EventRecord, Id, Record, Severity, MAX_ATTRS};
    use crate::stats::Counters;
    use std::sync::Arc;

    fn event(index: u64) -> Record {
        Record::Event(EventRecord {
            topic: Id::new("test.topic"),
            source: Id::new("test-source"),
            schema: Id::new("test.event"),
            schema_version: 1,
            ts_ms: index,
            count: 1,
            severity: Severity::Info,
            trace: None,
            attrs: Default::default(),
        })
    }

    fn ring(records: usize) -> (Ring, Arc<Counters>) {
        let counters = Arc::new(Counters::new());
        let bounds = Bounds { max_records: records, max_bytes: 1 << 20, max_record_bytes: 4 << 10 };
        (Ring::new(bounds, counters.clone()), counters)
    }

    #[test]
    fn overflow_drops_the_oldest_and_counts_it() {
        let (ring, counters) = ring(4);
        for index in 0..6 {
            assert!(ring.push(event(index)));
        }
        assert_eq!(ring.len(), 4);
        let stats = counters.snapshot();
        assert_eq!(stats.accepted, 6);
        assert_eq!(stats.telemetry_dropped, 2);
        let kept = ring.drain(10);
        let stamps: Vec<u64> = kept.iter().map(Record::ts_ms).collect();
        assert_eq!(stamps, vec![2, 3, 4, 5], "the newest survive");
    }

    #[test]
    fn the_byte_budget_also_evicts() {
        let counters = Arc::new(Counters::new());
        let one = event(0).encoded_len();
        let bounds = Bounds { max_records: 100, max_bytes: one * 2, max_record_bytes: 4 << 10 };
        let ring = Ring::new(bounds, counters.clone());
        for index in 0..5 {
            assert!(ring.push(event(index)));
        }
        assert_eq!(ring.len(), 2);
        assert!(ring.bytes() <= one * 2);
        assert_eq!(counters.snapshot().telemetry_dropped, 3);
        assert_eq!(counters.snapshot().oversized, 0);
    }

    #[test]
    fn a_record_bigger_than_the_whole_budget_is_refused_not_kept_over_budget() {
        let counters = Arc::new(Counters::new());
        let one = event(0).encoded_len();
        let bounds = Bounds { max_records: 8, max_bytes: one / 2, max_record_bytes: 4 << 10 };
        let ring = Ring::new(bounds, counters.clone());
        assert!(!ring.push(event(0)));
        assert_eq!(ring.len(), 0);
        assert!(ring.bytes() <= bounds.max_bytes);
        assert_eq!(counters.snapshot().telemetry_dropped, 1);
    }

    #[test]
    fn an_oversized_record_is_refused_whole() {
        let counters = Arc::new(Counters::new());
        let bounds = Bounds { max_records: 16, max_bytes: 1 << 20, max_record_bytes: 40 };
        let ring = Ring::new(bounds, counters.clone());
        let mut big = match event(1) {
            Record::Event(event) => event,
            _ => unreachable!(),
        };
        for index in 0..MAX_ATTRS {
            big.attrs.push(crate::record::Attr::id(&format!("key{index}"), &"v".repeat(40)));
        }
        assert!(!ring.push(Record::Event(big)));
        assert_eq!(ring.len(), 0);
        let stats = counters.snapshot();
        assert_eq!(stats.oversized, 1);
        assert_eq!(stats.telemetry_dropped, 1);
    }

    #[test]
    fn a_zero_budget_refuses_everything_and_counters_inspect_attributes() {
        let counters = Arc::new(Counters::new());
        let ring = Ring::new(Bounds { max_records: 0, max_bytes: 1024, max_record_bytes: 1024 }, counters.clone());
        assert!(!ring.push(event(0)));
        assert_eq!(counters.snapshot().telemetry_dropped, 1);

        let (ring, counters) = ring4();
        let mut record = match event(0) {
            Record::Event(event) => event,
            _ => unreachable!(),
        };
        record.attrs.push(crate::record::Attr::from_text("note", "a sentence with spaces in it"));
        record.attrs.push(crate::record::Attr::from_text("auth", "sk-abcdefghijklmn7f2a"));
        assert!(ring.push(Record::Event(record)));
        let stats = counters.snapshot();
        assert_eq!(stats.attrs_digested, 1);
        assert_eq!(stats.attrs_redacted, 1);
    }

    fn ring4() -> (Ring, Arc<Counters>) {
        ring(4)
    }

    #[test]
    fn drain_is_bounded_and_ordered() {
        let (ring, _) = ring(8);
        for index in 0..5 {
            ring.push(event(index));
        }
        let first = ring.drain(2);
        assert_eq!(first.len(), 2);
        assert_eq!(first[0].ts_ms(), 0);
        assert_eq!(ring.len(), 3);
        assert_eq!(ring.drain(0).len(), 0);
        assert_eq!(ring.drain(10).len(), 3);
        assert!(ring.is_empty());
    }
}
