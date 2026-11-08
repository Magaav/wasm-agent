//! Backoff with jitter (`docs/MODEL-GATEWAY.md`, "Fallback, backoff, breaker").
//!
//! Exponential in the attempt, capped by the policy, then jittered inside ±50% so a fleet that hit the
//! same 429 does not retry in lockstep. The jitter source is a seed the caller advances, so the sequence
//! is deterministic in a test and varied in a node; a server's `Retry-After` wins when it is larger,
//! and the cap wins over both (a provider asking for an hour must not hold a turn for an hour).

/// `[0.5, 1.5)` scaled exponential, in milliseconds.
pub fn delay_ms(attempt: u32, base_ms: u64, max_ms: u64, jitter: f64) -> u64 {
    let exponent = attempt.saturating_sub(1).min(16);
    let raw = (base_ms as u128).saturating_mul(1u128 << exponent).min(max_ms as u128 * 2) as u64;
    let scaled = (raw as f64 * jitter).round() as u64;
    scaled.clamp(1, max_ms.max(1))
}

/// A deterministic jitter in `[0.5, 1.5)` from a seed (splitmix64's finalizer). No `rand` dependency,
/// and the same seed always yields the same delay, which is what makes the retry test exact.
pub fn jitter_from(seed: u64) -> f64 {
    let mut z = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^= z >> 31;
    0.5 + (z as f64 / u64::MAX as f64)
}

/// The delay to honour: the provider's hint when it gave one, else the jittered exponential, capped.
pub fn retry_delay_ms(
    attempt: u32,
    base_ms: u64,
    max_ms: u64,
    retry_after_ms: Option<u64>,
    seed: u64,
) -> u64 {
    let computed = delay_ms(attempt, base_ms, max_ms, jitter_from(seed));
    match retry_after_ms {
        Some(hint) => hint.max(computed).min(max_ms.max(1)),
        None => computed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_delay_grows_exponentially_and_is_capped() {
        let base = 400;
        let max = 8_000;
        let at = |attempt| delay_ms(attempt, base, max, 1.0);
        assert_eq!(at(1), 400);
        assert_eq!(at(2), 800);
        assert_eq!(at(3), 1_600);
        assert_eq!(at(4), 3_200);
        assert_eq!(at(5), 6_400);
        assert_eq!(at(6), max, "the cap is the policy's, not the provider's");
        assert_eq!(at(60), max);
        assert_eq!(at(0), 400, "attempt 0 is treated as the first");
    }

    #[test]
    fn jitter_stays_inside_half_to_one_and_a_half() {
        for seed in 0..500u64 {
            let jitter = jitter_from(seed);
            assert!((0.5..1.5).contains(&jitter), "seed {seed} gave {jitter}");
        }
        // Deterministic: the same seed is the same delay.
        assert_eq!(jitter_from(42), jitter_from(42));
        assert_ne!(jitter_from(1), jitter_from(2));
    }

    #[test]
    fn a_retry_after_hint_wins_but_never_past_the_cap() {
        // 400 computed, the provider asks for 2 s: honour it.
        assert_eq!(retry_delay_ms(1, 400, 8_000, Some(2_000), 7), 2_000);
        // The provider asks for an hour: the cap wins.
        assert_eq!(retry_delay_ms(1, 400, 8_000, Some(3_600_000), 7), 8_000);
        // A hint smaller than the computed delay does not shorten it: the computed value stays.
        let computed = delay_ms(3, 400, 8_000, jitter_from(7));
        assert_eq!(retry_delay_ms(3, 400, 8_000, Some(1), 7), computed);
    }
}
