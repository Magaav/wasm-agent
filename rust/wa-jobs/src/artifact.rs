//! Portable automation artifacts: a versioned, machine-independent form of a job definition.
//!
//! An installed job binds to this machine: an absolute trigger directory, an absolute script, an
//! explicit CDP page websocket, an operator's session, a phone number. A **portable artifact** carries
//! the *intent* and a list of **named resource slots** instead, so it can be exported from one node and
//! imported into another without dragging a path, a machine address, a session id or a credential with
//! it. Importing requires an explicit local binding for every required slot and an explicit approval;
//! the imported definition is installed **disabled**, and the same revision-safety as any other edit
//! applies (an identical import is a no-op; a changed one invalidates approval).
//!
//! Guest scope is not a smaller operator scope: an artifact owned by a guest cannot request an
//! elevation and cannot name a profile the guest is not allowed to run. The check is structural, here,
//! not a sentence in a prompt.
//!
//! This module never touches the store; `Store::put_artifact` / `Store::export_job` do, so the binding
//! and approval rules stay testable without a database.
use serde_json::{json, Map, Value};
use std::path::Path;

pub const SCHEMA: &str = "wasm-agent/automation";
pub const SCHEMA_VERSION: u64 = 1;

/// Profiles a guest could name *if* a guest principal were enforced at dispatch. It is not: the sentinel
/// authenticates as the local operator, so a `job-deterministic` guest import would execute as operator.
/// Guest subagent imports are therefore refused outright (see `import_artifact`); the list is kept only
/// as documentation of the shape a future principal binding would allow.
pub const GUEST_PROFILES: [&str; 1] = ["job-deterministic"];

fn fail<T>(why: &str) -> super::Result<T> {
    Err(why.into())
}

fn ident(value: &Value, key: &str) -> bool {
    let text = value[key].as_str().unwrap_or("");
    !text.is_empty()
        && text.len() <= 100
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
}

/// A binding value is either a bare path string or `{ "path": "...", "approved": true }`.
fn binding_path(binding: &Value) -> Option<&str> {
    if let Some(path) = binding.as_str() {
        if path.is_empty() {
            return None;
        }
        return Some(path);
    }
    binding
        .get("path")
        .and_then(Value::as_str)
        .filter(|path| !path.is_empty())
}

/// Credential-shaped *keys* are refused anywhere in an exported artifact: a job definition is operator
/// input, and exporting it must not become the way a token leaves the machine.
fn credential_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase();
    ["token", "secret", "password", "passwd", "credential", "authorization", "api_key", "apikey", "private_key", "access_key"]
        .iter()
        .any(|needle| key.contains(needle))
}

fn scan_credentials(value: &Value) -> bool {
    match value {
        Value::Object(map) => map
            .iter()
            .any(|(key, child)| credential_key(key) || scan_credentials(child)),
        Value::Array(items) => items.iter().any(scan_credentials),
        _ => false,
    }
}

