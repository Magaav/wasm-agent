//! The registry: components -> metric families -> series, plus rollups and the trace ring.
//!
//! One lock covers all mutable state. Call sites are short (a handful of map lookups and one
//! saturating add), which is the right trade for a telemetry path: a contended fine-grained lock
//! scheme would cost more thought than the microseconds it saves, and it would make the fixed-size
//! accounting much harder to keep true.
use crate::clock::{Clock, SystemClock};
use crate::config::Config;
use crate::histogram::Histogram as RawHistogram;
use crate::labels::Labels;
use crate::rollup::{RollupSeriesView, Rollups};
use crate::trace::{Keep, Sampler, Span, SpanStatus, TraceStore};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, MutexGuard};

/// What a family is. A name may only be one kind per component; a clash is refused and counted
/// (`TelemetryStats::kind_conflicts`), never silently coerced.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Counter,
    Gauge,
    Histogram,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Counter => "counter",
            Kind::Gauge => "gauge",
            Kind::Histogram => "histogram",
        }
    }
}

/// The observation a call site makes, after the handle has fixed component/name/kind.
#[derive(Clone, Copy, Debug)]
pub(crate) enum Op {
    Add(u64),
    Set(i64),
    /// Read-modify-write inside the registry lock, so two threads adding to one gauge cannot lose
    /// an increment (a get-then-set from the handle would).
    AddToGauge(i64),
    Observe(u64, bool),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Reject {
    Components,
    Families,
    Conflict,
}

pub(crate) enum SeriesState {
    Counter(u64),
    Gauge(i64),
    Histogram(RawHistogram),
}

pub(crate) struct Series {
    pub(crate) labels: Labels,
    pub(crate) state: SeriesState,
    pub(crate) rollup: Option<usize>,
    /// Set when the rollup cap refused this series, so every later record does not retry.
    pub(crate) rollup_refused: bool,
}

pub(crate) struct Family {
    pub(crate) kind: Kind,
    pub(crate) sub_bits: u8,
    pub(crate) series: Vec<Series>,
    /// Distinct label sets folded into the `wa_other` series.
    pub(crate) dropped_sets: u64,
}

impl Family {
    fn new(kind: Kind, sub_bits: u8) -> Self {
        Self {
            kind,
            sub_bits,
            series: Vec::new(),
            dropped_sets: 0,
        }
    }
}

pub(crate) struct Component {
    pub(crate) families: BTreeMap<Arc<str>, Family>,
}

pub(crate) struct State {
    pub(crate) components: BTreeMap<Arc<str>, Component>,
    pub(crate) rollups: Rollups,
    pub(crate) traces: TraceStore,
    pub(crate) span_seq: u64,
    pub(crate) kind_conflicts: u64,
    pub(crate) dropped_families: u64,
    pub(crate) dropped_components: u64,
}

impl State {
    /// Find (or create) the series an observation belongs to. Returns the series index and the
    /// rollup index, or why it was refused.
    fn resolve(
        &mut self,
        cfg: &Config,
        now_ms: u64,
        component: &Arc<str>,
        name: &Arc<str>,
        kind: Kind,
        labels: &[(&str, &str)],
    ) -> Result<(usize, Option<usize>), Reject> {
        if !self.components.contains_key(component.as_ref())
            && self.components.len() >= cfg.max_components
        {
            return Err(Reject::Components);
        }
        let entry = self
            .components
            .entry(component.clone())
            .or_insert_with(|| Component {
                families: BTreeMap::new(),
            });
        if !entry.families.contains_key(name.as_ref()) {
            if entry.families.len() >= cfg.max_families_per_component {
                return Err(Reject::Families);
            }
            entry
                .families
                .insert(name.clone(), Family::new(kind, cfg.hist_sub_bits));
        }
        let family = entry
            .families
            .get_mut(name.as_ref())
            .expect("family just inserted");
        if family.kind != kind {
            return Err(Reject::Conflict);
        }
        let found = family
            .series
            .iter()
            .position(|s| s.labels.matches(labels, cfg));
        let idx = match found {
            Some(idx) => idx,
            None => {
                let named = family.series.iter().filter(|s| !s.labels.is_other()).count();
                if named >= cfg.max_series_per_family {
                    family.dropped_sets = family.dropped_sets.saturating_add(1);
                    match family.series.iter().position(|s| s.labels.is_other()) {
                        Some(idx) => idx,
                        None => {
                            family.series.push(Series {
                                labels: Labels::other(),
                                state: new_state(kind, family.sub_bits),
                                rollup: None,
                                rollup_refused: true,
                            });
                            family.series.len() - 1
                        }
                    }
                } else {
                    family.series.push(Series {
                        labels: Labels::canonical(labels, cfg),
                        state: new_state(kind, family.sub_bits),
                        rollup: None,
                        rollup_refused: false,
                    });
                    family.series.len() - 1
                }
            }
        };
        let wants_rollup = family.series[idx].rollup.is_none() && !family.series[idx].rollup_refused;
        if !wants_rollup {
            return Ok((idx, family.series[idx].rollup));
        }
        let labels = family.series[idx].labels.clone();
        let rollup = self.rollups.track(component, name, labels, cfg, now_ms);
        let series = &mut self
            .components
            .get_mut(component.as_ref())
            .expect("component present")
            .families
            .get_mut(name.as_ref())
            .expect("family present")
            .series[idx];
        series.rollup = rollup;
        series.rollup_refused = rollup.is_none();
        Ok((idx, rollup))
    }

