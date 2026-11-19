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
pub fn install_label(state: &std::path::Path, install: &std::path::Path, node_name: &str, node_id: &str) -> String {
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
    let pin = std::fs::read_to_string(state.join("pins.txt")).ok()
        .and_then(|text| active_pin_for(&text, node_name, node_id));
    match (released, pin) {
        (_, Some(commit)) => format!("{} (pinned)", &commit[..commit.len().min(8)]),
        (Some(release), None) => release,
        (None, None) => base,
    }
}

/// The pin in force for THIS node, from the ledger's text - or None.
///
/// The rule is lua/core/pins.lua's, restated in one place because two languages read the same file:
///
///   * a record is a block of key=value lines, separated by blank lines, and a block may start at an
///     "id=" line without a blank line before it;
///   * the LAST record that names this node and states a state decides - an earlier one is superseded,
///     so a cleared pin does not keep a node labelled "(pinned)";
///   * a record names this node when its node= or node_id= equals this node's name or its id (the
///     ledger spells one and a request may carry the other).
///
/// IT PARSE THE BLOCK, NOT THE LINE ORDER. The previous reader walked the file line by line and kept
/// whatever commit= it saw, resetting on state= - so a commit= written ABOVE a state=cleared was
/// still taken as the active pin (the reset came too late), and a pin for ANOTHER node marked this one
/// "(pinned)". Both are one test each below.
fn active_pin_for(text: &str, node_name: &str, node_id: &str) -> Option<String> {
    let mut latest: Option<std::collections::BTreeMap<String, String>> = None;
    let mut current: std::collections::BTreeMap<String, String> = std::collections::BTreeMap::new();
    let mut flush = |record: &mut std::collections::BTreeMap<String, String>| {
        if record.is_empty() { return; }
        let names_this = {
            let want_name = node_name.trim();
            let want_id = node_id.trim();
            let have_node = record.get("node").map(|value| value.trim()).unwrap_or("");
            let have_id = record.get("node_id").map(|value| value.trim()).unwrap_or("");
            let mut named = false;
            if !want_name.is_empty() && (have_node == want_name || have_id == want_name) { named = true; }
            if !want_id.is_empty() && (have_id == want_id || have_node == want_id) { named = true; }
            named
        };
        if names_this && record.get("state").map(|value| !value.trim().is_empty()).unwrap_or(false) {
            let taken = std::mem::take(record);
            latest = Some(taken);
        } else {
            record.clear();
        }
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() {
            flush(&mut current);
            continue;
        }
        // A new record can start without a blank line in front of it (the writer puts one, a hand
        // edit may not): an "id=" line after an id already seen begins the next block.
        if let Some((key, value)) = line.split_once('=') {
            let key = key.trim();
            if key == "id" && current.contains_key("id") { flush(&mut current); }
            current.insert(key.to_string(), value.trim().to_string());
        }
    }
    flush(&mut current);
    let record = latest?;
    // The LAST record naming this node decides, and it must SAY active: a state=cleared record is a
    // supersession, which is why it is the latest one found and still releases nothing.
    if record.get("state").map(|value| value.trim()) != Some("active") { return None; }
    let commit = record.get("commit").map(|value| value.trim()).unwrap_or("");
    if commit.is_empty() || commit == "unknown" { return None; }
    Some(commit.to_string())
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

    /// A pin for ANOTHER node does not mark this one "(pinned)" - the ledger is fleet-wide, and the
    /// reader used to take whatever commit= it saw last, whoever the record named.
    #[test]
    fn a_pin_for_another_node_is_not_this_node_pin() {
        let ledger = "schema=wasm-agent-pins/1
id=aaaa
node=work
node_id=deadbeef
kind=pin
state=active
commit=1111111111111111
reason=held

";
        assert_eq!(active_pin_for(ledger, "avell", "cafebabe"), None,
            "a pin naming another node must not label this one");
        assert_eq!(active_pin_for(ledger, "work", "").as_deref(), Some("1111111111111111"),
            "and the node it does name is the one marked");
        assert_eq!(active_pin_for(ledger, "", "deadbeef").as_deref(), Some("1111111111111111"),
            "a request that carries only the id still finds it");
    }

    /// State BEFORE commit is the order the Lua writer emits, and commit BEFORE state is what a hand
    /// edit may look like: a cleared record must not pin either way.
    #[test]
    fn a_cleared_record_pins_nothing_whatever_the_line_order() {
        let state_first = "id=aaaa
node=work
state=cleared
commit=1111111111111111

";
        assert_eq!(active_pin_for(state_first, "work", ""), None, "state=cleared before commit= clears");
        let commit_first = "id=aaaa
node=work
commit=1111111111111111
state=cleared

";
        assert_eq!(active_pin_for(commit_first, "work", ""), None, "state=cleared after commit= clears too");
        let active_first = "id=aaaa
node=work
commit=2222222222222222
state=active

";
        assert_eq!(active_pin_for(active_first, "work", "").as_deref(), Some("2222222222222222"),
            "an active record in either order is a pin");
    }

    /// The LAST record naming the node decides: a pin that was cleared and re-applied is active, and
    /// one that was re-applied and then cleared is not.
    #[test]
    fn the_last_record_for_this_node_wins() {
        let ledger = "id=a
node=work
state=active
commit=3333333333333333

id=b
node=work
state=cleared
commit=3333333333333333

";
        assert_eq!(active_pin_for(ledger, "work", ""), None, "the later clear supersedes the earlier pin");
        let again = "id=a
node=work
state=cleared
commit=3333333333333333

id=b
node=work
state=active
commit=4444444444444444

";
        assert_eq!(active_pin_for(again, "work", "").as_deref(), Some("4444444444444444"),
            "and re-applying it is a pin again");
    }

    /// A record that names no commit, or one that says unknown, is not a pin a reader may show.
    #[test]
    fn an_unknown_commit_is_not_a_pin() {
        let unknown = "id=a
node=work
state=active
commit=unknown

";
        assert_eq!(active_pin_for(unknown, "work", ""), None);
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
