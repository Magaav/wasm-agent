//! Caps. Every bound that keeps storage fixed lives here and nowhere else: a metrics registry whose
//! size is decided by traffic is a leak with a nice name.
use std::collections::BTreeMap;

/// One nanosecond-capable instant is not needed: every series is in milliseconds/microseconds.
#[derive(Clone, Debug)]
pub struct Config {
    /// Components this registry will describe. Beyond this, series are refused and counted.
    pub max_components: usize,
    /// Metric families (counter/gauge/histogram names) per component.
    pub max_families_per_component: usize,
    /// Label sets per family. Overflow folds into one `wa_other` series and is counted.
    pub max_series_per_family: usize,
    /// Label pairs kept on one series; extra pairs are dropped (order and truncation first).
    pub max_labels: usize,
    pub max_label_key: usize,
    pub max_label_value: usize,
    /// Metric name kept; longer names are truncated (a truncated name is still a name).
    pub max_name_len: usize,
    /// Log-bucket resolution: `1 << sub_bits` buckets per power of two (~6% at the default 4).
    pub hist_sub_bits: u8,
    /// Series that get minute/hour/day rollups. Rollups cost ~230 KiB per series, so this is a cap,
    /// not a hint; series beyond it keep their live value only and are counted.
    pub rollup_series: usize,
    /// Per-minute slots kept (24 h at one minute each).
    pub minute_slots: usize,
    /// Per-hour slots kept (30 d at one hour each).
    pub hour_slots: usize,
    /// Per-day slots kept. "Forever" needs *some* number: 3653 days is ten years.
    pub day_slots: usize,
    /// Trace ring, oldest-first eviction. Default 200 MiB per node.
    pub trace_bytes: usize,
    /// Share of *normal* spans kept, per mille (20 = 2%). Errors and slow spans are always kept.
    pub trace_sample_permille: u32,
    /// Default "slow" threshold for a span; per-op overrides in `trace_slow_by_op`.
    pub trace_slow_us: u64,
    /// Per-op slow thresholds, keyed `"component/op"`.
    pub trace_slow_by_op: BTreeMap<String, u64>,
    pub max_span_attrs: usize,
    pub max_attr_key: usize,
    pub max_attr_value: usize,
    pub max_span_name: usize,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            max_components: 256,
            max_families_per_component: 512,
            max_series_per_family: 32,
            max_labels: 4,
            max_label_key: 32,
            max_label_value: 64,
            max_name_len: 96,
            hist_sub_bits: 4,
            rollup_series: 64,
            minute_slots: 24 * 60,
            hour_slots: 30 * 24,
            day_slots: 3653,
            trace_bytes: 200 * 1024 * 1024,
            trace_sample_permille: 20,
            trace_slow_us: 500_000,
            trace_slow_by_op: BTreeMap::new(),
            max_span_attrs: 8,
            max_attr_key: 32,
            max_attr_value: 64,
            max_span_name: 96,
        }
    }
}

impl Config {
    /// Small caps for tests and for a node that would rather lose detail than memory.
    pub fn for_tests() -> Self {
        Self {
            max_components: 8,
            max_families_per_component: 8,
            max_series_per_family: 2,
            max_labels: 2,
            rollup_series: 4,
            minute_slots: 4,
            hour_slots: 4,
            day_slots: 4,
            trace_bytes: 4096,
            trace_sample_permille: 20,
            trace_slow_us: 100_000,
            ..Self::default()
        }
    }

    /// Slow threshold for one op: exact key first, then the component-wide entry `"component/*"`,
    /// then the default. Never silently falls back to "not slow".
    pub fn slow_us(&self, component: &str, op: &str) -> u64 {
        if let Some(v) = self.trace_slow_by_op.get(&format!("{component}/{op}")) {
            return *v;
        }
        if let Some(v) = self.trace_slow_by_op.get(&format!("{component}/*")) {
            return *v;
        }
        self.trace_slow_us
    }

    pub fn set_slow_us(&mut self, component: &str, op: &str, micros: u64) {
        self.trace_slow_by_op
            .insert(format!("{component}/{op}"), micros);
    }
}
