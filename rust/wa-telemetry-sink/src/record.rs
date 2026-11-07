//! The typed records the sink carries. No JSON inside: a record is a struct, and only the export
//! edge (`crate::jsonl`, `crate::otlp`) turns one into text.
//!
//! Two properties are structural rather than checked:
//!
//! 1. **A record has no message-text field.** There is nowhere to put a transcript, a prompt, a file
//!    path or an error body. Text can only arrive as an attribute *value*, and
//!    [`Attr::from_text`] reduces anything that is not already an id or a count to a digest, and
//!    anything secret-shaped to nothing at all.
//! 2. **A name is a name.** [`Id`] keeps `[A-Za-z0-9_.:/@*+#%-]` and replaces every other character
//!    with `_`, bounded to [`MAX_ID`] bytes. User data that a producer wrongly hands to `Id::new`
//!    arrives visibly mangled instead of verbatim — the mangle *is* the signal that it should have
//!    been a counter or a digest.

use crate::hash::{fnv1a128, fnv1a64};
use crate::redact;

/// Longest id kept; longer ids are truncated (a truncated name is still a name).
pub const MAX_ID: usize = 64;
/// Attribute pairs kept on one record. Beyond this the extra pair is dropped, never the record.
pub const MAX_ATTRS: usize = 8;
/// Longest attribute text considered as a value before it is digested.
pub const MAX_ATTR_TEXT: usize = 256;

/// A validated, bounded name: a component, an op, a topic, a label key. Never a message.
#[derive(Clone, PartialEq, Eq, PartialOrd, Ord, Debug, Hash)]
pub struct Id(Box<str>);

impl Id {
    pub fn new(raw: &str) -> Id {
        let mut text = String::with_capacity(raw.len().min(MAX_ID));
        for ch in raw.chars() {
            if text.len() >= MAX_ID {
                break;
            }
            let keep = ch.is_ascii_alphanumeric()
                || matches!(ch, '_' | '-' | '.' | ':' | '/' | '@' | '*' | '+' | '#' | '%');
            text.push(if keep { ch } else { '_' });
        }
        if text.is_empty() {
            text.push_str("unknown");
        }
        Id(text.into_boxed_str())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The wire form: an id that already satisfies the charset, refused rather than sanitised.
    /// [`crate::codec::decode`] uses this, so a frame cannot smuggle text in through an id field.
    pub fn from_wire(raw: &str) -> Option<Id> {
        if raw.is_empty() || raw.len() > MAX_ID {
            return None;
        }
        let clean = raw
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.' | ':' | '/' | '@' | '*' | '+' | '#' | '%'));
        if clean {
            Some(Id(raw.into()))
        } else {
            None
        }
    }

    /// True when the input survives `Id::new` unchanged: the producer passed a name, not user data.
    /// Call sites are expected to *count* a `false` (it means "this belongs in a digest").
    pub fn is_clean_name(raw: &str) -> bool {
        !raw.is_empty() && Id::new(raw).as_str() == raw
    }
}

impl std::fmt::Display for Id {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// Sixteen bytes, hex on the wire; the shape OTLP and the existing trace ring both use.
#[derive(Clone, Copy, PartialEq, Eq, Debug, Hash)]
pub struct TraceId([u8; 16]);

impl TraceId {
    pub fn from_bytes(bytes: [u8; 16]) -> TraceId {
        TraceId(bytes)
    }

    /// From 32 hex characters; anything else is not a trace id.
    pub fn parse_hex(raw: &str) -> Option<TraceId> {
        if raw.len() != 32 {
            return None;
        }
        let mut out = [0u8; 16];
        for (index, chunk) in raw.as_bytes().chunks(2).enumerate() {
            let text = std::str::from_utf8(chunk).ok()?;
            out[index] = u8::from_str_radix(text, 16).ok()?;
        }
        Some(TraceId(out))
    }

    /// A guest-supplied trace label (any text) becomes a stable id. Not reversible: only correlation.
    pub fn from_label(label: &str) -> TraceId {
        TraceId(fnv1a128(label.as_bytes()))
    }

    pub fn to_hex(self) -> String {
        let mut text = String::with_capacity(32);
        for byte in self.0 {
            text.push_str(&format!("{byte:02x}"));
        }
        text
    }

