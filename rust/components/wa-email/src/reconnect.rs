//! Reconnect pacing: how long the connector waits after a failed or dropped session.
//!
//! The rule is the supervisor's (`docs/SERVICE-COMPONENTS.md`: "restart with backoff 1 s doubling to
//! 60 s, reset after 10 min healthy"), applied to the connector's own sessions so a server that is
//! down, a credential that is wrong or a network that flaps does not turn into a hot loop. Wrong
//! credentials are the one case that does *not* back off on its own schedule: they are a permanent
//! answer until an operator changes the vault, so the connector reports `degraded` and keeps the
//! longest delay.

/// What the session loop should do next.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AfterFailure {
    /// Try again after this many milliseconds.
    Wait(u64),
    /// The failure is permanent until an operator acts (bad credentials, a refused grant): wait, and
    /// report degraded - retrying sooner would only be noise.
    WaitPermanent(u64),
}

impl AfterFailure {
    /// The wait this outcome asks for.
    pub fn delay_ms(&self) -> u64 {
        match self {
            AfterFailure::Wait(ms) | AfterFailure::WaitPermanent(ms) => *ms,
        }
    }
}

/// Exponential backoff with a healthy-reset, in the supervisor's numbers.
#[derive(Clone, Debug)]
pub struct Backoff {
    base_ms: u64,
    max_ms: u64,
    reset_after_ms: u64,
    /// The delay the next failure will produce.
    next_ms: u64,
    /// When the current session started being healthy, and how long it has to stay so to reset.
    healthy_since: Option<u64>,
}

impl Default for Backoff {
    fn default() -> Self {
        Backoff { base_ms: 1_000, max_ms: 60_000, reset_after_ms: 600_000, next_ms: 1_000, healthy_since: None }
    }
}

impl Backoff {
    pub fn new(base_ms: u64, max_ms: u64, reset_after_ms: u64) -> Backoff {
        Backoff { base_ms, max_ms, reset_after_ms, next_ms: base_ms.max(1), healthy_since: None }
    }

    /// A session just became healthy at `now_ms` (it logged in and finished a round).
    pub fn healthy(&mut self, now_ms: u64) {
        if self.healthy_since.is_none() {
            self.healthy_since = Some(now_ms);
            return;
        }
        if now_ms.saturating_sub(self.healthy_since.unwrap_or(now_ms)) >= self.reset_after_ms {
            // Ten healthy minutes: the next failure starts from the base again.
            self.next_ms = self.base_ms;
            self.healthy_since = Some(now_ms);
        }
    }

    /// A session failed at `now_ms`. Returns the delay and doubles it for the next time.
    pub fn failure(&mut self, now_ms: u64) -> u64 {
        self.healthy_since = None;
        let delay = self.next_ms.clamp(1, self.max_ms);
        self.next_ms = delay.saturating_mul(2).min(self.max_ms);
        let _ = now_ms;
        delay
    }

    /// A failure that no amount of retrying fixes by itself.
    pub fn permanent_failure(&mut self) -> AfterFailure {
        self.healthy_since = None;
        self.next_ms = self.max_ms;
        AfterFailure::WaitPermanent(self.max_ms)
    }

    /// The delay the next failure would produce (the value a status/log line shows).
    pub fn current_ms(&self) -> u64 {
        self.next_ms
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failures_double_from_one_second_to_the_sixty_second_ceiling() {
        let mut backoff = Backoff::default();
        let delays: Vec<u64> = (0..8).map(|i| backoff.failure(i * 1_000)).collect();
        assert_eq!(delays, vec![1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000]);
        assert_eq!(backoff.current_ms(), 60_000, "the ceiling is where it stays");
    }

    #[test]
    fn ten_healthy_minutes_reset_the_delay_to_the_base() {
        let mut backoff = Backoff::default();
        for i in 0..5 {
            backoff.failure(i);
        }
        assert_eq!(backoff.current_ms(), 32_000);
        // Healthy, but not for long enough yet: the next failure still costs 32 s.
        backoff.healthy(1_000_000);
        assert_eq!(backoff.failure(1_000_500), 32_000);
        // A session that stays healthy past the reset window starts over.
        backoff.healthy(2_000_000);
        backoff.healthy(2_000_000 + 600_000);
        assert_eq!(backoff.current_ms(), 1_000);
        assert_eq!(backoff.failure(2_600_001), 1_000);
    }

    #[test]
    fn a_wrong_credential_waits_the_ceiling_and_says_so() {
        let mut backoff = Backoff::default();
        assert_eq!(backoff.permanent_failure(), AfterFailure::WaitPermanent(60_000));
        // A permanent failure leaves the delay at the ceiling: an operator changing the vault is what
        // makes the next session work, not a retry.
        assert_eq!(backoff.current_ms(), 60_000);
        // A later success still resets it, so a fixed credential does not stay slow forever.
        backoff.healthy(0);
        backoff.healthy(600_000);
        assert_eq!(backoff.current_ms(), 1_000);
    }

    #[test]
    fn a_zero_base_is_still_a_positive_wait() {
        let mut backoff = Backoff::new(0, 10, 100);
        assert_eq!(backoff.failure(0), 1, "a delay of zero would be a hot loop");
    }
}