    fn note(&mut self, reject: Reject) {
        match reject {
            Reject::Components => self.dropped_components = self.dropped_components.saturating_add(1),
            Reject::Families => self.dropped_families = self.dropped_families.saturating_add(1),
            Reject::Conflict => self.kind_conflicts = self.kind_conflicts.saturating_add(1),
        }
    }

    fn apply(
        &mut self,
        component: &Arc<str>,
        name: &Arc<str>,
        idx: usize,
        op: Op,
        now_ms: u64,
    ) {
        let (value, last, error, rollup) = {
            let series = &mut self
                .components
                .get_mut(component.as_ref())
                .expect("component present")
                .families
                .get_mut(name.as_ref())
                .expect("family present")
                .series[idx];
            let (value, last, error) = match (&mut series.state, op) {
                (SeriesState::Counter(c), Op::Add(n)) => {
                    *c = c.saturating_add(n);
                    (n, n.min(i64::MAX as u64) as i64, false)
                }
                (SeriesState::Gauge(g), Op::Set(v)) => {
                    *g = v;
                    (v.max(0) as u64, v, false)
                }
                (SeriesState::Gauge(g), Op::AddToGauge(delta)) => {
                    *g = g.saturating_add(delta);
                    ((*g).max(0) as u64, *g, false)
                }
                (SeriesState::Histogram(h), Op::Observe(micros, ok)) => {
                    h.observe(micros);
                    (micros, micros.min(i64::MAX as u64) as i64, !ok)
                }
                _ => return,
            };
            (value, last, error, series.rollup)
        };
        if let Some(rollup) = rollup {
            self.rollups.record(rollup, value, last, error, now_ms);
        }
    }

    pub(crate) fn family_count(&self) -> usize {
        self.components.values().map(|c| c.families.len()).sum()
    }

    pub(crate) fn series_count(&self) -> usize {
        self.components
            .values()
            .map(|c| c.families.values().map(|f| f.series.len()).sum::<usize>())
            .sum()
    }
}

fn new_state(kind: Kind, sub_bits: u8) -> SeriesState {
    match kind {
        Kind::Counter => SeriesState::Counter(0),
        Kind::Gauge => SeriesState::Gauge(0),
        Kind::Histogram => SeriesState::Histogram(RawHistogram::new(sub_bits)),
    }
}

pub(crate) struct Inner {
    pub(crate) cfg: Arc<Config>,
    clock: Arc<dyn Clock>,
    state: Mutex<State>,
    sampler: Sampler,
}

impl Inner {
    pub(crate) fn now_ms(&self) -> u64 {
        self.clock.now_ms()
    }

