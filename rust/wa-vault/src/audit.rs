//! The hash-chained audit log: one line per operation, never a value.
//!
//! A line is one JSON object with a fixed field order, and its `hash` is SHA-256 over
//!
//! ```text
//! vault-audit-v1|<prev_hash>|<seq>|<ts>|<actor>|<op>|<name>|<version>|<result>
//! ```
//!
//! so an operator can recompute it with any SHA-256 tool. `prev_hash` makes an edit to line *n*
//! break line *n+1*; the document carries `audit_head` (the last hash) so a **truncated** log is
//! detected too, not just an edited one. `seq` is 1-based and must increase by one: a reordered line
//! is a failure even when every hash is internally consistent.
//!
//! The fields are exactly the ones a person can be shown: when, who, what operation, which entry,
//! which version, whether it was allowed. `result` carries a reason word after `refused:` and, for one
//! op only (`import-ed25519`), the **public** key after `ok:` - which is public data by definition.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// The `prev_hash` of the first line.
pub const GENESIS: &str = "genesis";
/// Domain string of a line hash.
pub const DOMAIN: &str = "vault-audit-v1";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AuditRecord {
    pub seq: u64,
    pub ts: i64,
    pub actor: String,
    pub op: String,
    pub name: String,
    pub version: u32,
    pub result: String,
    pub prev_hash: String,
    pub hash: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChainError(pub String);

impl ChainError {
    pub fn reason(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for ChainError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for ChainError {}

/// The canonical bytes a line's hash is taken over. Public because an operator's own script has to be
/// able to reproduce it.
#[allow(clippy::too_many_arguments)] // the fields of one line, named as the line names them
pub fn canonical(
    prev_hash: &str,
    seq: u64,
    ts: i64,
    actor: &str,
    op: &str,
    name: &str,
    version: u32,
    result: &str,
) -> String {
    format!("{DOMAIN}|{prev_hash}|{seq}|{ts}|{actor}|{op}|{name}|{version}|{result}")
}

#[allow(clippy::too_many_arguments)]
pub fn hash_of(
    prev_hash: &str,
    seq: u64,
    ts: i64,
    actor: &str,
    op: &str,
    name: &str,
    version: u32,
    result: &str,
) -> String {
    let digest = Sha256::digest(
        canonical(prev_hash, seq, ts, actor, op, name, version, result).as_bytes(),
    );
    crate::hex::encode(digest.as_slice())
}

impl AuditRecord {
    #[allow(clippy::too_many_arguments)]
    pub fn next(
        prev_hash: &str,
        seq: u64,
        ts: i64,
        actor: &str,
        op: &str,
        name: &str,
        version: u32,
        result: &str,
    ) -> Self {
        AuditRecord {
            seq,
            ts,
            actor: actor.to_string(),
            op: op.to_string(),
            name: name.to_string(),
            version,
            result: result.to_string(),
            prev_hash: prev_hash.to_string(),
            hash: hash_of(prev_hash, seq, ts, actor, op, name, version, result),
        }
    }
}

pub fn parse(lines: &[&str]) -> Result<Vec<AuditRecord>, ChainError> {
    let mut records = Vec::with_capacity(lines.len());
    for (index, line) in lines.iter().enumerate() {
        let record: AuditRecord = serde_json::from_str(line)
            .map_err(|_| ChainError(format!("audit_line_unreadable:{}", index + 1)))?;
        records.push(record);
    }
    Ok(records)
}

/// Verify the chain. `expected_head` is the document's `audit_head`, so the caller that owns the
/// document detects truncation; a verifier that only has the log still detects edits and reordering.
pub fn verify(records: &[AuditRecord], expected_head: &str) -> Result<usize, ChainError> {
    let mut prev = GENESIS.to_string();
    for (index, record) in records.iter().enumerate() {
        let expected_seq = index as u64 + 1;
        if record.seq != expected_seq {
            return Err(ChainError(format!("audit_seq_out_of_order:{}", expected_seq)));
        }
        if record.prev_hash != prev {
            return Err(ChainError(format!("audit_prev_hash_mismatch:{}", record.seq)));
        }
        let recomputed = hash_of(
            &record.prev_hash,
            record.seq,
            record.ts,
            &record.actor,
            &record.op,
            &record.name,
            record.version,
            &record.result,
        );
        if recomputed != record.hash {
            return Err(ChainError(format!("audit_hash_mismatch:{}", record.seq)));
        }
        prev = record.hash.clone();
    }
    if prev != expected_head {
        // Either a line was appended without the document (verify answered `false`, so this is the
        // interesting direction) or the tail of the log was cut.
        return Err(ChainError("audit_head_mismatch".to_string()));
    }
    Ok(records.len())
}
