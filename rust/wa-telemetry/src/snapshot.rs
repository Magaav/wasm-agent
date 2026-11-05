//! Snapshot: the whole registry as one little-endian blob, written atomically.
//!
//! A hand-written format, not a derive: the bytes are stable, they are the same on every node and
//! architecture, and a reader never needs a schema crate to make sense of them. Reading validates
//! magic and version and refuses to guess at anything else — a truncated or foreign file is an
//! error, never a half-restored registry.
//!
//! Restore *replaces* the registry: it is a restore to the saved point, not a merge. The caps come
//! from the running `Config`, so a node that shrank its rings keeps the newest buckets of each.
use crate::config::Config;
use crate::labels::Labels;
use crate::metrics::{Component, Family, Metrics, Series, SeriesState};
use crate::rollup::{Cell, Level, RollupSeries, Rollups};
use std::collections::BTreeMap;
use std::fmt;
use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::sync::Arc;

const MAGIC: &[u8; 8] = b"WATELEM1";
const VERSION: u32 = 1;

#[derive(Debug)]
pub enum SnapshotError {
    BadMagic,
    BadVersion(u32),
    Truncated(&'static str),
    Io(io::Error),
}

impl fmt::Display for SnapshotError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SnapshotError::BadMagic => write!(f, "not a wa-telemetry snapshot"),
            SnapshotError::BadVersion(v) => write!(f, "unsupported snapshot version {v}"),
            SnapshotError::Truncated(where_) => write!(f, "snapshot truncated while reading {where_}"),
            SnapshotError::Io(e) => write!(f, "snapshot io: {e}"),
        }
    }
}

impl std::error::Error for SnapshotError {}

impl From<io::Error> for SnapshotError {
    fn from(e: io::Error) -> Self {
        SnapshotError::Io(e)
    }
}

impl Metrics {
    /// Encode metrics, rollups and the trace ring. The result is bounded by the caps, so this is
    /// safe to write on a timer without checking its size first.
    pub fn snapshot_bytes(&self) -> Vec<u8> {
        let state = self.inner.lock();
        let mut out = Vec::with_capacity(64 * 1024);
        out.extend_from_slice(MAGIC);
        put_u32(&mut out, VERSION);
        put_u64(&mut out, self.inner.now_ms());
        put_u32(&mut out, state.components.len() as u32);
        for (component, entry) in &state.components {
            put_str(&mut out, component);
            put_u32(&mut out, entry.families.len() as u32);
            for (name, family) in &entry.families {
                put_u8(&mut out, kind_code(family.kind));
                put_str(&mut out, name);
                put_u8(&mut out, family.sub_bits);
                put_u64(&mut out, family.dropped_sets);
                put_u32(&mut out, family.series.len() as u32);
                for series in &family.series {
                    put_labels(&mut out, &series.labels);
                    match &series.state {
                        SeriesState::Counter(v) => put_u64(&mut out, *v),
                        SeriesState::Gauge(v) => put_i64(&mut out, *v),
                        SeriesState::Histogram(h) => {
                            put_u8(&mut out, h.sub_bits());
                            put_u64(&mut out, h.count());
                            put_u64(&mut out, h.sum());
                            put_u64(&mut out, h.min());
                            put_u64(&mut out, h.max());
                            put_u32(&mut out, h.buckets().len() as u32);
                            for c in h.buckets() {
                                put_u64(&mut out, *c);
                            }
                        }
                    }
                }
            }
        }
        let rolls = state.rollups.raw();
        put_u32(&mut out, rolls.len() as u32);
        put_u64(&mut out, state.rollups.refused());
        for s in rolls {
            put_str(&mut out, &s.component);
            put_str(&mut out, &s.name);
            put_labels(&mut out, &s.labels);
            put_u32(&mut out, s.minute);
            put_u32(&mut out, s.hour);
            put_u32(&mut out, s.day);
            put_cell(&mut out, &s.cur);
            put_cell(&mut out, &s.cur_hour);
            put_cell(&mut out, &s.cur_day);
            put_level(&mut out, &s.minutes);
            put_level(&mut out, &s.hours);
            put_level(&mut out, &s.days);
        }
        put_u64(&mut out, state.span_seq);
        put_u64(&mut out, state.kind_conflicts);
        put_u64(&mut out, state.dropped_families);
        put_u64(&mut out, state.dropped_components);
        let blobs: Vec<&Vec<u8>> = state.traces.raw().iter().collect();
        let trace_bytes: u64 = blobs.iter().map(|b| b.len() as u64).sum();
        put_u64(&mut out, trace_bytes);
        put_u64(&mut out, state.traces.spans_kept);
        put_u64(&mut out, state.traces.spans_dropped_by_sampler);
        put_u64(&mut out, state.traces.spans_evicted);
        put_u64(&mut out, state.traces.spans_oversized);
        put_u64(&mut out, state.traces.attrs_dropped);
        put_u64(&mut out, state.traces.attrs_truncated);
        put_u32(&mut out, blobs.len() as u32);
        for blob in blobs {
            put_bytes(&mut out, blob);
        }
        out
    }

