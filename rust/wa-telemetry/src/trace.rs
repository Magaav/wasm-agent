//! Spans and the sampling decision, kept in a byte-capped ring with oldest-first eviction.
//!
//! Keeping every span is what makes traces unaffordable on a node that runs for weeks, so the
//! sampler is biased on purpose: an error is always kept, a span slower than its op's threshold is
//! always kept, and normal spans are kept at 1–5% by a hash of their identity. The hash makes the
//! decision deterministic for a given span — replaying the same span gives the same answer — so a
//! sample rate is reproducible instead of "whatever rand did".
//!
//! The ring stores encoded blobs, not structs: the byte cap is then exact, eviction is a pop from
//! the front, and a span that arrives bigger than the whole ring is refused and counted.
use crate::config::Config;
use std::collections::VecDeque;
use std::sync::Arc;

/// Fixed cost of the encoded header; used nowhere but in the docs of `encoded_len`.
const SPAN_HEADER_BYTES: usize = 8 + 8 + 8 + 1 + 2 + 2 + 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpanStatus {
    Ok,
    /// The op returned a failure.
    Error,
    /// A queued item never ran (freshness window, TTL).
    Expired,
    /// The caller or the operator stopped it.
    Cancelled,
}

impl SpanStatus {
    pub fn is_error(self) -> bool {
        !matches!(self, SpanStatus::Ok)
    }
    pub fn as_str(self) -> &'static str {
        match self {
            SpanStatus::Ok => "ok",
            SpanStatus::Error => "error",
            SpanStatus::Expired => "expired",
            SpanStatus::Cancelled => "cancelled",
        }
    }
    fn code(self) -> u8 {
        match self {
            SpanStatus::Ok => 0,
            SpanStatus::Error => 1,
            SpanStatus::Expired => 2,
            SpanStatus::Cancelled => 3,
        }
    }
    fn from_code(c: u8) -> Option<Self> {
        Some(match c {
            0 => SpanStatus::Ok,
            1 => SpanStatus::Error,
            2 => SpanStatus::Expired,
            3 => SpanStatus::Cancelled,
            _ => return None,
        })
    }
}

/// One completed operation. `start_ms` is the wall clock at start, `duration_us` the measured span.
#[derive(Clone, Debug)]
pub struct Span {
    /// Deterministic identity; also the sampling seed. `0` means "assign one".
    pub trace_id: u64,
    pub component: Arc<str>,
    pub op: Arc<str>,
    pub start_ms: u64,
    pub duration_us: u64,
    pub status: SpanStatus,
    pub attrs: Vec<(String, String)>,
}

impl Span {
    pub fn new(component: impl Into<Arc<str>>, op: impl Into<Arc<str>>, start_ms: u64, duration_us: u64, status: SpanStatus) -> Self {
        Self {
            trace_id: 0,
            component: component.into(),
            op: op.into(),
            start_ms,
            duration_us,
            status,
            attrs: Vec::new(),
        }
    }

    pub fn attr(mut self, key: &str, value: &str) -> Self {
        self.attrs.push((key.to_string(), value.to_string()));
        self
    }

    pub fn with_trace_id(mut self, id: u64) -> Self {
        self.trace_id = id;
        self
    }

    /// Encode as a little-endian blob (the ring's storage form).
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.encoded_len());
        out.extend_from_slice(&self.trace_id.to_le_bytes());
        out.extend_from_slice(&self.start_ms.to_le_bytes());
        out.extend_from_slice(&self.duration_us.to_le_bytes());
        out.push(self.status.code());
        put_str16(&mut out, &self.component);
        put_str16(&mut out, &self.op);
        out.push(self.attrs.len().min(u8::MAX as usize) as u8);
        for (k, v) in self.attrs.iter().take(u8::MAX as usize) {
            put_str16(&mut out, k);
            put_str16(&mut out, v);
        }
        out
    }

    pub fn encoded_len(&self) -> usize {
        SPAN_HEADER_BYTES
            + self.component.len()
            + self.op.len()
            + self
                .attrs
                .iter()
                .take(u8::MAX as usize)
                .map(|(k, v)| 4 + k.len() + v.len())
                .sum::<usize>()
    }

    pub fn decode(blob: &[u8]) -> Option<Span> {
        let mut r = Reader { b: blob, pos: 0 };
        let trace_id = r.u64()?;
        let start_ms = r.u64()?;
        let duration_us = r.u64()?;
        let status = SpanStatus::from_code(r.u8()?)?;
        let component: Arc<str> = Arc::from(r.str16()?);
        let op: Arc<str> = Arc::from(r.str16()?);
        let n = r.u8()? as usize;
        let mut attrs = Vec::with_capacity(n.min(64));
        for _ in 0..n {
            let k = r.str16()?.to_string();
            let v = r.str16()?.to_string();
            attrs.push((k, v));
        }
        Some(Span {
            trace_id,
            component,
            op,
            start_ms,
            duration_us,
            status,
            attrs,
        })
    }
}

