//! Token buckets and daily counters, in exact integer arithmetic.
//!
//! Bucket state is kept in "units": one token is [`UNITS_PER_TOKEN`] units, so a bucket that
//! allows `n` tokens per minute holds `n * 60_000` units and refills by `per_minute` units per
//! millisecond. Everything is integer, so a decision never depends on floating-point rounding and
//! a snapshot round-trip cannot change a limit. `retry_after` is exact, rounded up to whole ms.
//!
//! Time is the injected clock: epoch milliseconds, passed to every call. Two rules keep a clock
//! that moves backwards (a snapshot restored on another node, a corrected wall clock) from handing
//! out free capacity: elapsed time is clamped at zero and `last_ms` never moves back.
use crate::policy::RateLimit;
use serde::{Deserialize, Serialize};

/// Units in one token.
pub const UNITS_PER_TOKEN: u64 = 60_000;

/// Milliseconds in one day: the window of a `daily_cap`, counted in UTC epochs.
pub const DAY_MS: u64 = 86_400_000;

/// A fixed-capacity token bucket.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bucket {
    /// Tokens left, in [`UNITS_PER_TOKEN`]-units, never above the capacity of the rate in use.
    pub units: u64,
    /// Injected clock reading of the last refill.
    pub last_ms: u64,
}

impl Bucket {
    /// A full bucket at `now_ms`.
    pub fn full(rate: &RateLimit, now_ms: u64) -> Bucket {
        Bucket { units: capacity_units(rate), last_ms: now_ms }
    }

    /// Units available at `now_ms`, after refilling and clamping to `rate`'s capacity. Pure: the
    /// caller decides whether to keep the result.
    pub fn available(&self, rate: &RateLimit, now_ms: u64) -> u64 {
        let elapsed = now_ms.saturating_sub(self.last_ms);
        let added = elapsed.saturating_mul(u64::from(rate.per_minute));
        self.units.saturating_add(added).min(capacity_units(rate))
    }

    /// Refill and clamp in place (used by a commit, never by a peek).
    pub fn refill(&mut self, rate: &RateLimit, now_ms: u64) {
        if now_ms > self.last_ms {
            self.units = self.available(rate, now_ms);
            self.last_ms = now_ms;
        }
        self.units = self.units.min(capacity_units(rate));
    }

    /// Whole tokens available at `now_ms`.
    pub fn tokens(&self, rate: &RateLimit, now_ms: u64) -> u64 {
        self.available(rate, now_ms) / UNITS_PER_TOKEN
    }

    /// Take one token if there is one; returns the retry delay otherwise. Commits the refill.
    pub fn take(&mut self, rate: &RateLimit, now_ms: u64) -> Result<(), u64> {
        self.refill(rate, now_ms);
        if self.units >= UNITS_PER_TOKEN {
            self.units -= UNITS_PER_TOKEN;
            Ok(())
        } else {
            Err(retry_after_ms(self.units, rate))
        }
    }

    /// Milliseconds until one token is available (0 when one is available now).
    pub fn retry_after_ms(&self, rate: &RateLimit, now_ms: u64) -> u64 {
        retry_after_ms(self.available(rate, now_ms), rate)
    }
}

fn capacity_units(rate: &RateLimit) -> u64 {
    rate.capacity().saturating_mul(UNITS_PER_TOKEN)
}

fn retry_after_ms(units: u64, rate: &RateLimit) -> u64 {
    let per_minute = u64::from(rate.per_minute.max(1));
    let missing = UNITS_PER_TOKEN.saturating_sub(units.min(UNITS_PER_TOKEN));
    if missing == 0 {
        return 0;
    }
    // units are tokens·ms, refill is per_minute units per ms: ms = missing / per_minute, rounded up.
    missing.div_ceil(per_minute)
}

/// How many calls of one capability happened today (UTC day of the injected clock).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DailyCounter {
    /// Day index: `now_ms / DAY_MS`.
    pub day: u64,
    pub count: u32,
}

impl DailyCounter {
    pub fn new(day: u64) -> DailyCounter {
        DailyCounter { day, count: 0 }
    }

    /// The count that counts for `now_ms` (0 after a day rollover).
    pub fn count_on(&self, now_ms: u64) -> u32 {
        if self.day == day_of(now_ms) {
            self.count
        } else {
            0
        }
    }

    /// Count one call; a call on a new day starts the counter over.
    pub fn bump(&mut self, now_ms: u64) {
        let day = day_of(now_ms);
        if self.day != day {
            *self = DailyCounter { day, count: 1 };
        } else {
            self.count = self.count.saturating_add(1);
        }
    }
}

/// UTC day index of an epoch-ms reading.
pub fn day_of(now_ms: u64) -> u64 {
    now_ms / DAY_MS
}