    /// Replace this registry's contents with the snapshot.
    pub fn restore_bytes(&self, bytes: &[u8]) -> Result<(), SnapshotError> {
        let cfg = self.inner.cfg.clone();
        let decoded = decode(bytes, &cfg)?;
        let mut state = self.inner.lock();
        state.components = decoded.components;
        state.rollups = decoded.rollups;
        state.traces.restore(decoded.trace_blobs);
        state.traces.spans_kept = decoded.trace_counters.0;
        state.traces.spans_dropped_by_sampler = decoded.trace_counters.1;
        state.traces.spans_evicted = decoded.trace_counters.2;
        state.traces.spans_oversized = decoded.trace_counters.3;
        state.traces.attrs_dropped = decoded.trace_counters.4;
        state.traces.attrs_truncated = decoded.trace_counters.5;
        state.span_seq = decoded.span_seq;
        state.kind_conflicts = decoded.kind_conflicts;
        state.dropped_families = decoded.dropped_families;
        state.dropped_components = decoded.dropped_components;
        Ok(())
    }

    /// Write atomically: temp file next to the target, fsync, rename. A reader never sees a partial
    /// snapshot, and a crash leaves either the old file or the new one.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        let bytes = self.snapshot_bytes();
        let tmp = match path.file_name().and_then(|n| n.to_str()) {
            Some(name) => path.with_file_name(format!("{name}.tmp")),
            None => return Err(io::Error::new(io::ErrorKind::InvalidInput, "snapshot path has no file name")),
        };
        {
            let mut file = fs::File::create(&tmp)?;
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        fs::rename(&tmp, path)
    }

    pub fn load(&self, path: &Path) -> Result<(), SnapshotError> {
        let bytes = fs::read(path)?;
        self.restore_bytes(&bytes)
    }
}

struct Decoded {
    components: BTreeMap<Arc<str>, Component>,
    rollups: Rollups,
    trace_blobs: Vec<Vec<u8>>,
    trace_counters: (u64, u64, u64, u64, u64, u64),
    span_seq: u64,
    kind_conflicts: u64,
    dropped_families: u64,
    dropped_components: u64,
}

