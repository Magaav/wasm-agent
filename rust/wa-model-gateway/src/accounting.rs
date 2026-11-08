//! Accounting: what every call cost, per session/model/class (`docs/MODEL-GATEWAY.md`, "Accounting").
//!
//! One record per call (no message text, ever: a session id, a model, a class, a label and numbers) plus
//! per-key totals. The kernel ships the records to telemetry; the totals are what `wa models` prints and
//! what a budget review reads.

use std::collections::BTreeMap;

use crate::types::{Label, TaskClass, Usage};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Accounted {
    pub session: String,
    pub provider: String,
    pub model: String,
    pub class: TaskClass,
    pub label: Label,
    pub usage: Usage,
    pub cost_micros: u64,
    pub cache_hit: bool,
    pub latency_ms: u64,
}

/// Per session/model/class: the totals the operator reads.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Totals {
    pub calls: u64,
    pub usage: Usage,
    pub cost_micros: u64,
    pub cache_hits: u64,
}

#[derive(Clone, Debug, Default)]
pub struct Accounting {
    entries: Vec<Accounted>,
    totals: BTreeMap<(String, String, TaskClass), Totals>,
    dropped: u64,
}

/// How many call records this instance keeps before it starts counting what it dropped. The kernel
/// drains them (`accounting`) and the guest's memory is bounded by its manifest; a record that cannot be
/// kept is counted, never silently lost.
pub const MAX_ENTRIES: usize = 4096;

impl Accounting {
    pub fn record(&mut self, entry: Accounted) {
        let key = (entry.session.clone(), entry.model.clone(), entry.class);
        let totals = self.totals.entry(key).or_default();
        totals.calls += 1;
        totals.usage.merge(entry.usage);
        totals.cost_micros += entry.cost_micros;
        if entry.cache_hit {
            totals.cache_hits += 1;
        }
        if self.entries.len() < MAX_ENTRIES {
            self.entries.push(entry);
        } else {
            self.dropped += 1;
        }
    }

    pub fn entries(&self) -> &[Accounted] {
        &self.entries
    }

    pub fn dropped(&self) -> u64 {
        self.dropped
    }

    pub fn totals(&self) -> Vec<((String, String, TaskClass), Totals)> {
        self.totals.iter().map(|(key, value)| (key.clone(), value.clone())).collect()
    }

    /// Totals for one key, for a test or an operator's question.
    pub fn total_for(&self, session: &str, model: &str, class: TaskClass) -> Option<&Totals> {
        self.totals.get(&(session.to_string(), model.to_string(), class))
    }

    pub fn reset(&mut self) {
        self.entries.clear();
        self.totals.clear();
        self.dropped = 0;
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty() && self.totals.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(model: &str, usage: Usage) -> Accounted {
        Accounted {
            session: "s1".into(),
            provider: "deepseek".into(),
            model: model.into(),
            class: TaskClass::Default,
            label: Label::Internal,
            usage,
            cost_micros: 7,
            cache_hit: usage.cache_read_tokens > 0,
            latency_ms: 42,
        }
    }

    #[test]
    fn totals_add_up_per_session_model_and_class() {
        let mut accounting = Accounting::default();
        accounting.record(entry("m", Usage { input_tokens: 10, cache_read_tokens: 5, ..Usage::default() }));
        accounting.record(entry("m", Usage { input_tokens: 20, output_tokens: 3, ..Usage::default() }));
        let totals = accounting.total_for("s1", "m", TaskClass::Default).expect("totals");
        assert_eq!(totals.calls, 2);
        assert_eq!(totals.usage.input_tokens, 30);
        assert_eq!(totals.usage.output_tokens, 3);
        assert_eq!(totals.usage.cache_read_tokens, 5);
        assert_eq!(totals.cost_micros, 14);
        assert_eq!(totals.cache_hits, 1);
        assert!(accounting.total_for("s2", "m", TaskClass::Default).is_none());
    }

    #[test]
    fn the_record_list_is_bounded_and_counts_what_it_dropped() {
        let mut accounting = Accounting::default();
        let usage = Usage { input_tokens: 1, ..Usage::default() };
        for _ in 0..(MAX_ENTRIES + 3) {
            accounting.record(entry("m", usage));
        }
        assert_eq!(accounting.len(), MAX_ENTRIES);
        assert_eq!(accounting.dropped(), 3);
        // The totals still saw every call, which is what a budget reads.
        assert_eq!(accounting.total_for("s1", "m", TaskClass::Default).expect("totals").calls, (MAX_ENTRIES + 3) as u64);
    }

    #[test]
    fn a_reset_clears_records_and_totals() {
        let mut accounting = Accounting::default();
        accounting.record(entry("m", Usage::default()));
        accounting.reset();
        assert!(accounting.is_empty());
        assert!(accounting.totals().is_empty());
    }
}
