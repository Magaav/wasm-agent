//! The tests are the specification: ordering, freshness, leases, backoff, alerting, restart.

use crate::*;
use std::sync::Arc;

const T0: i64 = 1_700_000_000_000;

struct Fixture {
    kv: Arc<MemoryKv>,
    clock: Arc<FixedClock>,
    policy: Policy,
    queue: Queue,
}

impl Fixture {
    fn new() -> Self {
        Self::with(Policy::default())
    }

    fn with(policy: Policy) -> Self {
        let kv = Arc::new(MemoryKv::new());
        let clock = Arc::new(FixedClock::new(T0));
        let queue = Queue::new(kv.clone(), clock.clone(), policy.clone());
        Self {
            kv,
            clock,
            policy,
            queue,
        }
    }

    /// A new queue over the same bytes: a process restart, nothing carried in memory.
    fn restart(&self) -> Queue {
        Queue::new(self.kv.clone(), self.clock.clone(), self.policy.clone())
    }

    fn enqueue(&self, queue: &str, payload: &[u8]) -> JobId {
        self.queue
            .enqueue(EnqueueRequest::new(queue, payload.to_vec()))
            .expect("enqueue")
            .id
    }

    fn take(&self, queue: &str, worker: &str) -> Job {
        self.queue
            .take(queue, worker, None)
            .expect("take")
            .job()
            .expect("a job")
    }

    fn now(&self) -> i64 {
        self.clock.now_ms()
    }
}

fn job(f: &Fixture, id: JobId) -> Job {
    f.queue.job(id).expect("load").expect("job exists")
}

// ------------------------------------------------------------------ basics

#[test]
fn a_handover_returns_the_lease_without_spending_an_attempt() {
    let f = Fixture::new();
    let first = f.enqueue("stt", b"one");
    let second = f.enqueue("stt", b"two");
    let third = f.enqueue("stt", b"three");
    let leased = f.take("stt", "comp.1:w1");
    assert_eq!(leased.id, first);

    // The retired instance's lease goes back, immediately, with its attempt budget untouched.
    assert_eq!(f.queue.handover("stt", "comp.1:").expect("handover"), 1);
    let back = job(&f, first);
    assert_eq!(back.state, JobState::Ready);
    assert_eq!(back.lease_worker, None);
    assert_eq!(back.lease_until, None);
    assert_eq!(back.not_before, f.now(), "a handover is due now, not after a retry delay");
    assert_eq!(back.attempts, 0, "the job did not fail");
    assert_eq!(back.lease_expiries, 0, "nor did it lose its lease");
    assert_eq!(back.last_error, None);

    // The old worker cannot settle what it no longer holds - that is the fence.
    assert_eq!(f.queue.done_by(first, "comp.1:w1", b"late").unwrap_err(), QueueError::LeaseLost);
    assert_eq!(f.queue.fail_by(first, "comp.1:w1", "late").unwrap_err(), QueueError::LeaseLost);

    // The instance that replaced it takes all three, once each, oldest first.
    let taken: Vec<JobId> = (0..3).map(|_| f.take("stt", "comp.2:w1").id).collect();
    assert_eq!(taken, vec![first, second, third]);
    assert!(matches!(f.queue.take("stt", "comp.2:w1", None).expect("take"), TakeOutcome::Empty));
    for id in [first, second, third] {
        assert_eq!(f.queue.done_by(id, "comp.2:w1", b"ok").expect("settle").state, JobState::Done);
    }
    let stats = f.queue.stats("stt").expect("stats");
    assert_eq!((stats.ready, stats.leased, stats.done), (0, 0, 3), "none lost, none duplicated: {stats:?}");

    // A prefix that matches nothing is not an error, and an empty one is (it would match everyone).
    assert_eq!(f.queue.handover("stt", "comp.9:").expect("nothing in flight"), 0);
    assert!(f.queue.handover("stt", "").is_err());
}

/// The read-only twin of `handover`: what a swap asks before it decides to wait for an instance to
/// finish (`docs/SERVICE-COMPONENTS.md`, "A swap waits for the work in flight"). It must agree with
/// `handover` job for job - the failure it prevents is a swap that waits 30 s for work that was never
/// there, or skips the wait while a lease is held.
#[test]
fn in_flight_counts_exactly_the_leases_a_handover_would_take_back() {
    let f = Fixture::new();
    let mine = f.enqueue("stt", b"mine");
    let theirs = f.enqueue("stt", b"theirs");
    assert_eq!(f.queue.in_flight("stt", "comp.1:").expect("count"), 0, "nothing taken yet");

    let my_lease = f.take("stt", "comp.1:w1");
    assert_eq!(my_lease.id, mine);
    f.take("stt", "comp.2:w1");
    assert_eq!(f.queue.in_flight("stt", "comp.1:").expect("count"), 1, "only this prefix's lease");
    assert_eq!(f.queue.in_flight("stt", "comp.2:").expect("count"), 1);
    assert_eq!(f.queue.in_flight("stt", "comp.").expect("count"), 2, "a longer prefix sees both");

    // Exactly the leases the count named are the ones handed back, and the count then reads zero.
    assert_eq!(f.queue.in_flight("stt", "comp.1:").expect("count"), 1);
    assert_eq!(f.queue.handover("stt", "comp.1:").expect("handover"), 1);
    assert_eq!(f.queue.in_flight("stt", "comp.1:").expect("count"), 0);
    assert_eq!(job(&f, mine).state, JobState::Ready);
    assert_eq!(job(&f, theirs).state, JobState::Leased, "another instance's work is not ours to count");

    // A settled job is not in flight, even while its settlement is the last thing that happened.
    f.queue.done_by(theirs, "comp.2:w1", b"ok").expect("settle");
    assert_eq!(f.queue.in_flight("stt", "comp.2:").expect("count"), 0);
    // The same two refusals as `handover`: a bad name, and an empty prefix (which would name every
    // worker, including the one taking over).
    assert!(f.queue.in_flight("stt", "").is_err());
    assert!(f.queue.in_flight("", "comp.1:").is_err());
}

