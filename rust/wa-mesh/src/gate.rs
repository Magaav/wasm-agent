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
//! | 3 | neither | off, `source: default` |
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
use std::time::SystemTime;

/// The process variables that are a statement, in the order they are read.
pub const FLAGS: [&str; 2] = ["WA_MESH", "WASM_AGENT_MESH"];

/// Where an answer came from. Spelled the way the existing lines already spell it, so the supervisor's
/// log and an audit line keep meaning the same thing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    Environment,
    Policy,
    Default,
}

impl Source {
    pub fn label(self) -> &'static str {
        match self {
            Source::Environment => "environment WA_MESH",
            Source::Policy => "policy.json mesh.enabled",
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

/// The rule, pure and testable: the environment's statement, else the operator's, else off.
pub fn decide(env: Option<bool>, policy: Option<&MeshPolicy>) -> Switch {
    if let Some(enabled) = env {
        return Switch::from_env(enabled);
    }
    match policy {
        Some(policy) if policy.enabled => {
            Switch { enabled: true, source: Source::Policy, problem: None }
        }
        Some(_) | None => Switch::off(None),
    }
}

/// Read the file and answer — no cache. `Ok` is a parsed section; a file with no `mesh` section is a
/// node whose policy says nothing, which is the default.
pub fn from_file(policy_path: &Path) -> Switch {
    match MeshPolicy::from_policy_file(policy_path) {
        Ok(policy) => decide(None, Some(&policy)),
        Err(error) => Switch::off(Some(error.0)),
    }
}

struct Cached {
    path: PathBuf,
    stamp: (SystemTime, u64),
    switch: Switch,
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
        if entry.path == policy_path && entry.stamp == stamp {
            return entry.switch.clone();
        }
    }
    let switch = from_file(policy_path);
    // A missing file is *not* cached: it may be written a moment from now, and a gate must notice.
    *held = stamp.map(|stamp| Cached { path: policy_path.to_path_buf(), stamp, switch: switch.clone() });
    switch
}

/// Forget the cached answer. The cache is keyed by mtime and size, which is enough for a real file;
/// this exists for a test that rewrites a file inside one filesystem timestamp tick, and for a caller
/// that has just written the policy itself and does not want to reason about clock resolution.
pub fn reset_cache() {
    *cache().lock().unwrap_or_else(|poisoned| poisoned.into_inner()) = None;
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
}
