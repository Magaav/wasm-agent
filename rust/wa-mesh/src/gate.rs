//! One answer to "is the mesh on for this node right now", so every gate asks the same question.
//!
//! The mesh has several gates and they had grown different rules. `host.mesh_call` and the relay hop
//! already read `policy.json`; the Lua remote-call path read `WA_MESH` and nothing else; the mount read
//! both. On 07/11 that difference showed up on a live node: `policy.json` said `"mesh": {"enabled":
//! true}` — a roster had been pushed to a *running* node, with the port and the flag its own policy
//! carries — and `wa call nextcloud bash …` went down the legacy path and was refused
//! `not a pinned operator`, because the client's gate had never heard of the policy. A process's
//! environment cannot be changed while it runs, so a gate that only reads the environment can only be
//! turned on by a restart; a gate that reads the operator's own file can be turned on by the operator.
//!
//! The one rule, in order, for every gate ([`crate::host_call::dispatch`], `enabled_at_runtime` (and so
//! `mesh_peer_call` on `/node/call`), [`crate::host_call::Settings`] for the mount, and
//! `lua/core/nodes.lua`'s remote-call gate through `host.mesh_call`'s `{gate: true}` mode):
//!
//! | # | statement | answer |
//! | --- | --- | --- |
//! | 1 | `WA_MESH` (or `WASM_AGENT_MESH`) says on or off | that, `source: environment` |
//! | 2 | `policy.json`'s `mesh.enabled` | that, `source: policy` |
//! | 3 | neither, and a roster verifies against the pinned `mesh.roster_key` | **on**, `source: roster` |
//! | 4 | neither, and no roster verifies | off (the legacy path), `source: default` |
//!
//! Rule 3 is the 08/11 change ("every new feature on by default, each with a live per-feature off
//! switch"): a node whose policy pins a fleet key *and* whose roster verifies against it is a node an
//! operator deliberately put in a fleet, so it decides by the roster unless the operator says otherwise.
//! Everything else keeps the old answer — no pinned key, no roster, an unreadable or expired roster, or
//! `mesh.enabled: false` — which is the legacy path, and `wa features` reports which one is live.
//!
//! An explicit `WA_MESH=0` is a statement too: an operator who writes it to a node's env file means
//! off, and a policy that says `enabled: true` must not quietly overrule the person who started the
//! process. (Unset, or empty, is not a statement — the policy decides.)
//!
//! **Cheap, and read per call.** The policy is one small JSON file, but a gate on a call path must not
//! parse it every time, so the answer is cached and re-read when the file's mtime or size changes
//! ([`cached`]) — the same invalidation the mount uses, so a policy edited a second ago is in force on
//! the next call and not on the next restart. A file that appears where there was none is never served
//! from a cache. Every answer carries where it came from, because a denial has to be explainable.
//!
//! A policy that cannot be read is **off**, with the reason kept ([`Switch::problem`]): a gate that
//! guessed "on" from a half-written file would be the one thing worse than the mesh not being on.

use crate::policy::MeshPolicy;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};

/// The process variables that are a statement, in the order they are read.
pub const FLAGS: [&str; 2] = ["WA_MESH", "WASM_AGENT_MESH"];

/// The variable that points at a roster file directly (`wa-mesh/src/host_call::Paths` honours it too).
pub const ROSTER_ENV: &str = "WASM_AGENT_MESH_ROSTER";
/// The roster a node looks for when nothing names one: `<config>/mesh-roster.json`, where `config` is
/// the directory `policy.json` is in (`~/.wasm-agent` on a real node).
pub const DEFAULT_ROSTER: &str = "mesh-roster.json";
/// How long a verified roster is believed before it is verified again: a roster has an expiry, so a
/// gate that cached "verified" forever would keep an expired fleet alive.
const ROSTER_TRUST_MS: u64 = 60_000;

/// Where an answer came from. Spelled the way the existing lines already spell it, so the supervisor's
/// log and an audit line keep meaning the same thing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Environment,
    Policy,
    /// No statement either way, and a roster verifies against the pinned key: on by default.
    Roster,
    Default,
}

impl Source {
    pub fn label(self) -> &'static str {
        match self {
            Source::Environment => "environment WA_MESH",
            Source::Policy => "policy.json mesh.enabled",
            Source::Roster => "default: roster verified",
            Source::Default => "default off",
        }
    }
}

