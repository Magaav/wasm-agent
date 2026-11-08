//! The wire codec every fabric record shares: a strict object, a version, and bounded strings.
//!
//! The transport is the node's existing signed call (`docs/RENDEZVOUS.md`, "Relay"), so this module
//! invents no framing: a heartbeat, an offer, an accept and a refusal are JSON objects with a **fixed
//! key set**. A key the protocol does not name is a refusal, not a field quietly dropped, so a record
//! from a newer peer fails loudly instead of half-executing (`docs/FABRIC.md`, "Compatibility").

use serde_json::{Map, Value};

/// The protocol generation, in every record. A bump is a new contract.
pub const VERSION: u64 = 1;

/// The longest refusal reason, one line: a peer's words are echoed in the log and in the admin view,
/// so they are bounded and stripped of anything a terminal would act on.
pub const MAX_REASON: usize = 200;

/// Why a record was not accepted. Never carries a payload, only the field or the word that was wrong.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Refusal {
    /// The record is not the shape the protocol names; the word is the field.
    Malformed(&'static str),
    /// The record is a different generation of the protocol.
    Version(u64),
    /// A bounded field was longer than the bound; the word is the field.
    TooLarge(&'static str),
    /// The record is right but the moment has passed (an offer past its deadline).
    Late,
}

impl Refusal {
    /// The one-line word that goes on the wire (`{"refused": "..."}`) and into the log.
    pub fn as_str(&self) -> String {
        match self {
            Refusal::Malformed(field) => format!("malformed:{field}"),
            Refusal::Version(version) => format!("version:{version}"),
            Refusal::TooLarge(field) => format!("too_large:{field}"),
            Refusal::Late => "late".to_string(),
        }
    }
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.as_str())
    }
}

/// One line, at most `max` characters, with control characters replaced: a reason is printed, never
/// executed. (The queue applies the same rule to its own `last_error`.)
pub fn one_line(text: &str, max: usize) -> String {
    let mut out = String::with_capacity(text.len().min(max));
    for character in text.chars() {
        if out.chars().count() >= max {
            break;
        }
        out.push(if character.is_control() { ' ' } else { character });
    }
    out
}

/// Decode one record: UTF-8 JSON, an object, the protocol version, and **only** the keys `allowed`
/// names. The returned map is what the caller reads fields from.
pub fn object(bytes: &[u8], allowed: &[&'static str]) -> Result<Map<String, Value>, Refusal> {
    let text = std::str::from_utf8(bytes).map_err(|_| Refusal::Malformed("not_utf8"))?;
    let value: Value = serde_json::from_str(text).map_err(|_| Refusal::Malformed("not_json"))?;
    let object = value.as_object().ok_or(Refusal::Malformed("not_an_object"))?.clone();
    for key in object.keys() {
        if !allowed.contains(&key.as_str()) {
            return Err(Refusal::Malformed("unknown_field"));
        }
    }
    let version = object.get("v").and_then(Value::as_u64).ok_or(Refusal::Malformed("v"))?;
    if version != VERSION {
        return Err(Refusal::Version(version));
    }
    Ok(object)
}

/// A required, non-empty string field no longer than `max`.
pub fn bounded(object: &Map<String, Value>, key: &'static str, max: usize) -> Result<String, Refusal> {
    let text = object.get(key).and_then(Value::as_str).ok_or(Refusal::Malformed(key))?;
    if text.is_empty() {
        return Err(Refusal::Malformed(key));
    }
    if text.len() > max {
        return Err(Refusal::TooLarge(key));
    }
    Ok(text.to_string())
}

/// A required unsigned integer field.
pub fn unsigned(object: &Map<String, Value>, key: &'static str) -> Result<u64, Refusal> {
    object.get(key).and_then(Value::as_u64).ok_or(Refusal::Malformed(key))
}

/// A required signed integer field.
pub fn signed(object: &Map<String, Value>, key: &'static str) -> Result<i64, Refusal> {
    object.get(key).and_then(Value::as_i64).ok_or(Refusal::Malformed(key))
}
