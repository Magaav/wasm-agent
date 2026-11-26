//! The provider's rolling limits, read by the host program on its own thread.
//!
//! `/status` used to read them with `host.http` from inside the interpreter, which is fine between
//! runs and impossible mid-run: the interpreter is inside the turn, so opening the panel mid-run had
//! nothing to draw and told the reader to come back later. This module is the one door that reads
//! them instead:
//!
//! - `start(provider, url)` answers AT ONCE (`state: "loading"`) and does the GET on a thread of its
//!   own. No path here blocks a caller, so a turn never waits for the panel's numbers.
//! - `poll(provider)` answers what the thread has: `loading`, `ready` with the usage object and its
//!   age, or `failed` with a line naming why.
//! - The last reading is kept per provider on disk (`~/.wasm-agent/cache/limits/<provider>.json`), so
//!   a new session's first /status draws the bars with their age while the fresh read loads.
//!
//! The credential never passes through this module's callers: Lua names the provider and the URL, and
//! this side resolves what to send - the vault's placeholder while `WASM_AGENT_VAULT_URL` is set (so
//! the key stays in the vault, as it always does for a vaulted node), or the process's own provider
//! key when it is not. Nothing here writes a credential, and no error message carries one.
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use serde_json::{json, Value};

/// A `/usage` read is a small request; eight seconds is generous for it and short enough that the
/// panel's line says "timeout" while the reader is still looking at it.
pub const READ_TIMEOUT_SECONDS: u64 = 8;

/// The window a reading is considered fresh for. The panel asks for a refresh past it; the door
/// itself only refuses to start a second read while one is in flight.
pub const FRESH_SECONDS: u64 = 30;

#[derive(Clone, Default)]
struct Slot {
    loading: bool,
    usage: Option<Value>,
    error: Option<String>,
    /// When the reading in `usage` was taken (epoch seconds).
    at: Option<u64>,
}

fn slots() -> &'static Mutex<HashMap<String, Slot>> {
    static SLOTS: OnceLock<Mutex<HashMap<String, Slot>>> = OnceLock::new();
    SLOTS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Start a read (or report the one already in flight). Never blocks: the network work is on its own
/// thread, and its only side effect is the slot and the cache file.
pub fn start(provider: &str, url: &str) -> Value {
    start_with(provider, url, read_usage)
}

fn start_with(provider: &str, url: &str, fetch: impl Fn(&str) -> Result<Value, String> + Send + 'static) -> Value {
    let mut held = slots().lock().unwrap_or_else(|e| e.into_inner());
    let slot = held.entry(provider.to_string()).or_default();
    if slot.loading {
        return view(provider, slot);
    }
    // A new slot starts from the last reading on disk: a session that never opened the panel still
    // has something to draw, with its age.
    if slot.usage.is_none() && slot.at.is_none() {
        if let Some((at, usage)) = load_cache(provider) {
            slot.usage = Some(usage);
            slot.at = Some(at);
        }
    }
    slot.loading = true;
    slot.error = None;
    let answer = view(provider, slot);
    drop(held);

    let provider = provider.to_string();
    let url = url.to_string();
    std::thread::Builder::new()
        .name(format!("limits-read-{provider}"))
        .spawn(move || {
            let outcome = fetch(&url);
            let mut map = slots().lock().unwrap_or_else(|e| e.into_inner());
            let slot = map.entry(provider.clone()).or_default();
            slot.loading = false;
            match outcome {
                Ok(usage) => {
                    let at = now();
                    save_cache(&provider, at, &usage);
                    slot.usage = Some(usage);
                    slot.at = Some(at);
                    slot.error = None;
                }
                Err(error) => slot.error = Some(error),
            }
        })
        .ok();
    answer
}

/// What the door has for one provider, without starting anything.
pub fn poll(provider: &str) -> Value {
    let slots = slots().lock().unwrap_or_else(|e| e.into_inner());
    match slots.get(provider) {
        Some(slot) => view(provider, slot),
        None => {
            // Never asked: the disk's last reading is still the honest answer.
            match load_cache(provider) {
                Some((at, usage)) => json!({
                    "state": "ready",
                    "usage": usage,
                    "age_s": now().saturating_sub(at),
                }),
                None => json!({ "state": "none" }),
            }
        }
    }
}

/// Drop what this process holds for a provider (a failed read is retried on the next start).
pub fn forget(provider: &str) {
    slots().lock().unwrap_or_else(|e| e.into_inner()).remove(provider);
}

fn view(provider: &str, slot: &Slot) -> Value {
    let _ = provider;
    if slot.loading {
        let mut value = json!({ "state": "loading" });
        // A refresh over a reading we already have still draws the bars, with their age.
        if let (Some(usage), Some(at)) = (&slot.usage, slot.at) {
            value["usage"] = usage.clone();
            value["age_s"] = json!(now().saturating_sub(at));
        }
        return value;
    }
    match (&slot.usage, &slot.error) {
        (Some(usage), _) => json!({
            "state": "ready",
            "usage": usage,
            "age_s": slot.at.map(|at| now().saturating_sub(at)).unwrap_or(0),
        }),
        (None, Some(error)) => json!({ "state": "failed", "error": error }),
        (None, None) => json!({ "state": "none" }),
    }
}