    pub(crate) fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn record(
        &self,
        component: &Arc<str>,
        name: &Arc<str>,
        kind: Kind,
        labels: &[(&str, &str)],
        op: Op,
    ) {
        let now_ms = self.clock.now_ms();
        let mut state = self.lock();
        match state.resolve(&self.cfg, now_ms, component, name, kind, labels) {
            Ok((idx, _)) => state.apply(component, name, idx, op, now_ms),
            Err(reject) => state.note(reject),
        }
    }
}

/// Node-level counters and series counts, as an operator reads them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TraceStats {
    pub spans: usize,
    pub bytes: usize,
    pub max_bytes: usize,
    pub kept: u64,
    pub sampled_out: u64,
    pub evicted: u64,
    pub oversized: u64,
    pub attrs_dropped: u64,
    pub attrs_truncated: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TelemetryStats {
    pub components: usize,
    pub families: usize,
    pub series: usize,
    pub kind_conflicts: u64,
    pub dropped_components: u64,
    pub dropped_families: u64,
    pub rollup_series: usize,
    pub rollup_refused: u64,
    pub trace: TraceStats,
}

/// A histogram's value for one label set.
#[derive(Clone, Debug, PartialEq)]
pub struct HistogramView {
    pub count: u64,
    pub sum: u64,
    pub min: u64,
    pub max: u64,
    pub mean: Option<f64>,
    pub p50: Option<u64>,
    pub p95: Option<u64>,
    pub sub_bits: u8,
    pub buckets: Vec<u64>,
}

/// The registry. Cheap to clone (one `Arc`); hand the clone to a component runner.
#[derive(Clone)]
pub struct Metrics {
    pub(crate) inner: Arc<Inner>,
}

impl Metrics {
    pub fn new(cfg: Config) -> Self {
        Self::with_clock(cfg, Arc::new(SystemClock))
    }

    pub fn with_clock(cfg: Config, clock: Arc<dyn Clock>) -> Self {
        let cfg = Arc::new(cfg);
        let rollups = Rollups::new(&cfg);
        let traces = TraceStore::new(&cfg);
        Self {
            inner: Arc::new(Inner {
                sampler: Sampler::new(&cfg),
                cfg,
                clock,
                state: Mutex::new(State {
                    components: BTreeMap::new(),
                    rollups,
                    traces,
                    span_seq: 0,
                    kind_conflicts: 0,
                    dropped_families: 0,
                    dropped_components: 0,
                }),
            }),
        }
    }

    pub fn config(&self) -> &Config {
        &self.inner.cfg
    }

    pub fn now_ms(&self) -> u64 {
        self.inner.clock.now_ms()
    }

    pub fn counter(&self, component: &str, name: &str) -> Counter {
        self.handle(component, name, Kind::Counter)
    }

    pub fn gauge(&self, component: &str, name: &str) -> Gauge {
        self.handle(component, name, Kind::Gauge)
    }

    pub fn histogram(&self, component: &str, name: &str) -> Histogram {
        self.handle(component, name, Kind::Histogram)
    }

    fn handle<T: FromHandle>(&self, component: &str, name: &str, kind: Kind) -> T {
        let cfg = &self.inner.cfg;
        let component: Arc<str> = Arc::from(crate::labels::truncate(component, cfg.max_name_len));
        let name: Arc<str> = Arc::from(crate::labels::sanitize(name, cfg.max_name_len));
        T::from_handle(self.inner.clone(), component, name, kind)
    }

    /// Record one completed operation: the latency histogram (`op_duration_micros`), the outcome
    /// counter (`op_total`) and a span. This is the single call the host makes per component call.
    pub fn record_op(&self, component: &str, op: &str, start_ms: u64, duration_us: u64, status: SpanStatus) {
        self.histogram(component, "op_duration_micros")
            .observe_labeled(duration_us, status == SpanStatus::Ok, &[("op", op)]);
        self.counter(component, "op_total")
            .add_labeled(1, &[("op", op), ("status", status.as_str())]);
        self.record_span(Span::new(component, op, start_ms, duration_us, status));
    }

    /// Start a span now; `finish` records its duration, its histogram and its trace.
    pub fn start_span(&self, component: &str, op: &str) -> SpanTimer {
        SpanTimer {
            metrics: self.clone(),
            component: component.to_string(),
            op: op.to_string(),
            start_ms: self.now_ms(),
            started: std::time::Instant::now(),
            attrs: Vec::new(),
        }
    }

    /// Offer a span to the sampler and the ring. `true` when it is in the ring.
    pub fn record_span(&self, span: Span) -> bool {
        let mut state = self.inner.lock();
        let mut span = span;
        if span.trace_id == 0 {
            state.span_seq = state.span_seq.wrapping_add(1).max(1);
            span.trace_id = state.span_seq;
        }
        let decision: Keep = self.inner.sampler.decide(&span);
        state.traces.store(&span, &self.inner.cfg, decision)
    }

