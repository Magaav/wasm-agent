//! Streaming redaction of the node's own secrets from operation output.
//!
//! Operation stdout/stderr is written to disk as it arrives, so a key a command prints would
//! otherwise sit in `operations/<id>/stdout` - and a promoted process that outlives the turn
//! stays there after the transcript has moved on. Measured: a `bash` call dumped the config
//! file and the API key was written to an operation's stdout, not only to the transcript.
//!
//! The redactor runs *before* the write, so the file and the in-memory view are redacted by
//! the same pass and there is no raw window. It is exact-value replacement: the shape
//! patterns the Lua redactor uses for logs would mangle ordinary output (`task-runner`
//! contains `sk-`), and the node knows its own values anyway.
//!
//! A secret can straddle an 8 KiB read, so the last `max_len - 1` bytes are held back until
//! more output (or EOF) can complete a match. That is the whole state; the cost is one
//! substring scan per chunk and no extra I/O.

/// The node's own configured secrets come from the same names the Lua redactor uses
/// (`lua/core/redact.lua`). Keep the two lists in step; both are a handful of names.
pub const SECRET_ENV: &[&str] = &[
    "WASM_AGENT_LLM_API_KEY",
    "OPENAI_API_KEY",
    "OPENCODE_GO_API_KEY",
    "WASM_AGENT_PROMPT_CACHE_KEY",
];

const REDACTED: &[u8] = b"<redacted>";

/// The values of the node's configured secrets, from the process environment. The host has
/// already resolved the config file into the environment (`main.rs`), so this sees the same
/// values `host.getenv` does. Values shorter than eight bytes are ignored: they would redact
/// ordinary text.
pub fn env_secrets() -> Vec<Vec<u8>> {
    let mut values = Vec::new();
    for name in SECRET_ENV {
        if let Ok(value) = std::env::var(name) {
            if value.len() >= 8 {
                values.push(value.into_bytes());
            }
        }
    }
    values
}

pub struct Redactor {
    secrets: Vec<Vec<u8>>,
    /// Candidate secret indices by first byte, so a non-match position costs one lookup.
    by_first: [Vec<usize>; 256],
    max_len: usize,
    carry: Vec<u8>,
}

impl Redactor {
    pub fn new(secrets: &[Vec<u8>]) -> Self {
        let mut by_first: [Vec<usize>; 256] = std::array::from_fn(|_| Vec::new());
        let mut max_len = 0;
        for (index, secret) in secrets.iter().enumerate() {
            if secret.is_empty() {
                continue;
            }
            by_first[secret[0] as usize].push(index);
            max_len = max_len.max(secret.len());
        }
        Self { secrets: secrets.to_vec(), by_first, max_len, carry: Vec::new() }
    }

    /// True when there is anything to do; a no-op redactor returns chunks unchanged.
    pub fn is_active(&self) -> bool {
        self.max_len > 0
    }

    /// Redact what can be redacted now and return the bytes safe to write. Only a suffix
    /// that could still complete into a secret is held back, so ordinary output streams
    /// through without the one-chunk lag a fixed-size hold-back would add.
    pub fn push(&mut self, chunk: &[u8]) -> Vec<u8> {
        if !self.is_active() {
            return chunk.to_vec();
        }
        self.carry.extend_from_slice(chunk);
        let mut out = Vec::with_capacity(self.carry.len());
        let mut index = 0;
        while index < self.carry.len() {
            if let Some(length) = self.match_at(index) {
                out.extend_from_slice(REDACTED);
                index += length;
            } else if self.could_extend(index) {
                // A proper prefix of a secret: the rest may be the next chunk. Keep it.
                break;
            } else {
                out.push(self.carry[index]);
                index += 1;
            }
        }
        self.carry.drain(..index);
        out
    }

    /// Flush the held-back bytes at end of stream. No match can extend further, so this is a
    /// final scan that catches a secret whose tail was the last thing the process wrote.
    pub fn finish(&mut self) -> Vec<u8> {
        let mut out = Vec::new();
        let mut index = 0;
        while index < self.carry.len() {
            if let Some(length) = self.match_at(index) {
                out.extend_from_slice(REDACTED);
                index += length;
            } else {
                out.push(self.carry[index]);
                index += 1;
            }
        }
        self.carry.clear();
        out
    }