/// One `GET <url>/usage`, with the same headers the model call sends. The answer is the `usage`
/// object itself (the three windows the panel draws), never the envelope around it.
pub fn read_usage(url: &str) -> Result<Value, String> {
    let url = url.trim_end_matches('/').to_string() + "/usage";
    let credential = credential().ok_or_else(|| "no provider credential in this process".to_string())?;
    let agent = crate::host::limits_agent(&url).map_err(|error| format!("could not build the client: {error}"))?;
    let request = agent
        .get(&url)
        .header("Authorization", format!("Bearer {credential}"))
        .header("Accept", "application/json")
        .header("User-Agent", "wasm-agent/0.1 provider-proxy");
    let response = request.call().map_err(|error| {
        // ureq's own words are the useful ones ("timeout", "connection refused"); the URL is not a
        // secret and the credential is never in this string.
        let text = error.to_string();
        if text.to_lowercase().contains("timeout") {
            format!("the provider didn't answer (timeout {READ_TIMEOUT_SECONDS} s)")
        } else {
            format!("the provider didn't answer ({text})")
        }
    })?;
    let status = response.status().as_u16();
    if status != 200 {
        return Err(format!("the provider answered HTTP {status}"));
    }
    let text = response.into_body().read_to_string().map_err(|error| format!("the answer was cut: {error}"))?;
    let payload: Value = serde_json::from_str(&text).map_err(|_| "the provider answered something that is not JSON".to_string())?;
    payload
        .get("usage")
        .filter(|usage| usage.is_object())
        .cloned()
        .ok_or_else(|| "the provider answered without a usage object".to_string())
}

/// What to send as the credential: the vault's placeholder when this node is vaulted (the key never
/// reaches this process, exactly as for a model call), else the process's own provider key.
fn credential() -> Option<String> {
    let vaulted = std::env::var_os("WASM_AGENT_VAULT_URL").is_some()
        || std::env::var_os("WASM_AGENT_OPENCODE_GO_VAULT_URL").is_some();
    if vaulted {
        return Some("wa-vault-brokered".to_string());
    }
    ["WASM_AGENT_LLM_API_KEY", "OPENCODE_GO_API_KEY", "OPENAI_API_KEY"]
        .iter()
        .find_map(|name| std::env::var(name).ok().filter(|value| !value.is_empty()))
}

fn cache_path(provider: &str) -> Option<std::path::PathBuf> {
    let safe: String = provider.chars().map(|ch| if ch.is_ascii_alphanumeric() || ch == '-' || ch == '_' { ch } else { '-' }).collect();
    let home = wa_host_support::paths::resolve_home();
    Some(std::path::PathBuf::from(home).join(".wasm-agent").join("cache").join("limits").join(format!("{safe}.json")))
}

fn load_cache(provider: &str) -> Option<(u64, Value)> {
    let path = cache_path(provider)?;
    let text = std::fs::read_to_string(path).ok()?;
    let value: Value = serde_json::from_str(&text).ok()?;
    let at = value.get("at").and_then(Value::as_u64)?;
    let usage = value.get("usage").filter(|usage| usage.is_object())?.clone();
    Some((at, usage))
}

fn save_cache(provider: &str, at: u64, usage: &Value) {
    let Some(path) = cache_path(provider) else { return };
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let body = json!({ "at": at, "usage": usage }).to_string();
    let _ = std::fs::write(path, body);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settle(provider: &str) {
        for _ in 0..200 {
            let value = poll(provider);
            if value["state"] != "loading" { return }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("the read never settled");
    }

    #[test]
    fn the_first_answer_is_loading_and_the_threads_answer_is_the_three_windows() {
        let name = format!("test-loading-{}", std::process::id());
        forget(&name);
        let usage = json!({"rolling": {"status": "ok", "percent": 12, "resetsAt": "2026-01-01T00:00:00Z"}});
        let started = start_with(&name, "http://unused.invalid/v1", move |_url| Ok(usage.clone()));
        assert_eq!(started["state"], "loading", "the door answers before the network does: {started}");
        settle(&name);
        let value = poll(&name);
        assert_eq!(value["state"], "ready");
        assert_eq!(value["usage"]["rolling"]["percent"], 12);
        assert!(value["age_s"].as_u64().is_some(), "a reading has an age");
        forget(&name);
    }

    #[test]
    fn a_failure_is_a_named_line_and_never_a_blank() {
        let name = format!("test-failure-{}", std::process::id());
        forget(&name);
        start_with(&name, "http://unused.invalid/v1", |_url| Err("the provider didn't answer (timeout 8 s)".to_string()));
        settle(&name);
        let value = poll(&name);
        assert_eq!(value["state"], "failed");
        assert!(value["error"].as_str().unwrap().contains("timeout 8 s"), "{value}");
        assert!(value.get("usage").is_none(), "a failure carries no stale bars");
        forget(&name);
    }

    #[test]
    fn a_slot_that_was_never_asked_reads_the_disk_and_a_fresh_start_does_not_double_read() {
        let name = format!("test-disk-{}", std::process::id());
        forget(&name);
        save_cache(&name, now(), &json!({"weekly": {"status": "ok", "percent": 3, "resetsAt": "x"}}));
        let value = poll(&name);
        assert_eq!(value["state"], "ready", "the disk answers before any read: {value}");
        assert_eq!(value["usage"]["weekly"]["percent"], 3);
        // The first start seeds from the disk and answers loading; a second start while it is in
        // flight does not start another read.
        let started = start_with(&name, "http://unused.invalid/v1", |_url| {
            std::thread::sleep(std::time::Duration::from_millis(200));
            Ok(json!({"monthly": {"status": "ok", "percent": 1, "resetsAt": "x"}}))
        });
        assert_eq!(started["state"], "loading");
        assert_eq!(started["usage"]["weekly"]["percent"], 3, "the last reading draws while the new one loads");
        let again = start_with(&name, "http://unused.invalid/v1", |_url| panic!("a second read must not start"));
        assert_eq!(again["state"], "loading");
        settle(&name);
        assert_eq!(poll(&name)["usage"]["monthly"]["percent"], 1);
        forget(&name);
        let _ = std::fs::remove_file(cache_path(&name).expect("a path"));
    }
}