    pub fn bytes(self) -> [u8; 16] {
        self.0
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SpanStatus {
    Ok,
    Error,
    Expired,
    Cancelled,
}

impl SpanStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            SpanStatus::Ok => "ok",
            SpanStatus::Error => "error",
            SpanStatus::Expired => "expired",
            SpanStatus::Cancelled => "cancelled",
        }
    }

    /// The closed set a protocol status an operator (or a collector) queries by.
    pub fn from_code(code: u8) -> Option<SpanStatus> {
        Some(match code {
            0 => SpanStatus::Ok,
            1 => SpanStatus::Error,
            2 => SpanStatus::Expired,
            3 => SpanStatus::Cancelled,
            _ => return None,
        })
    }

    pub fn code(self) -> u8 {
        match self {
            SpanStatus::Ok => 0,
            SpanStatus::Error => 1,
            SpanStatus::Expired => 2,
            SpanStatus::Cancelled => 3,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Severity {
    Trace,
    Debug,
    Info,
    Warn,
    Error,
    Critical,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Severity::Trace => "trace",
            Severity::Debug => "debug",
            Severity::Info => "info",
            Severity::Warn => "warn",
            Severity::Error => "error",
            Severity::Critical => "critical",
        }
    }

    /// OTLP's fixed severity numbers (logs data model).
    pub fn otlp_number(self) -> u8 {
        match self {
            Severity::Trace => 1,
            Severity::Debug => 5,
            Severity::Info => 9,
            Severity::Warn => 13,
            Severity::Error => 17,
            Severity::Critical => 21,
        }
    }

    pub fn from_code(code: u8) -> Option<Severity> {
        Some(match code {
            0 => Severity::Trace,
            1 => Severity::Debug,
            2 => Severity::Info,
            3 => Severity::Warn,
            4 => Severity::Error,
            5 => Severity::Critical,
            _ => return None,
        })
    }

    pub fn code(self) -> u8 {
        match self {
            Severity::Trace => 0,
            Severity::Debug => 1,
            Severity::Info => 2,
            Severity::Warn => 3,
            Severity::Error => 4,
            Severity::Critical => 5,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MetricKind {
    Counter,
    Gauge,
}

impl MetricKind {
    pub fn as_str(self) -> &'static str {
        match self {
            MetricKind::Counter => "counter",
            MetricKind::Gauge => "gauge",
        }
    }

    pub fn code(self) -> u8 {
        match self {
            MetricKind::Counter => 0,
            MetricKind::Gauge => 1,
        }
    }

    pub fn from_code(code: u8) -> Option<MetricKind> {
        Some(match code {
            0 => MetricKind::Counter,
            1 => MetricKind::Gauge,
            _ => return None,
        })
    }
}

/// The unit a metric value is in. A closed set, for the same reason a label is.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Unit {
    Count,
    Micros,
    Millis,
    Bytes,
    Ratio,
}

impl Unit {
    pub fn as_str(self) -> &'static str {
        match self {
            Unit::Count => "1",
            Unit::Micros => "us",
            Unit::Millis => "ms",
            Unit::Bytes => "By",
            Unit::Ratio => "1",
        }
    }

    pub fn otlp_name(self) -> &'static str {
        match self {
            Unit::Count | Unit::Ratio => "1",
            Unit::Micros => "us",
            Unit::Millis => "ms",
            Unit::Bytes => "By",
        }
    }

    pub fn code(self) -> u8 {
        match self {
            Unit::Count => 0,
            Unit::Micros => 1,
            Unit::Millis => 2,
            Unit::Bytes => 3,
            Unit::Ratio => 4,
        }
    }

    pub fn from_code(code: u8) -> Option<Unit> {
        Some(match code {
            0 => Unit::Count,
            1 => Unit::Micros,
            2 => Unit::Millis,
            3 => Unit::Bytes,
            4 => Unit::Ratio,
            _ => return None,
        })
    }
}

/// One attribute value. `Id` and `Count` are the only shapes a producer can state; the rest are what
/// the sink does with text it was handed and must not export.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum AttrValue {
    Id(Id),
    Count(u64),
    /// A value that is not a name and not a count: its byte length and a fingerprint, never the text.
    Digest { len: u32, hash: u64 },
    /// Secret-shaped: dropped with no digest (a digest of a secret would be an oracle).
    Redacted,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Attr {
    pub key: Id,
    pub value: AttrValue,
}

impl Attr {
    pub fn id(key: &str, value: &str) -> Attr {
        Attr { key: Id::new(key), value: AttrValue::Id(Id::new(value)) }
    }

