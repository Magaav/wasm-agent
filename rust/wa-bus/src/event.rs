//! The event envelope and its wire form.
//!
//! Every event carries `{id, topic, ts, source, schema/version, payload, trace}`. The payload is
//! opaque bytes: the bus never parses it, and nothing here ever logs it (`Event::summary` reports a
//! length, never the bytes).
//!
//! The wire form is a small, versioned, self-describing binary encoding so a durable topic can keep
//! the exact bytes a reader later replays — no serde, no schema drift on the way to storage.

use crate::topic::Topic;
use std::fmt;

/// Monotonic event id, assigned by [`crate::Bus::publish`] when the publisher left it unset.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Default)]
pub struct EventId(pub u64);

impl EventId {
    /// `EventId(0)`: "assign one for me". `Bus::publish` replaces it with the next id.
    pub const UNASSIGNED: EventId = EventId(0);

    pub fn is_assigned(self) -> bool {
        self.0 != 0
    }
}

impl fmt::Display for EventId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// The schema name and version of a payload. Two producers of the same topic must agree on it, and a
/// consumer can refuse a version it does not know instead of guessing at the bytes.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Schema {
    pub name: String,
    pub version: u32,
}

impl Schema {
    pub fn new(name: &str, version: u32) -> Schema {
        Schema { name: name.to_string(), version }
    }
}

impl fmt::Display for Schema {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}@{}", self.name, self.version)
    }
}

/// One published fact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    /// Assigned by the bus on publish; keep it to correlate delivery with the durable log.
    pub id: EventId,
    pub topic: Topic,
    /// Milliseconds since the Unix epoch. `0` on publish means "stamp it now".
    pub ts_ms: u64,
    /// The component that produced the event. The host sets this; a guest never names itself.
    pub source: String,
    pub schema: Schema,
    pub payload: Vec<u8>,
    /// Trace id from the run that produced the event, if there was one.
    pub trace: Option<String>,
}

impl Event {
    /// A new event with an unassigned id, stamped now.
    pub fn new(topic: Topic, source: &str, schema: &str, payload: impl Into<Vec<u8>>) -> Event {
        Event {
            id: EventId::UNASSIGNED,
            topic,
            ts_ms: now_ms(),
            source: source.to_string(),
            schema: Schema::new(schema, 1),
            payload: payload.into(),
            trace: None,
        }
    }

    /// A new event from a topic string, refusing an invalid topic.
    pub fn parse(
        topic: &str,
        source: &str,
        schema: &str,
        payload: impl Into<Vec<u8>>,
    ) -> Result<Event, crate::BusError> {
        Ok(Event::new(Topic::parse(topic)?, source, schema, payload))
    }

    pub fn with_schema_version(mut self, version: u32) -> Event {
        self.schema.version = version;
        self
    }

    pub fn with_trace(mut self, trace: &str) -> Event {
        self.trace = Some(trace.to_string());
        self
    }

    pub fn with_ts(mut self, ts_ms: u64) -> Event {
        self.ts_ms = ts_ms;
        self
    }

    pub fn with_id(mut self, id: EventId) -> Event {
        self.id = id;
        self
    }

    pub fn with_payload(mut self, payload: impl Into<Vec<u8>>) -> Event {
        self.payload = payload.into();
        self
    }

    /// One log line about the event: identity and size, never the payload bytes and never the
    /// payload's text. This is the shape a log line may have (docs/BUS.md).
    pub fn summary(&self) -> String {
        format!(
            "event id={} topic={} ts={} source={} schema={} bytes={} trace={}",
            self.id,
            self.topic,
            self.ts_ms,
            self.source,
            self.schema,
            self.payload.len(),
            self.trace.as_deref().unwrap_or("-")
        )
    }

