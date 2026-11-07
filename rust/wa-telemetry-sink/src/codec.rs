//! The wire between a producer (or the sink component) and the sink: fixed little-endian fields,
//! length-prefixed ids, no JSON.
//!
//! Same reasoning as `wa-telemetry/src/snapshot.rs`: a hand-written layout has deterministic bytes,
//! no derive macro, no format churn, and no second JSON dialect on the bus. The transport is opaque
//! (`list<u8>` in `wa:bus`, `list<u8>` in `wa:telemetry/sink`), so the format is ours to state and
//! ours to bound.
//!
//! Every decoder input is hostile: bounds are checked before allocation, utf-8 is validated, ids
//! longer than [`MAX_ID`] are refused rather than truncated, and trailing bytes are an error (a frame
//! with a hidden second payload is a bug or an attack, never something to ignore).

use crate::record::{
    Attr, AttrValue, Attrs, EventRecord, Id, MetricKind, MetricRecord, Record, Severity, SpanRecord,
    SpanStatus, TraceId, Unit, MAX_ATTRS, MAX_ID,
};

pub const MAGIC: [u8; 4] = *b"WTS1";
/// magic + record count.
pub const HEADER_BYTES: usize = 6;
/// Records in one frame. A batch is bounded by the producer's flush policy; this is the hard ceiling.
pub const MAX_RECORDS: usize = 4096;
/// Bytes in one frame, checked before allocation.
pub const MAX_FRAME_BYTES: usize = 1 << 20;

const TAG_SPAN: u8 = 1;
const TAG_METRIC: u8 = 2;
const TAG_EVENT: u8 = 3;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CodecError {
    /// Not a sink frame.
    BadMagic,
    /// The frame ended before the record did.
    Truncated,
    /// More records than [`MAX_RECORDS`], or a count that does not match what followed.
    BadCount,
    /// The frame is bigger than [`MAX_FRAME_BYTES`].
    TooLarge,
    /// Bytes after the last record.
    TrailingBytes,
    /// An id was not utf-8.
    BadUtf8,
    /// An id longer than [`MAX_ID`], or more than [`MAX_ATTRS`] attributes.
    BadBound,
    /// An id that is not a name (the wire carries names only, never text).
    BadName,
    /// A tag, status, severity, metric kind or unit outside its closed set.
    BadDiscriminant,
}

impl std::fmt::Display for CodecError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let text = match self {
            CodecError::BadMagic => "bad_magic",
            CodecError::Truncated => "truncated",
            CodecError::BadCount => "bad_count",
            CodecError::TooLarge => "too_large",
            CodecError::TrailingBytes => "trailing_bytes",
            CodecError::BadUtf8 => "bad_utf8",
            CodecError::BadBound => "bad_bound",
            CodecError::BadName => "bad_name",
            CodecError::BadDiscriminant => "bad_discriminant",
        };
        f.write_str(text)
    }
}

impl std::error::Error for CodecError {}

/// Encode a batch. Refuses a batch [`decode`] would refuse instead of writing a frame whose count is a
/// lie: a producer with more records chunks them (the component splits at its `max_batch`).
pub fn encode(records: &[Record]) -> Result<Vec<u8>, CodecError> {
    if records.len() > MAX_RECORDS {
        return Err(CodecError::BadCount);
    }
    let bytes: usize = records.iter().map(Record::encoded_len).sum();
    if HEADER_BYTES + bytes > MAX_FRAME_BYTES {
        return Err(CodecError::TooLarge);
    }
    let mut out = Vec::with_capacity(HEADER_BYTES + bytes);
    out.extend_from_slice(&MAGIC);
    put_u16(&mut out, records.len() as u16);
    for record in records {
        put_record(&mut out, record);
    }
    Ok(out)
}