    pub fn count(key: &str, value: u64) -> Attr {
        Attr { key: Id::new(key), value: AttrValue::Count(value) }
    }

    /// The redaction boundary for text: an id-shaped value stays an id, a number becomes a count and
    /// everything else becomes a digest — except a value that is secret-shaped, which leaves nothing.
    ///
    /// This is a *producer-side* function (the host builds records, the sink buffers them): it runs the
    /// redaction pass and allocates. [`crate::sink::Sink::record`] never calls it, so no producer pays
    /// for it twice.
    pub fn from_text(key: &str, raw: &str) -> Attr {
        let key = Id::new(key);
        if redact::is_secret_like(raw) || redact::text(raw) != raw {
            return Attr { key, value: AttrValue::Redacted };
        }
        if let Ok(value) = raw.parse::<u64>() {
            return Attr { key, value: AttrValue::Count(value) };
        }
        if raw.len() <= MAX_ID && raw.chars().all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '.' | ':' | '/' | '@' | '*')) {
            return Attr { key, value: AttrValue::Id(Id::new(raw)) };
        }
        let capped: String = raw.chars().take(MAX_ATTR_TEXT).collect();
        Attr { key, value: AttrValue::Digest { len: capped.len() as u32, hash: fnv1a64(capped.as_bytes()) } }
    }

    /// JSONL rendering: a string for a name, an integer for a count, and `{"len":…,"digest":…}` for
    /// text that was reduced. `Redacted` renders as the string `<redacted>`.
    pub fn value_json(&self) -> String {
        match &self.value {
            AttrValue::Id(id) => format!("\"{}\"", crate::json::escape(id.as_str())),
            AttrValue::Count(value) => value.to_string(),
            AttrValue::Digest { len, hash } => format!("{{\"len\":{len},\"digest\":\"{hash:016x}\"}}"),
            AttrValue::Redacted => "\"<redacted>\"".to_string(),
        }
    }

    /// OTLP attributes: the same three shapes as a string/bool/int `AnyValue`.
    pub fn otlp_json(&self) -> String {
        match &self.value {
            AttrValue::Id(id) => format!(
                "{{\"key\":\"{}\",\"value\":{{\"stringValue\":\"{}\"}}}}",
                crate::json::escape(self.key.as_str()),
                crate::json::escape(id.as_str())
            ),
            AttrValue::Count(value) => format!(
                "{{\"key\":\"{}\",\"value\":{{\"intValue\":\"{}\"}}}}",
                crate::json::escape(self.key.as_str()),
                value
            ),
            AttrValue::Digest { len, hash } => format!(
                "{{\"key\":\"{}\",\"value\":{{\"stringValue\":\"digest:{hash:016x}:{len}\"}}}}",
                crate::json::escape(self.key.as_str())
            ),
            AttrValue::Redacted => format!(
                "{{\"key\":\"{}\",\"value\":{{\"stringValue\":\"<redacted>\"}}}}",
                crate::json::escape(self.key.as_str())
            ),
        }
    }
}

/// The attributes of one record: capped, unique by key (the first wins), sorted by key so the same
/// record always encodes to the same bytes.
#[derive(Clone, Default, PartialEq, Eq, Debug)]
pub struct Attrs(Vec<Attr>);

impl Attrs {
    pub fn new() -> Attrs {
        Attrs(Vec::new())
    }

    pub fn from(pairs: Vec<Attr>) -> Attrs {
        let mut attrs = Attrs::new();
        for pair in pairs {
            attrs.push(pair);
        }
        attrs
    }