#[test]
fn a_handover_leaves_another_instances_lease_alone_and_expires_stale_work() {
    let f = Fixture::new();
    let mine = f.enqueue("stt", b"mine");
    f.queue
        .enqueue(EnqueueRequest::new("stt", b"stale".to_vec()).fresh_for(1_000))
        .expect("enqueue");
    let held = f.take("stt", "comp.2:w1");
    assert_eq!(held.id, mine);
    let stale = f.take("stt", "comp.1:w1");
    assert_ne!(stale.id, mine, "the live instance's job is the one taken first");
    f.clock.advance(2_000);

    // Only the prefix's own lease moves; the live instance keeps the one it holds.
    assert_eq!(f.queue.handover("stt", "comp.1:").expect("handover"), 1);
    assert_eq!(job(&f, mine).state, JobState::Leased, "another instance's lease is not this swap's");
    assert_eq!(job(&f, stale.id).state, JobState::Expired, "stale work is never handed to the next instance");
}

#[test]
fn enqueue_take_done_roundtrip_keeps_bytes_exact() {
    let f = Fixture::new();
    let payload: Vec<u8> = (0u8..=255).collect();
    let id = f.enqueue("stt", &payload);
    assert_eq!(job(&f, id).state, JobState::Ready);
    assert_eq!(job(&f, id).payload, payload);

    let leased = f.take("stt", "w1");
    assert_eq!(leased.id, id);
    assert_eq!(leased.state, JobState::Leased);
    assert_eq!(leased.payload, payload);
    assert_eq!(leased.lease_worker.as_deref(), Some("w1"));
    assert_eq!(leased.lease_until, Some(T0 + f.policy.lease_ms));

    let settled = f.queue.done_by(id, "w1", &[0, 1, 2, 159]).expect("done");
    assert_eq!(settled.state, JobState::Done);
    assert_eq!(settled.result.as_deref(), Some(&[0, 1, 2, 159][..]));
    assert_eq!(settled.lease_worker, None);
    assert!(f.queue.take("stt", "w1", None).expect("take") == TakeOutcome::Empty);

    let stats = f.queue.stats("stt").expect("stats");
    assert_eq!(stats.done, 1);
    assert_eq!(stats.ready, 0);
    assert_eq!(stats.leased, 0);
}

#[test]
fn dedupe_key_names_one_job_per_queue() {
    let f = Fixture::new();
    let first = f
        .queue
        .enqueue(EnqueueRequest::new("stt", b"a".to_vec()).dedupe("msg-1"))
        .expect("enqueue");
    assert!(!first.dedupe_hit);
    let second = f
        .queue
        .enqueue(EnqueueRequest::new("stt", b"other payload".to_vec()).dedupe("msg-1"))
        .expect("enqueue");
    assert!(second.dedupe_hit);
    assert_eq!(second.id, first.id);
    assert_eq!(f.queue.list("stt", None, 10).expect("list").len(), 1);
    // The stored payload is the first one, not the duplicate's.
    assert_eq!(job(&f, first.id).payload, b"a".to_vec());

    // Another queue is another job, and the same key after settling still names the old record
    // (dedupe is released by reap, not by completion).
    let other = f
        .queue
        .enqueue(EnqueueRequest::new("ocr", b"a".to_vec()).dedupe("msg-1"))
        .expect("enqueue");
    assert!(!other.dedupe_hit);
    assert_ne!(other.id, first.id);
    f.queue.done_by(first.id, "w", &[]).ok();
    let again = f
        .queue
        .enqueue(EnqueueRequest::new("stt", b"a".to_vec()).dedupe("msg-1"))
        .expect("enqueue");
    assert!(again.dedupe_hit);
    assert_eq!(again.id, first.id);
}

#[test]
fn a_dedupe_claim_left_by_a_crash_is_reclaimed() {
    let f = Fixture::new();
    let first = f
        .queue
        .enqueue(EnqueueRequest::new("stt", b"a".to_vec()).dedupe("k"))
        .expect("enqueue");
    // Simulate the crash window: the claim landed, the job record did not.
    for (key, _) in f.kv.entries() {
        if key.starts_with(b"j/") || key.starts_with(b"i/") {
            f.kv.remove_raw(&key);
        }
    }
    assert!(f.queue.job(first.id).expect("job").is_none());
    let second = f
        .queue
        .enqueue(EnqueueRequest::new("stt", b"a".to_vec()).dedupe("k"))
        .expect("enqueue");
    assert!(!second.dedupe_hit);
    assert_ne!(second.id, first.id);
    assert!(f.take("stt", "w").id == second.id);
}