    /// Close every rollup bucket the clock has left. Call once a second (or once a minute); calling
    /// it early costs nothing and losing a bucket is only possible if nobody ever calls it.
    pub fn tick(&self) {
        let now_ms = self.inner.clock.now_ms();
        self.inner.lock().rollups.advance_all(now_ms);
    }

    pub fn stats(&self) -> TelemetryStats {
        self.stats_of(&self.inner.lock())
    }

    /// The same view for an already-locked state (export holds the lock across a whole scrape).
    pub(crate) fn stats_of(&self, state: &State) -> TelemetryStats {
        TelemetryStats {
            components: state.components.len(),
            families: state.family_count(),
            series: state.series_count(),
            kind_conflicts: state.kind_conflicts,
            dropped_components: state.dropped_components,
            dropped_families: state.dropped_families,
            rollup_series: state.rollups.len(),
            rollup_refused: state.rollups.refused(),
            trace: TraceStats {
                spans: state.traces.len(),
                bytes: state.traces.bytes(),
                max_bytes: state.traces.max_bytes(),
                kept: state.traces.spans_kept,
                sampled_out: state.traces.spans_dropped_by_sampler,
                evicted: state.traces.spans_evicted,
                oversized: state.traces.spans_oversized,
                attrs_dropped: state.traces.attrs_dropped,
                attrs_truncated: state.traces.attrs_truncated,
            },
        }
    }

    /// Retained spans, oldest first. Decoded on read: the ring stores bytes, not structs.
    pub fn spans(&self) -> Vec<Span> {
        self.inner.lock().traces.to_vec()
    }

    /// Rollups for every tracked series. `minutes`/`hours`/`days` are finished buckets only; the
    /// open minute is `current`.
    pub fn rollups(&self) -> Vec<RollupSeriesView> {
        self.inner.lock().rollups.views()
    }

    /// Fraction of normal spans kept, per mille, as configured.
    pub fn sample_permille(&self) -> u32 {
        self.inner.sampler.permille()
    }
}

pub(crate) trait FromHandle: Sized {
    fn from_handle(inner: Arc<Inner>, component: Arc<str>, name: Arc<str>, kind: Kind) -> Self;
}

/// A counter handle. Cheap to clone and safe to hold: the registry, not the handle, owns the value.
#[derive(Clone)]
pub struct Counter {
    inner: Arc<Inner>,
    component: Arc<str>,
    name: Arc<str>,
}

impl FromHandle for Counter {
    fn from_handle(inner: Arc<Inner>, component: Arc<str>, name: Arc<str>, _kind: Kind) -> Self {
        Self {
            inner,
            component,
            name,
        }
    }
}

impl std::fmt::Debug for Counter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Counter")
            .field("component", &self.component)
            .field("name", &self.name)
            .finish()
    }
}

impl Counter {
    pub fn add(&self, n: u64) {
        self.add_labeled(n, &[]);
    }
    pub fn inc(&self) {
        self.add(1);
    }
    pub fn add_labeled(&self, n: u64, labels: &[(&str, &str)]) {
        self.inner
            .record(&self.component, &self.name, Kind::Counter, labels, Op::Add(n));
    }
    /// Current value of one label set, `None` when that set was never recorded.
    pub fn get(&self, labels: &[(&str, &str)]) -> Option<u64> {
        let state = self.inner.lock();
        let family = state
            .components
            .get(self.component.as_ref())?
            .families
            .get(self.name.as_ref())?;
        let series = family
            .series
            .iter()
            .find(|s| s.labels.matches(labels, &self.inner.cfg))?;
        match series.state {
            SeriesState::Counter(v) => Some(v),
            _ => None,
        }
    }
}

/// A gauge handle: last write wins, negative values are legal.
#[derive(Clone)]
pub struct Gauge {
    inner: Arc<Inner>,
    component: Arc<str>,
    name: Arc<str>,
}

impl FromHandle for Gauge {
    fn from_handle(inner: Arc<Inner>, component: Arc<str>, name: Arc<str>, _kind: Kind) -> Self {
        Self {
            inner,
            component,
            name,
        }
    }
}

impl std::fmt::Debug for Gauge {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Gauge")
            .field("component", &self.component)
            .field("name", &self.name)
            .finish()
    }
}