/// Milliseconds until the next UTC day boundary (when a `daily_cap` starts over).
pub fn ms_until_next_day(now_ms: u64) -> u64 {
    let into_day = now_ms % DAY_MS;
    if into_day == 0 {
        DAY_MS
    } else {
        DAY_MS - into_day
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const T0: u64 = 1_760_000_000_000; // an arbitrary epoch-ms instant

    #[test]
    fn a_full_bucket_allows_capacity_then_refuses_with_an_exact_delay() {
        let rate = RateLimit::new(6, None);
        let mut b = Bucket::full(&rate, T0);
        assert_eq!(b.tokens(&rate, T0), 6);
        for _ in 0..6 {
            assert!(b.take(&rate, T0).is_ok());
        }
        // 6/min => one token every 10_000 ms
        assert_eq!(b.take(&rate, T0).unwrap_err(), 10_000);
        assert_eq!(b.take(&rate, T0).unwrap_err(), 10_000);
        // half a token back after 5 s is not a token
        assert_eq!(b.take(&rate, T0 + 5_000).unwrap_err(), 5_000);
        // a full token after 10 s
        assert!(b.take(&rate, T0 + 10_000).is_ok());
        assert_eq!(b.tokens(&rate, T0 + 10_000), 0);
    }

    #[test]
    fn refill_is_capped_at_the_capacity() {
        let rate = RateLimit::new(2, Some(2));
        let mut b = Bucket::full(&rate, T0);
        b.take(&rate, T0).unwrap();
        // an hour later: still only 2 tokens, never a burst of 120
        assert_eq!(b.tokens(&rate, T0 + 3_600_000), 2);
        b.refill(&rate, T0 + 3_600_000);
        assert_eq!(b.units, capacity_units(&rate));
        // burst may exceed one minute's worth
        let slow = RateLimit::new(2, Some(10));
        assert_eq!(Bucket::full(&slow, T0).tokens(&slow, T0), 10);
    }

    #[test]
    fn a_clock_that_moves_backwards_gives_no_extra_tokens() {
        let rate = RateLimit::new(6, None);
        let mut b = Bucket::full(&rate, T0);
        for _ in 0..6 {
            b.take(&rate, T0).unwrap();
        }
        assert_eq!(b.take(&rate, T0 - 60_000).unwrap_err(), 10_000);
        assert_eq!(b.last_ms, T0);
        assert_eq!(b.units, 0);
    }

    #[test]
    fn available_is_pure_and_retry_after_rounds_up() {
        let rate = RateLimit::new(7, None); // 8.57 ms per token: fractional on purpose
        let mut b = Bucket::full(&rate, T0);
        for _ in 0..7 {
            b.take(&rate, T0).unwrap();
        }
        assert_eq!(b.units, 0);
        // 1 ms of refill is 7 units, still short of a token
        assert_eq!(b.available(&rate, T0 + 1), 7);
        assert_eq!(b.retry_after_ms(&rate, T0 + 1), 8_571);
        assert!(b.take(&rate, T0 + 8_571).is_err());
        assert!(b.take(&rate, T0 + 8_572).is_ok());
        // peek did not touch the state
        let before = b;
        let _ = b.available(&rate, T0 + 100_000);
        assert_eq!(b, before);
    }

    #[test]
    fn daily_counter_rolls_over_at_the_utc_boundary() {
        let start = (T0 / DAY_MS) * DAY_MS;
        assert_eq!(ms_until_next_day(start), DAY_MS);
        assert_eq!(ms_until_next_day(start + 1), DAY_MS - 1);
        assert_eq!(day_of(start + DAY_MS - 1), day_of(start));
        assert_eq!(day_of(start + DAY_MS), day_of(start) + 1);

        let mut c = DailyCounter::new(day_of(start));
        c.bump(start);
        c.bump(start);
        assert_eq!(c.count_on(start), 2);
        assert_eq!(c.count, 2);
        assert_eq!(c.count_on(start + DAY_MS), 0);
        c.bump(start + DAY_MS);
        assert_eq!((c.day, c.count), (day_of(start) + 1, 1));
    }

    #[test]
    fn buckets_round_trip_through_json_without_losing_units() {
        let rate = RateLimit::new(7, None);
        let mut b = Bucket::full(&rate, T0);
        b.take(&rate, T0).unwrap();
        let text = serde_json::to_string(&b).unwrap();
        assert_eq!(serde_json::from_str::<Bucket>(&text).unwrap(), b);
        // a snapshot from a future writer is refused rather than misread
        assert!(serde_json::from_str::<Bucket>(r#"{"units":1,"last_ms":2,"extra":3}"#).is_err());
    }
}