fn put_record(out: &mut Vec<u8>, record: &Record) {
    match record {
        Record::Span(span) => {
            out.push(TAG_SPAN);
            put_id(out, &span.component);
            put_id(out, &span.op);
            put_u64(out, span.start_ms);
            put_u64(out, span.duration_us);
            out.push(span.status.code());
            put_trace(out, span.trace);
            put_attrs(out, &span.attrs);
        }
        Record::Metric(metric) => {
            out.push(TAG_METRIC);
            put_id(out, &metric.component);
            put_id(out, &metric.name);
            out.push(metric.kind.code());
            out.push(metric.unit.code());
            put_u64(out, metric.value);
            put_attrs(out, &metric.labels);
        }
        Record::Event(event) => {
            out.push(TAG_EVENT);
            put_id(out, &event.topic);
            put_id(out, &event.source);
            put_id(out, &event.schema);
            put_u32(out, event.schema_version);
            put_u64(out, event.ts_ms);
            put_u64(out, event.count);
            out.push(event.severity.code());
            put_trace(out, event.trace);
            put_attrs(out, &event.attrs);
        }
    }
}

fn put_id(out: &mut Vec<u8>, id: &Id) {
    let bytes = id.as_str().as_bytes();
    put_u16(out, bytes.len() as u16);
    out.extend_from_slice(bytes);
}

fn put_trace(out: &mut Vec<u8>, trace: Option<TraceId>) {
    match trace {
        Some(trace) => {
            out.push(1);
            out.extend_from_slice(&trace.bytes());
        }
        None => out.push(0),
    }
}

fn put_attrs(out: &mut Vec<u8>, attrs: &Attrs) {
    out.push(attrs.len() as u8);
    for attr in attrs.iter() {
        put_id(out, &attr.key);
        match &attr.value {
            AttrValue::Id(id) => {
                out.push(0);
                put_id(out, id);
            }
            AttrValue::Count(value) => {
                out.push(1);
                put_u64(out, *value);
            }
            AttrValue::Digest { len, hash } => {
                out.push(2);
                put_u32(out, *len);
                put_u64(out, *hash);
            }
            AttrValue::Redacted => out.push(3),
        }
    }
}

fn put_u16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn put_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}

fn put_u64(out: &mut Vec<u8>, value: u64) {
    out.extend_from_slice(&value.to_le_bytes());
}

/// Decode a batch, refusing anything the encoder could not have produced.
pub fn decode(frame: &[u8]) -> Result<Vec<Record>, CodecError> {
    if frame.len() > MAX_FRAME_BYTES {
        return Err(CodecError::TooLarge);
    }
    if frame.len() < HEADER_BYTES || frame[..4] != MAGIC {
        return Err(if frame.len() < HEADER_BYTES { CodecError::Truncated } else { CodecError::BadMagic });
    }
    let count = u16::from_le_bytes([frame[4], frame[5]]) as usize;
    if count > MAX_RECORDS {
        return Err(CodecError::BadCount);
    }
    let mut reader = Reader { bytes: frame, at: HEADER_BYTES };
    let mut records = Vec::with_capacity(count.min(64));
    for _ in 0..count {
        records.push(reader.record()?);
    }
    if reader.at != frame.len() {
        return Err(CodecError::TrailingBytes);
    }
    Ok(records)
}

struct Reader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl<'a> Reader<'a> {
    fn u8(&mut self) -> Result<u8, CodecError> {
        let byte = *self.bytes.get(self.at).ok_or(CodecError::Truncated)?;
        self.at += 1;
        Ok(byte)
    }

    fn u16(&mut self) -> Result<u16, CodecError> {
        let bytes = self.take(2)?;
        Ok(u16::from_le_bytes([bytes[0], bytes[1]]))
    }

    fn u32(&mut self) -> Result<u32, CodecError> {
        let bytes = self.take(4)?;
        Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn u64(&mut self) -> Result<u64, CodecError> {
        let bytes = self.take(8)?;
        let mut array = [0u8; 8];
        array.copy_from_slice(bytes);
        Ok(u64::from_le_bytes(array))
    }

    fn take(&mut self, len: usize) -> Result<&'a [u8], CodecError> {
        let end = self.at.checked_add(len).ok_or(CodecError::Truncated)?;
        let slice = self.bytes.get(self.at..end).ok_or(CodecError::Truncated)?;
        self.at = end;
        Ok(slice)
    }