#[test]
fn higher_priority_first_then_fifo() {
    let f = Fixture::with(Policy::default().with_concurrency("q", 8));
    let low_a = f
        .queue
        .enqueue(EnqueueRequest::new("q", b"low-a".to_vec()))
        .expect("enqueue")
        .id;
    let high_a = f
        .queue
        .enqueue(EnqueueRequest::new("q", b"high-a".to_vec()).priority(5))
        .expect("enqueue")
        .id;
    let low_b = f
        .queue
        .enqueue(EnqueueRequest::new("q", b"low-b".to_vec()))
        .expect("enqueue")
        .id;
    let high_b = f
        .queue
        .enqueue(EnqueueRequest::new("q", b"high-b".to_vec()).priority(5))
        .expect("enqueue")
        .id;
    assert_eq!(f.take("q", "w").id, high_a);
    assert_eq!(f.take("q", "w").id, high_b);
    assert_eq!(f.take("q", "w").id, low_a);
    assert_eq!(f.take("q", "w").id, low_b);
    assert_eq!(
        f.queue.take("q", "w", None).expect("take"),
        TakeOutcome::Empty
    );
}

#[test]
fn a_not_before_job_does_not_hide_a_due_one_behind_it() {
    let f = Fixture::with(Policy::default().with_concurrency("q", 2));
    let later = f
        .queue
        .enqueue(
            EnqueueRequest::new("q", b"later".to_vec())
                .priority(9)
                .not_before(T0 + 5_000),
        )
        .expect("enqueue")
        .id;
    let now_job = f.enqueue("q", b"now");
    assert_eq!(f.take("q", "w").id, now_job);
    assert_eq!(
        f.queue.take("q", "w", None).expect("take"),
        TakeOutcome::Empty
    );
    f.clock.advance(5_000);
    assert_eq!(f.take("q", "w").id, later);
}

#[test]
fn per_queue_concurrency_limit_is_honoured() {
    let f = Fixture::with(
        Policy {
            concurrency: 2,
            ..Policy::default()
        }
        .with_concurrency("ocr", 1),
    );
    for _ in 0..3 {
        f.enqueue("stt", b"x");
    }
    let a = f.take("stt", "w1");
    let b = f.take("stt", "w2");
    assert_eq!(
        f.queue.take("stt", "w3", None).expect("take"),
        TakeOutcome::AtLimit {
            leased: 2,
            limit: 2
        }
    );
    f.queue.done_by(a.id, "w1", &[]).expect("done");
    assert_ne!(f.take("stt", "w3").id, a.id);
    assert!(b.id != JobId(0));

    f.enqueue("ocr", b"y");
    f.enqueue("ocr", b"z");
    f.take("ocr", "w1");
    assert_eq!(
        f.queue.take("ocr", "w2", None).expect("take"),
        TakeOutcome::AtLimit {
            leased: 1,
            limit: 1
        }
    );
}

// ------------------------------------------------------------------ leases and crashes

#[test]
fn lease_expiry_returns_the_job_without_spending_an_attempt() {
    let f = Fixture::new();
    let id = f.enqueue("stt", b"a");
    let first = f.queue.take("stt", "w1", Some(1_000)).expect("take");
    assert!(matches!(first, TakeOutcome::Job(_)));
    assert_eq!(
        f.queue.take("stt", "w2", None).expect("take"),
        TakeOutcome::Empty,
        "a live lease is not stolen"
    );
    f.clock.advance(1_001);
    let again = f.take("stt", "w2");
    assert_eq!(again.id, id);
    assert_eq!(again.attempts, 0, "a lost lease is not a failed attempt");
    assert_eq!(again.lease_expiries, 1);
}

#[test]
fn heartbeat_extends_a_lease_and_lapses_with_it() {
    let f = Fixture::new();
    let id = f.enqueue("stt", b"a");
    f.queue.take("stt", "w1", Some(1_000)).expect("take");
    let until = f.queue.heartbeat(id, "w1", Some(900)).expect("heartbeat");
    assert_eq!(until, T0 + 900);
    assert_eq!(job(&f, id).lease_until, Some(T0 + 900));
    f.clock.advance(901);
    let second = f.take("stt", "w2");
    assert_eq!(second.lease_worker.as_deref(), Some("w2"));
    // The old worker learns it lost the job instead of settling it.
    assert_eq!(
        f.queue.heartbeat(id, "w1", None),
        Err(QueueError::LeaseLost)
    );
    assert_eq!(
        f.queue.done_by(id, "w1", b"stale"),
        Err(QueueError::LeaseLost)
    );
    assert_eq!(
        f.queue.done_by(id, "w2", b"fresh").expect("done").state,
        JobState::Done
    );
}

