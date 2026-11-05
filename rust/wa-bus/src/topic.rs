//! Topics and subscription patterns.
//!
//! A topic is a dotted, lowercase-friendly path: `whatsapp.transcript.ready`. Segments are
//! `[A-Za-z0-9_-]` with an alphanumeric first and last character, at most 64 bytes each and 16
//! segments. Those are the same characters a kv key, a Windows path and a WIT string accept, so a
//! topic can be used as a retention key and as a grant name without escaping.
//!
//! The first segment is the **namespace**. It is what "a component's own namespace" means in the
//! access policy ([`crate::access`]): a component may publish and subscribe under its own id and
//! nowhere else unless a grant says so.
//!
//! A subscription pattern is either an exact topic (`whatsapp.transcript.ready`) or a prefix
//! wildcard ending in `.*` (`whatsapp.*`, which also covers `whatsapp.transcript.ready`), or the
//! bare `*`, which covers everything. `whatsapp.*` does **not** match `whatsapp` itself: the
//! wildcard stands for "at least one more segment".

use std::fmt;

/// Max bytes in one topic segment.
pub const MAX_SEGMENT: usize = 64;
/// Max bytes in a whole topic.
pub const MAX_TOPIC: usize = 256;
/// Max number of segments in a topic.
pub const MAX_SEGMENTS: usize = 16;

/// Why a topic or pattern was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TopicError {
    Empty,
    TooLong(usize),
    TooManySegments(usize),
    EmptySegment,
    SegmentTooLong(String, usize),
    BadSegment(String),
    /// `*` anywhere but as the whole pattern or as the last `.*` segment.
    BadWildcard,
}

impl fmt::Display for TopicError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TopicError::Empty => write!(f, "empty topic"),
            TopicError::TooLong(n) => write!(f, "topic is {n} bytes, max {MAX_TOPIC}"),
            TopicError::TooManySegments(n) => {
                write!(f, "topic has {n} segments, max {MAX_SEGMENTS}")
            }
            TopicError::EmptySegment => write!(f, "topic has an empty segment (double dot?)"),
            TopicError::SegmentTooLong(s, n) => {
                write!(f, "segment {s:?} is {n} bytes, max {MAX_SEGMENT}")
            }
            TopicError::BadSegment(s) => write!(
                f,
                "segment {s:?} must be [A-Za-z0-9_-] with an alphanumeric first and last character"
            ),
            TopicError::BadWildcard => write!(
                f,
                "a wildcard is only allowed as the whole pattern (\"*\") or as the last segment (\"a.b.*\")"
            ),
        }
    }
}

impl std::error::Error for TopicError {}

fn segment_ok(s: &str) -> bool {
    if s.is_empty() || s.len() > MAX_SEGMENT {
        return false;
    }
    let b = s.as_bytes();
    let alnum = |c: u8| c.is_ascii_alphanumeric();
    alnum(b[0])
        && alnum(b[b.len() - 1])
        && b.iter()
            .all(|c| c.is_ascii_alphanumeric() || *c == b'-' || *c == b'_')
}

fn check(s: &str) -> Result<(), TopicError> {
    if s.is_empty() {
        return Err(TopicError::Empty);
    }
    if s.len() > MAX_TOPIC {
        return Err(TopicError::TooLong(s.len()));
    }
    let segments: Vec<&str> = s.split('.').collect();
    if segments.len() > MAX_SEGMENTS {
        return Err(TopicError::TooManySegments(segments.len()));
    }
    for seg in segments {
        if seg.is_empty() {
            return Err(TopicError::EmptySegment);
        }
        if seg.len() > MAX_SEGMENT {
            return Err(TopicError::SegmentTooLong(seg.to_string(), seg.len()));
        }
        if !segment_ok(seg) {
            return Err(TopicError::BadSegment(seg.to_string()));
        }
    }
    Ok(())
}

/// A validated event topic. Construct with [`Topic::parse`] or [`Topic::new`]; the inner string is
/// private so no unvalidated topic can reach the bus.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Topic(String);

impl Topic {
    /// Validate and wrap `s`.
    pub fn parse(s: &str) -> Result<Topic, TopicError> {
        check(s)?;
        Ok(Topic(s.to_string()))
    }