    fn match_at(&self, index: usize) -> Option<usize> {
        for secret_index in &self.by_first[self.carry[index] as usize] {
            let secret = &self.secrets[*secret_index];
            if self.carry[index..].starts_with(secret) {
                return Some(secret.len());
            }
        }
        None
    }

    /// Whether `carry[index..]` is a proper prefix of some secret, i.e. a match could start
    /// here only if the stream continues. The length check makes this O(1) away from the end:
    /// only a tail shorter than the longest secret can qualify.
    fn could_extend(&self, index: usize) -> bool {
        let suffix = &self.carry[index..];
        for secret in &self.secrets {
            if suffix.len() < secret.len() && secret.starts_with(suffix) {
                return true;
            }
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn secret() -> Vec<u8> {
        b"sk-live-SECRETVALUE-0123456789abcdef".to_vec()
    }

    #[test]
    fn replaces_a_whole_secret_in_one_chunk() {
        let mut redactor = Redactor::new(&[secret()]);
        let mut out = redactor.push(b"before sk-live-SECRETVALUE-0123456789abcdef after");
        out.extend(redactor.finish());
        assert_eq!(String::from_utf8_lossy(&out), "before <redacted> after");
    }

    /// The reason the carry buffer exists: an 8 KiB read can split the key in half.
    #[test]
    fn replaces_a_secret_split_across_chunks() {
        let mut redactor = Redactor::new(&[secret()]);
        let whole = b"key=sk-live-SECRETVALUE-0123456789abcdef\n";
        let (first, second) = whole.split_at(12);
        let mut out = redactor.push(first);
        out.extend(redactor.push(second));
        out.extend(redactor.finish());
        let text = String::from_utf8_lossy(&out);
        assert!(text.contains("<redacted>"), "{text}");
        assert!(!text.contains("SECRETVALUE"), "the split secret leaked: {text}");
        assert!(text.starts_with("key="), "the rest is kept: {text}");
    }

    /// One byte at a time is the worst case for the hold-back; it must still not leak.
    #[test]
    fn replaces_a_secret_split_across_many_single_byte_chunks() {
        let mut redactor = Redactor::new(&[secret()]);
        let whole = b"a sk-live-SECRETVALUE-0123456789abcdef b";
        let mut out = Vec::new();
        for byte in whole {
            out.extend(redactor.push(&[*byte]));
        }
        out.extend(redactor.finish());
        let text = String::from_utf8_lossy(&out);
        assert!(!text.contains("SECRETVALUE"), "{text}");
        assert!(text.contains("<redacted>") && text.starts_with("a ") && text.ends_with(" b"), "{text}");
    }

    #[test]
    fn ordinary_output_is_not_delayed_by_the_hold_back() {
        let mut redactor = Redactor::new(&[secret()]);
        // No suffix here is a prefix of the secret, so nothing waits for the next chunk.
        assert_eq!(redactor.push(b"ordinary output"), b"ordinary output");
        assert_eq!(redactor.finish(), b"");
    }

    #[test]
    fn a_secret_prefix_at_the_end_waits_for_the_next_chunk() {
        let mut redactor = Redactor::new(&[secret()]);
        // `sk-live-` is a prefix of the secret, so the tail is held; `key=` is not.
        assert_eq!(redactor.push(b"key=sk-live-"), b"key=");
        let mut out = redactor.push(b"SECRETVALUE-0123456789abcdef");
        out.extend(redactor.finish());
        assert_eq!(String::from_utf8_lossy(&out), "<redacted>");
    }

    /// A short secret must be caught even when a long one sets the hold-back window.
    #[test]
    fn a_short_secret_is_not_hidden_by_a_longer_one() {
        let long = vec![b'x'; 64];
        let short = b"SHORTSECRET".to_vec();
        let mut redactor = Redactor::new(&[long, short.clone()]);
        let mut out = redactor.push(b"tail SHORTSECRET");
        out.extend(redactor.finish());
        let text = String::from_utf8_lossy(&out);
        assert!(!text.contains("SHORTSECRET"), "{text}");
        assert!(text.starts_with("tail "), "{text}");
    }

    #[test]
    fn an_inactive_redactor_returns_the_chunk_unchanged() {
        let mut redactor = Redactor::new(&[]);
        assert!(!redactor.is_active());
        assert_eq!(redactor.push(b"anything at all"), b"anything at all");
    }
}