#[test]
fn settling_a_job_nobody_holds_is_refused() {
    let f = Fixture::with(Policy {
        max_attempts: 1,
        ..Policy::default()
    });
    let id = f.enqueue("stt", b"a");
    assert_eq!(f.queue.done(id, b"r"), Err(QueueError::LeaseLost));
    assert_eq!(f.queue.fail(id, "nope"), Err(QueueError::LeaseLost));
    assert_eq!(
        f.queue.done(JobId(999_999), b"r"),
        Err(QueueError::NotFound)
    );
    let _ = f.take("stt", "w");
    f.queue.fail(id, "broken").expect("fail");
    assert_eq!(f.queue.done(id, b"r"), Err(QueueError::LeaseLost));
}

#[test]
fn a_lease_lost_too_often_is_dead_lettered_rather_than_looping() {
    let f = Fixture::with(Policy {
        max_lease_losses: 1,
        ..Policy::default()
    });
    let id = f.enqueue("stt", b"a");
    f.queue.take("stt", "w", Some(100)).expect("take");
    f.clock.advance(101);
    let retaken = f
        .queue
        .take("stt", "w", Some(100))
        .expect("take")
        .job()
        .expect("job");
    assert_eq!(retaken.id, id);
    assert_eq!(retaken.lease_expiries, 1);
    f.clock.advance(101);
    // Second loss exceeds max_lease_losses (1): dead, with an alert.
    assert_eq!(
        f.queue.take("stt", "w", None).expect("take"),
        TakeOutcome::Empty
    );
    let dead = job(&f, id);
    assert_eq!(dead.state, JobState::Dead);
    assert_eq!(dead.last_error.as_deref(), Some("lease_lost"));
    let alerts = f.queue.alerts(None, 10).expect("alerts");
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].kind, AlertKind::Dead);
}

#[test]
fn restart_keeps_everything_and_recovers_a_dead_workers_lease() {
    let f = Fixture::new();
    let id = f.enqueue("stt", b"payload");
    let taken = f.take("stt", "w1");
    assert_eq!(taken.id, id);

    let after = f.restart();
    let still = after.job(id).expect("load").expect("job");
    assert_eq!(still.state, JobState::Leased);
    assert_eq!(still.payload, b"payload".to_vec());
    assert_eq!(
        after.take("stt", "w2", None).expect("take"),
        TakeOutcome::Empty,
        "the lease is still valid after a restart"
    );

    f.clock.advance(f.policy.lease_ms + 1);
    let redo = after
        .take("stt", "w2", None)
        .expect("take")
        .job()
        .expect("job");
    assert_eq!(redo.id, id);
    assert_eq!(redo.payload, b"payload".to_vec());
    assert_eq!(redo.attempts, 0);
    assert_eq!(redo.lease_expiries, 1);
    assert_eq!(
        after.done_by(id, "w2", b"ok").expect("done").state,
        JobState::Done
    );
}

#[test]
fn repair_restores_derived_keys_and_drops_orphans() {
    let f = Fixture::new();
    let id = f
        .queue
        .enqueue(EnqueueRequest::new("stt", vec![1]).dedupe("k"))
        .expect("enqueue")
        .id;
    // A crash after the record but before the index and dedupe writes.
    for (key, _) in f.kv.entries() {
        if key.starts_with(b"i/") || key.starts_with(b"d/") {
            f.kv.remove_raw(&key);
        }
    }
    assert_eq!(
        f.queue.take("stt", "w", None).expect("take"),
        TakeOutcome::Empty
    );
    let fixed = f.queue.repair().expect("repair");
    assert_eq!(fixed.index_added, 1);
    assert_eq!(fixed.dedupe_added, 1);
    assert_eq!(f.take("stt", "w").id, id);

    // An index entry for a job that does not exist is removed, not taken.
    let orphan_queue = "ghost";
    let orphan = b"i/ghost/R\x00\x00\x00\x00\x00\x00\x00\x00\x07".to_vec();
    f.kv.put_raw(&orphan, &[]);
    let fixed = f.queue.repair().expect("repair");
    assert_eq!(fixed.index_removed, 1);
    assert!(f.queue.stats(orphan_queue).expect("stats").ready == 0);
    assert_eq!(
        f.queue.take(orphan_queue, "w", None).expect("take"),
        TakeOutcome::Empty
    );
}

#[test]
fn reap_retires_terminal_records_and_releases_dedupe() {
    let f = Fixture::with(Policy {
        done_retention_ms: 1_000,
        ..Policy::default()
    });
    let id = f
        .queue
        .enqueue(EnqueueRequest::new("stt", b"a".to_vec()).dedupe("k"))
        .expect("enqueue")
        .id;
    f.queue.take("stt", "w", None).expect("take");
    f.queue.progress(id, b"part").expect("progress");
    f.queue.done(id, b"result").expect("done");

    f.clock.advance(1_001);
    let swept = f.queue.sweep().expect("sweep");
    assert_eq!(swept.reaped, 1);
    assert!(f.queue.job(id).expect("job").is_none());
    assert!(f
        .queue
        .progress_since(id, 0, 10)
        .expect("progress")
        .is_empty());
    // The key may be used again now that the record is gone.
    let again = f
        .queue
        .enqueue(EnqueueRequest::new("stt", b"a".to_vec()).dedupe("k"))
        .expect("enqueue");
    assert!(!again.dedupe_hit);
    assert_ne!(again.id, id);
}

