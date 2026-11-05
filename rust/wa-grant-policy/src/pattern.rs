//! Target patterns for grant rules.
//!
//! A pattern is a short string matched against the *target* of a capability call (a chat id, a
//! URL authority, a secret name, a kv key). Three kinds, decided by where `*` appears:
//!
//! * no `*` at all — **exact**: the target must be equal (case sensitive);
//! * a single trailing `*` and none before it — **prefix**: `chat:*` matches `chat:123`;
//! * `*` anywhere else — **glob**: one `*` matches zero or more characters, so `*@g.us` matches
//!   `5511999999999-123@g.us` and `alerts*` matches `alerts-billing`.
//!
//! There is no way to match a literal `*`; targets are identifiers and addresses, so a literal
//! star in a target is not a case the policy file has to express. Consecutive stars are one star.
//! An empty pattern, a pattern with control characters and a pattern longer than
//! [`MAX_PATTERN_LEN`] are rejected when the policy is loaded — a typo must not silently grant.
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;

/// Longest accepted pattern, in characters.
pub const MAX_PATTERN_LEN: usize = 512;

/// A target pattern: `whatsapp.send` to `chat:alerts`, `net.dial` to `*.whatsapp.net:443`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pattern {
    raw: String,
    kind: Kind,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Kind {
    Exact(String),
    Prefix(String),
    Glob(Vec<Tok>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Tok {
    Lit(Vec<char>),
    Star,
}

/// Why a pattern string was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PatternError(pub String);

impl fmt::Display for PatternError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid pattern: {}", self.0)
    }
}

impl std::error::Error for PatternError {}

impl Pattern {
    /// Parse a pattern. Only the shape is checked here; an empty pattern is a mistake, never a
    /// wildcard (write `*` for "any target").
    pub fn new(raw: &str) -> Result<Pattern, PatternError> {
        if raw.is_empty() {
            return Err(PatternError("empty pattern (use \"*\" to match any target)".into()));
        }
        if raw.chars().count() > MAX_PATTERN_LEN {
            return Err(PatternError(format!("longer than {MAX_PATTERN_LEN} characters")));
        }
        if raw.chars().any(|c| c.is_control()) {
            return Err(PatternError("contains a control character".into()));
        }
        let stars = raw.matches('*').count();
        let kind = if stars == 0 {
            Kind::Exact(raw.to_string())
        } else if stars == 1 && raw.ends_with('*') {
            Kind::Prefix(raw[..raw.len() - 1].to_string())
        } else {
            Kind::Glob(glob_tokens(raw))
        };
        Ok(Pattern { raw: raw.to_string(), kind })
    }

    /// The pattern exactly as written in the policy file.
    pub fn as_str(&self) -> &str {
        &self.raw
    }

    /// Is this pattern matched by an empty test? Not used to decide anything; it exists so the
    /// engine can tell "match everything" apart when explaining a decision.
    pub fn is_any(&self) -> bool {
        self.raw == "*"
    }

    /// Does `target` match? Always case sensitive.
    pub fn matches(&self, target: &str) -> bool {
        match &self.kind {
            Kind::Exact(want) => want == target,
            Kind::Prefix(prefix) => target.starts_with(prefix.as_str()),
            Kind::Glob(tokens) => glob_match(tokens, &target.chars().collect::<Vec<_>>()),
        }
    }
}

impl fmt::Display for Pattern {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.raw)
    }
}

impl Serialize for Pattern {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&self.raw)
    }
}

impl<'de> Deserialize<'de> for Pattern {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Pattern, D::Error> {
        let raw = String::deserialize(d)?;
        Pattern::new(&raw).map_err(serde::de::Error::custom)
    }
}

fn glob_tokens(raw: &str) -> Vec<Tok> {
    let mut tokens: Vec<Tok> = Vec::new();
    let mut lit: Vec<char> = Vec::new();
    for ch in raw.chars() {
        if ch == '*' {
            if !lit.is_empty() {
                tokens.push(Tok::Lit(std::mem::take(&mut lit)));
            }
            if !matches!(tokens.last(), Some(Tok::Star)) {
                tokens.push(Tok::Star);
            }
        } else {
            lit.push(ch);
        }
    }
    if !lit.is_empty() {
        tokens.push(Tok::Lit(lit));
    }
    tokens
}

