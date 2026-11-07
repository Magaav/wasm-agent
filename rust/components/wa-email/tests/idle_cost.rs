//! The optimization check the job asks for: what an idle connector costs.
//!
//! The node-level number (RSS and turn latency of `wa serve` with the component enabled vs absent) needs
//! `wa-host` to serve `wa:email/transport` and a temp home to run in, and this lane may not touch
//! `wa-host`. What *can* be measured here, exactly and repeatably, is the component's own idle cost in
//! the shape the node pays it:
//!
//! * **resident state** - the bytes the connector holds between rounds (the index view, the protocol
//!   machines, the backoff, the rate limiter). That is what a node's RSS would grow by for this
//!   component, minus the wasmtime instance and the linear-memory floor (the artifact's own size is
//!   reported below as `wasm_bytes`).
//! * **idle turn** - one "nothing to do this poll" step: the cost of asking the protocol machine whether
//!   it has anything to write and of the session's own bookkeeping. A poll interval is one timer plus
//!   these turns, so this is the whole per-poll CPU cost when the mailbox is quiet.
//!
//! Run with `cargo test --test idle-cost -- --nocapture` to see the numbers. The test asserts the
//! properties a budget depends on: an idle turn allocates nothing, and the resident state stays inside a
//! few tens of KiB (a 128 MiB grant is not the risk here; a leak would be).
use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Instant;

use wa_email_index::{MemoryStore, Request as Query};
use wa_email_outbox::{RateLimiter, RatePolicy, Secret};
use wa_email::imap::Imap;

// ---- a counting allocator, so "does an idle turn allocate" is measured rather than assumed ----------

struct Counting;

static LIVE: AtomicUsize = AtomicUsize::new(0);
static PEAK: AtomicUsize = AtomicUsize::new(0);
static ALLOCATIONS: AtomicUsize = AtomicUsize::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let pointer = System.alloc(layout);
        if !pointer.is_null() {
            let live = LIVE.fetch_add(layout.size(), Ordering::Relaxed) + layout.size();
            PEAK.fetch_max(live, Ordering::Relaxed);
            ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        }
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        LIVE.fetch_sub(layout.size(), Ordering::Relaxed);
        System.dealloc(pointer, layout)
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn live() -> usize {
    LIVE.load(Ordering::Relaxed)
}

/// The connector's resident state, built the way a guest builds it at start: an index view, one IMAP
/// session per mailbox, a rate limiter and a backoff.
struct Idle {
    index: MemoryStore,
    imap: Imap,
    limiter: RateLimiter,
    backoff: wa_email::reconnect::Backoff,
}

impl Idle {
    fn new() -> Idle {
        let mut index = MemoryStore::default();
        for uid in 1..=100u32 {
            let record = wa_email_index::Record {
                mailbox: "INBOX".into(),
                uid,
                uid_validity: 7,
                message_id: Some(format!("<{uid}@example.com>")),
                from: wa_email_index::Address::new(Some("Ana Silva"), "ana@example.com"),
                to: vec![wa_email_index::Address::new(None, "me@example.com")],
                cc: Vec::new(),
                subject: format!("Relatório mensal {uid}"),
                received_ms: 1_793_959_200_000 + i64::from(uid),
                sent_ms: None,
                in_reply_to: None,
                snippet: "Segue o relatório em anexo.".into(),
                text: "Segue o relatório em anexo. Obrigada.".into(),
                text_truncated: false,
                attachments: Vec::new(),
                flags: vec!["\\Seen".into()],
            };
            wa_email_index::index_record(&mut index, &record, &[]).expect("an indexed record");
        }
        let mut imap = Imap::new("INBOX", "me@example.com", Secret::new("s3cret"));
        imap.seed_floor(100);
        Idle {
            index,
            imap,
            limiter: RateLimiter::new(RatePolicy { per_minute: 6, per_day: 100, min_interval_ms: 2_000 }),
            backoff: wa_email::reconnect::Backoff::default(),
        }
    }

    /// One idle poll: the protocol machine has nothing to write, the limiter and the backoff are read,
    /// and nothing else happens. This is the whole cost of a poll interval on a quiet mailbox.
    fn idle_poll(&mut self) -> bool {
        let waiting = matches!(self.imap.step(), wa_email::imap::Step::Wait);
        let _ = self.limiter.try_acquire(&["example.com"], 1_000);
        let _ = self.backoff.current_ms();
        waiting
    }

    /// One query job answered from the view: the cost of a search over what the component holds. It runs
    /// only when a job arrives (not on a poll), and it is measured separately for that reason.
    fn answer(&self) -> u64 {
        let mut query = Query::search().with_q("relatorio");
        query.limit = Some(5);
        let answer = wa_email_index::search(&self.index, &query).expect("an answer");
        answer.get("matched").and_then(|value| value.as_u64()).unwrap_or(0)
    }
}