/// The answer, with its provenance (and, when the policy could not be read, why).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Switch {
    pub enabled: bool,
    pub source: Source,
    pub problem: Option<String>,
}

impl Switch {
    pub fn label(&self) -> &'static str {
        self.source.label()
    }

    fn from_env(enabled: bool) -> Switch {
        Switch { enabled, source: Source::Environment, problem: None }
    }

    fn off(problem: Option<String>) -> Switch {
        Switch { enabled: false, source: Source::Default, problem }
    }
}

/// What a flag value means: `1`/`true`/`on`/`yes` on, `0`/`false`/`off`/`no` off, anything else is not
/// a statement this code invents a meaning for (an unrecognised value is off, which is what a process
/// switch that only ever matched `1` did before, and an empty value is not a statement at all).
fn parse_flag(value: &str) -> Option<bool> {
    match value.trim().to_ascii_lowercase().as_str() {
        "" => None,
        "1" | "true" | "on" | "yes" => Some(true),
        _ => Some(false),
    }
}

/// The environment's answer, when it makes one.
pub fn env_answer() -> Option<bool> {
    for name in FLAGS {
        if let Ok(value) = std::env::var(name) {
            if let Some(answer) = parse_flag(&value) {
                return Some(answer);
            }
        }
    }
    None
}

/// The rule, pure and testable: the environment's statement, else the operator's, else the default —
/// which is on when `roster_verified` says a roster verifies against the pinned key, off otherwise.
pub fn decide_with_roster(env: Option<bool>, policy: Option<&MeshPolicy>, roster_verified: bool) -> Switch {
    if let Some(enabled) = env {
        return Switch::from_env(enabled);
    }
    match policy {
        Some(policy) => match policy.enabled {
            Some(enabled) => Switch { enabled, source: Source::Policy, problem: None },
            None if roster_verified && policy.has_pinned_key() => {
                Switch { enabled: true, source: Source::Roster, problem: None }
            }
            None => Switch::off(None),
        },
        None => Switch::off(None),
    }
}

/// [`decide_with_roster`] without a roster answer: what the pure rule says when nobody checked one.
pub fn decide(env: Option<bool>, policy: Option<&MeshPolicy>) -> Switch {
    decide_with_roster(env, policy, false)
}

/// The roster file this node would verify: `WASM_AGENT_MESH_ROSTER`, else `mesh.roster` relative to the
/// config directory, else `<config>/mesh-roster.json`.
pub fn roster_path(policy: &MeshPolicy, config: &Path) -> PathBuf {
    if let Ok(explicit) = std::env::var(ROSTER_ENV) {
        let explicit = explicit.trim();
        if !explicit.is_empty() {
            return PathBuf::from(explicit);
        }
    }
    policy.roster_path(config).unwrap_or_else(|| config.join(DEFAULT_ROSTER))
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Would a roster verify against this policy's pinned key right now? Cheap-gated by mtime and size of the
/// roster file and re-verified at most once a minute, because a gate on a call path asks this per call
/// and an ed25519 verify is not free. A missing pin, a missing roster, an unreadable one or one that does
/// not verify are all `false`, which is the legacy path.
pub fn roster_verified(policy: &MeshPolicy, config: &Path) -> bool {
    if !policy.has_pinned_key() {
        return false;
    }
    let path = roster_path(policy, config);
    let stamp = std::fs::metadata(&path)
        .and_then(|metadata| metadata.modified().map(|modified| (modified, metadata.len())))
        .ok();
    let Some(stamp) = stamp else { return false };
    let now = now_ms();
    {
        let held = roster_cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(entry) = held.as_ref() {
            if entry.path == path
                && entry.stamp == stamp
                && entry.key == policy.roster_key
                && now.saturating_sub(entry.verified_at_ms) < ROSTER_TRUST_MS
            {
                return entry.verified;
            }
        }
    }
    let verified = match crate::roster::Roster::from_file(&path) {
        Ok(roster) => crate::seam::verify_roster(&roster, &policy.roster_key, now / 1000).is_ok(),
        Err(_) => false,
    };
    let mut held = roster_cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    *held = Some(RosterCache {
        path,
        stamp,
        key: policy.roster_key.clone(),
        verified_at_ms: now,
        verified,
    });
    verified
}

struct RosterCache {
    path: PathBuf,
    stamp: (SystemTime, u64),
    key: String,
    verified_at_ms: u64,
    verified: bool,
}

fn roster_cache() -> &'static Mutex<Option<RosterCache>> {
    static CACHE: OnceLock<Mutex<Option<RosterCache>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

/// Read the file and answer — no cache. `Ok` is a parsed section; a file with no `mesh` section is a
/// node whose policy says nothing, which is the default. The roster is looked for beside the policy file
/// (that directory is the node's config directory), so a test's temp config is a self-contained one.
pub fn from_file(policy_path: &Path) -> Switch {
    match MeshPolicy::from_policy_file(policy_path) {
        Ok(policy) => {
            let config = config_dir(policy_path);
            decide_with_roster(None, Some(&policy), roster_verified(&policy, &config))
        }
        Err(error) => Switch::off(Some(error.0)),
    }
}

fn config_dir(policy_path: &Path) -> PathBuf {
    policy_path.parent().map(Path::to_path_buf).unwrap_or_else(|| PathBuf::from("."))
}

struct Cached {
    path: PathBuf,
    stamp: (SystemTime, u64),
    switch: Switch,
    /// When this answer was computed. The roster half of the answer is not keyed by a stat (the roster
    /// path is only known once the policy is parsed), so an answer older than [`ROSTER_TRUST_MS`] is
    /// recomputed: a roster that appears, is replaced or expires is noticed within that window, and a
    /// policy edit is still noticed on the next call.
    answered_at_ms: u64,
}

fn cache() -> &'static Mutex<Option<Cached>> {
    static CACHE: OnceLock<Mutex<Option<Cached>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(None))
}