fn decode(bytes: &[u8], cfg: &Config) -> Result<Decoded, SnapshotError> {
    let mut r = Reader { b: bytes, pos: 0 };
    let magic = r.take(8).ok_or(SnapshotError::Truncated("magic"))?;
    if magic != MAGIC {
        return Err(SnapshotError::BadMagic);
    }
    let version = r.u32()?;
    if version != VERSION {
        return Err(SnapshotError::BadVersion(version));
    }
    let _saved_at = r.u64()?;
    let components_len = r.u32()? as usize;
    let mut components: BTreeMap<Arc<str>, Component> = BTreeMap::new();
    // Every entry is parsed even when the live caps are smaller: skipping entries without reading
    // them would leave the reader at the wrong offset and turn "this node shrank its caps" into
    // "this snapshot is corrupt".
    for _ in 0..components_len {
        let component: Arc<str> = Arc::from(r.str()?);
        let families_len = r.u32()? as usize;
        let mut families: BTreeMap<Arc<str>, Family> = BTreeMap::new();
        for _ in 0..families_len {
            let kind = kind_from(r.u8()?)?;
            let name: Arc<str> = Arc::from(r.str()?);
            let sub_bits = r.u8()?;
            let dropped_sets = r.u64()?;
            let series_len = r.u32()? as usize;
            let mut series = Vec::new();
            for _ in 0..series_len {
                let labels = read_labels(&mut r)?;
                let state = match kind {
                    crate::metrics::Kind::Counter => SeriesState::Counter(r.u64()?),
                    crate::metrics::Kind::Gauge => SeriesState::Gauge(r.i64()?),
                    crate::metrics::Kind::Histogram => {
                        let sub = r.u8()?;
                        let count = r.u64()?;
                        let sum = r.u64()?;
                        let min = r.u64()?;
                        let max = r.u64()?;
                        let n = r.u32()? as usize;
                        let mut buckets = Vec::with_capacity(n.min(crate::histogram::bucket_count(sub)));
                        for _ in 0..n {
                            buckets.push(r.u64()?);
                        }
                        let mut h = crate::histogram::Histogram::new(sub);
                        h.restore(count, sum, min, max, &buckets);
                        SeriesState::Histogram(h)
                    }
                };
                if series.len() < cfg.max_series_per_family + 1 {
                    series.push(Series {
                        labels,
                        state,
                        rollup: None,
                        rollup_refused: false,
                    });
                }
            }
            if families.len() < cfg.max_families_per_component {
                families.insert(
                    name,
                    Family {
                        kind,
                        sub_bits,
                        series,
                        dropped_sets,
                    },
                );
            }
        }
        if components.len() < cfg.max_components {
            components.insert(component, Component { families });
        }
    }
    let rolls_len = r.u32()? as usize;
    let rollup_refused = r.u64()?;
    let mut rollups = Rollups::new(cfg);
    let mut restored: Vec<RollupSeries> = Vec::new();
    for _ in 0..rolls_len {
        let component: Arc<str> = Arc::from(r.str()?);
        let name: Arc<str> = Arc::from(r.str()?);
        let labels = read_labels(&mut r)?;
        let minute = r.u32()?;
        let hour = r.u32()?;
        let day = r.u32()?;
        let cur = read_cell(&mut r)?;
        let cur_hour = read_cell(&mut r)?;
        let cur_day = read_cell(&mut r)?;
        let minutes = read_level(&mut r, cfg.minute_slots)?;
        let hours = read_level(&mut r, cfg.hour_slots)?;
        let days = read_level(&mut r, cfg.day_slots)?;
        if restored.len() >= cfg.rollup_series {
            continue;
        }
        restored.push(RollupSeries {
            component,
            name,
            labels,
            minute,
            hour,
            day,
            cur,
            cur_hour,
            cur_day,
            minutes,
            hours,
            days,
        });
    }
    rollups.restore_series(restored);
    rollups.set_refused(rollup_refused);
    // Re-link each series to its restored rollup (identity is (component, name, labels)).
    for (component, entry) in components.iter_mut() {
        for (name, family) in entry.families.iter_mut() {
            for series in family.series.iter_mut() {
                if series.labels.is_other() {
                    series.rollup_refused = true;
                    continue;
                }
                match rollups.lookup(component, name, &series.labels) {
                    Some(idx) => {
                        series.rollup = Some(idx);
                        series.rollup_refused = false;
                    }
                    None => series.rollup_refused = true,
                }
            }
        }
    }
    let span_seq = r.u64()?;
    let kind_conflicts = r.u64()?;
    let dropped_families = r.u64()?;
    let dropped_components = r.u64()?;
    let trace_bytes = r.u64()? as usize;
    let c0 = r.u64()?;
    let c1 = r.u64()?;
    let c2 = r.u64()?;
    let c3 = r.u64()?;
    let c4 = r.u64()?;
    let c5 = r.u64()?;
    let blobs_len = r.u32()? as usize;
    let mut trace_blobs = Vec::with_capacity(trace_bytes.min(cfg.trace_bytes) / 64);
    let mut read_bytes = 0usize;
    for _ in 0..blobs_len {
        let blob = r.bytes()?.to_vec();
        if read_bytes + blob.len() <= cfg.trace_bytes {
            read_bytes += blob.len();
            trace_blobs.push(blob);
        }
    }
    Ok(Decoded {
        components,
        rollups,
        trace_blobs,
        trace_counters: (c0, c1, c2, c3, c4, c5),
        span_seq,
        kind_conflicts,
        dropped_families,
        dropped_components,
    })
}

fn kind_code(kind: crate::metrics::Kind) -> u8 {
    match kind {
        crate::metrics::Kind::Counter => 0,
        crate::metrics::Kind::Gauge => 1,
        crate::metrics::Kind::Histogram => 2,
    }
}