    fn id(&mut self) -> Result<Id, CodecError> {
        let len = self.u16()? as usize;
        if len > MAX_ID {
            return Err(CodecError::BadBound);
        }
        let bytes = self.take(len)?;
        let text = std::str::from_utf8(bytes).map_err(|_| CodecError::BadUtf8)?;
        Id::from_wire(text).ok_or(CodecError::BadName)
    }

    fn trace(&mut self) -> Result<Option<TraceId>, CodecError> {
        match self.u8()? {
            0 => Ok(None),
            1 => {
                let bytes = self.take(16)?;
                let mut array = [0u8; 16];
                array.copy_from_slice(bytes);
                Ok(Some(TraceId::from_bytes(array)))
            }
            _ => Err(CodecError::BadDiscriminant),
        }
    }

    fn attrs(&mut self) -> Result<Attrs, CodecError> {
        let count = self.u8()? as usize;
        if count > MAX_ATTRS {
            return Err(CodecError::BadBound);
        }
        let mut attrs = Attrs::new();
        for _ in 0..count {
            let key = self.id()?;
            let value = match self.u8()? {
                0 => AttrValue::Id(self.id()?),
                1 => AttrValue::Count(self.u64()?),
                2 => AttrValue::Digest { len: self.u32()?, hash: self.u64()? },
                3 => AttrValue::Redacted,
                _ => return Err(CodecError::BadDiscriminant),
            };
            // Duplicate keys cannot come from `Attrs::push`; a frame that has them is refused rather
            // than quietly keeping the first.
            if !attrs.push(Attr { key, value }) {
                return Err(CodecError::BadBound);
            }
        }
        Ok(attrs)
    }

