//! Time, injected. The queue never calls the system clock itself: every deadline, lease and
//! backoff is derived from `Clock::now_ms`, so a test is a `FixedClock` moved forward and a restart
//! is the same state read at a later instant.

use std::sync::atomic::{AtomicI64, Ordering};

/// Milliseconds since the Unix epoch, as the queue orders and expires things.
pub trait Clock {
    fn now_ms(&self) -> i64;
}

/// The wall clock. Only the host should use this: a component gets the kernel's clock.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn now_ms(&self) -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    }
}

/// A clock the test moves by hand.
#[derive(Debug, Default)]
pub struct FixedClock {
    now: AtomicI64,
}

impl FixedClock {
    pub fn new(now_ms: i64) -> Self {
        Self {
            now: AtomicI64::new(now_ms),
        }
    }

    pub fn set(&self, now_ms: i64) {
        self.now.store(now_ms, Ordering::SeqCst);
    }

    pub fn advance(&self, ms: i64) -> i64 {
        self.now.fetch_add(ms, Ordering::SeqCst) + ms
    }
}

impl Clock for FixedClock {
    fn now_ms(&self) -> i64 {
        self.now.load(Ordering::SeqCst)
    }
}