fn kind_from(code: u8) -> Result<crate::metrics::Kind, SnapshotError> {
    match code {
        0 => Ok(crate::metrics::Kind::Counter),
        1 => Ok(crate::metrics::Kind::Gauge),
        2 => Ok(crate::metrics::Kind::Histogram),
        _ => Err(SnapshotError::Truncated("metric kind")),
    }
}

fn put_u8(out: &mut Vec<u8>, v: u8) {
    out.push(v);
}
fn put_u32(out: &mut Vec<u8>, v: u32) {
    out.extend_from_slice(&v.to_le_bytes());
}
fn put_u64(out: &mut Vec<u8>, v: u64) {
    out.extend_from_slice(&v.to_le_bytes());
}
fn put_i64(out: &mut Vec<u8>, v: i64) {
    out.extend_from_slice(&v.to_le_bytes());
}
fn put_str(out: &mut Vec<u8>, s: &str) {
    put_bytes(out, s.as_bytes());
}
fn put_bytes(out: &mut Vec<u8>, b: &[u8]) {
    put_u32(out, b.len() as u32);
    out.extend_from_slice(b);
}
fn put_labels(out: &mut Vec<u8>, labels: &Labels) {
    put_u32(out, labels.len() as u32);
    for (k, v) in labels.pairs() {
        put_str(out, k);
        put_str(out, v);
    }
}
fn put_cell(out: &mut Vec<u8>, cell: &Cell) {
    put_u32(out, cell.observations);
    put_u32(out, cell.errors);
    put_u64(out, cell.sum);
    put_u32(out, cell.min);
    put_u32(out, cell.max);
    put_i64(out, cell.last);
}
fn put_level(out: &mut Vec<u8>, level: &Level) {
    let points = level.iter();
    put_u32(out, points.len() as u32);
    for (key, cell) in points {
        put_u32(out, key);
        put_cell(out, &cell);
    }
}

fn read_labels(r: &mut Reader<'_>) -> Result<Labels, SnapshotError> {
    let n = r.u32()? as usize;
    let mut pairs = Vec::with_capacity(n.min(64));
    for _ in 0..n.min(64) {
        let k = r.str()?.to_string();
        let v = r.str()?.to_string();
        pairs.push((k, v));
    }
    Ok(Labels::from_pairs(pairs))
}

fn read_cell(r: &mut Reader<'_>) -> Result<Cell, SnapshotError> {
    Ok(Cell {
        observations: r.u32()?,
        errors: r.u32()?,
        sum: r.u64()?,
        min: r.u32()?,
        max: r.u32()?,
        last: r.i64()?,
    })
}

fn read_level(r: &mut Reader<'_>, cap: usize) -> Result<Level, SnapshotError> {
    let n = r.u32()? as usize;
    let mut level = Level::new(cap);
    for _ in 0..n {
        let key = r.u32()?;
        let cell = read_cell(r)?;
        level.push(key, cell);
    }
    Ok(level)
}

struct Reader<'a> {
    b: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(n)?;
        let slice = self.b.get(self.pos..end)?;
        self.pos = end;
        Some(slice)
    }
    fn u8(&mut self) -> Result<u8, SnapshotError> {
        self.take(1).map(|s| s[0]).ok_or(SnapshotError::Truncated("u8"))
    }
    fn u32(&mut self) -> Result<u32, SnapshotError> {
        self.take(4)
            .and_then(|s| s.try_into().ok())
            .map(u32::from_le_bytes)
            .ok_or(SnapshotError::Truncated("u32"))
    }
    fn u64(&mut self) -> Result<u64, SnapshotError> {
        self.take(8)
            .and_then(|s| s.try_into().ok())
            .map(u64::from_le_bytes)
            .ok_or(SnapshotError::Truncated("u64"))
    }
    fn i64(&mut self) -> Result<i64, SnapshotError> {
        self.take(8)
            .and_then(|s| s.try_into().ok())
            .map(i64::from_le_bytes)
            .ok_or(SnapshotError::Truncated("i64"))
    }
    fn bytes(&mut self) -> Result<&'a [u8], SnapshotError> {
        let n = self.u32()? as usize;
        self.take(n).ok_or(SnapshotError::Truncated("bytes"))
    }
    fn str(&mut self) -> Result<&'a str, SnapshotError> {
        std::str::from_utf8(self.bytes()?).map_err(|_| SnapshotError::Truncated("string"))
    }
}