// ------------------------------------------------------------------ retries

#[test]
fn fail_backs_off_exponentially_and_dead_letters_at_max_attempts() {
    let f = Fixture::with(Policy {
        max_attempts: 4,
        retry: RetryPolicy {
            base_ms: 1_000,
            max_ms: 3_000,
        },
        ..Policy::default()
    });
    let id = f.enqueue("stt", b"a");
    let expected = [1_000, 2_000, 3_000];
    for (index, delay) in expected.iter().enumerate() {
        let taken = f.take("stt", "w");
        assert_eq!(taken.id, id);
        assert_eq!(taken.attempts as usize, index);
        let failed = f.queue.fail(id, "decode_failed").expect("fail");
        assert_eq!(failed.state, JobState::Ready);
        assert_eq!(failed.attempts as usize, index + 1);
        assert_eq!(failed.not_before, Some(f.now() + delay));
        // Not due yet.
        assert_eq!(
            f.queue.take("stt", "w", None).expect("take"),
            TakeOutcome::Empty
        );
        f.clock.advance(*delay);
    }
    assert_eq!(f.take("stt", "w").id, id);
    let dead = f.queue.fail(id, "decode_failed").expect("fail");
    assert!(dead.dead);
    assert_eq!(dead.state, JobState::Dead);
    assert_eq!(dead.attempts, 4);
    let stored = job(&f, id);
    assert_eq!(stored.state, JobState::Dead);
    assert_eq!(stored.last_error.as_deref(), Some("decode_failed"));
    let alerts = f.queue.alerts(None, 10).expect("alerts");
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].kind, AlertKind::Dead);
    assert_eq!(alerts[0].job, id);
}

#[test]
fn retry_policy_is_monotonic_and_capped() {
    let policy = RetryPolicy {
        base_ms: 100,
        max_ms: 1_000,
    };
    assert_eq!(policy.delay_ms(0), 0);
    assert_eq!(policy.delay_ms(1), 100);
    assert_eq!(policy.delay_ms(2), 200);
    assert_eq!(policy.delay_ms(4), 800);
    assert_eq!(policy.delay_ms(5), 1_000);
    assert_eq!(policy.delay_ms(100), 1_000);
}

#[test]
fn a_failed_job_past_its_freshness_is_expired_not_retried() {
    let f = Fixture::with(Policy::default().with_fresh_ms(10_000));
    let id = f.enqueue("stt", b"a");
    f.queue.take("stt", "w", None).expect("take");
    f.queue.fail(id, "boom").expect("fail");
    f.clock.advance(10_001);
    assert_eq!(
        f.queue.take("stt", "w", None).expect("take"),
        TakeOutcome::Empty
    );
    let stored = job(&f, id);
    assert_eq!(stored.state, JobState::Expired);
    assert_eq!(
        f.queue.alerts(None, 10).expect("alerts")[0].kind,
        AlertKind::Expired
    );
}

// ------------------------------------------------------------------ freshness

#[test]
fn stale_jobs_are_dropped_without_running_even_if_no_sweep_ran() {
    let f = Fixture::with(Policy::default().with_fresh_ms(1_000));
    let id = f.enqueue("stt", b"old audio");
    f.clock.advance(1_001);
    // `take` alone must refuse to run old work.
    assert_eq!(
        f.queue.take("stt", "w", None).expect("take"),
        TakeOutcome::Empty
    );
    let stored = job(&f, id);
    assert_eq!(stored.state, JobState::Expired);
    assert_eq!(
        stored.payload,
        b"old audio".to_vec(),
        "the record keeps what was dropped"
    );
    assert!(stored.result.is_none());
    assert_eq!(
        f.queue.alerts(None, 10).expect("alerts")[0].kind,
        AlertKind::Expired
    );
}

#[test]
fn expire_stale_is_the_bulk_sweep_and_reports_each_id() {
    let f = Fixture::with(Policy::default().with_fresh_ms(1_000));
    let first = f.enqueue("stt", b"a");
    let second = f.enqueue("stt", b"b");
    let kept = f
        .queue
        .enqueue(EnqueueRequest::new("stt", b"c".to_vec()).fresh_for(60_000))
        .expect("enqueue")
        .id;
    f.clock.advance(1_001);
    let outcome = f.queue.expire_stale().expect("expire");
    assert_eq!(outcome.expired, vec![first, second]);
    assert_eq!(job(&f, first).state, JobState::Expired);
    assert_eq!(job(&f, second).state, JobState::Expired);
    assert_eq!(job(&f, kept).state, JobState::Ready);
    assert_eq!(f.queue.expire_stale().expect("expire").expired.len(), 0);
}

#[test]
fn expire_stale_accepts_an_explicit_instant() {
    let f = Fixture::with(Policy::default().with_fresh_ms(1_000));
    let id = f.enqueue("stt", b"a");
    assert_eq!(
        f.queue.expire_stale_at(T0 + 1_000).expect("expire").expired,
        vec![id]
    );
    assert_eq!(job(&f, id).state, JobState::Expired);
    assert_eq!(f.now(), T0, "the injected clock did not move");
}