impl Gauge {
    pub fn set(&self, v: i64) {
        self.set_labeled(v, &[]);
    }
    pub fn add(&self, delta: i64) {
        self.add_labeled(delta, &[]);
    }
    pub fn set_labeled(&self, v: i64, labels: &[(&str, &str)]) {
        self.inner
            .record(&self.component, &self.name, Kind::Gauge, labels, Op::Set(v));
    }
    /// Add to the current value. The registry does the arithmetic under its own lock, so two
    /// threads adding to the same gauge cannot lose an increment.
    pub fn add_labeled(&self, delta: i64, labels: &[(&str, &str)]) {
        self.inner
            .record(&self.component, &self.name, Kind::Gauge, labels, Op::AddToGauge(delta));
    }
    pub fn get(&self, labels: &[(&str, &str)]) -> Option<i64> {
        let state = self.inner.lock();
        let family = state
            .components
            .get(self.component.as_ref())?
            .families
            .get(self.name.as_ref())?;
        let series = family
            .series
            .iter()
            .find(|s| s.labels.matches(labels, &self.inner.cfg))?;
        match series.state {
            SeriesState::Gauge(v) => Some(v),
            _ => None,
        }
    }
}

/// A histogram handle. Latency is recorded in microseconds on a fixed log bucket array.
#[derive(Clone)]
pub struct Histogram {
    inner: Arc<Inner>,
    component: Arc<str>,
    name: Arc<str>,
}

impl FromHandle for Histogram {
    fn from_handle(inner: Arc<Inner>, component: Arc<str>, name: Arc<str>, _kind: Kind) -> Self {
        Self {
            inner,
            component,
            name,
        }
    }
}

impl std::fmt::Debug for Histogram {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Histogram")
            .field("component", &self.component)
            .field("name", &self.name)
            .finish()
    }
}

impl Histogram {
    pub fn observe(&self, micros: u64, ok: bool) {
        self.observe_labeled(micros, ok, &[]);
    }

    pub fn observe_labeled(&self, micros: u64, ok: bool, labels: &[(&str, &str)]) {
        self.inner.record(
            &self.component,
            &self.name,
            Kind::Histogram,
            labels,
            Op::Observe(micros, ok),
        );
    }

    /// Convenience for a measured `Duration`: sub-microsecond work counts as 0 µs, never as 1 ms.
    pub fn observe_duration(&self, d: std::time::Duration, ok: bool) {
        self.observe(d.as_micros().min(u64::MAX as u128) as u64, ok);
    }

    pub fn get(&self, labels: &[(&str, &str)]) -> Option<HistogramView> {
        let state = self.inner.lock();
        let family = state
            .components
            .get(self.component.as_ref())?
            .families
            .get(self.name.as_ref())?;
        let series = family
            .series
            .iter()
            .find(|s| s.labels.matches(labels, &self.inner.cfg))?;
        match &series.state {
            SeriesState::Histogram(h) => Some(HistogramView {
                count: h.count(),
                sum: h.sum(),
                min: h.min(),
                max: h.max(),
                mean: h.mean(),
                p50: h.p50(),
                p95: h.p95(),
                sub_bits: h.sub_bits(),
                buckets: h.buckets().to_vec(),
            }),
            _ => None,
        }
    }
}

/// A span that has started and not yet finished.
pub struct SpanTimer {
    metrics: Metrics,
    component: String,
    op: String,
    start_ms: u64,
    /// Monotonic, so the measured duration cannot be shortened by a wall-clock step. The wall
    /// clock only places the span on the timeline (`start_ms`).
    started: std::time::Instant,
    attrs: Vec<(String, String)>,
}

impl SpanTimer {
    pub fn attr(mut self, key: &str, value: &str) -> Self {
        self.attrs.push((key.to_string(), value.to_string()));
        self
    }

    pub fn elapsed_us(&self) -> u64 {
        self.started.elapsed().as_micros().min(u64::MAX as u128) as u64
    }

    /// Finish, record the latency histogram and offer the span to the sampler.
    pub fn finish(self, status: SpanStatus) -> bool {
        let duration_us = self.elapsed_us();
        self.metrics.histogram(&self.component, "op_duration_micros").observe_labeled(
            duration_us,
            status == SpanStatus::Ok,
            &[("op", &self.op)],
        );
        self.metrics.counter(&self.component, "op_total").add_labeled(
            1,
            &[("op", &self.op), ("status", status.as_str())],
        );
        let mut span = Span::new(
            self.component.as_str(),
            self.op.as_str(),
            self.start_ms,
            duration_us,
            status,
        );
        span.attrs = self.attrs;
        self.metrics.record_span(span)
    }
}
