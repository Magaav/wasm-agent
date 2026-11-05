//! Latency histograms on a fixed, log-shaped bucket array (HDR idea, not the HDR crate).
//!
//! Values are microseconds. Bucket 0..2^sub are exact; above that each power of two is split into
//! `2^sub` buckets, so the relative error is at most `1/2^(sub+1)` (3.1% at the default 4) whatever
//! the magnitude. The array is `(64 - sub) << sub` counters — 976 at the default — allocated once
//! per series, never resized, and the same index scheme is used by the rollup sums' helper views.
//!
//! Percentiles interpolate linearly inside the bucket a rank lands in. That is an estimate with a
//! known bound (the bucket width), not a guess: it is not presented as an exact order statistic.

/// Buckets per power of two, log2. Clamped to 1..=6 by `Histogram::new`.
pub const DEFAULT_SUB_BITS: u8 = 4;

#[derive(Clone, Debug)]
pub struct Histogram {
    sub_bits: u8,
    buckets: Vec<u64>,
    count: u64,
    sum: u64,
    min: u64,
    max: u64,
}

impl Histogram {
    pub fn new(sub_bits: u8) -> Self {
        let sub_bits = sub_bits.clamp(1, 6);
        Self {
            sub_bits,
            buckets: vec![0u64; bucket_count(sub_bits)],
            count: 0,
            sum: 0,
            min: u64::MAX,
            max: 0,
        }
    }

    pub fn sub_bits(&self) -> u8 {
        self.sub_bits
    }

    pub fn observe(&mut self, micros: u64) {
        let idx = index_of(self.sub_bits, micros);
        if let Some(cell) = self.buckets.get_mut(idx) {
            *cell = cell.saturating_add(1);
        }
        self.count = self.count.saturating_add(1);
        self.sum = self.sum.saturating_add(micros);
        self.min = self.min.min(micros);
        self.max = self.max.max(micros);
    }

    pub fn count(&self) -> u64 {
        self.count
    }
    pub fn sum(&self) -> u64 {
        self.sum
    }
    /// Smallest observation, 0 when there is none.
    pub fn min(&self) -> u64 {
        if self.count == 0 {
            0
        } else {
            self.min
        }
    }
    pub fn max(&self) -> u64 {
        self.max
    }
    pub fn buckets(&self) -> &[u64] {
        &self.buckets
    }

    /// Mean value, `None` when empty (never a fabricated zero).
    pub fn mean(&self) -> Option<f64> {
        if self.count == 0 {
            None
        } else {
            Some(self.sum as f64 / self.count as f64)
        }
    }

    /// Linear-interpolated quantile of the observations, in microseconds. `None` when empty.
    pub fn quantile(&self, q: f64) -> Option<u64> {
        if self.count == 0 {
            return None;
        }
        let q = q.clamp(0.0, 1.0);
        let target = ((q * self.count as f64).ceil() as u64).max(1);
        let mut cumulative = 0u64;
        for (idx, &c) in self.buckets.iter().enumerate() {
            if c == 0 {
                continue;
            }
            let before = cumulative;
            cumulative += c;
            if cumulative >= target {
                let (lo, hi) = bounds_of(self.sub_bits, idx);
                let within = (target - before) as f64 / c as f64;
                let value = lo as f64 + within * (hi.saturating_sub(lo)) as f64;
                return Some(value.round().min(hi as f64) as u64);
            }
        }
        Some(self.max)
    }

    pub fn p50(&self) -> Option<u64> {
        self.quantile(0.50)
    }
    pub fn p95(&self) -> Option<u64> {
        self.quantile(0.95)
    }

    /// Replace this histogram's contents with a decoded snapshot.
    pub(crate) fn restore(&mut self, count: u64, sum: u64, min: u64, max: u64, buckets: &[u64]) {
        if buckets.len() == self.buckets.len() {
            self.buckets.copy_from_slice(buckets);
        } else {
            for (i, v) in buckets.iter().enumerate().take(self.buckets.len()) {
                self.buckets[i] = *v;
            }
        }
        self.count = count;
        self.sum = sum;
        self.min = if count == 0 { u64::MAX } else { min };
        self.max = max;
    }
}