#[test]
fn a_job_a_worker_is_holding_is_not_expired_under_it() {
    let f = Fixture::with(Policy::default().with_fresh_ms(1_000));
    let id = f.enqueue("stt", b"a");
    f.queue.take("stt", "w", Some(50_000)).expect("take");
    f.clock.advance(2_000);
    assert_eq!(f.queue.expire_stale().expect("expire").expired.len(), 0);
    assert_eq!(job(&f, id).state, JobState::Leased);
    // Once the lease is gone, the stale rule applies.
    f.clock.advance(50_000);
    f.queue.sweep().expect("sweep");
    assert_eq!(job(&f, id).state, JobState::Expired);
}

// ------------------------------------------------------------------ timeout alerts

#[test]
fn an_unfinished_job_raises_one_timeout_alert() {
    let f = Fixture::with(Policy::default());
    let id = f
        .queue
        .enqueue(EnqueueRequest::new("stt", b"a".to_vec()).deadline_in(1_000))
        .expect("enqueue")
        .id;
    assert_eq!(f.queue.sweep().expect("sweep").timed_out, 0);
    f.clock.advance(1_001);
    let swept = f.queue.sweep().expect("sweep");
    assert_eq!(swept.timed_out, 1);
    // Still ready: a timeout is a report, not a verdict.
    assert_eq!(job(&f, id).state, JobState::Ready);
    f.clock.advance(60_000);
    assert_eq!(
        f.queue.sweep().expect("sweep").timed_out,
        0,
        "one alert per job"
    );
    let alerts = f.queue.alerts(None, 10).expect("alerts");
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].kind, AlertKind::TimedOut);
    assert!(alerts[0].reason.contains("ready"));

    // A leased job past its deadline is reported too.
    let leased_id = f
        .queue
        .enqueue(
            EnqueueRequest::new("stt", b"b".to_vec())
                .deadline_in(1_000)
                .priority(9),
        )
        .expect("enqueue")
        .id;
    f.queue.take("stt", "w", Some(600_000)).expect("take");
    f.clock.advance(1_001);
    assert_eq!(f.queue.sweep().expect("sweep").timed_out, 1);
    assert!(f
        .queue
        .alerts(None, 10)
        .expect("alerts")
        .iter()
        .any(|alert| alert.job == leased_id && alert.reason.contains("leased")));
    assert_eq!(job(&f, leased_id).state, JobState::Leased);
}

// ------------------------------------------------------------------ alerts

#[test]
fn alerts_are_rate_limited_batched_and_never_lose_items() {
    let f = Fixture::with(Policy {
        max_attempts: 1,
        alerts: AlertPolicy {
            min_gap_ms: 60_000,
            batch_max: 3,
            max_age_ms: 6 * 3_600_000,
        },
        ..Policy::default()
    });
    for _ in 0..5 {
        let id = f.enqueue("stt", b"a");
        f.queue.take("stt", "w", None).expect("take");
        f.queue.fail(id, "boom").expect("fail");
    }
    let first = f.queue.next_alerts().expect("alerts").expect("a batch");
    assert_eq!(first.items.len(), 3);
    assert_eq!(first.overflow, 2);
    assert_eq!(first.dropped, 0);
    assert_eq!(
        f.queue.next_alerts().expect("alerts"),
        None,
        "at most one batch per min_gap_ms"
    );
    f.clock.advance(60_001);
    let second = f.queue.next_alerts().expect("alerts").expect("a batch");
    assert_eq!(second.items.len(), 2);
    assert_eq!(second.overflow, 0);
    f.clock.advance(60_001);
    assert_eq!(f.queue.next_alerts().expect("alerts"), None);
    let sent = f.queue.alerts(Some(AlertState::Sent), 10).expect("alerts");
    assert_eq!(sent.len(), 5, "no alert was dropped by batching");
}

#[test]
fn an_alert_too_old_to_deliver_is_dropped_and_visible_as_dropped() {
    let f = Fixture::with(Policy {
        max_attempts: 1,
        alerts: AlertPolicy {
            min_gap_ms: 1_000,
            batch_max: 12,
            max_age_ms: 60_000,
        },
        ..Policy::default()
    });
    let id = f.enqueue("stt", b"a");
    f.queue.take("stt", "w", None).expect("take");
    f.queue.fail(id, "boom").expect("fail");
    f.clock.advance(60_001);
    assert_eq!(f.queue.next_alerts().expect("alerts"), None);
    assert_eq!(
        f.queue
            .alerts(Some(AlertState::Dropped), 10)
            .expect("alerts")
            .len(),
        1
    );
}

#[test]
fn alert_reasons_are_single_line_and_carry_no_payload() {
    let f = Fixture::with(Policy {
        max_attempts: 1,
        ..Policy::default()
    });
    let secret = "TRANSCRIPT-SECRET";
    let id = f.enqueue("stt", secret.as_bytes());
    f.queue.take("stt", "w", None).expect("take");
    f.queue
        .fail(id, "worker said:\nline one\r\nline two")
        .expect("fail");
    let alerts = f.queue.alerts(None, 10).expect("alerts");
    assert_eq!(alerts.len(), 1);
    assert_eq!(alerts[0].reason, "worker said: line one  line two");
    assert!(!alerts[0].reason.contains('\n'));
    let stored = &job(&f, id).last_error.clone().unwrap();
    assert!(!stored.contains(secret));
}