    fn record(&mut self) -> Result<Record, CodecError> {
        match self.u8()? {
            TAG_SPAN => Ok(Record::Span(SpanRecord {
                component: self.id()?,
                op: self.id()?,
                start_ms: self.u64()?,
                duration_us: self.u64()?,
                status: SpanStatus::from_code(self.u8()?).ok_or(CodecError::BadDiscriminant)?,
                trace: self.trace()?,
                attrs: self.attrs()?,
            })),
            TAG_METRIC => Ok(Record::Metric(MetricRecord {
                component: self.id()?,
                name: self.id()?,
                kind: MetricKind::from_code(self.u8()?).ok_or(CodecError::BadDiscriminant)?,
                unit: Unit::from_code(self.u8()?).ok_or(CodecError::BadDiscriminant)?,
                value: self.u64()?,
                labels: self.attrs()?,
            })),
            TAG_EVENT => Ok(Record::Event(EventRecord {
                topic: self.id()?,
                source: self.id()?,
                schema: self.id()?,
                schema_version: self.u32()?,
                ts_ms: self.u64()?,
                count: self.u64()?,
                severity: Severity::from_code(self.u8()?).ok_or(CodecError::BadDiscriminant)?,
                trace: self.trace()?,
                attrs: self.attrs()?,
            })),
            _ => Err(CodecError::BadDiscriminant),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::record::Attr;

    fn sample() -> Vec<Record> {
        let mut span = SpanRecord {
            component: Id::new("wa-host"),
            op: Id::new("lib.component.run"),
            start_ms: 1_700_000_000_123,
            duration_us: 42,
            status: SpanStatus::Error,
            trace: Some(TraceId::parse_hex("4bf92f3577b34da6a3ce929d0e0e4736").unwrap()),
            attrs: Attrs::from(vec![
                Attr::id("status", "error"),
                Attr::count("attempts", 2),
                Attr::from_text("reason", "not a name at all"),
                Attr::from_text("credentials", "sk-abcdefghijklmn7f2a"),
            ]),
        };
        span.attrs.push(Attr::id("component", "wa-whatsapp"));
        vec![
            Record::Span(span),
            Record::metric("wa-host", "op_total", MetricKind::Counter, Unit::Micros, 9_000_000_000),
            Record::event("whatsapp.transcript.ready", "wa-whatsapp", "wa.whatsapp.transcript", 1_700_000_000_000),
            Record::event("node.tick", "wa-host", "wa.node.tick", 0),
        ]
    }

    #[test]
    fn round_trips_every_variant() {
        let records = sample();
        let frame = encode(&records).expect("encode");
        assert_eq!(decode(&frame), Ok(records));
    }

    #[test]
    fn frame_has_no_json_in_it() {
        let frame = encode(&sample()).expect("encode");
        // Binary fields can legitimately contain any byte, so the check is for JSON *structure*: an
        // object or array opener followed by a quoted key, which a binary counter cannot produce.
        assert!(!frame.windows(2).any(|window| window == b"{\""), "no JSON object on the wire");
        assert!(!frame.windows(2).any(|window| window == b"[\""), "no JSON array on the wire");
        assert_eq!(&frame[..4], &MAGIC);
    }

    #[test]
    fn encoded_len_matches_encode_for_empty_and_one() {
        assert_eq!(encode(&[]).expect("encode").len(), HEADER_BYTES);
        let one = Record::event("a.b", "c", "d", 1);
        assert_eq!(encode(std::slice::from_ref(&one)).expect("encode").len(), HEADER_BYTES + one.encoded_len());
    }

    #[test]
    fn hostile_frames_are_refused() {
        assert_eq!(decode(&[]), Err(CodecError::Truncated));
        assert_eq!(decode(b"NOPE\x00\x00"), Err(CodecError::BadMagic));
        let frame = encode(&sample()).expect("encode");
        assert_eq!(decode(&frame[..frame.len() - 1]), Err(CodecError::Truncated));
        let mut trailing = frame.clone();
        trailing.push(0);
        assert_eq!(decode(&trailing), Err(CodecError::TrailingBytes));
        let mut bad_tag = frame.clone();
        bad_tag[HEADER_BYTES] = 9;
        assert_eq!(decode(&bad_tag), Err(CodecError::BadDiscriminant));
        let mut big_count = frame.clone();
        big_count[4..6].copy_from_slice(&(MAX_RECORDS as u16 + 1).to_le_bytes());
        assert_eq!(decode(&big_count), Err(CodecError::BadCount));
        assert_eq!(decode(&vec![0u8; MAX_FRAME_BYTES + 1]), Err(CodecError::TooLarge));
    }

    #[test]
    fn oversized_id_is_refused_not_truncated() {
        let frame = {
            let mut out = Vec::new();
            out.extend_from_slice(&MAGIC);
            put_u16(&mut out, 1);
            out.push(TAG_EVENT);
            put_u16(&mut out, (MAX_ID + 1) as u16);
            out.extend_from_slice(&[b'a'; MAX_ID + 1]);
            out
        };
        assert_eq!(decode(&frame), Err(CodecError::BadBound));
    }

    #[test]
    fn encode_refuses_a_batch_bigger_than_the_decoder_accepts() {
        let many: Vec<Record> = (0..=MAX_RECORDS).map(|index| Record::event("a.b", "c", "d.e", index as u64)).collect();
        assert_eq!(encode(&many).err(), Some(CodecError::BadCount));
    }

    #[test]
    fn an_id_that_is_not_a_name_is_refused() {
        let frame = {
            let mut out = Vec::new();
            out.extend_from_slice(&MAGIC);
            put_u16(&mut out, 1);
            out.push(TAG_EVENT);
            let text = b"hello there";
            put_u16(&mut out, text.len() as u16);
            out.extend_from_slice(text);
            out
        };
        assert_eq!(decode(&frame), Err(CodecError::BadName));
    }

    #[test]
    fn an_empty_attrs_block_is_valid() {
        let frame = encode(&[Record::span("wa-host", "op", 0, 1, SpanStatus::Ok)]).expect("encode");
        let decoded = decode(&frame).expect("decode");
        assert!(decoded[0].attrs().is_empty());
    }
}