/// Number of buckets for a given resolution.
pub fn bucket_count(sub_bits: u8) -> usize {
    let sub = 1usize << sub_bits;
    sub + (64 - sub_bits as usize) * sub
}

/// Bucket index for a value. Monotonic in the value, and `index_of(b, v) <= bucket_count(b) - 1`.
pub fn index_of(sub_bits: u8, micros: u64) -> usize {
    let sub = 1u64 << sub_bits;
    if micros < sub {
        return micros as usize;
    }
    let e = (63 - micros.leading_zeros() as u64) - sub_bits as u64;
    let m = (micros >> e) - sub;
    let idx = sub + e * sub + m;
    (idx as usize).min(bucket_count(sub_bits) - 1)
}

/// Inclusive-ish `[lo, hi]` value range a bucket covers.
pub fn bounds_of(sub_bits: u8, idx: usize) -> (u64, u64) {
    let sub = 1usize << sub_bits;
    if idx < sub {
        return (idx as u64, idx as u64);
    }
    let e = (idx - sub) / sub;
    let m = (idx - sub) % sub;
    let lo = ((m + sub) as u128) << e;
    let hi = (((m + sub + 1) as u128) << e) - 1;
    (
        lo.min(u64::MAX as u128) as u64,
        hi.min(u64::MAX as u128) as u64,
    )
}

/// Upper bound of a bucket in seconds, for the Prometheus `le` label.
pub fn upper_seconds(sub_bits: u8, idx: usize) -> f64 {
    bounds_of(sub_bits, idx).1 as f64 / 1_000_000.0
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn bucket_index_is_monotonic_and_bounded() {
        let b = DEFAULT_SUB_BITS;
        let last = bucket_count(b) - 1;
        let mut prev = 0usize;
        let mut v = 0u64;
        while v < u64::MAX / 2 {
            let idx = index_of(b, v);
            assert!(idx >= prev, "{v}");
            assert!(idx <= last);
            prev = idx;
            v = v * 2 + 1;
        }
        assert_eq!(index_of(b, 0), 0);
        assert_eq!(index_of(b, 15), 15);
        assert_eq!(index_of(b, u64::MAX), last);
    }

    #[test]
    fn bounds_contain_their_own_bucket_values() {
        let b = DEFAULT_SUB_BITS;
        for idx in 0..bucket_count(b) {
            let (lo, hi) = bounds_of(b, idx);
            assert!(lo <= hi, "bucket {idx}");
            assert_eq!(index_of(b, lo), idx);
            assert_eq!(index_of(b, hi), idx);
        }
    }

    #[test]
    fn percentile_lands_inside_the_right_bucket() {
        let mut h = Histogram::new(DEFAULT_SUB_BITS);
        for _ in 0..90 {
            h.observe(1_000);
        }
        for _ in 0..10 {
            h.observe(50_000);
        }
        assert_eq!(h.count(), 100);
        assert_eq!(h.sum(), 90_000 + 500_000);
        assert_eq!(h.min(), 1_000);
        assert_eq!(h.max(), 50_000);
        let p50 = h.p50().unwrap();
        let p95 = h.p95().unwrap();
        let (lo, hi) = bounds_of(DEFAULT_SUB_BITS, index_of(DEFAULT_SUB_BITS, 1_000));
        assert!(p50 >= lo && p50 <= hi, "p50 {p50} not in {lo}..{hi}");
        let (lo, hi) = bounds_of(DEFAULT_SUB_BITS, index_of(DEFAULT_SUB_BITS, 50_000));
        assert!(p95 >= lo && p95 <= hi, "p95 {p95} not in {lo}..{hi}");
        assert!(p95 > p50);
        assert!(h.mean().unwrap() > 0.0);
    }

    #[test]
    fn empty_histogram_reports_nothing_not_zero() {
        let h = Histogram::new(DEFAULT_SUB_BITS);
        assert_eq!(h.quantile(0.5), None);
        assert_eq!(h.mean(), None);
        assert_eq!(h.count(), 0);
        assert_eq!(h.min(), 0);
    }
}