// ------------------------------------------------------------------ progress

#[test]
fn progress_is_append_only_and_read_incrementally() {
    let f = Fixture::with(Policy {
        max_progress_entries: 4,
        ..Policy::default()
    });
    let id = f.enqueue("stt", b"a");
    assert_eq!(f.queue.progress(id, b"one").expect("progress"), 0);
    assert_eq!(f.queue.progress(id, b"two").expect("progress"), 1);
    assert_eq!(f.queue.progress(id, b"three").expect("progress"), 2);

    let all = f.queue.progress_since(id, 0, 10).expect("progress");
    assert_eq!(all.len(), 3);
    assert_eq!(all[1].bytes, b"two".to_vec());
    let after = f.queue.progress_since(id, 1, 10).expect("progress");
    assert_eq!(
        after.iter().map(|entry| entry.seq).collect::<Vec<_>>(),
        vec![1, 2]
    );
    let page = f.queue.progress_since(id, 0, 2).expect("progress");
    assert_eq!(page.len(), 2);

    assert_eq!(f.queue.progress(id, b"four").expect("progress"), 3);
    assert_eq!(f.queue.progress(id, b"five"), Err(QueueError::ProgressFull));
    let stored = job(&f, id);
    assert_eq!(stored.progress_entries, 4);
    assert_eq!(stored.progress_bytes, 3 + 3 + 5 + 4);
}

#[test]
fn a_result_larger_than_the_bound_is_refused_not_truncated() {
    let f = Fixture::with(Policy {
        max_result_bytes: 4,
        ..Policy::default()
    });
    let id = f.enqueue("stt", b"a");
    f.queue.take("stt", "w", None).expect("take");
    assert!(matches!(
        f.queue.done(id, b"12345"),
        Err(QueueError::TooLarge(_))
    ));
    assert_eq!(
        job(&f, id).state,
        JobState::Leased,
        "the lease survives a refusal"
    );
    assert_eq!(
        f.queue.done(id, b"1234").expect("done").result.as_deref(),
        Some(&b"1234"[..])
    );
}

// ------------------------------------------------------------------ admin

#[test]
fn dead_letters_can_be_listed_and_requeued() {
    let f = Fixture::with(Policy {
        max_attempts: 1,
        ..Policy::default()
    });
    let id = f.enqueue("stt", b"a");
    let other = f.enqueue("ocr", b"b");
    f.queue.take("stt", "w", None).expect("take");
    f.queue.fail(id, "boom").expect("fail");
    assert_eq!(f.queue.dead_letters("stt", 10).expect("dead").len(), 1);
    assert_eq!(f.queue.dead_letters("ocr", 10).expect("dead").len(), 0);
    assert_eq!(f.queue.dead_letters("stt", 10).expect("dead")[0].id, id);

    let revived = f.queue.requeue(id).expect("requeue");
    assert_eq!(revived.state, JobState::Ready);
    assert_eq!(revived.attempts, 0);
    assert_eq!(revived.max_attempts, 1);
    assert_eq!(f.take("stt", "w").id, id);
    assert_eq!(
        f.queue.requeue(id),
        Err(QueueError::Invalid(
            "only dead-lettered jobs can be requeued (job is leased)".into()
        ))
    );
    assert_eq!(
        f.queue.requeue(other),
        Err(QueueError::Invalid(
            "only dead-lettered jobs can be requeued (job is ready)".into()
        ))
    );
}

#[test]
fn requeue_keeps_freshness_unless_it_is_explicitly_refreshed() {
    let f = Fixture::with(Policy::default().with_fresh_ms(1_000));
    let dead = |f: &Fixture, request: EnqueueRequest| {
        let id = f.queue.enqueue(request).expect("enqueue").id;
        f.queue.take("stt", "w", None).expect("take");
        f.queue.fail(id, "boom").expect("fail");
        id
    };
    let one = dead(
        &f,
        EnqueueRequest::new("stt", b"a".to_vec()).max_attempts(1),
    );
    let two = dead(
        &f,
        EnqueueRequest::new("stt", b"b".to_vec()).max_attempts(1),
    );
    f.clock.advance(1_001);
    f.queue.requeue(one).expect("requeue");
    assert_eq!(
        f.queue.take("stt", "w", None).expect("take"),
        TakeOutcome::Empty
    );
    assert_eq!(job(&f, one).state, JobState::Expired);

    f.queue
        .requeue_with(two, &RequeueOptions::refreshing_fresh())
        .expect("requeue");
    assert_eq!(job(&f, two).state, JobState::Ready);
    assert_eq!(f.take("stt", "w").id, two);
}

