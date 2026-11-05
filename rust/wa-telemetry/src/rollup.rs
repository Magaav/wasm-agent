//! Rollups: the same series observed three times over — per minute for a day, per hour for a month,
//! per day for (practically) ever — each in a fixed-size ring keyed by its bucket.
//!
//! Storage is bounded by construction: the arrays are allocated from `Config` and never grow, a
//! bucket that a ring has already wrapped past is gone, and an idle series simply leaves empty slots.
//! There is no compaction job, no periodic rewrite and no file that grows with traffic.
//!
//! Roll-up is hierarchical on purpose. An hour's cell is the sum of the minute cells it contains, so
//! a query never re-reads the minutes: a hot 24 h window costs 1440 slot reads, not a scan.
use crate::config::Config;
use crate::labels::Labels;
use std::collections::BTreeMap;
use std::sync::Arc;

pub const MINUTE_MS: u64 = 60_000;
pub const HOUR_MS: u64 = 3_600_000;
pub const DAY_MS: u64 = 86_400_000;

/// One bucket of rolled-up series data. Counts and min/max saturate at `u32` (a single observation
/// above ~71 minutes of microseconds saturates min/max rather than wrapping); `sum` is `u64`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Cell {
    pub observations: u32,
    pub errors: u32,
    pub sum: u64,
    pub min: u32,
    pub max: u32,
    pub last: i64,
}

impl Cell {
    pub fn observe(&mut self, value: u64, last: i64, error: bool) {
        let capped = value.min(u32::MAX as u64) as u32;
        let first = self.observations == 0;
        self.observations = self.observations.saturating_add(1);
        if error {
            self.errors = self.errors.saturating_add(1);
        }
        self.sum = self.sum.saturating_add(value);
        if first {
            self.min = capped;
            self.max = capped;
        } else {
            self.min = self.min.min(capped);
            self.max = self.max.max(capped);
        }
        self.last = last;
    }

