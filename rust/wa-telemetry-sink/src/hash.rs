//! Two non-cryptographic hashes, both FNV-1a, used for two different jobs.
//!
//! * [`fnv1a64`] fingerprints a *value* that may not be exported as text (an attr the producer could
//!   not express as an id or a count). A digest lets an operator correlate two occurrences ("the same
//!   reason twice") without the sink being a copy of the message.
//! * [`fnv1a128`] turns a trace label into a 16-byte trace id, so a bus event that names a trace by a
//!   guest-supplied string still lands in one OTLP trace.
//!
//! Neither is a security boundary: a digest of a *secret* would be an oracle, which is why a value
//! that looks like a credential is dropped with no digest at all (`crate::redact`). A digest of a
//! message body is only a correlation key, never a reversible encoding, and the sink never exports
//! both a digest and its input.

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

pub fn fnv1a64(bytes: &[u8]) -> u64 {
    let mut hash = FNV_OFFSET;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    hash
}

/// 128-bit FNV-1a over the same prime/offset with a second lane mixed in. Two 64-bit passes: the
/// first over the bytes, the second over the first hash and the length, so a 16-byte output depends
/// on every input byte in both halves.
pub fn fnv1a128(bytes: &[u8]) -> [u8; 16] {
    let low = fnv1a64(bytes);
    let mut high = FNV_OFFSET;
    for byte in low.to_le_bytes().iter().chain((bytes.len() as u64).to_le_bytes().iter()) {
        high ^= u64::from(*byte);
        high = high.wrapping_mul(FNV_PRIME);
    }
    let mut out = [0u8; 16];
    out[..8].copy_from_slice(&low.to_le_bytes());
    out[8..].copy_from_slice(&high.to_le_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fnv_is_stable_and_distinguishes_inputs() {
        assert_eq!(fnv1a64(b""), FNV_OFFSET);
        assert_eq!(fnv1a64(b"a"), fnv1a64(b"a"));
        assert_ne!(fnv1a64(b"a"), fnv1a64(b"b"));
        assert_eq!(fnv1a64(b"foobar"), 0x85944171f73967e8);
    }

    #[test]
    fn fnv128_depends_on_every_byte_and_the_length() {
        let a = fnv1a128(b"trace-1");
        assert_eq!(a, fnv1a128(b"trace-1"));
        assert_ne!(a, fnv1a128(b"trace-2"));
        assert_ne!(a, fnv1a128(b"trace-10"));
        assert_ne!(a[..8], a[8..], "both halves must carry information");
    }
}