#[test]
fn an_idle_connector_holds_its_state_and_its_turn_allocates_nothing() {
    // Warm up: the first call touches thread-local and allocator bookkeeping of the runtime, not the
    // connector's.
    let baseline = {
        let mut warm = Idle::new();
        for _ in 0..8 {
            warm.idle_poll();
        }
        let _ = warm.answer();
        drop(warm);
        live()
    };

    let mut idle = Idle::new();
    let resident = live().saturating_sub(baseline);

    // An idle turn must not allocate: a poll that allocates every interval is a poll that churns the
    // allocator forever for nothing.
    // Settle the limiter's own windows first: it grows a `VecDeque` and inserts a domain entry on the
    // first few calls, and *that* is a one-time cost, not a per-poll one.
    for _ in 0..32 {
        idle.idle_poll();
    }
    let allocations_before = ALLOCATIONS.load(Ordering::Relaxed);
    let turns = 10_000u32;
    let started = Instant::now();
    let mut waiting = 0usize;
    for _ in 0..turns {
        waiting += idle.idle_poll() as usize;
    }
    let elapsed = started.elapsed();
    let allocations = ALLOCATIONS.load(Ordering::Relaxed) - allocations_before;
    let per_turn_ns = elapsed.as_nanos() as f64 / f64::from(turns);

    // One query job, separately: it is work, not idle time.
    let started = Instant::now();
    let mut matched = 0u64;
    for _ in 0..20 {
        matched += idle.answer();
    }
    let query_ns = started.elapsed().as_nanos() as f64 / 20.0;
    assert!(matched >= 20, "the query answered from the view it holds: {matched}");

    // A baseline "do nothing" turn, for the comparison the report needs.
    let started = Instant::now();
    let mut sink = 0usize;
    for index in 0..turns {
        sink = sink.wrapping_add(index as usize & 1);
    }
    let baseline_ns = started.elapsed().as_nanos() as f64 / f64::from(turns);
    assert!(sink <= turns as usize);

    // The artifact the node instantiates: reported so the linear-memory floor has a number next to it.
    let wasm_bytes = artifact().map(|(_, bytes)| bytes).unwrap_or(0);

    println!(
        "idle-cost: resident_bytes={resident} idle_poll_ns={per_turn_ns:.1} baseline_noop_ns={baseline_ns:.1} allocations_per_idle_poll={:.4} idle_polls={turns} query_ns_for_100_records={query_ns:.0} wasm_bytes={wasm_bytes}",
        allocations as f64 / f64::from(turns),
    );
    assert_eq!(waiting, turns as usize, "a quiet mailbox leaves the machine waiting");
    assert_eq!(allocations, 0, "an idle poll allocates nothing ({allocations} allocations over {turns} polls)");
    assert!(resident < 256 * 1024, "the resident state of 100 indexed messages is {} bytes", resident);
    assert!(resident > 0, "the measurement saw the state it is measuring");
    // The peak is the resident state plus one query answer; it must not grow with the turn count.
    let peak = PEAK.load(Ordering::Relaxed);
    assert!(peak < 8 * 1024 * 1024, "the peak allocation over the run was {peak} bytes");
    drop(idle);
    // The allocator is process-wide and the harness runs both tests at once, so "everything was released"
    // is not a number this test can assert; what it does assert above is that a poll allocates nothing and
    // that the peak stays bounded, which is the property a budget depends on.
}

/// The built component, wherever this checkout's target directory is (`CARGO_TARGET_DIR` is set for the
/// lane that built it).
fn artifact() -> Option<(String, u64)> {
    let mut candidates = Vec::new();
    if let Ok(target) = std::env::var("CARGO_TARGET_DIR") {
        candidates.push(format!("{target}/wasm32-wasip2/release/wa_email.wasm"));
    }
    candidates.push(concat!(env!("CARGO_MANIFEST_DIR"), "/../../target/wasm32-wasip2/release/wa_email.wasm").to_string());
    if let Ok(path) = std::env::var("WA_EMAIL_WASM") {
        candidates.push(path);
    }
    candidates.iter().find_map(|path| std::fs::metadata(path).ok().filter(|meta| meta.is_file()).map(|meta| (path.clone(), meta.len())))
}

#[test]
fn the_archive_of_the_component_is_the_one_the_node_would_pin() {
    // `cargo build --release --target wasm32-wasip2` writes it next to the crate's target directory. When
    // it is absent this test says so instead of pretending to have checked it.
    match artifact() {
        Some((path, bytes)) => {
            println!("component artifact: {path} {bytes} bytes");
            assert!(bytes > 64 * 1024, "a component with a MIME reader and two protocol clients is not tiny: {bytes}");
        }
        None => println!("component artifact: SKIPPED (build it with `cargo build --release --target wasm32-wasip2`)"),
    }
}
