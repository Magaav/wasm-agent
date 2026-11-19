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

/// The ONE name for these bytes, and the only place it is composed.
///
/// The welcome box said `v0.1.0` because `lua/core/chat.lua` passed a literal, and `wa --version`
/// said the same because it printed the crate version - so every node claimed the version of the
/// source crate, whatever it had actually been built from (Victor, 18/11). A node's identity is its
/// commit: a release install is the binary of one commit, a dev build is another, and only the bytes
/// can say which.
///
/// A bare commit is unreadable on a terminal, and commit + the tree's state is the measurement the
/// 18/11 rollbacks were about, so:
///
///   `e5ba9089`        a clean build of that commit
///   `e5ba9089+dirty`  built from a tree with uncommitted changes - not the commit, and it says so
///   `unknown build`   the bytes cannot name a commit; NEVER a made-up number
///
/// A release tag (when the node was installed from one) and a pin are facts about the INSTALL rather
/// than about the bytes, so the caller that reads them appends them (`lua/core/build_identity.lua`).
/// This function stays answerable on a node with no tree, no home and no installed record, which is
/// where a rollback runs.
///
/// Everything that names this build reads it: the welcome box, `wa --version`, /health and the update
/// banner's installed side.
pub fn label() -> String {
    if COMMIT.is_empty() { return "unknown build".to_string(); }
    let short = &COMMIT[..COMMIT.len().min(8)];
    if DIRTY == "true" { format!("{short}+dirty") } else { short.to_string() }
}

/// The identity as an INSTALL knows it: the released name when this node was installed from one, the
/// pin it is held at when an operator pinned it, and otherwise the bytes' own label.
///
/// Both of those are records rather than facts about the bytes, which is exactly why they are read
/// here, once, and not inferred by each surface: `installed.txt`'s `binary_release` (written from
/// this same label by `scripts/lib/install-record.sh`) and the last active record in `pins.txt`.
/// A record that cannot be read changes nothing - the bytes' label stands, which is the answer that is
/// always true. The pin is shown as `<short> (pinned)`, so nobody has to know what a pin is to see
/// that this node is being held somewhere on purpose.
pub fn install_label(state: &std::path::Path, install: &std::path::Path) -> String {
    let base = label();
    let field = |path: &std::path::Path, key: &str| -> Option<String> {
        let text = std::fs::read_to_string(path).ok()?;
        text.lines()
            .filter_map(|line| line.trim().split_once('='))
            .find(|(name, _)| name.trim() == key)
            .map(|(_, value)| value.trim().to_string())
            .filter(|value| !value.is_empty())
    };
    // installed.txt lives IN the install directory (lua/core/update.lua's M.install_dir): ~/.local/bin
    // on Linux, or whatever WA_INSTALL_DIR names.
    let released = field(&install.join("installed.txt"), "binary_release")
        .or_else(|| field(&install.join("installed.txt"), "release"));
    // The pin store is one record per block of key=value lines; a later record for a node supersedes
    // an earlier one, and only state=active is a pin in force (lua/core/pins.lua's rule, and
    // scripts/lib/node-pins.sh reads the same file the same way).
    // The pin store is <config>/pins.txt, and lua/core/paths.lua puts config at ~/.wasm-agent.
    let pinned = std::fs::read_to_string(state.join("pins.txt")).ok().and_then(|text| {
        let mut active: Option<String> = None;
        for line in text.lines() {
            let Some((key, value)) = line.trim().split_once('=') else { continue };
            match key.trim() {
                "commit" => active = Some(value.trim().to_string()),
                "state" => { if value.trim() != "active" { active = None; } }
                _ => {}
            }
        }
        active.filter(|commit| !commit.is_empty() && commit != "unknown")
    });
    match (released, pinned) {
        (_, Some(commit)) => format!("{} (pinned)", &commit[..commit.len().min(8)]),
        (Some(release), None) => release,
        (None, None) => base,
    }
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