    /// Keep `attr` unless the record is at [`MAX_ATTRS`] or already has that key. Returns whether it
    /// was kept, so a producer can count the loss instead of assuming it.
    pub fn push(&mut self, attr: Attr) -> bool {
        if self.0.len() >= MAX_ATTRS || self.0.iter().any(|existing| existing.key == attr.key) {
            return false;
        }
        self.0.push(attr);
        self.0.sort_by(|a, b| a.key.cmp(&b.key));
        true
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn iter(&self) -> impl Iterator<Item = &Attr> {
        self.0.iter()
    }

    pub fn get(&self, key: &str) -> Option<&AttrValue> {
        self.0.iter().find(|attr| attr.key.as_str() == key).map(|attr| &attr.value)
    }
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct SpanRecord {
    pub component: Id,
    pub op: Id,
    pub start_ms: u64,
    pub duration_us: u64,
    pub status: SpanStatus,
    pub trace: Option<TraceId>,
    pub attrs: Attrs,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct MetricRecord {
    pub component: Id,
    pub name: Id,
    pub kind: MetricKind,
    pub unit: Unit,
    pub value: u64,
    pub labels: Attrs,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct EventRecord {
    pub topic: Id,
    pub source: Id,
    pub schema: Id,
    pub schema_version: u32,
    pub ts_ms: u64,
    /// How many facts this record stands for: a batched count is a count, never a repeated row.
    pub count: u64,
    pub severity: Severity,
    pub trace: Option<TraceId>,
    pub attrs: Attrs,
}

/// One item on the sink's wire: a fact the node already decided is worth exporting.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Record {
    Span(SpanRecord),
    Metric(MetricRecord),
    Event(EventRecord),
}

impl Record {
    pub fn span(component: &str, op: &str, start_ms: u64, duration_us: u64, status: SpanStatus) -> Record {
        Record::Span(SpanRecord {
            component: Id::new(component),
            op: Id::new(op),
            start_ms,
            duration_us,
            status,
            trace: None,
            attrs: Attrs::new(),
        })
    }

    pub fn event(topic: &str, source: &str, schema: &str, ts_ms: u64) -> Record {
        Record::Event(EventRecord {
            topic: Id::new(topic),
            source: Id::new(source),
            schema: Id::new(schema),
            schema_version: 1,
            ts_ms,
            count: 1,
            severity: Severity::Info,
            trace: None,
            attrs: Attrs::new(),
        })
    }

    pub fn metric(component: &str, name: &str, kind: MetricKind, unit: Unit, value: u64) -> Record {
        Record::Metric(MetricRecord {
            component: Id::new(component),
            name: Id::new(name),
            kind,
            unit,
            value,
            labels: Attrs::new(),
        })
    }

    pub fn kind_str(&self) -> &'static str {
        match self {
            Record::Span(_) => "span",
            Record::Metric(_) => "metric",
            Record::Event(_) => "event",
        }
    }

    pub fn attrs(&self) -> &Attrs {
        match self {
            Record::Span(span) => &span.attrs,
            Record::Metric(metric) => &metric.labels,
            Record::Event(event) => &event.attrs,
        }
    }

    pub fn trace(&self) -> Option<TraceId> {
        match self {
            Record::Span(span) => span.trace,
            Record::Metric(_) => None,
            Record::Event(event) => event.trace,
        }
    }

    /// Wall-clock stamp the record is filed under (JSONL filename rotation and OTLP time).
    pub fn ts_ms(&self) -> u64 {
        match self {
            Record::Span(span) => span.start_ms,
            Record::Metric(_) => 0,
            Record::Event(event) => event.ts_ms,
        }
    }

    /// Exact byte length of `encode(&[record])` minus its header. Used for the buffer's byte bound,
    /// so the bound is the encoded size and not a guess; `codec`'s tests assert the two agree.
    pub fn encoded_len(&self) -> usize {
        match self {
            Record::Span(span) => {
                1 + id_len(&span.component)
                    + id_len(&span.op)
                    + 8
                    + 8
                    + 1
                    + trace_len(span.trace)
                    + attrs_len(&span.attrs)
            }
            Record::Metric(metric) => {
                1 + id_len(&metric.component) + id_len(&metric.name) + 1 + 1 + 8 + attrs_len(&metric.labels)
            }
            Record::Event(event) => {
                1 + id_len(&event.topic)
                    + id_len(&event.source)
                    + id_len(&event.schema)
                    + 4
                    + 8
                    + 8
                    + 1
                    + trace_len(event.trace)
                    + attrs_len(&event.attrs)
            }
        }
    }
}

fn id_len(id: &Id) -> usize {
    2 + id.as_str().len()
}

fn trace_len(trace: Option<TraceId>) -> usize {
    if trace.is_some() {
        1 + 16
    } else {
        1
    }
}

fn attrs_len(attrs: &Attrs) -> usize {
    let mut total = 1;
    for attr in attrs.iter() {
        total += id_len(&attr.key);
        total += 1;
        total += match &attr.value {
            AttrValue::Id(id) => id_len(id),
            AttrValue::Count(_) => 8,
            AttrValue::Digest { .. } => 4 + 8,
            AttrValue::Redacted => 0,
        };
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn id_keeps_names_and_mangles_text() {
        assert_eq!(Id::new("wa-whatsapp"), Id::new("wa-whatsapp").clone());
        assert_eq!(Id::new("wa:kernel/kv.set").as_str(), "wa:kernel/kv.set");
        let mangled = Id::new("hello, can you read this for me?");
        assert!(!mangled.as_str().contains(' '), "{}", mangled.as_str());
        assert!(mangled.as_str().is_ascii());
        let long = "x".repeat(200);
        assert_eq!(Id::new(&long).as_str().len(), MAX_ID);
        assert_eq!(Id::new("").as_str(), "unknown");
        assert_eq!(Id::new("тест").as_str(), "____");
    }

    #[test]
    fn trace_ids_round_trip_and_hash_labels() {
        let hex = "4bf92f3577b34da6a3ce929d0e0e4736";
        let trace = TraceId::parse_hex(hex).expect("hex");
        assert_eq!(trace.to_hex(), hex);
        assert!(TraceId::parse_hex("not-a-trace").is_none());
        assert_ne!(TraceId::from_label("trace-a"), TraceId::from_label("trace-b"));
        assert_eq!(TraceId::from_label("trace-a"), TraceId::from_label("trace-a"));
    }

    #[test]
    fn attrs_cap_unique_sort_and_reduce_text() {
        let mut attrs = Attrs::new();
        assert!(attrs.push(Attr::id("status", "ok")));
        assert!(!attrs.push(Attr::id("status", "error")), "first key wins");
        for index in 0..MAX_ATTRS {
            attrs.push(Attr::count(&format!("k{index}"), index as u64));
        }
        assert_eq!(attrs.len(), MAX_ATTRS);
        assert!(!attrs.push(Attr::count("overflow", 1)));
        let keys: Vec<&str> = attrs.iter().map(|attr| attr.key.as_str()).collect();
        let mut sorted = keys.clone();
        sorted.sort();
        assert_eq!(keys, sorted);
    }

    #[test]
    fn attribute_text_never_leaves_as_text() {
        let digest = Attr::from_text("reason", "the user asked about their bank statement");
        assert!(matches!(digest.value, AttrValue::Digest { .. }));
        assert!(!digest.value_json().contains("bank"));
        let count = Attr::from_text("attempts", "3");
        assert_eq!(count.value, AttrValue::Count(3));
        let id = Attr::from_text("status", "ok");
        assert_eq!(id.value, AttrValue::Id(Id::new("ok")));
        let secret = Attr::from_text("auth", "sk-abcdefghijklmnop7f2a");
        assert_eq!(secret.value, AttrValue::Redacted, "no digest for a secret");
        assert!(!secret.value_json().contains("sk-"));
    }

    #[test]
    fn encoded_len_matches_the_codec() {
        let mut span = SpanRecord {
            component: Id::new("wa-whatsapp"),
            op: Id::new("transcribe"),
            start_ms: 1,
            duration_us: 2,
            status: SpanStatus::Error,
            trace: Some(TraceId::from_label("t")),
            attrs: Attrs::from(vec![Attr::id("status", "error"), Attr::from_text("note", "not a name")]),
        };
        span.attrs.push(Attr::count("attempts", 2));
        let records = vec![
            Record::Span(span),
            Record::metric("wa-host", "op_total", MetricKind::Counter, Unit::Count, 7),
            Record::event("whatsapp.transcript.ready", "wa-whatsapp", "wa.event", 99),
        ];
        let encoded = crate::codec::encode(&records).expect("encode");
        let header = crate::codec::HEADER_BYTES;
        let sum: usize = records.iter().map(Record::encoded_len).sum();
        assert_eq!(encoded.len(), header + sum);
    }
}