/// Why a span was kept, or that it was not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Keep {
    /// The op failed: always kept.
    Error,
    /// Slower than its op's threshold: always kept.
    Slow,
    /// Normal span that won the 1–5% hash draw.
    Sampled,
    /// Normal span that lost it.
    Dropped,
}

impl Keep {
    pub fn is_kept(self) -> bool {
        !matches!(self, Keep::Dropped)
    }
}

/// The sampling rules, fixed at construction so a node cannot drift between two call sites.
#[derive(Clone, Debug)]
pub struct Sampler {
    permille: u32,
    slow_us: u64,
    by_op: Vec<(String, u64)>,
}

impl Sampler {
    pub fn new(cfg: &Config) -> Self {
        Self {
            permille: cfg.trace_sample_permille.min(1000),
            slow_us: cfg.trace_slow_us,
            by_op: cfg
                .trace_slow_by_op
                .iter()
                .map(|(k, v)| (k.clone(), *v))
                .collect(),
        }
    }

    pub fn permille(&self) -> u32 {
        self.permille
    }

    pub fn slow_us(&self, component: &str, op: &str) -> u64 {
        let exact = format!("{component}/{op}");
        let any = format!("{component}/*");
        self.by_op
            .iter()
            .find(|(k, _)| *k == exact)
            .or_else(|| self.by_op.iter().find(|(k, _)| *k == any))
            .map(|(_, v)| *v)
            .unwrap_or(self.slow_us)
    }

    /// The rule, in order. An error is never sampled away: the spans worth reading are the ones
    /// that went wrong, and a trace store that misses them is decoration.
    pub fn decide(&self, span: &Span) -> Keep {
        if span.status.is_error() {
            return Keep::Error;
        }
        if span.duration_us > self.slow_us(&span.component, &span.op) {
            return Keep::Slow;
        }
        if self.permille == 0 {
            return Keep::Dropped;
        }
        if self.permille >= 1000 {
            return Keep::Sampled;
        }
        let h = sample_hash(&span.component, &span.op, span.trace_id);
        if (h % 1000) < self.permille as u64 {
            Keep::Sampled
        } else {
            Keep::Dropped
        }
    }
}

/// FNV-1a over the span identity: component, op and trace id. Stable across runs and platforms, so
/// "this span is in the sample" is a property of the span, not of the process.
pub fn sample_hash(component: &str, op: &str, trace_id: u64) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in component
        .as_bytes()
        .iter()
        .chain([0xffu8].iter())
        .chain(op.as_bytes().iter())
        .chain([0xffu8].iter())
        .chain(trace_id.to_le_bytes().iter())
    {
        h ^= *byte as u64;
        h = h.wrapping_mul(0x1000_0000_01b3);
    }
    h
}

/// Truncate attributes to the configured caps. Returns how many pairs were dropped and how many
/// values were truncated, so capping is a number and not a silent edit.
pub fn cap_attrs(attrs: &[(String, String)], cfg: &Config) -> (Vec<(String, String)>, u64, u64) {
    let mut out = Vec::with_capacity(attrs.len().min(cfg.max_span_attrs));
    let mut truncated = 0u64;
    for (k, v) in attrs.iter().take(cfg.max_span_attrs) {
        let key = crate::labels::sanitize(k, cfg.max_attr_key);
        let value = truncate_utf8(v, cfg.max_attr_value);
        if value.len() != v.len() {
            truncated += 1;
        }
        out.push((key, value));
    }
    let dropped = attrs.len().saturating_sub(cfg.max_span_attrs) as u64;
    (out, dropped, truncated)
}

fn truncate_utf8(s: &str, max: usize) -> String {
    if s.len() <= max {
        return s.to_string();
    }
    let mut end = max;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    s[..end].to_string()
}

/// The byte-capped span ring. Oldest-first eviction; nothing on disk.
#[derive(Clone, Debug)]
pub(crate) struct TraceStore {
    max_bytes: usize,
    bytes: usize,
    ring: VecDeque<Vec<u8>>,
    pub spans_kept: u64,
    pub spans_dropped_by_sampler: u64,
    pub spans_evicted: u64,
    pub spans_oversized: u64,
    pub attrs_dropped: u64,
    pub attrs_truncated: u64,
}

impl TraceStore {
    pub fn new(cfg: &Config) -> Self {
        Self {
            max_bytes: cfg.trace_bytes,
            bytes: 0,
            ring: VecDeque::new(),
            spans_kept: 0,
            spans_dropped_by_sampler: 0,
            spans_evicted: 0,
            spans_oversized: 0,
            attrs_dropped: 0,
            attrs_truncated: 0,
        }
    }

