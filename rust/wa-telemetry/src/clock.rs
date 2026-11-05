//! Time is injected, never read from `SystemTime` inside the design: rollup roll-over and sampling
//! are the two things a test must be able to drive across a minute, an hour and a day boundary.
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Wall clock in epoch milliseconds. Monotonicity is the host's problem (it may step backwards);
/// rollups tolerate it by keying on the bucket, not on elapsed time.
pub trait Clock: Send + Sync + 'static {
    fn now_ms(&self) -> u64;
}

/// The real clock.
#[derive(Clone, Copy, Debug, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }
}

/// A clock the test (or a replay) moves by hand.
#[derive(Clone, Debug)]
pub struct ManualClock {
    ms: std::sync::Arc<AtomicU64>,
}

impl ManualClock {
    pub fn new(start_ms: u64) -> Self {
        Self {
            ms: std::sync::Arc::new(AtomicU64::new(start_ms)),
        }
    }
    pub fn advance_ms(&self, ms: u64) {
        self.ms.fetch_add(ms, Ordering::SeqCst);
    }
    pub fn advance_secs(&self, secs: u64) {
        self.advance_ms(secs * 1000);
    }
    pub fn set_ms(&self, ms: u64) {
        self.ms.store(ms, Ordering::SeqCst);
    }
    pub fn now_ms(&self) -> u64 {
        self.ms.load(Ordering::SeqCst)
    }
}

impl Clock for ManualClock {
    fn now_ms(&self) -> u64 {
        self.ms.load(Ordering::SeqCst)
    }
}

/// Convenience: the same manual clock, as the trait object a `Metrics` takes.
pub fn manual(start_ms: u64) -> (ManualClock, std::sync::Arc<dyn Clock>) {
    let c = ManualClock::new(start_ms);
    let handle = c.clone();
    (c, std::sync::Arc::new(handle))
}
