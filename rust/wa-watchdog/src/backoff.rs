//! Exponential backoff, as a pure function of the attempt number.
//!
//! Deterministic on purpose: a single supervisor on a single machine does not gain anything from jitter it
//! cannot observe, and a test that cannot state the exact delays is not a test of the delays. The ceiling
//! matters more than the curve: a kernel that cannot start (a missing shared library, a bad manifest) must
//! not be retried thousands of times a minute, and `backoff_max_ms` is where that stops.

/// `attempt` is 0 for the first restart after the first good start.
#[derive(Debug, Clone, Copy)]
pub struct Backoff {
    pub base_ms: u64,
    pub factor: u32,
    pub max_ms: u64,
}

impl Backoff {
    pub fn new(base_ms: u64, factor: u32, max_ms: u64) -> Backoff {
        Backoff { base_ms, factor: factor.max(1), max_ms: max_ms.max(base_ms) }
    }

    /// The delay before the restart numbered `attempt` (0-based). Saturates at `max_ms`; never overflows,
    /// however many attempts a crash loop runs up.
    pub fn delay_ms(&self, attempt: u32) -> u64 {
        let mut delay = self.base_ms;
        for _ in 0..attempt {
            delay = match delay.checked_mul(self.factor as u64) {
                Some(next) => next,
                None => return self.max_ms,
            };
            if delay >= self.max_ms {
                return self.max_ms;
            }
        }
        delay.min(self.max_ms)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn it_doubles_from_the_base_up_to_the_ceiling() {
        let backoff = Backoff::new(500, 2, 60_000);
        let delays: Vec<u64> = (0..10).map(|attempt| backoff.delay_ms(attempt)).collect();
        assert_eq!(delays, [500, 1_000, 2_000, 4_000, 8_000, 16_000, 32_000, 60_000, 60_000, 60_000]);
    }

    #[test]
    fn a_huge_attempt_number_is_still_bounded() {
        let backoff = Backoff::new(1, 3, 30_000);
        assert_eq!(backoff.delay_ms(64), 30_000);
        assert_eq!(backoff.delay_ms(u32::MAX), 30_000);
    }

    #[test]
    fn a_ceiling_below_the_base_is_the_base() {
        let backoff = Backoff::new(1_000, 2, 100);
        assert_eq!(backoff.delay_ms(0), 1_000);
        assert_eq!(backoff.delay_ms(3), 1_000);
    }

    #[test]
    fn one_as_a_factor_keeps_a_constant_delay() {
        let backoff = Backoff::new(250, 1, 10_000);
        assert_eq!((0..4).map(|attempt| backoff.delay_ms(attempt)).collect::<Vec<_>>(), [250, 250, 250, 250]);
    }
}
