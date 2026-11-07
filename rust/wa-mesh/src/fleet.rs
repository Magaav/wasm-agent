//! Bootstrapping an existing operator's node into the fleet: install a roster, pin its key, enable it.
//!
//! The problem this solves, in one sentence: a node that was bound before the mesh existed pins the
//! operator list it was bound with, and no mesh call can change that from the outside — so the fleet
//! has to be installed *on* it, by somebody it already accepts.
//!
//! What travels is only what is public: the signed roster, the fleet **public** key, and the request
//! itself. There is no code path here that reads, accepts or forwards a private key — the fleet key
//! stays where the operator keeps it.
//!
//! What lands on the target, in this order, and each step is reversible from the backup the previous
//! one left:
//!
//! 1. `policy.prev.json` — the previous `policy.json`, byte for byte, before anything is merged;
//! 2. `policy.json` — a `mesh` section added or amended (`roster_key`, `enabled: true`, `roster`),
//!    nothing else in the file touched. This is the *additions-only* shape the deploy's policy merge
//!    uses for a node with no recorded base: new rules arrive, a rule the operator wrote is never
//!    rewritten;
//! 3. `mesh-roster.json` — the signed roster, atomically;
//! 4. `env` — `WA_MESH=1` appended when the node's own env file does not already say something about
//!    it, so a restart keeps the feature on.
//!
//! `mesh.enabled` in step 2 is what makes this work on a *running* node: the environment of a live
//! process cannot be changed, and the admission path reads the operator's policy per call
//! ([`crate::admission::in_force`]).
//!
//! The refusals are the part an operator will actually meet, so each one is a code:
//!
//! | code | meaning |
//! | --- | --- |
//! | `roster_key_missing` | no fleet public key was sent |
//! | `roster_unverified:*` | the roster does not verify against the key being pinned |
//! | `roster_missing_target` | the roster does not contain the node it is being installed on |
//! | `roster_pins_different_key` | the target already pins another fleet key; re-anchoring needs the old key's signature |
//! | `roster_replace_key_unverified` | a re-anchoring signature was sent but does not verify against the pinned key |
//! | `policy_unreadable` | `policy.json` is not a JSON object; nothing is overwritten |
//!
//! Re-anchoring is `mesh-anchor-v1|<new_key>|<roster fingerprint>` signed by the key the target pins
//! **now**. That signature can only come from the operator who holds the old fleet key, so a node
//! cannot be talked into a different fleet by a peer holding a valid roster of its own.
use crate::identity::verify;
use crate::roster::{Roster, RosterNode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

/// The domain of a re-anchoring statement. In the signed string so an anchor signature can never be
/// replayed as a call, a reply or a roster.
pub const ANCHOR_DOMAIN: &str = "mesh-anchor-v1";
/// The roster file a push writes, and the name the merged policy points at.
pub const ROSTER_FILE: &str = "mesh-roster.json";
pub const POLICY_FILE: &str = "policy.json";
pub const POLICY_BACKUP: &str = "policy.prev.json";
pub const ENV_FILE: &str = "env";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PushRequest {
    /// The target's config directory (`<home>/.wasm-agent`).
    pub config: String,
    /// The signed roster, verbatim.
    pub roster: String,
    /// The fleet public key to pin, hex.
    pub roster_key: String,
    /// The caller, as the target authenticated it — never as the caller claimed to be.
    pub caller_node_id: String,
    pub caller_public_key: String,
    /// The node it is being installed on: the roster must contain it.
    pub target_node_id: String,
    /// `--replace-key`: signature by the key the target pins *now* over
    /// `mesh-anchor-v1|<new_key>|<roster fingerprint>`.
    #[serde(default)]
    pub replace_key_signature: Option<String>,
    /// The port the target's mesh listener should answer on. When a caller cannot say (the relayed
    /// push carries no room for it), the port comes from the roster's own address for the target: the
    /// roster already says where that node answers, and a running node cannot be restarted to be told.
    #[serde(default)]
    pub port: Option<u16>,
    /// The address the target's listener should bind. Left as the target has it when absent.
    #[serde(default)]
    pub bind: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Installed {
    pub ok: bool,
    pub fleet: String,
    pub fingerprint: String,
    pub nodes: usize,
    pub roster_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub previous_key: Option<String>,
    pub backup: String,
    pub roster_path: String,
    /// Whether the running node is now deciding by the roster (`mesh.enabled` in its own policy).
    pub enabled: bool,
    /// What the *next* start will read from the node's env file.
    pub env: String,
    pub roster_entries: Vec<String>,
}

fn refuse(code: &str, detail: impl Into<String>) -> Value {
    json!({"ok": false, "error": code, "detail": detail.into()})
}

/// Read the `mesh` section's currently pinned key, without demanding that the rest of the file parses
/// as a full mesh policy (a node that has never had one has no section at all).
fn pinned_key(policy: &Value) -> Option<String> {
    policy
        .get("mesh")
        .and_then(|mesh| mesh.get("roster_key"))
        .and_then(Value::as_str)
        .map(|key| key.trim().to_ascii_lowercase())
        .filter(|key| !key.is_empty())
}

fn read_policy(path: &Path) -> Result<(Value, Vec<u8>), String> {
    match std::fs::read(path) {
        Ok(bytes) => {
            let value: Value = serde_json::from_slice(&bytes)
                .map_err(|error| format!("{POLICY_FILE} is not valid JSON: {error}"))?;
            if !value.is_object() {
                return Err(format!("{POLICY_FILE} is not a JSON object"));
            }
            Ok((value, bytes))
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok((json!({}), Vec::new())),
        Err(error) => Err(format!("{POLICY_FILE}: {error}")),
    }
}

/// Write atomically (temp in the same directory, then rename), so a half-written policy or roster is
/// never what a running node reads next.
fn write_atomic(path: &Path, bytes: &[u8]) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        wa_host_support::paths::private_dir(parent);
    }
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    std::fs::write(&temporary, bytes).map_err(|error| format!("{}: {error}", temporary.display()))?;
    if std::fs::rename(&temporary, path).is_err() {
        // Windows refuses to rename over an existing file.
        let _ = std::fs::remove_file(path);
        std::fs::rename(&temporary, path).map_err(|error| format!("{}: {error}", path.display()))?;
    }
    Ok(())
}

/// The port the roster says this node answers on: its first address's port, if it has one. A roster
/// address is `host:port` ([`crate::roster::check_address`] guarantees it), and the *target's* own
/// entry is the only statement about where the target listens that a push carries.
pub fn listener_port(roster: &Roster, target_node_id: &str) -> Option<u16> {
    let node = roster.node(target_node_id)?;
    node.addresses.iter().find_map(|address| {
        address
            .trim()
            .rsplit_once(':')
            .and_then(|(_, port)| port.parse::<u16>().ok())
            .filter(|port| *port != 0)
    })
}

/// Merge the mesh section in: every other key and every other field of `mesh` is kept as it is.
/// Returns the merged document and the key it replaced, if any.
fn merge_policy(
    mut policy: Value,
    roster_key: &str,
    port: Option<u16>,
    bind: Option<&str>,
) -> Result<(Value, Option<String>), String> {
    let previous = pinned_key(&policy);
    let object = policy
        .as_object_mut()
        .ok_or_else(|| format!("{POLICY_FILE} is not a JSON object"))?;
    let section = object.entry("mesh").or_insert_with(|| json!({}));
    let section = section
        .as_object_mut()
        .ok_or_else(|| "the mesh section of policy.json is not an object".to_string())?;
    section.insert("version".into(), json!(crate::policy::MESH_SCHEMA_VERSION));
    section.insert("roster_key".into(), json!(roster_key));
    section.insert("enabled".into(), json!(true));
    section.insert("roster".into(), json!(ROSTER_FILE));
    // The port is what lets a *running* node mount its listener without a restart: `enabled` alone is
    // roster admission on the relay path (docs/MESH.md §8, "the flag"). Never guessed and never
    // removed: a target that has no address in the roster (or no port in it) keeps whatever its own
    // policy says, including "no listener".
    if let Some(port) = port {
        section.insert("port".into(), json!(port));
    }
    if let Some(bind) = bind.map(str::trim).filter(|bind| !bind.is_empty()) {
        section.insert("bind".into(), json!(bind));
    }
    Ok((policy, previous))
}

/// Append `WA_MESH=1` to the node's env file when it says nothing about the flag. A line that already
/// sets it is never rewritten: the operator's own statement wins, including `WA_MESH=0`.
fn enable_env(config: &Path) -> (String, bool) {
    let path = config.join(ENV_FILE);
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    let mentions = text.lines().any(|line| {
        let line = line.trim();
        !line.starts_with('#') && line.split('=').next().map(str::trim) == Some("WA_MESH")
    });
    if mentions {
        return ("kept: the env file already names WA_MESH".into(), false);
    }
    let mut next = text;
    if !next.is_empty() && !next.ends_with('\n') {
        next.push('\n');
    }
    next.push_str("WA_MESH=1\n");
    match write_atomic(&path, next.as_bytes()) {
        Ok(()) => ("appended WA_MESH=1".into(), true),
        Err(error) => (format!("not written: {error}"), false),
    }
}

impl PushRequest {
    /// Verify the request, then install it. Every refusal happens before the first file is written.
    pub fn install(&self) -> Value {
        let config = PathBuf::from(self.config.trim());
        if config.as_os_str().is_empty() {
            return refuse("config_required", "no target config directory");
        }
        let key = self.roster_key.trim().to_ascii_lowercase();
        if key.is_empty() {
            return refuse("roster_key_missing", "the fleet public key is required");
        }
        // Only public material is accepted, and only when it agrees with itself.
        let roster = match Roster::parse(&self.roster) {
            Ok(roster) => roster,
            Err(error) => return refuse("roster_unverified", error.0),
        };
        let now_s = crate::wire::now_seconds();
        if let Err(error) = roster.verify(&key, now_s) {
            return refuse("roster_unverified", error.0);
        }
        if roster.node(&self.target_node_id).is_none() {
            return refuse(
                "roster_missing_target",
                "the roster does not contain the node it is being installed on",
            );
        }
        let policy_path = config.join(POLICY_FILE);
        let (policy, previous_bytes) = match read_policy(&policy_path) {
            Ok(read) => read,
            Err(error) => return refuse("policy_unreadable", error),
        };
        let previous = pinned_key(&policy);
        if let Some(previous) = previous.as_deref() {
            if previous != key {
                // No silent re-anchoring: a different fleet key needs the old key's signature.
                let message = format!("{ANCHOR_DOMAIN}|{key}|{}", roster.fingerprint());
                let given = self.replace_key_signature.as_deref().unwrap_or_default();
                if given.is_empty() {
                    return refuse(
                        "roster_pins_different_key",
                        "this node already pins another fleet key; pass --replace-key with the old key's signature to re-anchor it",
                    );
                }
                if !verify(previous, &message, given) {
                    return refuse(
                        "roster_replace_key_unverified",
                        "the re-anchoring signature does not verify against the key this node pins now",
                    );
                }
            }
        }
        let port = self.port.or_else(|| listener_port(&roster, &self.target_node_id));
        let bind = self.bind.clone();
        let (merged, _) = match merge_policy(policy, &key, port, bind.as_deref()) {
            Ok(merged) => merged,
            Err(error) => return refuse("policy_unreadable", error),
        };
        let backup = config.join(POLICY_BACKUP);
        let mut written: Vec<PathBuf> = Vec::new();
        if !previous_bytes.is_empty() {
            if let Err(error) = write_atomic(&backup, &previous_bytes) {
                return refuse("policy_backup_failed", error);
            }
            written.push(backup.clone());
        }
        let text = match serde_json::to_string_pretty(&merged) {
            Ok(text) => text + "\n",
            Err(error) => return refuse("policy_unreadable", error.to_string()),
        };
        if let Err(error) = write_atomic(&policy_path, text.as_bytes()) {
            return refuse("policy_write_failed", error);
        }
        written.push(policy_path);
        let roster_path = config.join(ROSTER_FILE);
        if let Err(error) = write_atomic(&roster_path, self.roster.as_bytes()) {
            return refuse("roster_write_failed", error);
        }
        written.push(roster_path.clone());
        let (env, env_written) = enable_env(&config);
        if env_written {
            written.push(config.join(ENV_FILE));
        }
        let previous_key = previous.filter(|previous| previous != &key);
        let mut answer = json!({
            "ok": true,
            "fleet": roster.fleet,
            "fingerprint": roster.fingerprint(),
            "nodes": roster.nodes.len(),
            "roster_key": key,
            "previous_key": previous_key,
            "backup": backup.to_string_lossy(),
            "roster_path": roster_path.to_string_lossy(),
            "enabled": true,
            "port": port,
            "bind": bind,
            "listener": if port.is_some() {
                "mounts on the node's next poll: no restart"
            } else {
                "no port: the roster gives this node no address, so it enables roster admission without listening"
            },
            "env": env,
            "roster_entries": roster
                .nodes
                .iter()
                .map(|node: &RosterNode| format!("{}:{}", node.name, node.level))
                .collect::<Vec<_>>(),
            "written": written.iter().map(|path| path.to_string_lossy().to_string()).collect::<Vec<_>>(),
        });
        let _ = now_s;
        if let Some(object) = answer.as_object_mut() {
            object.insert(
                "privacy".into(),
                json!("no private key travelled: the fleet key was never sent"),
            );
        }
        answer
    }
}

/// What a push would do, without doing it: the operator's `--dry-run`, and what the target reports
/// when it refuses for a reason the caller can fix.
pub fn plan(config: &Path, roster: &Roster, roster_key: &str) -> Value {
    let policy_path = config.join(POLICY_FILE);
    let policy = match read_policy(&policy_path) {
        Ok((policy, _)) => policy,
        Err(error) => return refuse("policy_unreadable", error),
    };
    json!({
        "ok": true,
        "config": config.to_string_lossy(),
        "fleet": roster.fleet,
        "fingerprint": roster.fingerprint(),
        "pinned_key": pinned_key(&policy),
        "requested_key": roster_key.trim().to_ascii_lowercase(),
        "ports": roster.nodes.iter().filter_map(|node| listener_port(roster, &node.node_id).map(|port| json!([node.name, port]))).collect::<Vec<_>>(),
        "roster_path": config.join(ROSTER_FILE).to_string_lossy(),
        "backup": config.join(POLICY_BACKUP).to_string_lossy(),
        "env": config.join(ENV_FILE).to_string_lossy(),
    })
}

/// The `mesh` section of a policy document, for a test or an operator reading the file.
pub fn mesh_section(value: &Value) -> Map<String, Value> {
    value
        .get("mesh")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testkit::{fleet_key, temp_dir, Member};
    use crate::roster::Draft;

    fn fleet() -> (crate::identity::Identity, Roster, Member) {
        let key = fleet_key();
        let node = Member::new("nextcloud", 1, &[]);
        let roster = Draft {
            fleet: "ohana".into(),
            issued_at: crate::wire::now_seconds().saturating_sub(60),
            expires_at: 0,
            nodes: vec![node.node.clone()],
        }
        .sign(&key);
        (key, roster, node)
    }

    fn request(dir: &Path, key: &crate::identity::Identity, roster: &Roster, target: &Member) -> PushRequest {
        PushRequest {
            config: dir.to_string_lossy().to_string(),
            roster: serde_json::to_string_pretty(roster).unwrap(),
            roster_key: key.public_key.clone(),
            caller_node_id: "b".into(),
            caller_public_key: "aa".into(),
            target_node_id: target.node.node_id.clone(),
            replace_key_signature: None,
            port: None,
            bind: None,
        }
    }

    #[test]
    fn a_push_adds_the_section_pins_the_key_and_keeps_a_backup() {
        let (key, roster, node) = fleet();
        let dir = temp_dir("push");
        let before = r#"{"version":1,"components":{"wa-whatsapp":{"capabilities":{"kv.write":["ix/*"]}}}}"#;
        std::fs::write(dir.join(POLICY_FILE), before).unwrap();
        std::fs::write(dir.join(ENV_FILE), "WASM_AGENT_MANAGED=0\n").unwrap();
        let answer = request(&dir, &key, &roster, &node).install();
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["fleet"], "ohana");
        assert_eq!(answer["roster_key"], key.public_key);
        // The backup is the previous file, byte for byte.
        assert_eq!(std::fs::read_to_string(dir.join(POLICY_BACKUP)).unwrap(), before);
        // The merged policy keeps the operator's rules and gains the mesh section.
        let merged: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join(POLICY_FILE)).unwrap()).unwrap();
        assert_eq!(merged["components"]["wa-whatsapp"]["capabilities"]["kv.write"][0], "ix/*");
        assert_eq!(merged["mesh"]["roster_key"], key.public_key);
        assert_eq!(merged["mesh"]["enabled"], true);
        assert_eq!(merged["mesh"]["roster"], ROSTER_FILE);
        // The roster is the signed one, and the running node now decides by it.
        let installed = Roster::from_file(dir.join(ROSTER_FILE)).unwrap();
        installed.verify(&key.public_key, crate::wire::now_seconds()).unwrap();
        let policy = crate::policy::MeshPolicy::from_policy_file(dir.join(POLICY_FILE)).unwrap();
        assert!(crate::admission::in_force(&policy));
        assert_eq!(std::fs::read_to_string(dir.join(ENV_FILE)).unwrap().trim(), "WASM_AGENT_MANAGED=0\nWA_MESH=1");
    }

    #[test]
    fn a_roster_that_does_not_verify_against_the_key_being_pinned_writes_nothing() {
        let (key, roster, node) = fleet();
        let dir = temp_dir("push-bad-roster");
        let mut req = request(&dir, &key, &roster, &node);
        req.roster_key = fleet_key().public_key; // a different key than the one that signed
        let answer = req.install();
        assert_eq!(answer["error"], "roster_unverified", "{answer}");
        assert!(!dir.join(POLICY_FILE).exists());
        assert!(!dir.join(ROSTER_FILE).exists());

        // A tampered roster is refused the same way, even with the right key.
        let mut req = request(&dir, &key, &roster, &node);
        req.roster = serde_json::to_string(&roster)
            .unwrap()
            .replace("\"level\":1", "\"level\":0");
        assert_eq!(req.install()["error"], "roster_unverified");
        assert!(!dir.join(POLICY_FILE).exists());
    }

    #[test]
    fn a_different_pinned_key_needs_the_old_keys_signature() {
        let (key, roster, node) = fleet();
        let dir = temp_dir("push-reanchor");
        let old = fleet_key();
        std::fs::write(
            dir.join(POLICY_FILE),
            json!({"version":1,"mesh":{"version":1,"roster_key":old.public_key}}).to_string(),
        )
        .unwrap();
        let mut req = request(&dir, &key, &roster, &node);
        // Without a signature: refused, and the file is untouched (no silent re-anchoring).
        let answer = req.install();
        assert_eq!(answer["error"], "roster_pins_different_key", "{answer}");
        let untouched: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join(POLICY_FILE)).unwrap()).unwrap();
        assert_eq!(untouched["mesh"]["roster_key"], old.public_key);
        // A signature by the wrong key is refused.
        let message = format!("{ANCHOR_DOMAIN}|{}|{}", key.public_key, roster.fingerprint());
        req.replace_key_signature = Some(key.sign(&message));
        assert_eq!(req.install()["error"], "roster_replace_key_unverified");
        // The old key's signature re-anchors it.
        req.replace_key_signature = Some(old.sign(&message));
        let answer = req.install();
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["previous_key"], old.public_key);
        let merged: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join(POLICY_FILE)).unwrap()).unwrap();
        assert_eq!(merged["mesh"]["roster_key"], key.public_key);
    }

    #[test]
    fn a_policy_that_cannot_be_read_is_not_overwritten() {
        let (key, roster, node) = fleet();
        let dir = temp_dir("push-unreadable");
        std::fs::write(dir.join(POLICY_FILE), "{not json").unwrap();
        assert_eq!(request(&dir, &key, &roster, &node).install()["error"], "policy_unreadable");
        assert_eq!(std::fs::read_to_string(dir.join(POLICY_FILE)).unwrap(), "{not json");
        // A `mesh` section that is not an object is refused too, rather than replaced.
        std::fs::write(dir.join(POLICY_FILE), json!({"version":1,"mesh":"yes"}).to_string()).unwrap();
        assert_eq!(request(&dir, &key, &roster, &node).install()["error"], "policy_unreadable");
    }

    #[test]
    fn a_roster_without_the_target_in_it_is_refused() {
        let (key, roster, _) = fleet();
        let dir = temp_dir("push-missing-target");
        let other = Member::new("elsewhere", 0, &[]);
        assert_eq!(
            request(&dir, &key, &roster, &other).install()["error"],
            "roster_missing_target"
        );
        assert!(!dir.join(POLICY_FILE).exists());
    }

    #[test]
    fn a_second_push_is_idempotent_and_keeps_one_backup() {
        let (key, roster, node) = fleet();
        let dir = temp_dir("push-twice");
        assert_eq!(request(&dir, &key, &roster, &node).install()["ok"], true);
        let first = std::fs::read_to_string(dir.join(POLICY_FILE)).unwrap();
        assert_eq!(request(&dir, &key, &roster, &node).install()["ok"], true);
        let second = std::fs::read_to_string(dir.join(POLICY_FILE)).unwrap();
        assert_eq!(first, second);
        assert!(dir.join(POLICY_BACKUP).exists());
    }

    /// The push is what makes the mesh live on a *running* node, so the `mesh` section it writes has
    /// to be the whole statement: on, the roster, and the port. The port comes from the roster's own
    /// address for the target — the only "where this node answers" a relayed push carries — and a
    /// target the roster gives no address keeps whatever its policy says (never a guessed port).
    #[test]
    fn a_push_persists_the_port_the_roster_gives_the_target() {
        let key = fleet_key();
        let node = Member::new("nextcloud", 1, &["192.168.1.10:8891", "nextcloud.example.net:8892"]);
        let roster = Draft {
            fleet: "ohana".into(),
            issued_at: crate::wire::now_seconds().saturating_sub(60),
            expires_at: 0,
            nodes: vec![node.node.clone()],
        }
        .sign(&key);
        assert_eq!(listener_port(&roster, &node.node.node_id), Some(8891), "the first address wins");
        let dir = temp_dir("push-port");
        let answer = request(&dir, &key, &roster, &node).install();
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["port"], 8891);
        let merged: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join(POLICY_FILE)).unwrap()).unwrap();
        assert_eq!(merged["mesh"]["port"], 8891);
        assert_eq!(merged["mesh"]["enabled"], true);
        // A typed port on the request (a caller that can send one) wins over the derived one.
        let dir = temp_dir("push-port-explicit");
        let mut req = request(&dir, &key, &roster, &node);
        req.port = Some(8893);
        assert_eq!(req.install()["port"], 8893);
        let merged: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join(POLICY_FILE)).unwrap()).unwrap();
        assert_eq!(merged["mesh"]["port"], 8893);

        // No address for the target: roster admission is enabled, no listener is promised, and the
        // port a target already had is not removed.
        let quiet = Member::new("quiet", 1, &[]);
        let quiet_roster = Draft {
            fleet: "ohana".into(),
            issued_at: crate::wire::now_seconds().saturating_sub(60),
            expires_at: 0,
            nodes: vec![quiet.node.clone()],
        }
        .sign(&key);
        assert_eq!(listener_port(&quiet_roster, &quiet.node.node_id), None);
        let dir = temp_dir("push-no-port");
        std::fs::write(
            dir.join(POLICY_FILE),
            json!({"version":1,"mesh":{"version":1,"port":8894}}).to_string(),
        )
        .unwrap();
        let answer = request(&dir, &key, &quiet_roster, &quiet).install();
        assert_eq!(answer["ok"], true, "{answer}");
        assert_eq!(answer["port"], Value::Null);
        let merged: Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join(POLICY_FILE)).unwrap()).unwrap();
        assert_eq!(merged["mesh"]["port"], 8894, "an existing port is not removed");
    }
}