    /// Encode for durable retention. Deterministic: the same event always yields the same bytes.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(MAGIC.len() + 64 + self.payload.len());
        out.extend_from_slice(MAGIC);
        out.push(FORMAT);
        out.extend_from_slice(&self.id.0.to_le_bytes());
        put_str(&mut out, self.topic.as_str());
        out.extend_from_slice(&self.ts_ms.to_le_bytes());
        put_str(&mut out, &self.source);
        put_str(&mut out, &self.schema.name);
        out.extend_from_slice(&self.schema.version.to_le_bytes());
        match &self.trace {
            Some(t) => {
                out.push(1);
                put_str(&mut out, t);
            }
            None => out.push(0),
        }
        put_bytes(&mut out, &self.payload);
        out
    }

    /// Decode what [`Event::encode`] wrote. Every length is checked against the remaining input, so
    /// a truncated or corrupted record is an error, never a silently short event.
    pub fn decode(bytes: &[u8]) -> Result<Event, DecodeError> {
        let mut r = Reader { buf: bytes, pos: 0 };
        if r.take(MAGIC.len())? != MAGIC {
            return Err(DecodeError::BadMagic);
        }
        let format = r.take(1)?[0];
        if format != FORMAT {
            return Err(DecodeError::UnsupportedFormat(format));
        }
        let id = EventId(r.u64()?);
        let topic = Topic::parse(r.str()?).map_err(|e| DecodeError::BadTopic(e.to_string()))?;
        let ts_ms = r.u64()?;
        let source = r.str()?.to_string();
        let schema = Schema::new(r.str()?, r.u32()?);
        let trace = match r.take(1)?[0] {
            0 => None,
            1 => Some(r.str()?.to_string()),
            other => return Err(DecodeError::BadTraceFlag(other)),
        };
        let payload = r.bytes()?.to_vec();
        if r.pos != r.buf.len() {
            return Err(DecodeError::TrailingBytes(r.buf.len() - r.pos));
        }
        Ok(Event { id, topic, ts_ms, source, schema, payload, trace })
    }
}

const MAGIC: &[u8; 6] = b"WABUS1";
const FORMAT: u8 = 1;

/// A stored event could not be read back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DecodeError {
    Truncated,
    BadMagic,
    UnsupportedFormat(u8),
    BadTopic(String),
    BadStr,
    BadTraceFlag(u8),
    TrailingBytes(usize),
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DecodeError::Truncated => write!(f, "event record is truncated"),
            DecodeError::BadMagic => write!(f, "event record has the wrong magic"),
            DecodeError::UnsupportedFormat(v) => write!(f, "unsupported event format {v}"),
            DecodeError::BadTopic(why) => write!(f, "stored topic is invalid: {why}"),
            DecodeError::BadStr => write!(f, "stored string is not valid utf-8"),
            DecodeError::BadTraceFlag(v) => write!(f, "bad trace flag {v}"),
            DecodeError::TrailingBytes(n) => write!(f, "event record has {n} trailing bytes"),
        }
    }
}

impl std::error::Error for DecodeError {}

fn put_str(out: &mut Vec<u8>, s: &str) {
    let n = u16::try_from(s.len()).unwrap_or(u16::MAX);
    out.extend_from_slice(&n.to_le_bytes());
    out.extend_from_slice(&s.as_bytes()[..n as usize]);
}

fn put_bytes(out: &mut Vec<u8>, b: &[u8]) {
    let n = u32::try_from(b.len()).unwrap_or(u32::MAX);
    out.extend_from_slice(&n.to_le_bytes());
    out.extend_from_slice(&b[..n as usize]);
}

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Result<&'a [u8], DecodeError> {
        let end = self.pos.checked_add(n).ok_or(DecodeError::Truncated)?;
        if end > self.buf.len() {
            return Err(DecodeError::Truncated);
        }
        let out = &self.buf[self.pos..end];
        self.pos = end;
        Ok(out)
    }

    fn u32(&mut self) -> Result<u32, DecodeError> {
        let b = self.take(4)?;
        Ok(u32::from_le_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn u64(&mut self) -> Result<u64, DecodeError> {
        let b = self.take(8)?;
        Ok(u64::from_le_bytes([b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]]))
    }

    fn str(&mut self) -> Result<&'a str, DecodeError> {
        let n = {
            let b = self.take(2)?;
            u16::from_le_bytes([b[0], b[1]]) as usize
        };
        std::str::from_utf8(self.take(n)?).map_err(|_| DecodeError::BadStr)
    }

    fn bytes(&mut self) -> Result<&'a [u8], DecodeError> {
        let n = self.u32()? as usize;
        self.take(n)
    }
}

/// Milliseconds since the Unix epoch, saturating at 0 for a clock before 1970.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
