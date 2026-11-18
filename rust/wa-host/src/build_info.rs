//! The binary's own identity: `wa --build-info` and `wa --contains <commit>`.
//!
//! WHY A COMMAND AND NOT A FILE. `installed.txt` is written by whoever installs, so it records a belief -
//! on 18/11 it said `commit=14963b6f` for bytes built from 8 commits that were on no landed branch, and the
//! node was replaced by a deploy that trusted it. The belief and the bytes came apart; only the bytes can
//! settle it. So the build identity is compiled in (`build.rs`) and reported here, and every install path
//! writes its record FROM this answer instead of from its own intention (`scripts/lib/install-record.sh`).
//!
//! WHY IT RUNS BEFORE EVERYTHING ELSE. The two callers that need it most run on a node that is broken or
//! being replaced: the rollback path (`scripts/rollback-node.sh`, which must work with no tree, no network
//! and no healthy node) and the ancestry guard in a deploy, which asks the RUNNING binary what it is before
//! replacing it. `main` therefore dispatches `--build-info` and `--contains` before the home directory, the
//! environment file, the database, the graph index and the interpreter are touched.
//!
//! `--contains` is the ancestry question answered from inside the binary: "does this build contain commit
//! X?" - yes, no, or unknown (older than the ancestry window this build carries, or a malformed id). A
//! release install has a binary and no checkout, so it is the only party that can answer; a tree install
//! asks git, which is the same question from the primary source (`scripts/lib/install-record.sh` is the one
//! place the verdict is decided).
include!(concat!(env!("OUT_DIR"), "/build_info.rs"));

/// How the commit was learned: `git` in this checkout, or `env` from a stamper that built another tree.
pub const COMMIT_SOURCE: &str = SOURCE;

/// The identity document, one `key=value` per line - the same shape `installed.txt` uses, so a record can
/// be written by copying fields and a reader needs no parser beyond `sed -n 's/^key=//p'`.
pub fn render() -> String {
    format!(
        "version={VERSION}\ncommit={}\ntree={}\ndirty={}\nsource={}\nsource_shared={}\nbuilt_epoch={}\nancestors={}\nancestors_complete={}\n",
        if COMMIT.is_empty() { "unknown" } else { COMMIT },
        if TREE.is_empty() { "unknown" } else { TREE },
        DIRTY,
        COMMIT_SOURCE,
        SOURCE_SHARED,
        BUILT_EPOCH,
        ANCESTORS.len(),
        if ANCESTORS_COMPLETE { "true" } else { "false" },
    )
}

/// The verdict of "does this build contain that commit".
#[derive(Debug, PartialEq, Eq)]
pub enum Contains {
    /// The commit is this build's commit, or one of its ancestors.
    Yes(String),
    /// The commit is not an ancestor - going to this build would lose it.
    No,
    /// The question cannot be answered from this build: no ancestry was embedded, or the id is not one.
    Unknown(&'static str),
}

/// Answer whether this build contains `spec`, which may be abbreviated (7+ hex characters): the records
/// written before full ids were the rule carry the 12 characters `ship.sh` printed.
pub fn contains(spec: &str) -> Contains {
    let spec = spec.trim().to_ascii_lowercase();
    if spec.is_empty() { return Contains::Unknown("no_commit_named"); }
    if spec.len() < 7 { return Contains::Unknown("commit_too_short"); }
    if !spec.bytes().all(|b| b.is_ascii_hexdigit()) { return Contains::Unknown("commit_not_hex"); }
    // One candidate, two sources: the build's own commit and the ancestors it carries.
    if COMMIT.starts_with(&spec) { return Contains::Yes(COMMIT.to_string()); }
    // ANCESTORS is sorted at build time, so a prefix lands on the first entry at or after it.
    if ANCESTORS_COMPLETE {
        let at = ANCESTORS.partition_point(|candidate| &candidate[..spec.len().min(candidate.len())] < spec.as_str());
        if let Some(candidate) = ANCESTORS.get(at) {
            if candidate.starts_with(&spec) { return Contains::Yes(candidate.to_string()); }
        }
        return Contains::No;
    }
    Contains::Unknown("no_ancestry_embedded")
}

/// `wa --contains <commit>` -> prints the verdict and returns the process exit code.
///
/// The exit code is the contract a script reads: 0 yes, 1 no, 2 unknown. `no` and `unknown` are different
/// answers and a caller that treats them as one would either block every install of an old release or
/// accept a silent downgrade.
pub fn contains_command(spec: &str) -> i32 {
    match contains(spec) {
        Contains::Yes(full) => {
            println!("contains=yes\ncommit={full}\nasked={}\nthis_build={}\n", spec.trim(), if COMMIT.is_empty() { "unknown" } else { COMMIT });
            0
        }
        Contains::No => {
            println!("contains=no\nasked={}\nthis_build={}\n", spec.trim(), if COMMIT.is_empty() { "unknown" } else { COMMIT });
            1
        }
        Contains::Unknown(reason) => {
            println!("contains=unknown\nreason={reason}\nasked={}\nthis_build={}\n", spec.trim(), if COMMIT.is_empty() { "unknown" } else { COMMIT });
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The document is what every install record is written from, so its field names are a contract.
    #[test]
    fn render_names_every_field_the_records_read() {
        let document = render();
        for key in ["version=", "commit=", "tree=", "dirty=", "source=", "source_shared=", "built_epoch=", "ancestors=", "ancestors_complete="] {
            assert!(document.lines().any(|line| line.starts_with(key)), "missing {key} in:\n{document}");
        }
        assert!(document.ends_with('\n'), "the document is line-oriented");
    }

    /// A build with no git and no stamp says unknown rather than inventing an identity.
    #[test]
    fn an_unstamped_build_never_claims_a_commit() {
        let document = render();
        let commit = document.lines().find_map(|line| line.strip_prefix("commit=")).unwrap();
        assert_eq!(commit.is_empty(), false);
        assert!(commit == "unknown" || commit.len() == 40, "commit must be a full id or unknown, got {commit}");
    }

    #[test]
    fn a_malformed_id_is_unknown_rather_than_no() {
        assert_eq!(contains(""), Contains::Unknown("no_commit_named"));
        assert_eq!(contains("abc"), Contains::Unknown("commit_too_short"));
        assert_eq!(contains("zzzzzzzz"), Contains::Unknown("commit_not_hex"));
    }

    /// The question this command exists for: whether a candidate build contains the commit a node runs.
    /// The expected verdict is computed from the embedded data, so the test states the rule and not a
    /// hard-coded history.
    #[test]
    fn contains_answers_from_the_embedded_ancestry() {
        if COMMIT.is_empty() {
            assert_eq!(contains("deadbeefdeadbeef"), Contains::Unknown("no_ancestry_embedded"));
            return;
        }
        assert_eq!(contains(COMMIT), Contains::Yes(COMMIT.to_string()));
        assert_eq!(contains(&COMMIT[..12]), Contains::Yes(COMMIT.to_string()));
        // An id this history cannot contain: NO only when the ancestry this build carries is COMPLETE, which is
        // the verdict a deploy refuses on. From a truncated list (a shallow build clone) the same question is
        // UNKNOWN, because the commit may simply be below the cut - and "no" from an incomplete list is how every
        // install of an old release would have been refused.
        let absent = "0123456789abcdef0123456789abcdef01234567";
        if ANCESTORS_COMPLETE {
            assert_eq!(contains(absent), Contains::No);
        } else {
            assert_eq!(contains(absent), Contains::Unknown("no_ancestry_embedded"));
        }
    }
}