/// Single-star glob match, linear backtracking (no recursion, no allocation per step).
fn glob_match(tokens: &[Tok], text: &[char]) -> bool {
    let mut ti = 0usize;
    let mut si = 0usize;
    // Where the last `*` started: (token index of the star, text index it had consumed).
    let mut star: Option<(usize, usize)> = None;
    while si < text.len() {
        let lit_len = match tokens.get(ti) {
            Some(Tok::Lit(lit)) if lit.len() <= text.len() - si => {
                if lit.iter().enumerate().all(|(k, c)| text[si + k] == *c) {
                    Some(lit.len())
                } else {
                    None
                }
            }
            _ => None,
        };
        if let Some(len) = lit_len {
            ti += 1;
            si += len;
        } else if matches!(tokens.get(ti), Some(Tok::Star)) {
            star = Some((ti, si));
            ti += 1;
        } else if let Some((star_ti, star_si)) = star {
            if star_si >= text.len() {
                return false;
            }
            star = Some((star_ti, star_si + 1));
            ti = star_ti + 1;
            si = star_si + 1;
        } else {
            return false;
        }
    }
    while matches!(tokens.get(ti), Some(Tok::Star)) {
        ti += 1;
    }
    ti == tokens.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> Pattern {
        Pattern::new(s).expect("pattern")
    }

    #[test]
    fn exact_patterns_are_case_sensitive_and_not_prefixes() {
        assert!(p("chat:alerts").matches("chat:alerts"));
        assert!(!p("chat:alerts").matches("chat:alerts:2"));
        assert!(!p("chat:alerts").matches("Chat:Alerts"));
        assert!(!p("chat:alerts").matches(""));
    }

    #[test]
    fn trailing_star_is_a_prefix() {
        let pat = p("chat:*");
        assert!(pat.matches("chat:"));
        assert!(pat.matches("chat:123"));
        assert!(!pat.matches("chat123"));
        assert!(p("*").matches(""));
        assert!(p("*").matches("anything at all"));
    }

    #[test]
    fn glob_star_matches_any_run_including_empty() {
        let group = p("*@g.us");
        assert!(group.matches("5511999999999-123@g.us"));
        assert!(!group.matches("5511999999999@s.whatsapp.net"));
        assert!(p("a*b*c").matches("abc"));
        assert!(p("a*b*c").matches("axxbyyc"));
        assert!(!p("a*b*c").matches("axxbyy"));
        // two stars collapse to one; the run may be empty
        assert_eq!(p("a**b").as_str(), "a**b");
        assert!(p("a**b").matches("ab"));
        assert!(p("a**b").matches("axxb"));
        assert_eq!(p("a**b").matches("axxb"), p("a*b").matches("axxb"));
        assert!(p("*a*").matches("bab"));
        assert!(!p("*a*").matches("bb"));
    }

    #[test]
    fn glob_handles_repeated_prefix_attempts() {
        // The classic backtracking trap: many a's, then a failing tail.
        let pat = p("*aaaaab");
        assert!(!pat.matches(&"a".repeat(200)));
        assert!(!pat.matches(&format!("{}ba", "a".repeat(200))));
        assert!(pat.matches(&format!("{}aaaab", "a".repeat(200))));
    }

    #[test]
    fn glob_is_character_based_not_byte_based() {
        assert!(p("olá*").matches("olá mundo"));
        assert!(p("*mundo").matches("olá mundo"));
    }

    #[test]
    fn bad_patterns_are_refused() {
        assert!(Pattern::new("").is_err());
        assert!(Pattern::new("a\nb").is_err());
        assert!(Pattern::new(&"x".repeat(MAX_PATTERN_LEN + 1)).is_err());
        assert!(Pattern::new(&"x".repeat(MAX_PATTERN_LEN)).is_ok());
    }

    #[test]
    fn patterns_round_trip_through_json() {
        let pat = p("*@g.us");
        let text = serde_json::to_string(&pat).unwrap();
        assert_eq!(text, "\"*@g.us\"");
        let back: Pattern = serde_json::from_str(&text).unwrap();
        assert_eq!(back, pat);
        assert!(serde_json::from_str::<Pattern>("\"\"").is_err());
    }
}
