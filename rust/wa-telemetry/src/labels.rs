//! Label sets: canonical, capped, and compared cheaply on the hot path.
//!
//! Cardinality is bounded in three places and all three are visible: pairs per series (`max_labels`),
//! label sets per family (`max_series_per_family`, overflow -> one `wa_other` series, counted), and
//! families per component. A component that invents a label value per message cannot grow the
//! registry: it overflows, and the overflow is a number an operator can read.
use crate::config::Config;

/// The single label set every overflowed series folds into.
pub const OTHER_LABEL: (&str, &str) = ("wa_other", "1");

/// Canonical label set: sorted by key, truncated to the caps, first duplicate key wins.
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Labels {
    pairs: Vec<(String, String)>,
}

impl Labels {
    pub fn empty() -> Self {
        Self { pairs: Vec::new() }
    }

    /// The overflow series. One per family, so a flood of bad label values costs one series.
    pub fn other() -> Self {
        Self {
            pairs: vec![(OTHER_LABEL.0.to_string(), OTHER_LABEL.1.to_string())],
        }
    }

    /// Rebuild from decoded pairs (snapshot restore). Trusted input: it was canonical when written.
    pub(crate) fn from_pairs(pairs: Vec<(String, String)>) -> Labels {
        Self { pairs }
    }

    pub fn is_other(&self) -> bool {
        self.pairs.len() == 1 && self.pairs[0].0 == OTHER_LABEL.0
    }

    pub fn len(&self) -> usize {
        self.pairs.len()
    }

    pub fn is_empty(&self) -> bool {
        self.pairs.is_empty()
    }

    pub fn pairs(&self) -> &[(String, String)] {
        &self.pairs
    }

    /// Canonical form of a caller's labels. Order does not matter, a duplicate key keeps the first,
    /// anything past the caps is cut.
    pub fn canonical(input: &[(&str, &str)], cfg: &Config) -> Labels {
        let mut pairs: Vec<(String, String)> = Vec::with_capacity(input.len().min(cfg.max_labels));
        for (k, v) in input.iter().take(cfg.max_labels) {
            let key = sanitize(k, cfg.max_label_key);
            if key.is_empty() || pairs.iter().any(|(have, _)| *have == key) {
                continue;
            }
            pairs.push((key, sanitize(v, cfg.max_label_value)));
        }
        pairs.sort_by(|a, b| a.0.cmp(&b.0));
        Self { pairs }
    }

    /// Does the stored set equal this caller's labels?
    ///
    /// The fast path is exact match on the raw literals, which is what a host call site passes
    /// (`&[("status", "ok")]`) and needs no allocation. Anything else is canonicalised once and
    /// compared, so order and truncation are irrelevant to identity.
    pub fn matches(&self, input: &[(&str, &str)], cfg: &Config) -> bool {
        if input.len() == self.pairs.len()
            && input
                .iter()
                .zip(self.pairs.iter())
                .all(|((k, v), (have_k, have_v))| k == have_k && v == have_v)
        {
            return true;
        }
        *self == Labels::canonical(input, cfg)
    }

    /// `k1=v1,k2=v2` — for diagnostics and JSON keys, never for identity.
    pub fn to_key_string(&self) -> String {
        if self.pairs.is_empty() {
            return String::new();
        }
        self.pairs
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join(",")
    }
}

/// A component name is a *label value*, not a metric name: it keeps its dashes and dots (an
/// operator looks for `wa-whatsapp`), and is only bounded in length.
pub fn truncate(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

/// Metric/label names: `[A-Za-z0-9_]`, truncated to `max` bytes. Truncation happens on a character
/// boundary so a name can never be invalid UTF-8.
pub fn sanitize(s: &str, max: usize) -> String {
    let mut out = String::with_capacity(s.len().min(max));
    let mut used = 0usize;
    for ch in s.chars() {
        let cost = ch.len_utf8();
        if used + cost > max {
            break;
        }
        used += cost;
        if ch.is_ascii_alphanumeric() || ch == '_' {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    out
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn canonical_ignores_order_and_cuts_to_caps() {
        let cfg = Config::for_tests();
        let a = Labels::canonical(&[("b", "2"), ("a", "1")], &cfg);
        let b = Labels::canonical(&[("a", "1"), ("b", "2")], &cfg);
        assert_eq!(a, b);
        let cut = Labels::canonical(&[("a", "1"), ("b", "2"), ("c", "3")], &cfg);
        assert_eq!(cut.len(), cfg.max_labels);
        assert!(cut.matches(&[("b", "2"), ("a", "1")], &cfg));
        assert!(cut.matches(&[("a", "1"), ("b", "2"), ("c", "3")], &cfg));
        assert!(!cut.matches(&[("a", "1"), ("b", "3")], &cfg));
        assert!(!cut.matches(&[("a", "1")], &cfg));
    }

    #[test]
    fn sanitize_keeps_names_printable_and_truncates_utf8_safely() {
        assert_eq!(sanitize("a b/c-d", 32), "a_b_c_d");
        assert_eq!(sanitize("abcdef", 3), "abc");
        assert_eq!(sanitize("aé", 3), "a_");
        assert_eq!(truncate("wa-whatsapp", 32), "wa-whatsapp");
        assert!(sanitize("não", 1).len() <= 1);
    }
}