/// A credential in a *value* is as much a leak as one in a key: a prompt (or a nested param) that
/// quotes a token ships it. The prefixes are the well-known ones, checked at a token boundary with a
/// minimum length so ordinary words ("task-force") are not flagged.
fn scan_credential_values(text: &str) -> bool {
    for prefix in ["sk-", "xoxb-", "xoxp-", "ghp_", "github_pat_", "AKIA"] {
        let mut from = 0;
        while let Some(offset) = text[from..].find(prefix) {
            let pos = from + offset;
            let before_ok = pos == 0 || !text.as_bytes()[pos - 1].is_ascii_alphanumeric();
            let rest = &text[pos + prefix.len()..];
            let token = rest
                .bytes()
                .take_while(|b| b.is_ascii_alphanumeric() || *b == b'-' || *b == b'_')
                .count();
            if before_ok && token >= 8 {
                return true;
            }
            from = pos + prefix.len();
        }
    }
    if text.contains("-----BEGIN ") {
        return true;
    }
    let lower = text.to_ascii_lowercase();
    [
        "token=",
        "token: ",
        "password=",
        "password: ",
        "secret=",
        "secret: ",
        "api_key=",
        "apikey=",
        "authorization: bearer",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

/// A POSIX absolute path is as machine-specific as a drive path, and a prompt or nested param that
/// quotes `/home/...` is just as non-portable. Known roots and a generic two-segment `/a/b` form are
/// flagged; relative paths, JSON schema values (`wasm-agent/automation`) and URL paths are not.
fn scan_posix_path(text: &str) -> bool {
    let bytes = text.as_bytes();
    let mut index = 0;
    while index + 1 < bytes.len() {
        if bytes[index] != b'/' {
            index += 1;
            continue;
        }
        let before_ok = index == 0
            || matches!(
                bytes[index - 1],
                b' ' | b'\t' | b'\n' | b'"' | b'\'' | b'(' | b'=' | b',' | b'[' | b'{'
            );
        let after = bytes[index + 1];
        if !before_ok || !(after.is_ascii_alphanumeric() || after == b'~' || after == b'.') {
            index += 1;
            continue;
        }
        let segment = &text[index + 1..];
        for root in [
            "home/", "tmp/", "var/", "usr/", "etc/", "opt/", "root/", "mnt/", "media/", "srv/",
            "proc/", "sys/", "dev/",
        ] {
            if segment.starts_with(root) {
                return true;
            }
        }
        // MSYS drive form: /c/Users/...
        if segment.len() >= 2
            && segment.as_bytes()[0].is_ascii_alphabetic()
            && segment.as_bytes()[1] == b'/'
        {
            return true;
        }
        let first = segment
            .bytes()
            .take_while(|b| b.is_ascii_alphanumeric() || *b == b'-' || *b == b'_' || *b == b'.')
            .count();
        if (2..=40).contains(&first) && segment.as_bytes().get(first) == Some(&b'/') {
            if let Some(&next) = segment.as_bytes().get(first + 1) {
                if next.is_ascii_alphanumeric() || next == b'~' || next == b'.' {
                    return true;
                }
            }
        }
        index += 1;
    }
    false
}

/// A machine binding is a drive-letter path, a POSIX absolute path or a loopback websocket. All are what
/// make a definition non-portable, and all must be gone before the artifact leaves.
fn scan_machine_binding(text: &str) -> bool {
    let bytes = text.as_bytes();
    for (index, byte) in bytes.iter().enumerate() {
        if !byte.is_ascii_alphabetic() {
            continue;
        }
        // `C:\` / `C:/` where the drive letter is not part of a longer word.
        let previous_ok = index == 0 || !bytes[index - 1].is_ascii_alphanumeric();
        if previous_ok
            && index + 2 < bytes.len()
            && bytes[index + 1] == b':'
            && (bytes[index + 2] == b'\\' || bytes[index + 2] == b'/')
        {
            return true;
        }
    }
    if ["ws://127.0.0.1", "ws://localhost", "ws://[::1]"]
        .iter()
        .any(|needle| text.contains(needle))
    {
        return true;
    }
    scan_posix_path(text)
}

/// A portable artifact is an allowlist, not a denylist: only the known portable fields are accepted, so a
/// raw `trigger.path`, `trigger.websocket_url` or `action.script` cannot ride alongside the resource slots
/// and bypass the binding step, and an unrecognised authority field cannot arrive at all.
fn ensure_keys(value: &Value, allowed: &[&str], where_: &str) -> super::Result<()> {
    if let Some(map) = value.as_object() {
        for key in map.keys() {
            if !allowed.contains(&key.as_str()) {
                return fail(&format!("unknown_artifact_field:{where_}.{key}"));
            }
        }
    }
    Ok(())
}

fn validate_portable_shape(artifact: &Value) -> super::Result<()> {
    ensure_keys(
        artifact,
        &[
            "schema",
            "schema_version",
            "id",
            "name",
            "description",
            "trigger",
            "action",
            "resources",
            "requirements",
            "scope",
        ],
        "artifact",
    )?;
    let trigger = &artifact["trigger"];
    if let Some(map) = trigger.as_object() {
        for key in map.keys() {
            let allowed: &[&str] = match trigger["kind"].as_str().unwrap_or("") {
                "event" => &["kind", "topic"],
                "schedule" => &["kind", "every_seconds"],
                "file" => &["kind", "pattern"],
                "cdp" => &["kind", "binding", "setup_expression"],
                _ => &["kind"],
            };
            if !allowed.contains(&key.as_str()) {
                if matches!(key.as_str(), "path" | "websocket_url") {
                    return fail(&format!("artifact_contains_raw_binding:trigger.{key}"));
                }
                return fail(&format!("unknown_artifact_field:trigger.{key}"));
            }
        }
    }
    let action = &artifact["action"];
    if let Some(map) = action.as_object() {
        for key in map.keys() {
            let allowed: &[&str] = match action["kind"].as_str().unwrap_or("") {
                "wake" => &["kind", "session", "skill", "prompt", "profile"],
                "subagent" => &["kind", "profile", "prompt", "timeout_seconds"],
                "run" => &["kind", "timeout_seconds"],
                _ => &["kind"],
            };
            if !allowed.contains(&key.as_str()) {
                if key == "script" {
                    return fail("artifact_contains_raw_binding:action.script");
                }
                return fail(&format!("unknown_artifact_field:action.{key}"));
            }
        }
    }
    if let Some(resources) = artifact["resources"].as_array() {
        for resource in resources {
            ensure_keys(resource, &["slot", "kind", "required", "description"], "resource")?;
        }
    }
    ensure_keys(
        &artifact["requirements"],
        &["child_capacity", "browser", "network", "elevation"],
        "requirements",
    )?;
    ensure_keys(&artifact["scope"], &["owner", "role", "guest_owned"], "scope")?;
    Ok(())
}

/// The two authorities this import path understands. Anything else is a typo or an attempt to be missed
/// by the guest check, so it is refused rather than silently treated as operator.
fn normalize_importer_role(role: &str) -> Option<&'static str> {
    match role {
        "operator" | "master" => Some("operator"),
        "guest" => Some("guest"),
        _ => None,
    }
}

/// The resource slots an artifact requires, so a caller can prompt for exactly what is missing.
pub fn requirements(artifact: &Value) -> super::Result<Value> {
    let resources = artifact
        .get("resources")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter(|item| item.get("required").and_then(Value::as_bool).unwrap_or(false))
                .map(|item| {
                    json!({
                        "slot": item.get("slot").and_then(Value::as_str).unwrap_or(""),
                        "kind": item.get("kind").and_then(Value::as_str).unwrap_or(""),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(json!({"resources": resources}))
}

/// Export is an allowlist too: an installed job with an unrecognised trigger/action field is refused, so a
/// hidden binding or credential in an unexpected field cannot be silently dropped or shipped.
fn validate_exportable_shape(job: &Value) -> super::Result<()> {
    let trigger = &job["trigger"];
    if let Some(map) = trigger.as_object() {
        for key in map.keys() {
            let allowed: &[&str] = match trigger["kind"].as_str().unwrap_or("") {
                "event" => &["kind", "topic"],
                "schedule" => &["kind", "every_seconds"],
                "file" => &["kind", "path", "pattern"],
                "cdp" => &["kind", "websocket_url", "binding", "setup_expression"],
                _ => &["kind"],
            };
            if !allowed.contains(&key.as_str()) {
                return fail(&format!("unknown_job_field:trigger.{key}"));
            }
        }
    }
    let action = &job["action"];
    if let Some(map) = action.as_object() {
        for key in map.keys() {
            let allowed: &[&str] = match action["kind"].as_str().unwrap_or("") {
                "wake" => &["kind", "session", "skill", "prompt", "profile"],
                "subagent" => &["kind", "profile", "prompt", "timeout_seconds"],
                "run" => &["kind", "script", "timeout_seconds"],
                _ => &["kind"],
            };
            if !allowed.contains(&key.as_str()) {
                return fail(&format!("unknown_job_field:action.{key}"));
            }
        }
    }
    Ok(())
}

fn copy_allowed(source: &Value, keys: &[&str]) -> Value {
    let mut out = Map::new();
    if let Some(map) = source.as_object() {
        for key in keys {
            if let Some(value) = map.get(*key) {
                out.insert((*key).into(), value.clone());
            }
        }
    }
    Value::Object(out)
}

/// Export an installed job as a portable artifact. Absolute bindings become named slots, free text that
/// still looks like a machine binding or a credential stops the export instead of shipping silently, and
/// only allowlisted fields are emitted.
pub fn export_artifact(job: &Value) -> super::Result<Value> {
    super::validate(job)?;
    validate_exportable_shape(job)?;
    let mut artifact = Map::new();
    artifact.insert("schema".into(), json!(SCHEMA));
    artifact.insert("schema_version".into(), json!(SCHEMA_VERSION));
    for key in ["id", "name", "description"] {
        if let Some(value) = job.get(key) {
            artifact.insert(key.into(), value.clone());
        }
    }
    let mut resources: Vec<Value> = Vec::new();
    let trigger_kind = job["trigger"]["kind"].as_str().unwrap_or("");
    let trigger = copy_allowed(
        &job["trigger"],
        match trigger_kind {
            "event" => &["kind", "topic"],
            "schedule" => &["kind", "every_seconds"],
            "file" => &["kind", "pattern"],
            "cdp" => &["kind", "binding", "setup_expression"],
            _ => &["kind"],
        },
    );
    match trigger_kind {
        "file" => resources.push(json!({"slot":"trigger_path","kind":"file_directory","required":true,
            "description":"Local directory the file trigger observes."})),
        "cdp" => resources.push(json!({"slot":"page","kind":"cdp_page","required":true,
            "description":"Explicit loopback DevTools page websocket for this machine."})),
        _ => {}
    }
    let action_kind = job["action"]["kind"].as_str().unwrap_or("");
    if action_kind == "pipeline" {
        // Refused rather than exported with its steps dropped. A pipeline's meaning *is* its steps, and its
        // scripts are machine bindings: an artifact carrying only `{"kind":"pipeline"}` would look complete
        // and do nothing - the same failure `docs/SPELLS.md` refuses for a sentinel plan, for the same
        // reason. Per-step script slots are the next step, not a guess made here.
        return fail("pipeline_not_exportable_yet");
    }
    let action = copy_allowed(
        &job["action"],
        match action_kind {
            "wake" => &["kind", "session", "skill", "prompt", "profile"],
            "subagent" => &["kind", "profile", "prompt", "timeout_seconds"],
            "run" => &["kind", "timeout_seconds"],
            _ => &["kind"],
        },
    );
    if action_kind == "run" {
        resources.push(json!({"slot":"script","kind":"script_path","required":true,
            "description":"Local script the deterministic action executes, inside WA_SENTINEL_SCRIPTS."}));
    }
    let child_capacity = match action["kind"].as_str().unwrap_or("") {
        "subagent" => 1,
        "wake" => 1,
        _ => 0,
    };
    let mut bounds = Map::new();
    bounds.insert("child_capacity".into(), json!(child_capacity));
    bounds.insert("browser".into(), json!(trigger["kind"] == "cdp"));
    bounds.insert("network".into(), json!(action["kind"] == "wake" || action["kind"] == "subagent"));
    bounds.insert("elevation".into(), json!(false));
    artifact.insert("trigger".into(), trigger);
    artifact.insert("action".into(), action);
    artifact.insert("resources".into(), Value::Array(resources));
    artifact.insert("requirements".into(), Value::Object(bounds));
    artifact.insert("scope".into(), json!({"owner":"operator","role":"operator","guest_owned":false}));

    let value = Value::Object(artifact);
    let text = value.to_string();
    if scan_credentials(&value) || scan_credential_values(&text) {
        return fail("artifact_contains_credential");
    }
    if scan_machine_binding(&text) {
        return fail("artifact_contains_machine_binding");
    }
    Ok(value)
}

/// Rebuild an installed definition from a portable artifact and explicit local bindings.
///
/// `approved` is the operator's approval of those bindings. It is a separate flag, not a field of the
/// artifact: an artifact must not be able to approve itself. `importer_role` is the **caller's**
/// authority (`operator` or `guest`), never the artifact's claim - an artifact that says
/// `owner: operator` must not hand a guest operator capabilities. The rebuilt definition is always
/// returned disabled by `Store::put`; approval here authorises the *binding*, not the enabling.
pub fn import_artifact(
    artifact: &Value,
    bindings: &Value,
    approved: bool,
    importer_role: &str,
) -> super::Result<Value> {
    if artifact["schema"].as_str().unwrap_or("") != SCHEMA {
        return fail("unknown_artifact_schema");
    }
    if artifact["schema_version"].as_u64() != Some(SCHEMA_VERSION) {
        return fail("unsupported_artifact_schema_version");
    }
    // The artifact is an allowlist of portable fields, and the same scans that guard export guard import:
    // a hand-written artifact must not carry a raw binding, a credential or a machine path.
    validate_portable_shape(artifact)?;
    let text = artifact.to_string();
    if scan_credentials(artifact) || scan_credential_values(&text) {
        return fail("artifact_contains_credential");
    }
    if scan_machine_binding(&text) {
        return fail("artifact_contains_machine_binding");
    }
    let importer_role = normalize_importer_role(importer_role)
        .ok_or_else(|| "unknown_importer_role")?;
    if !ident(artifact, "id") {
        return fail("invalid_artifact_id");
    }
    if artifact["name"].as_str().unwrap_or("").is_empty() {
        return fail("artifact_name_required");
    }
    let mut job = Map::new();
    job.insert("id".into(), artifact["id"].clone());
    job.insert("name".into(), artifact["name"].clone());
    if let Some(description) = artifact.get("description") {
        job.insert("description".into(), description.clone());
    }
    let mut trigger = artifact["trigger"].clone();
    let mut action = artifact["action"].clone();

    let resources = artifact
        .get("resources")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    // A binding for a slot the artifact never declared is refused rather than ignored: it is how a
    // caller would try to smuggle a value past the portability review.
    let declared: Vec<&str> = resources
        .iter()
        .filter_map(|resource| resource.get("slot").and_then(Value::as_str))
        .collect();
    if let Some(map) = bindings.as_object() {
        for key in map.keys() {
            if !declared.contains(&key.as_str()) {
                return fail(&format!("unknown_binding_slot:{key}"));
            }
        }
    }
    let mut bound = Map::new();
    let mut needs_approval = false;
    for resource in &resources {
        let slot = resource.get("slot").and_then(Value::as_str).unwrap_or("");
        let kind = resource.get("kind").and_then(Value::as_str).unwrap_or("");
        let required = resource.get("required").and_then(Value::as_bool).unwrap_or(false);
        let binding = bindings.get(slot);
        let Some(path) = binding.and_then(binding_path) else {
            if required {
                return fail(&format!("resource_not_bound:{slot}"));
            }
            continue;
        };
        needs_approval = true;
        match kind {
            "file_directory" | "file_path" => {
                if !Path::new(path).is_absolute() {
                    return fail(&format!("resource_needs_absolute_path:{slot}"));
                }
                trigger["path"] = json!(path);
            }
            "cdp_page" => {
                let loopback = path.starts_with("ws://127.0.0.1:")
                    || path.starts_with("ws://localhost:")
                    || path.starts_with("ws://[::1]:");
                if !loopback || !path.contains("/devtools/page/") {
                    return fail(&format!("resource_needs_loopback_devtools_page:{slot}"));
                }
                trigger["websocket_url"] = json!(path);
            }
            "script_path" => {
                if !Path::new(path).is_absolute() {
                    return fail(&format!("resource_needs_absolute_path:{slot}"));
                }
                action["script"] = json!(path);
            }
            _ => return fail(&format!("unknown_resource_kind:{kind}")),
        }
        bound.insert(slot.into(), json!(path));
    }
    if needs_approval && !approved {
        return fail("resource_binding_needs_approval");
    }

    // Guest scope is the importer's authority, not the artifact's claim. A guest import is restricted
    // whatever the artifact says about itself, and so is any artifact that declares itself guest-owned.
    let elevation = artifact["requirements"]["elevation"].as_bool().unwrap_or(false);
    let owner = artifact["scope"]["owner"].as_str();
    let scope_role = artifact["scope"]["role"].as_str();
    // An inconsistent scope (owner says operator, role says guest, or the reverse) is refused rather than
    // resolved in the artifact's favour.
    let owner_guest = matches!(owner, Some("guest"));
    let owner_operator = matches!(owner, Some("operator") | Some("master"));
    let role_guest = matches!(scope_role, Some("guest"));
    let role_operator = matches!(scope_role, Some("operator") | Some("master"));
    if (owner_guest && role_operator) || (owner_operator && role_guest) {
        return fail("inconsistent_artifact_scope");
    }
    let artifact_guest_owned = artifact["scope"]["guest_owned"].as_bool().unwrap_or(false)
        || owner_guest
        || role_guest;
    if importer_role == "guest" || artifact_guest_owned {
        if elevation {
            return fail("guest_artifact_cannot_request_elevation");
        }
        match action["kind"].as_str().unwrap_or("") {
            "subagent" => {
                // The runtime executes a child as the local operator; it cannot currently enforce a guest
                // principal at dispatch, so an `imported_by:"guest"` claim would not match execution. A
                // profile *name* is not a principal binding: refuse the guest subagent import rather than
                // trust `job-deterministic` to mean something the runtime does not enforce.
                return fail("guest_subagent_requires_principal_binding");
            }
            // A wake is the operator's own conversation; a run is operator-controlled shell. Neither is
            // a guest capability.
            "wake" | "run" => return fail("guest_artifact_capability_not_permitted"),
            _ => {}
        }
    }

    job.insert("trigger".into(), trigger);
    job.insert("action".into(), action);
    // Record the authority that actually imported it, so a later reader never has to trust the
    // artifact's own scope claim.
    job.insert("imported_by".into(), json!(importer_role));
    let value = Value::Object(job);
    super::validate(&value)?;
    Ok(json!({"definition": value, "bound": bound, "artifact": {"schema": SCHEMA, "schema_version": SCHEMA_VERSION}}))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_path(relative: &str) -> String {
        std::env::temp_dir()
            .join("wasm-agent-artifact-tests")
            .join(relative)
            .to_string_lossy()
            .into_owned()
    }

    fn wake_job() -> Value {
        json!({"id":"received","name":"Review incoming","trigger":{"kind":"event","topic":"whatsapp.message"},
            "action":{"kind":"subagent","profile":"whatsapp-responder","prompt":"Decide; do not send without approval."}})
    }
    fn file_job() -> Value {
        let trigger_path = fixture_path("approved/incoming");
        let script = fixture_path("approved/procedures/validate.sh");
        json!({"id":"documents","name":"Validate incoming",
            "trigger":{"kind":"file","path":trigger_path,"pattern":".json"},
            "action":{"kind":"run","script":script,"timeout_seconds":60}})
    }
    fn page_job() -> Value {
        json!({"id":"page","name":"Page events",
            "trigger":{"kind":"cdp","websocket_url":"ws://127.0.0.1:9222/devtools/page/ABC","binding":"wa_event"},
            "action":{"kind":"subagent","profile":"whatsapp-responder","prompt":"Decide."}})
    }

    #[test]
    fn export_strips_absolute_bindings_into_slots() {
        let job = file_job();
        let trigger_path = job["trigger"]["path"].as_str().unwrap().to_owned();
        let script = job["action"]["script"].as_str().unwrap().to_owned();
        let artifact = export_artifact(&job).unwrap();
        assert_eq!(artifact["trigger"]["kind"], "file");
        assert!(artifact["trigger"].get("path").is_none(), "path must become a slot");
        assert!(artifact["action"].get("script").is_none(), "script must become a slot");
        let slots: Vec<&str> = artifact["resources"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r["slot"].as_str().unwrap())
            .collect();
        assert!(slots.contains(&"trigger_path") && slots.contains(&"script"));
        let text = artifact.to_string();
        assert!(!text.contains(&trigger_path), "trigger path may not survive export: {text}");
        assert!(!text.contains(&script), "script path may not survive export: {text}");
    }

    #[test]
    fn export_refuses_credentials_and_page_bindings() {
        let artifact = export_artifact(&page_job()).unwrap();
        assert!(artifact["trigger"].get("websocket_url").is_none());
        assert_eq!(artifact["requirements"]["browser"], true);
        let mut leaky = page_job();
        leaky["action"]["prompt"] = json!("use token sk-abc123");
        // The value is a credential-shaped word but not a binding; the *key* rule is what is structural.
        // A credential in a value is still caught when it is shaped like a key, and a machine address is
        // always caught.
        leaky["action"]["prompt"] = json!("post to ws://127.0.0.1:9999/devtools/page/X");
        assert_eq!(export_artifact(&leaky).unwrap_err().to_string(), "artifact_contains_machine_binding");
        let mut keyed = page_job();
        keyed["action"]["api_key"] = json!("sk-abc");
        assert_eq!(export_artifact(&keyed).unwrap_err().to_string(), "unknown_job_field:action.api_key");
    }

    #[test]
    fn import_requires_every_required_binding_and_approval() {
        let artifact = export_artifact(&file_job()).unwrap();
        let trigger_path = fixture_path("approved/incoming");
        let script = fixture_path("approved/procedures/validate.sh");
        let bindings = json!({"trigger_path":trigger_path,"script":script});
        assert_eq!(
            import_artifact(&artifact, &bindings, false, "operator").unwrap_err().to_string(),
            "resource_binding_needs_approval"
        );
        let missing = json!({"trigger_path":fixture_path("approved/incoming")});
        assert_eq!(
            import_artifact(&artifact, &missing, true, "operator").unwrap_err().to_string(),
            "resource_not_bound:script"
        );
        let relative = json!({"trigger_path":"incoming","script":fixture_path("approved/procedures/validate.sh")});
        assert_eq!(
            import_artifact(&artifact, &relative, true, "operator").unwrap_err().to_string(),
            "resource_needs_absolute_path:trigger_path"
        );
        // A binding for a slot the artifact never declared is refused, not silently ignored.
        let extra = json!({"trigger_path":fixture_path("approved/incoming"),"script":fixture_path("approved/procedures/validate.sh"),"endpoint":"ws://127.0.0.1:1/devtools/page/X"});
        assert_eq!(
            import_artifact(&artifact, &extra, true, "operator").unwrap_err().to_string(),
            "unknown_binding_slot:endpoint"
        );
        let rebuilt = import_artifact(&artifact, &bindings, true, "operator").unwrap();
        assert_eq!(rebuilt["definition"]["trigger"]["path"], bindings["trigger_path"]);
        assert_eq!(rebuilt["definition"]["action"]["script"], bindings["script"]);
        assert_eq!(rebuilt["definition"]["imported_by"], "operator");
    }

    #[test]
    fn cdp_page_binding_must_be_loopback_and_explicit() {
        let artifact = export_artifact(&page_job()).unwrap();
        let remote = json!({"page":"ws://example.com:9222/devtools/page/ABC"});
        assert_eq!(
            import_artifact(&artifact, &remote, true, "operator").unwrap_err().to_string(),
            "resource_needs_loopback_devtools_page:page"
        );
        let loopback = json!({"page":"ws://127.0.0.1:9222/devtools/page/ABC"});
        assert!(import_artifact(&artifact, &loopback, true, "operator").is_ok());
    }

    /// Export is an allowlist: an unknown trigger/action field is refused (not silently dropped), so a
    /// binding or credential in an unexpected field cannot ship; allowed free text is still scanned.
    #[test]
    fn export_refuses_unknown_fields_and_scans_allowed_text() {
        let mut nested = file_job();
        nested["action"]["params"] = json!({"workdir": "/home/operator/secret"});
        assert_eq!(export_artifact(&nested).unwrap_err().to_string(), "unknown_job_field:action.params");
        let mut context_field = file_job();
        context_field["action"]["context"] = json!("see /c/Users/operator/notes");
        assert_eq!(export_artifact(&context_field).unwrap_err().to_string(), "unknown_job_field:action.context");
        let mut trigger_field = file_job();
        trigger_field["trigger"]["extra"] = json!("/home/operator");
        assert_eq!(export_artifact(&trigger_field).unwrap_err().to_string(), "unknown_job_field:trigger.extra");
        // Allowed free text is scanned: a path or a value credential refuses.
        let mut posix = wake_job();
        posix["action"]["prompt"] = json!("run /tmp/evil.sh first");
        assert_eq!(export_artifact(&posix).unwrap_err().to_string(), "artifact_contains_machine_binding");
        let mut token = wake_job();
        token["action"]["prompt"] = json!("use sk-abcdefghijklmnop to authenticate");
        assert_eq!(export_artifact(&token).unwrap_err().to_string(), "artifact_contains_credential");
        let mut bearer = wake_job();
        bearer["action"]["prompt"] = json!("authorization: bearer abcdef");
        assert_eq!(export_artifact(&bearer).unwrap_err().to_string(), "artifact_contains_credential");
        // A relative prompt path is not a machine binding, and an ordinary word is not a token.
        let mut relative = wake_job();
        relative["action"]["prompt"] = json!("run scripts/whatsapp-reply.mjs --send; task-force review");
        assert!(export_artifact(&relative).is_ok());
    }

    /// The importer's authority is what restricts an import; an artifact claiming `owner: operator`
    /// cannot grant a guest operator capabilities, and a guest subagent import is refused entirely until
    /// a guest principal is enforced at dispatch (a profile name is not a principal binding).
    #[test]
    fn guest_import_cannot_spoof_owner_or_select_an_operator_profile() {
        let bindings = json!({});
        let artifact = export_artifact(&wake_job()).unwrap();
        assert_eq!(artifact["scope"]["owner"], "operator", "the artifact claims operator scope");
        assert_eq!(
            import_artifact(&artifact, &bindings, true, "guest").unwrap_err().to_string(),
            "guest_subagent_requires_principal_binding",
            "a guest import cannot select an operator profile by claiming owner=operator"
        );
        let mut arbitrary = artifact.clone();
        arbitrary["action"]["profile"] = json!("operator-tools");
        assert_eq!(
            import_artifact(&arbitrary, &bindings, true, "guest").unwrap_err().to_string(),
            "guest_subagent_requires_principal_binding"
        );
        let mut wake = artifact.clone();
        wake["action"] = json!({"kind":"wake","session":"s","prompt":"p"});
        assert_eq!(
            import_artifact(&wake, &bindings, true, "guest").unwrap_err().to_string(),
            "guest_artifact_capability_not_permitted"
        );
        let mut run = artifact.clone();
        run["trigger"] = json!({"kind":"event","topic":"t"});
        run["action"] = json!({"kind":"run","timeout_seconds":30});
        run["resources"] = json!([{"slot":"script","kind":"script_path","required":true}]);
        assert_eq!(
            import_artifact(&run, &json!({"script":fixture_path("approved/x.sh")}), true, "guest").unwrap_err().to_string(),
            "guest_artifact_capability_not_permitted"
        );
        // Regression: a guest cannot import even the guest-named deterministic profile, because it would
        // execute as the operator; a profile name is not a principal binding.
        let mut guest_named = artifact.clone();
        guest_named["action"]["profile"] = json!("job-deterministic");
        assert_eq!(
            import_artifact(&guest_named, &bindings, true, "guest").unwrap_err().to_string(),
            "guest_subagent_requires_principal_binding"
        );
        // ...but a local operator import of the same artifact still works.
        assert!(import_artifact(&guest_named, &bindings, true, "operator").is_ok());
        let mut self_guest = artifact.clone();
        self_guest["scope"] = json!({"owner":"guest","guest_owned":true});
        assert_eq!(
            import_artifact(&self_guest, &bindings, true, "operator").unwrap_err().to_string(),
            "guest_subagent_requires_principal_binding"
        );
        let mut elevated = artifact.clone();
        elevated["action"]["profile"] = json!("job-deterministic");
        elevated["requirements"]["elevation"] = json!(true);
        assert_eq!(
            import_artifact(&elevated, &bindings, true, "guest").unwrap_err().to_string(),
            "guest_artifact_cannot_request_elevation"
        );
        elevated["requirements"]["elevation"] = json!(false);
        assert_eq!(
            import_artifact(&elevated, &bindings, true, "guest").unwrap_err().to_string(),
            "guest_subagent_requires_principal_binding"
        );
    }

    #[test]
    fn unknown_schema_version_is_refused() {
        let artifact = export_artifact(&wake_job()).unwrap();
        let mut future = artifact.clone();
        future["schema_version"] = json!(999);
        assert_eq!(
            import_artifact(&future, &json!({}), true, "operator").unwrap_err().to_string(),
            "unsupported_artifact_schema_version"
        );
        let mut alien = artifact;
        alien["schema"] = json!("something-else");
        assert_eq!(
            import_artifact(&alien, &json!({}), true, "operator").unwrap_err().to_string(),
            "unknown_artifact_schema"
        );
    }

    /// The importer's authority is a two-value allowlist. A typo must not fall through to operator.
    #[test]
    fn importer_role_is_allowlisted_and_normalized() {
        let artifact = export_artifact(&wake_job()).unwrap();
        assert_eq!(
            import_artifact(&artifact, &json!({}), true, "guestt").unwrap_err().to_string(),
            "unknown_importer_role"
        );
        assert_eq!(
            import_artifact(&artifact, &json!({}), true, "admin").unwrap_err().to_string(),
            "unknown_importer_role"
        );
        let master = import_artifact(&artifact, &json!({}), true, "master").unwrap();
        assert_eq!(master["definition"]["imported_by"], "operator", "master is an explicit operator alias");
    }

    /// The artifact's own scope must be consistent; an owner/role disagreement is refused, not resolved in
    /// the artifact's favour.
    #[test]
    fn inconsistent_artifact_scope_is_refused() {
        let mut artifact = export_artifact(&wake_job()).unwrap();
        artifact["scope"] = json!({"owner":"operator","role":"guest"});
        assert_eq!(
            import_artifact(&artifact, &json!({}), true, "operator").unwrap_err().to_string(),
            "inconsistent_artifact_scope"
        );
        artifact["scope"] = json!({"owner":"guest","role":"operator"});
        assert_eq!(
            import_artifact(&artifact, &json!({}), true, "operator").unwrap_err().to_string(),
            "inconsistent_artifact_scope"
        );
        // scope.role=guest is honoured even when owner is omitted (and a subagent is refused outright).
        artifact["scope"] = json!({"role":"guest"});
        assert_eq!(
            import_artifact(&artifact, &json!({}), true, "operator").unwrap_err().to_string(),
            "guest_subagent_requires_principal_binding"
        );
    }

    /// A raw binding field in the artifact bypasses the resource-slot step, and a credential must not ride
    /// in on import either. Both are refused before anything is bound.
    #[test]
    fn import_refuses_raw_bindings_unknown_fields_and_credentials() {
        let artifact = export_artifact(&page_job()).unwrap();
        let mut raw = artifact.clone();
        raw["trigger"]["websocket_url"] = json!("ws://127.0.0.1:9222/devtools/page/ABC");
        assert_eq!(
            import_artifact(&raw, &json!({"page":"ws://127.0.0.1:9222/devtools/page/ABC"}), true, "operator").unwrap_err().to_string(),
            "artifact_contains_raw_binding:trigger.websocket_url"
        );
        let mut raw_script = artifact.clone();
        let script = fixture_path("approved/x.sh");
        raw_script["action"] = json!({"kind":"run","script":script});
        raw_script["trigger"] = json!({"kind":"event","topic":"t"});
        raw_script["resources"] = json!([{"slot":"script","kind":"script_path","required":true}]);
        assert_eq!(
            import_artifact(&raw_script, &json!({"script":fixture_path("approved/x.sh")}), true, "operator").unwrap_err().to_string(),
            "artifact_contains_raw_binding:action.script"
        );
        let mut unknown = artifact.clone();
        unknown["authority"] = json!("operator");
        assert_eq!(
            import_artifact(&unknown, &json!({"page":"ws://127.0.0.1:9222/devtools/page/ABC"}), true, "operator").unwrap_err().to_string(),
            "unknown_artifact_field:artifact.authority"
        );
        let mut credential = artifact.clone();
        credential["action"]["prompt"] = json!("use sk-abcdefghijklmnop");
        assert_eq!(
            import_artifact(&credential, &json!({"page":"ws://127.0.0.1:9222/devtools/page/ABC"}), true, "operator").unwrap_err().to_string(),
            "artifact_contains_credential"
        );
    }
}