    pub fn merge(&mut self, other: &Cell) {
        if other.observations == 0 {
            return;
        }
        let first = self.observations == 0;
        self.observations = self.observations.saturating_add(other.observations);
        self.errors = self.errors.saturating_add(other.errors);
        self.sum = self.sum.saturating_add(other.sum);
        self.min = if first {
            other.min
        } else {
            self.min.min(other.min)
        };
        self.max = if first {
            other.max
        } else {
            self.max.max(other.max)
        };
        self.last = other.last;
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Slot {
    pub key: u32,
    pub used: bool,
    pub cell: Cell,
}

/// A fixed ring of buckets, indexed by `key % cap`. Keys that are still in the ring win over keys
/// that wrapped, so a query after a wrap sees the newest `cap` buckets in order.
#[derive(Clone, Debug)]
pub(crate) struct Level {
    pub cap: usize,
    pub slots: Vec<Slot>,
}

impl Level {
    pub fn new(cap: usize) -> Self {
        let cap = cap.max(1);
        Self {
            cap,
            slots: vec![Slot::default(); cap],
        }
    }

    pub fn push(&mut self, key: u32, cell: Cell) {
        if cell.observations == 0 {
            return;
        }
        let idx = key as usize % self.cap;
        if let Some(slot) = self.slots.get_mut(idx) {
            if slot.used && slot.key == key {
                slot.cell.merge(&cell);
            } else {
                *slot = Slot {
                    key,
                    used: true,
                    cell,
                };
            }
        }
    }

    pub fn iter(&self) -> Vec<(u32, Cell)> {
        let mut out: Vec<(u32, Cell)> = self
            .slots
            .iter()
            .filter(|s| s.used)
            .map(|s| (s.key, s.cell))
            .collect();
        out.sort_by_key(|(k, _)| *k);
        out
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level3 {
    Minute,
    Hour,
    Day,
}

/// One series' rollup state: the open minute, plus the hour and day it is accumulating into.
#[derive(Clone, Debug)]
pub(crate) struct RollupSeries {
    pub component: Arc<str>,
    pub name: Arc<str>,
    pub labels: Labels,
    pub minute: u32,
    pub hour: u32,
    pub day: u32,
    pub cur: Cell,
    pub cur_hour: Cell,
    pub cur_day: Cell,
    pub minutes: Level,
    pub hours: Level,
    pub days: Level,
}

impl RollupSeries {
    fn new(component: Arc<str>, name: Arc<str>, labels: Labels, cfg: &Config, now_ms: u64) -> Self {
        let (minute, hour, day) = keys(now_ms);
        Self {
            component,
            name,
            labels,
            minute,
            hour,
            day,
            cur: Cell::default(),
            cur_hour: Cell::default(),
            cur_day: Cell::default(),
            minutes: Level::new(cfg.minute_slots),
            hours: Level::new(cfg.hour_slots),
            days: Level::new(cfg.day_slots),
        }
    }

    /// Close every bucket the clock has left. Safe to call as often as the host likes; a jump over
    /// idle minutes closes exactly the buckets that hold data.
    pub fn advance(&mut self, now_ms: u64) {
        let (minute, hour, day) = keys(now_ms);
        if minute != self.minute {
            if self.cur.observations > 0 {
                let cell = std::mem::take(&mut self.cur);
                self.minutes.push(self.minute, cell);
                self.cur_hour.merge(&cell);
                self.cur_day.merge(&cell);
            }
            self.minute = minute;
        }
        if hour != self.hour {
            if self.cur_hour.observations > 0 {
                let cell = std::mem::take(&mut self.cur_hour);
                self.hours.push(self.hour, cell);
            }
            self.hour = hour;
        }
        if day != self.day {
            if self.cur_day.observations > 0 {
                let cell = std::mem::take(&mut self.cur_day);
                self.days.push(self.day, cell);
            }
            self.day = day;
        }
    }

    pub fn record(&mut self, value: u64, last: i64, error: bool, now_ms: u64) {
        self.advance(now_ms);
        self.cur.observe(value, last, error);
    }
}

pub(crate) fn keys(now_ms: u64) -> (u32, u32, u32) {
    (
        (now_ms / MINUTE_MS).min(u32::MAX as u64) as u32,
        (now_ms / HOUR_MS).min(u32::MAX as u64) as u32,
        (now_ms / DAY_MS).min(u32::MAX as u64) as u32,
    )
}

/// One minute/hour/day bucket as an operator reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RollupPoint {
    pub key: u32,
    /// First millisecond of the bucket.
    pub start_ms: u64,
    pub observations: u64,
    pub errors: u64,
    pub sum: u64,
    pub min: u64,
    pub max: u64,
    pub last: i64,
}

impl RollupPoint {
    fn of(level: Level3, key: u32, cell: Cell) -> Self {
        let span = match level {
            Level3::Minute => MINUTE_MS,
            Level3::Hour => HOUR_MS,
            Level3::Day => DAY_MS,
        };
        Self {
            key,
            start_ms: key as u64 * span,
            observations: cell.observations as u64,
            errors: cell.errors as u64,
            sum: cell.sum,
            min: cell.min as u64,
            max: cell.max as u64,
            last: cell.last,
        }
    }

    /// Mean of the observations in the bucket, `None` when empty (never a fabricated zero).
    pub fn mean(&self) -> Option<f64> {
        if self.observations == 0 {
            None
        } else {
            Some(self.sum as f64 / self.observations as f64)
        }
    }
}

/// Everything the rollup store holds for one series.
#[derive(Clone, Debug)]
pub struct RollupSeriesView {
    pub component: String,
    pub name: String,
    pub labels: Labels,
    /// Finished minutes, oldest first, at most `Config::minute_slots`.
    pub minutes: Vec<RollupPoint>,
    /// Finished hours, oldest first, at most `Config::hour_slots`.
    pub hours: Vec<RollupPoint>,
    /// Finished days, oldest first, at most `Config::day_slots`.
    pub days: Vec<RollupPoint>,
    pub current: RollupPoint,
}

/// The bounded set of series that carry rollups, plus the count of series the cap refused.
#[derive(Clone, Debug)]
pub(crate) struct Rollups {
    series: Vec<RollupSeries>,
    index: BTreeMap<(Arc<str>, Arc<str>, Labels), usize>,
    max_series: usize,
    pub refused: u64,
}

impl Rollups {
    pub fn new(cfg: &Config) -> Self {
        Self {
            series: Vec::new(),
            index: BTreeMap::new(),
            max_series: cfg.rollup_series,
            refused: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.series.len()
    }

    pub fn refused(&self) -> u64 {
        self.refused
    }

    /// Start rolling up a series, or return `None` when the cap is already spent (counted).
    pub fn track(&mut self, component: &Arc<str>, name: &Arc<str>, labels: Labels, cfg: &Config, now_ms: u64) -> Option<usize> {
        let key = (component.clone(), name.clone(), labels.clone());
        if let Some(idx) = self.index.get(&key) {
            return Some(*idx);
        }
        if self.series.len() >= self.max_series {
            self.refused = self.refused.saturating_add(1);
            return None;
        }
        let idx = self.series.len();
        self.series
            .push(RollupSeries::new(component.clone(), name.clone(), labels, cfg, now_ms));
        self.index.insert(key, idx);
        Some(idx)
    }

    pub fn record(&mut self, idx: usize, value: u64, last: i64, error: bool, now_ms: u64) {
        if let Some(s) = self.series.get_mut(idx) {
            s.record(value, last, error, now_ms);
        }
    }

    pub fn advance_all(&mut self, now_ms: u64) {
        for s in &mut self.series {
            s.advance(now_ms);
        }
    }

    pub fn views(&self) -> Vec<RollupSeriesView> {
        self.series
            .iter()
            .map(|s| RollupSeriesView {
                component: s.component.to_string(),
                name: s.name.to_string(),
                labels: s.labels.clone(),
                minutes: s
                    .minutes
                    .iter()
                    .into_iter()
                    .map(|(k, c)| RollupPoint::of(Level3::Minute, k, c))
                    .collect(),
                hours: s
                    .hours
                    .iter()
                    .into_iter()
                    .map(|(k, c)| RollupPoint::of(Level3::Hour, k, c))
                    .collect(),
                days: s
                    .days
                    .iter()
                    .into_iter()
                    .map(|(k, c)| RollupPoint::of(Level3::Day, k, c))
                    .collect(),
                current: RollupPoint::of(Level3::Minute, s.minute, s.cur),
            })
            .collect()
    }

    /// Index of a tracked series by identity, for re-linking after a restore.
    pub(crate) fn lookup(&self, component: &Arc<str>, name: &Arc<str>, labels: &Labels) -> Option<usize> {
        self.index
            .get(&(component.clone(), name.clone(), labels.clone()))
            .copied()
    }

    pub(crate) fn set_refused(&mut self, refused: u64) {
        self.refused = refused;
    }

    pub(crate) fn raw(&self) -> &[RollupSeries] {
        &self.series
    }

    pub(crate) fn restore_series(&mut self, restored: Vec<RollupSeries>) {
        self.series.clear();
        self.index.clear();
        for s in restored {
            let idx = self.series.len();
            self.index
                .insert((s.component.clone(), s.name.clone(), s.labels.clone()), idx);
            self.series.push(s);
        }
        if self.series.len() > self.max_series {
            self.series.truncate(self.max_series);
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn cell_min_max_survive_merge_and_saturate() {
        let mut c = Cell::default();
        c.observe(10, 10, false);
        c.observe(u64::MAX, -3, true);
        assert_eq!(c.observations, 2);
        assert_eq!(c.errors, 1);
        assert_eq!(c.min, 10);
        assert_eq!(c.max, u32::MAX);
        assert_eq!(c.last, -3);
        let mut m = Cell::default();
        m.observe(5, 5, false);
        m.merge(&c);
        assert_eq!(m.observations, 3);
        assert_eq!(m.min, 5);
    }

    #[test]
    fn ring_keeps_the_newest_cap_keys() {
        let mut level = Level::new(2);
        for key in 0..4u32 {
            let mut c = Cell::default();
            c.observe(key as u64, key as i64, false);
            level.push(key, c);
        }
        let keys: Vec<u32> = level.iter().into_iter().map(|(k, _)| k).collect();
        assert_eq!(keys, vec![2, 3]);
    }
}