#[test]
fn stats_report_every_state_and_the_oldest_ready_age() {
    let f = Fixture::with(Policy {
        max_attempts: 1,
        ..Policy::default()
    });
    let ready = f.enqueue("stt", b"r");
    let leased = f.enqueue("stt", b"l");
    let done = f.enqueue("stt", b"d");
    let dead = f.enqueue("stt", b"x");
    let _expired = f.enqueue("stt", b"e");
    for _ in 0..4 {
        f.queue.take("stt", "w", Some(600_000)).expect("take");
    }
    f.queue.done(done, b"ok").expect("done");
    f.queue.fail(dead, "boom").expect("fail");

    let timed = f
        .queue
        .enqueue(EnqueueRequest::new("stt", b"e".to_vec()).fresh_for(1))
        .expect("enqueue")
        .id;
    let _ = ready;
    let _ = leased;
    f.clock.advance(10);
    f.queue.expire_stale().expect("expire");

    let stats = f.queue.stats("stt").expect("stats");
    assert_eq!(stats.done, 1);
    assert_eq!(stats.dead, 1);
    assert_eq!(stats.expired, 1);
    assert!(stats.leased >= 1);
    assert!(stats.oldest_ready_age_ms >= 10);
    assert_eq!(job(&f, timed).state, JobState::Expired);
    assert_eq!(
        f.queue.stats("nothing").expect("stats"),
        QueueStats::default()
    );
    assert_eq!(f.queue.queues().expect("queues"), vec!["stt".to_string()]);
}

#[test]
fn the_same_operations_produce_byte_identical_state() {
    let run = || {
        let f = Fixture::with(Policy::default().with_fresh_ms(10_000));
        for index in 0..6 {
            f.queue
                .enqueue(
                    EnqueueRequest::new("stt", vec![index as u8])
                        .priority((index % 3) as u32)
                        .dedupe(format!("k{index}")),
                )
                .expect("enqueue");
        }
        let a = f.take("stt", "w1");
        f.queue.progress(a.id, b"chunk").expect("progress");
        f.queue.done_by(a.id, "w1", b"result").expect("done");
        let b = f.take("stt", "w1");
        f.queue.fail(b.id, "boom").expect("fail");
        f.clock.advance(30_000);
        f.queue.sweep().expect("sweep");
        let _ = f.queue.next_alerts().expect("alerts");
        f.kv.entries()
    };
    assert_eq!(
        run(),
        run(),
        "same operations at the same times: same bytes"
    );
}

// ------------------------------------------------------------------ refusals

#[test]
fn bad_requests_are_refused_by_name() {
    let f = Fixture::with(Policy {
        max_payload_bytes: 4,
        max_ready: 1,
        max_lease_ms: 1_000,
        ..Policy::default()
    });
    assert!(matches!(
        f.queue
            .enqueue(EnqueueRequest::new("bad/queue", b"x".to_vec())),
        Err(QueueError::Invalid(_))
    ));
    assert!(matches!(
        f.queue.enqueue(EnqueueRequest::new("q", b"12345".to_vec())),
        Err(QueueError::TooLarge(_))
    ));
    assert!(matches!(
        f.queue
            .enqueue(EnqueueRequest::new("q", b"x".to_vec()).max_attempts(0)),
        Err(QueueError::Invalid(_))
    ));
    assert!(matches!(
        f.queue
            .enqueue(EnqueueRequest::new("q", b"x".to_vec()).fresh_for(0)),
        Err(QueueError::Invalid(_))
    ));
    assert!(matches!(
        f.queue.enqueue(
            EnqueueRequest::new("q", b"x".to_vec())
                .fresh_for(1_000)
                .not_before(T0 + 1_000)
        ),
        Err(QueueError::Invalid(_))
    ));
    assert!(matches!(
        f.queue
            .enqueue(EnqueueRequest::new("q", b"x".to_vec()).dedupe("bad\u{7}key")),
        Err(QueueError::Invalid(_))
    ));
    f.queue
        .enqueue(EnqueueRequest::new("q", b"x".to_vec()))
        .expect("enqueue");
    assert!(matches!(
        f.queue.enqueue(EnqueueRequest::new("q", b"x".to_vec())),
        Err(QueueError::Full { .. })
    ));
    assert!(matches!(
        f.queue.take("q", "w", Some(1_001)),
        Err(QueueError::Invalid(_))
    ));
    assert!(matches!(
        f.queue.take("q", "bad worker", None),
        Err(QueueError::Invalid(_))
    ));
}

#[test]
fn a_namespaced_kv_keeps_other_data_out_of_the_scan() {
    let inner = MemoryKv::new();
    inner.put_raw(b"someone-elses-key", b"x");
    let scoped = Prefixed::new(inner.clone(), b"stt/".to_vec());
    let clock = FixedClock::new(T0);
    let queue = Queue::new(Arc::new(scoped), Arc::new(clock), Policy::default());
    let id = queue
        .enqueue(EnqueueRequest::new("stt", b"a".to_vec()))
        .expect("enqueue")
        .id;
    let taken = queue
        .take("stt", "w", None)
        .expect("take")
        .job()
        .expect("job");
    assert_eq!(taken.id, id);
    queue.done_by(id, "w", b"ok").expect("done");
    assert!(inner
        .entries()
        .iter()
        .any(|(key, value)| key == b"someone-elses-key" && value == b"x"));
    assert!(inner
        .entries()
        .iter()
        .all(|(key, _)| key == b"someone-elses-key" || key.starts_with(b"stt/")));
}