    pub fn max_bytes(&self) -> usize {
        self.max_bytes
    }
    pub fn bytes(&self) -> usize {
        self.bytes
    }
    pub fn len(&self) -> usize {
        self.ring.len()
    }

    /// Store a span that the sampler kept. Returns the reason it is present (or not).
    pub fn store(&mut self, span: &Span, cfg: &Config, decision: Keep) -> bool {
        if !decision.is_kept() {
            self.spans_dropped_by_sampler = self.spans_dropped_by_sampler.saturating_add(1);
            return false;
        }
        let (attrs, dropped, truncated) = cap_attrs(&span.attrs, cfg);
        self.attrs_dropped = self.attrs_dropped.saturating_add(dropped);
        self.attrs_truncated = self.attrs_truncated.saturating_add(truncated);
        let mut capped = span.clone();
        capped.attrs = attrs;
        let blob = capped.encode();
        if blob.len() > self.max_bytes {
            self.spans_oversized = self.spans_oversized.saturating_add(1);
            return false;
        }
        while self.bytes + blob.len() > self.max_bytes {
            match self.ring.pop_front() {
                Some(old) => {
                    self.bytes -= old.len();
                    self.spans_evicted = self.spans_evicted.saturating_add(1);
                }
                None => break,
            }
        }
        self.bytes += blob.len();
        self.ring.push_back(blob);
        self.spans_kept = self.spans_kept.saturating_add(1);
        true
    }

    pub fn iter(&self) -> impl Iterator<Item = Span> + '_ {
        self.ring.iter().filter_map(|b| Span::decode(b))
    }

    pub fn to_vec(&self) -> Vec<Span> {
        self.iter().collect()
    }

    pub(crate) fn raw(&self) -> &VecDeque<Vec<u8>> {
        &self.ring
    }

    pub(crate) fn restore(&mut self, blobs: Vec<Vec<u8>>) {
        self.ring.clear();
        self.bytes = 0;
        for b in blobs {
            if b.len() > self.max_bytes {
                self.spans_oversized = self.spans_oversized.saturating_add(1);
                continue;
            }
            while self.bytes + b.len() > self.max_bytes {
                match self.ring.pop_front() {
                    Some(old) => {
                        self.bytes -= old.len();
                        self.spans_evicted = self.spans_evicted.saturating_add(1);
                    }
                    None => break,
                }
            }
            self.bytes += b.len();
            self.ring.push_back(b);
        }
    }
}

fn put_str16(out: &mut Vec<u8>, s: &str) {
    let n = s.len().min(u16::MAX as usize);
    let mut end = n;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }
    out.extend_from_slice(&(end as u16).to_le_bytes());
    out.extend_from_slice(&s.as_bytes()[..end]);
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
    fn u8(&mut self) -> Option<u8> {
        Some(self.take(1)?[0])
    }
    fn u16(&mut self) -> Option<u16> {
        Some(u16::from_le_bytes(self.take(2)?.try_into().ok()?))
    }
    fn u64(&mut self) -> Option<u64> {
        Some(u64::from_le_bytes(self.take(8)?.try_into().ok()?))
    }
    fn str16(&mut self) -> Option<&'a str> {
        let n = self.u16()? as usize;
        std::str::from_utf8(self.take(n)?).ok()
    }
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn span_round_trips_through_its_encoding() {
        let span = Span::new("wa-whatsapp", "transcribe", 1_700_000_000_000, 34_500, SpanStatus::Error)
            .with_trace_id(99)
            .attr("lane", "audio")
            .attr("language", "pt");
        let blob = span.encode();
        assert_eq!(blob.len(), span.encoded_len());
        let back = Span::decode(&blob).expect("decodes");
        assert_eq!(back.trace_id, 99);
        assert_eq!(back.component.as_ref(), "wa-whatsapp");
        assert_eq!(back.op.as_ref(), "transcribe");
        assert_eq!(back.status, SpanStatus::Error);
        assert_eq!(back.attrs.len(), 2);
        assert_eq!(back.attrs[1], ("language".to_string(), "pt".to_string()));
        assert!(Span::decode(&blob[..blob.len() - 1]).is_none() || blob.len() < 4);
    }

    #[test]
    fn cap_attrs_truncates_and_counts() {
        let cfg = Config::for_tests();
        let attrs: Vec<(String, String)> = (0..cfg.max_span_attrs + 3)
            .map(|i| (format!("k{i}"), "x".repeat(cfg.max_attr_value + 5)))
            .collect();
        let (out, dropped, truncated) = cap_attrs(&attrs, &cfg);
        assert_eq!(out.len(), cfg.max_span_attrs);
        assert_eq!(dropped, 3);
        assert_eq!(truncated, cfg.max_span_attrs as u64);
        assert!(out[0].1.len() <= cfg.max_attr_value);
    }
}