/// The gate a call path asks: the environment's statement if it makes one (no disk at all), else
/// `policy.json`'s `mesh.enabled`, cached by mtime and size.
pub fn cached(policy_path: &Path) -> Switch {
    if let Some(enabled) = env_answer() {
        return Switch::from_env(enabled);
    }
    let stamp = std::fs::metadata(policy_path)
        .and_then(|metadata| metadata.modified().map(|modified| (modified, metadata.len())))
        .ok();
    let mut held = cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let (Some(stamp), Some(entry)) = (stamp, held.as_ref()) {
        if entry.path == policy_path
            && entry.stamp == stamp
            && now_ms().saturating_sub(entry.answered_at_ms) < ROSTER_TRUST_MS
        {
            return entry.switch.clone();
        }
    }
    let switch = from_file(policy_path);
    // A missing file is *not* cached: it may be written a moment from now, and a gate must notice.
    *held = stamp.map(|stamp| Cached {
        path: policy_path.to_path_buf(),
        stamp,
        switch: switch.clone(),
        answered_at_ms: now_ms(),
    });
    switch
}

/// Forget the cached answer. The cache is keyed by mtime and size, which is enough for a real file;
/// this exists for a test that rewrites a file inside one filesystem timestamp tick, and for a caller
/// that has just written the policy itself and does not want to reason about clock resolution.
pub fn reset_cache() {
    *cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
    *roster_cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::temp_dir;

    fn policy_text(enabled: bool) -> String {
        format!(r#"{{"version":1,"components":{{}},"mesh":{{"version":1,"enabled":{enabled}}}}}"#)
    }

    fn enabled_by_policy() -> MeshPolicy {
        MeshPolicy::from_policy_text(&policy_text(true)).expect("policy")
    }

    #[test]
    fn the_order_is_environment_then_the_operators_file_then_off() {
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let _env = crate::testkit::EnvGuard::set(&[("WA_MESH", None), ("WASM_AGENT_MESH", None)]);
        assert_eq!(env_answer(), None);

        // Off by default, and the policy turns it on without a restart.
        assert_eq!(decide(None, None), Switch::off(None));
        assert_eq!(decide(None, None).label(), "default off");
        let by_policy = decide(None, Some(&enabled_by_policy()));
        assert!(by_policy.enabled);
        assert_eq!(by_policy.label(), "policy.json mesh.enabled");

        // The environment wins, in both directions: `WA_MESH=0` written by the operator is a
        // statement, and the policy must not overrule the person who started the process.
        let on = decide(Some(true), Some(&enabled_by_policy()));
        assert!(on.enabled);
        assert_eq!(on.label(), "environment WA_MESH");
        let off = decide(Some(false), Some(&enabled_by_policy()));
        assert!(!off.enabled, "an explicit off beats a policy that says on");
        assert_eq!(off.label(), "environment WA_MESH");

        // And the variable itself, not only the pure rule: `0`/`false`/`off` all mean off, `1` means
        // on, an unset or empty one is not a statement.
        for (value, want) in [
            ("1", Some(true)),
            ("true", Some(true)),
            (" ON ", Some(true)),
            ("0", Some(false)),
            ("false", Some(false)),
            ("off", Some(false)),
            ("", None),
            ("yes", Some(true)),
            ("please", Some(false)),
        ] {
            assert_eq!(parse_flag(value), want, "flag {value:?}");
        }
        let _env = crate::testkit::EnvGuard::set(&[
            ("WASM_AGENT_MESH", Some("1")),
            ("WA_MESH", None),
        ]);
        assert_eq!(env_answer(), Some(true), "WASM_AGENT_MESH is the same switch");
        let _env = crate::testkit::EnvGuard::set(&[("WASM_AGENT_MESH", None), ("WA_MESH", Some("0"))]);
        assert_eq!(env_answer(), Some(false));
    }

    #[test]
    fn the_answer_is_cached_by_mtime_and_a_policy_that_appears_is_noticed() {
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let _env = crate::testkit::EnvGuard::set(&[("WA_MESH", None), ("WASM_AGENT_MESH", None)]);
        let dir = temp_dir("gate-cache");
        let path = dir.join("policy.json");
        // No file: off, and not cached, so writing one is seen on the next ask.
        assert!(!cached(&path).enabled);
        std::fs::write(&path, policy_text(true)).expect("policy");
        assert!(cached(&path).enabled, "a policy written a moment after the question is noticed");
        assert_eq!(cached(&path).label(), "policy.json mesh.enabled");

        // Edit it the way an operator would: the answer follows without a restart.
        std::fs::write(&path, policy_text(false)).expect("policy");
        assert!(!cached(&path).enabled, "an edited policy is in force on the next call");

        // The cache is keyed by the file, so asking twice about an unchanged file is one parse: the
        // second answer is the first one. A test cannot see that directly (it is a cost, not a
        // behaviour), so what is asserted is the invalidation the answer depends on.
        std::fs::write(&path, policy_text(true)).expect("policy");
        assert!(cached(&path).enabled);

        // A policy that cannot be read is off, with the reason kept — never a guessed "on".
        std::fs::write(&path, "{ not json").expect("broken policy");
        let broken = cached(&path);
        assert!(!broken.enabled);
        assert!(broken.problem.is_some(), "the reason is kept for the line that reports it");
        // A different path is a different question, not a stale answer.
        let other = dir.join("other.json");
        std::fs::write(&other, policy_text(true)).expect("other policy");
        assert!(cached(&other).enabled);
        reset_cache();
        assert!(!cached(&path).enabled, "the reset only forgets, it does not change the answer");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_policy_that_says_off_is_off_and_a_file_with_no_mesh_section_is_off() {
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let _env = crate::testkit::EnvGuard::set(&[("WA_MESH", None), ("WASM_AGENT_MESH", None)]);
        let dir = temp_dir("gate-off");
        let path = dir.join("policy.json");
        std::fs::write(&path, r#"{"version":1,"components":{}}"#).expect("policy");
        let answer = cached(&path);
        assert!(!answer.enabled);
        assert_eq!(answer.label(), "default off");
        assert!(answer.problem.is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The 08/11 default: the mesh is **on** when a roster verifies against the pinned key, and the
    /// legacy path otherwise. This is the switch `wa features` reports, so it is tested through the same
    /// [`cached`] door every call path uses, on files an operator would have (a policy, a roster beside
    /// it) and with no environment statement at all.
    #[test]
    fn the_default_is_on_when_a_roster_verifies_and_the_legacy_path_without_one() {
        let _lock = crate::testkit::ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        let _env = crate::testkit::EnvGuard::set(&[
            ("WA_MESH", None),
            ("WASM_AGENT_MESH", None),
            (ROSTER_ENV, None),
        ]);
        let dir = temp_dir("gate-roster");
        let fleet = crate::testkit::fleet_key();
        let roster = crate::testkit::roster_of(
            &fleet,
            vec![crate::testkit::node("laptop", 0, &[]), crate::testkit::node("oracle", 1, &[])],
        );
        let path = dir.join("policy.json");
        let silent = format!(
            r#"{{"version":1,"components":{{}},"mesh":{{"version":1,"roster_key":"{}"}}}}"#,
            fleet.public_key
        );
        std::fs::write(&path, &silent).expect("policy");

        // A pinned key and no roster yet: the legacy path, and it says so.
        reset_cache();
        let answer = cached(&path);
        assert!(!answer.enabled, "nothing to verify yet: {answer:?}");
        assert_eq!(answer.label(), "default off");

        // The roster lands (`wa fleet push-roster` writes it beside the policy): on by default.
        std::fs::write(dir.join(DEFAULT_ROSTER), serde_json::to_string(&roster).expect("roster json"))
            .expect("roster");
        reset_cache();
        let answer = cached(&path);
        assert!(answer.enabled, "a verified roster is the default: {answer:?}");
        assert_eq!(answer.label(), "default: roster verified");

        // The per-feature off switch: the operator's own statement wins over the default.
        std::fs::write(
            &path,
            format!(
                r#"{{"version":1,"components":{{}},"mesh":{{"version":1,"enabled":false,"roster_key":"{}"}}}}"#,
                fleet.public_key
            ),
        )
        .expect("policy");
        reset_cache();
        let answer = cached(&path);
        assert!(!answer.enabled, "mesh.enabled:false is the off switch: {answer:?}");
        assert_eq!(answer.label(), "policy.json mesh.enabled");

        // A roster that does not verify (here: not a roster at all) is the legacy path again, never a
        // guess and never a weaker admission.
        std::fs::write(&path, &silent).expect("policy");
        std::fs::write(dir.join(DEFAULT_ROSTER), "{\"version\":1}").expect("broken roster");
        reset_cache();
        assert!(!cached(&path).enabled, "an unverified roster is off");

        // ...and a key that is pinned to *another* fleet does not verify this roster either.
        let other = crate::testkit::fleet_key();
        std::fs::write(
            &path,
            format!(
                r#"{{"version":1,"components":{{}},"mesh":{{"version":1,"roster_key":"{}"}}}}"#,
                other.public_key
            ),
        )
        .expect("policy");
        std::fs::write(dir.join(DEFAULT_ROSTER), serde_json::to_string(&roster).expect("roster json"))
            .expect("roster");
        reset_cache();
        assert!(!cached(&path).enabled, "a roster signed by another fleet is not this node's roster");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The pure rule, so the ordering is asserted without a filesystem: env > policy statement >
    /// roster default > off.
    #[test]
    fn decide_with_roster_orders_the_four_statements() {
        let fleet = crate::testkit::fleet_key();
        let pinned = MeshPolicy::from_policy_text(&format!(
            r#"{{"version":1,"mesh":{{"version":1,"roster_key":"{}"}}}}"#,
            fleet.public_key
        ))
        .expect("policy");
        assert!(!decide_with_roster(None, Some(&pinned), false).enabled);
        let by_roster = decide_with_roster(None, Some(&pinned), true);
        assert!(by_roster.enabled);
        assert_eq!(by_roster.source, Source::Roster);
        // no pinned key: a "verified" roster is nothing this node could have checked
        let unpinned = MeshPolicy::from_policy_text(r#"{"version":1,"mesh":{"version":1}}"#).expect("policy");
        assert!(!decide_with_roster(None, Some(&unpinned), true).enabled);
        // the operator's statement wins over the default, in both directions
        let off = MeshPolicy::from_policy_text(&format!(
            r#"{{"version":1,"mesh":{{"version":1,"enabled":false,"roster_key":"{}"}}}}"#,
            fleet.public_key
        ))
        .expect("policy");
        assert!(!decide_with_roster(None, Some(&off), true).enabled);
        let on = MeshPolicy::from_policy_text(r#"{"version":1,"mesh":{"version":1,"enabled":true}}"#).expect("policy");
        assert!(decide_with_roster(None, Some(&on), false).enabled);
        assert_eq!(decide_with_roster(None, Some(&on), false).source, Source::Policy);
        // and the environment wins over everything, still
        assert!(!decide_with_roster(Some(false), Some(&on), true).enabled);
    }
}