    /// Alias for [`Topic::parse`], the name most callers use.
    pub fn new(s: &str) -> Result<Topic, TopicError> {
        Topic::parse(s)
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The first segment: the component namespace that owns the topic.
    pub fn namespace(&self) -> &str {
        match self.0.find('.') {
            Some(i) => &self.0[..i],
            None => &self.0,
        }
    }

    pub fn segments(&self) -> impl Iterator<Item = &str> {
        self.0.split('.')
    }

    /// Does this topic match `pattern`?
    pub fn matches(&self, pattern: &Pattern) -> bool {
        pattern.matches(self)
    }
}

impl fmt::Display for Topic {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::str::FromStr for Topic {
    type Err = TopicError;
    fn from_str(s: &str) -> Result<Topic, TopicError> {
        Topic::parse(s)
    }
}

/// A subscription pattern: one exact topic, or a prefix wildcard.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Pattern {
    /// Exactly this topic.
    Exact(Topic),
    /// Everything under `prefix` (`prefix.` + anything). `Prefix("")` is `*`: everything.
    Prefix(String),
}

impl Pattern {
    /// Parse `"a.b"`, `"a.*"` or `"*"`.
    pub fn parse(s: &str) -> Result<Pattern, TopicError> {
        if s == "*" {
            return Ok(Pattern::Prefix(String::new()));
        }
        if let Some(prefix) = s.strip_suffix(".*") {
            if prefix.contains('*') {
                return Err(TopicError::BadWildcard);
            }
            // The prefix must itself be a valid topic path, so `a..*` or `a*b.*` are refused.
            Topic::parse(prefix)?;
            return Ok(Pattern::Prefix(prefix.to_string()));
        }
        if s.contains('*') {
            return Err(TopicError::BadWildcard);
        }
        Ok(Pattern::Exact(Topic::parse(s)?))
    }

    /// The pattern that matches only `topic`.
    pub fn exact(topic: Topic) -> Pattern {
        Pattern::Exact(topic)
    }

    /// `*`: everything. Only a granted or host component gets far with it.
    pub fn all() -> Pattern {
        Pattern::Prefix(String::new())
    }

    /// The prefix this pattern covers (empty for `*`, the topic itself for an exact pattern).
    pub fn prefix(&self) -> &str {
        match self {
            Pattern::Exact(t) => t.as_str(),
            Pattern::Prefix(p) => p,
        }
    }

    /// Does `topic` fall under this pattern?
    pub fn matches(&self, topic: &Topic) -> bool {
        match self {
            Pattern::Exact(t) => t == topic,
            Pattern::Prefix(p) => {
                if p.is_empty() {
                    return true;
                }
                let t = topic.as_str();
                t.len() > p.len() && t.starts_with(p.as_str()) && t.as_bytes()[p.len()] == b'.'
            }
        }
    }

    /// Is every topic this pattern matches also matched by `self`? Used by the access policy so a
    /// grant for `whatsapp.*` authorises a subscription to `whatsapp.transcript.*` but not to `*`.
    pub fn covers(&self, other: &Pattern) -> bool {
        match (self, other) {
            (Pattern::Exact(a), Pattern::Exact(b)) => a == b,
            (Pattern::Exact(_), Pattern::Prefix(_)) => false,
            (Pattern::Prefix(_), Pattern::Exact(t)) => self.matches(t),
            (Pattern::Prefix(p), Pattern::Prefix(q)) => {
                if p.is_empty() {
                    return true;
                }
                q == p || (q.len() > p.len() && q.starts_with(p.as_str()) && q.as_bytes()[p.len()] == b'.')
            }
        }
    }

    /// The pattern as it is written: `a.b`, `a.*`, `*`.
    pub fn as_written(&self) -> String {
        match self {
            Pattern::Exact(t) => t.as_str().to_string(),
            Pattern::Prefix(p) if p.is_empty() => "*".to_string(),
            Pattern::Prefix(p) => format!("{p}.*"),
        }
    }
}

impl fmt::Display for Pattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.as_written())
    }
}
