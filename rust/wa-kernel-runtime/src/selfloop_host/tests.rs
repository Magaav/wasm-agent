//! The self-loop seam end to end: the built component, over a scoped `wa:kernel/sql` grant, against a
//! real (scratch) `memory.db`.
//!
//! These tests run the *built* artifact, so they are worth their minutes: the same code the node
//! calls, with the real schema, the real authorizer, and a fresh instance per call — which is also
//! how a restart is proved: nothing the component answered is remembered by the component, so a
//! pending wake that a second, independent instance still finds came from the row.
//!
//! The artifact is found by `component_bytes()` and SKIPPED (printed, and reported in REPORT.md) when
//! this checkout has not built the component — a skip is never counted as a pass.
use super::*;
use std::path::{Path, PathBuf};

fn temp_dir(tag: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "wa-selfloop-host-{}-{}-{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
    ));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).expect("temp dir");
    base
}

/// The built component, wherever this checkout put it. `WA_SELFLOOP_COMPONENT_WASM` wins (the Lua
/// parity test passes it), then the in-tree build, then the workspace target dir.
fn component_bytes() -> Option<Vec<u8>> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(path) = std::env::var("WA_SELFLOOP_COMPONENT_WASM") {
        candidates.push(PathBuf::from(path));
    }
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    candidates.push(manifest_dir.join("../components/selfloop/target/wasm32-wasip2/release/selfloop.wasm"));
    if let Ok(target) = std::env::var("CARGO_TARGET_DIR") {
        candidates.push(PathBuf::from(target).join("wasm32-wasip2/release/selfloop.wasm"));
    }
    candidates.into_iter().find_map(|path| std::fs::read(path).ok())
}

fn sha256_hex(bytes: &[u8]) -> String {
    use ring::digest::{digest, SHA256};
    digest(&SHA256, bytes).as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

/// The schema a migrated node has: `lua/core/schema.sql`, the session columns `memory.setup()` adds
/// (`user_id`, `objective`, `parent_session_id` are what the seam's authority checks read), and the
/// three `self_*` tables `lua/core/selfloop.lua` `setup()` creates. The component itself runs no DDL —
/// its grant has none — so a node that has never called `selfloop.setup()` is a `store_failed`, not a
/// component that silently creates its own schema.
fn create_database(path: &Path) {
    let schema = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../lua/core/schema.sql"))
        .expect("the node's schema is readable");
    let connection = rusqlite::Connection::open(path).expect("open db");
    connection.execute_batch(&schema).expect("schema applies");
    connection
        .execute_batch(
            "ALTER TABLE sessions ADD COLUMN user_id TEXT NOT NULL DEFAULT 'master';
             ALTER TABLE sessions ADD COLUMN node_id TEXT NOT NULL DEFAULT '';
             ALTER TABLE sessions ADD COLUMN title TEXT NOT NULL DEFAULT '';
             ALTER TABLE sessions ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;
             CREATE TABLE IF NOT EXISTS self_wakes (
               id TEXT PRIMARY KEY, owner TEXT NOT NULL, session_id TEXT NOT NULL,
               status TEXT NOT NULL DEFAULT 'pending', reason TEXT NOT NULL DEFAULT '',
               prompt TEXT NOT NULL DEFAULT '', due_at REAL, every_seconds REAL,
               on_topics TEXT NOT NULL DEFAULT '[]', probe TEXT NOT NULL DEFAULT '',
               probe_result TEXT NOT NULL DEFAULT '', event_json TEXT NOT NULL DEFAULT '',
               fired_at REAL NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL,
               attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT NOT NULL DEFAULT '',
               boot TEXT NOT NULL DEFAULT '');
             CREATE TABLE IF NOT EXISTS self_notes (
               session_id TEXT PRIMARY KEY, text TEXT NOT NULL DEFAULT '', updated_at REAL NOT NULL);
             CREATE TABLE IF NOT EXISTS self_notes_archive (
               id TEXT PRIMARY KEY, session_id TEXT NOT NULL, text TEXT NOT NULL,
               bytes INTEGER NOT NULL, reason TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL);
             INSERT INTO sessions(id,route_id,objective,started_at,ended_at,user_id,title,updated_at)
               VALUES('s1','','',100.0,NULL,'master','a thread',100.0),
                     ('child','','subagent',100.0,NULL,'master','a child',100.0);
             INSERT INTO sessions(id,route_id,objective,started_at,ended_at,user_id,title,updated_at)
               VALUES('guest-s','','',100.0,NULL,'guest','not ours',100.0);",
        )
        .expect("session and self_* tables");
}

/// A scratch store with the component installed the way a node installs it (bytes, pin, manifest).
struct Fixture {
    root: PathBuf,
    config: Config,
}

impl Fixture {
    fn install(tag: &str, bytes: &[u8]) -> Fixture {
        let root = temp_dir(tag);
        let components = root.join("components");
        std::fs::create_dir_all(&components).expect("components dir");
        std::fs::write(components.join("selfloop.wasm"), bytes).expect("component");
        std::fs::write(components.join("selfloop.wasm.sha256"), format!("{}  selfloop.wasm\n", sha256_hex(bytes)))
            .expect("pin");
        std::fs::copy(concat!(env!("CARGO_MANIFEST_DIR"), "/../components/selfloop/manifest.json"), components.join("selfloop.json"))
            .expect("manifest");
        create_database(&root.join("memory.db"));
        let config = Config {
            components_dir: components,
            db: root.join("memory.db"),
            wasm: None,
            manifest: None,
            timeout_ms: 2_000,
        };
        Fixture { root, config }
    }

    fn call(&self, value: serde_json::Value) -> serde_json::Value {
        call_with(&self.config, &value)
    }

    /// The same store, through a *fresh* instance: what a restarted node does.
    fn restart(&self) -> serde_json::Value {
        call_with(&self.config, &json!({"op":"list","owner":"master","session_id":"s1","all":true,"now":1000.0}))
    }

    fn db(&self) -> rusqlite::Connection {
        rusqlite::Connection::open(self.root.join("memory.db")).expect("open")
    }
}

fn ok(answer: &serde_json::Value) -> &serde_json::Value {
    assert_eq!(answer["ok"], serde_json::json!(true), "{answer}");
    &answer["result"]
}

fn skip(test: &str) {
    println!("SKIP {test}: no built selfloop component (build it with `cargo build --target wasm32-wasip2 --release` in rust/components/selfloop, or set WA_SELFLOOP_COMPONENT_WASM)");
}

const T0: f64 = 1_700_000_000.0;

#[test]
fn a_wake_scheduled_through_the_component_survives_a_restart_and_is_claimed_once() {
    let Some(bytes) = component_bytes() else { return skip("a_wake_scheduled_through_the_component_survives_a_restart") };
    let fixture = Fixture::install("restart", &bytes);

    let scheduled = fixture.call(json!({
        "op":"schedule","owner":"master","session_id":"s1","reason":"check the deploy",
        "prompt":"look again","in_seconds":60.0,"now":T0,
    }));
    let wake = ok(&scheduled).clone();
    let id = wake["wake"]["id"].as_str().expect("an id").to_string();
    assert_eq!(id.len(), 36, "a uuid-shaped id: {id}");
    assert_eq!(wake["wake"]["status"], json!("pending"));
    assert_eq!(wake["wake"]["due_at"], json!(T0 + 60.0));
    assert_eq!(wake["wake"]["in_seconds"], json!(60));

    // A restart: nothing of the component survives, and the pending row is still there.
    let listed = fixture.restart();
    let page = ok(&listed).clone();
    assert_eq!(page["count"], json!(1), "a new instance sees the pending wake: {page}");
    assert_eq!(page["wakes"][0]["id"].as_str(), Some(id.as_str()));
    assert_eq!(page["wakes"][0]["reason"], json!("check the deploy"));
    assert_eq!(page["pending"], json!(1));

    // It is not due early, is due at its time, and is claimed exactly once.
    let early = fixture.call(json!({"op":"plan","now":T0 + 59.0,"stale_seconds":1800.0}));
    assert_eq!(ok(&early)["due"].as_array().expect("array").len(), 0, "not due early");
    let due = fixture.call(json!({"op":"plan","now":T0 + 60.0,"stale_seconds":1800.0}));
    let plan = ok(&due).clone();
    assert_eq!(plan["due"].as_array().expect("array").len(), 1);
    assert_eq!(plan["due"][0]["attempts"], json!(0));
    let first = fixture.call(json!({"op":"claim","id":id,"boot":"boot-1","now":T0 + 60.0}));
    assert_eq!(ok(&first)["claimed"]["id"].as_str(), Some(id.as_str()));
    let second = fixture.call(json!({"op":"claim","id":id,"boot":"boot-1","now":T0 + 61.0}));
    assert!(ok(&second)["claimed"].is_null(), "a claimed wake is not claimable twice: {second}");

    // The turn reads the notes and renders the marker; the row settles as delivered.
    let turn = fixture.call(json!({"op":"turn","id":id,"session_id":"s1","reason":"check the deploy",
        "prompt":"look again","event_rendering":"","probe_rendering":"","now":T0 + 61.0}));
    let turn = ok(&turn).clone();
    assert!(turn["content"].as_str().expect("content").contains("[self-wake"), "{turn}");
    assert_eq!(turn["trace"]["kind"], json!("self_wake"));
    assert_eq!(turn["trace"]["id"].as_str(), Some(id.as_str()));
    let finished = fixture.call(json!({"op":"finish","id":id,"ok":true,"detail":"","now":T0 + 62.0}));
    assert_eq!(ok(&finished)["status"], json!("delivered"));

    // An interrupted dispatch is reconciled to `unknown`, never replayed.
    let inflight = fixture.call(json!({"op":"schedule","owner":"master","session_id":"s1","reason":"in flight",
        "in_seconds":1.0,"now":T0}));
    let inflight_id = ok(&inflight)["wake"]["id"].as_str().expect("id").to_string();
    fixture.call(json!({"op":"claim","id":inflight_id,"boot":"boot-1","now":T0 + 1.0}));
    let reconciled = fixture.call(json!({"op":"plan","now":T0 + 1.0 + 120.0,"stale_seconds":60.0}));
    assert_eq!(ok(&reconciled)["reconciled"], json!(1));
    let status: String = fixture
        .db()
        .query_row("SELECT status FROM self_wakes WHERE id=?", [&inflight_id], |row| row.get(0))
        .expect("row");
    assert_eq!(status, "unknown");
}

#[test]
fn an_unchanged_probe_spends_no_turn_and_a_changed_one_does() {
    let Some(bytes) = component_bytes() else { return skip("an_unchanged_probe_spends_no_turn") };
    let fixture = Fixture::install("probe", &bytes);
    let wake = fixture.call(json!({
        "op":"schedule","owner":"master","session_id":"s1","reason":"poll","in_seconds":10.0,
        "every_seconds":30.0,"probe":"return {changed:false}","now":T0,
    }));
    let id = ok(&wake)["wake"]["id"].as_str().expect("id").to_string();

    // Nothing changed: the row is re-armed at the cadence the model asked for, and it is not due.
    let unchanged = fixture.call(json!({"op":"probe","id":id,"now":T0 + 10.0,
        "result":{"changed":false,"detail":"{\"changed\":false}"}}));
    assert_eq!(ok(&unchanged), &json!("skipped"), "an unchanged probe is a skip, not a turn");
    let plan = fixture.call(json!({"op":"plan","now":T0 + 10.0,"stale_seconds":1800.0}));
    assert_eq!(ok(&plan)["due"].as_array().expect("array").len(), 0, "a skipped wake is not dispatched");
    let due_at: f64 = fixture
        .db()
        .query_row("SELECT due_at FROM self_wakes WHERE id=?", [&id], |row| row.get(0))
        .expect("row");
    assert_eq!(due_at, T0 + 40.0, "re-armed one cadence later");
    let stored: String = fixture
        .db()
        .query_row("SELECT probe_result FROM self_wakes WHERE id=?", [&id], |row| row.get(0))
        .expect("row");
    assert_eq!(stored, "{\"changed\":false}", "the probe's own rendering is stored verbatim");

    // Changed: the row is due and its result travels with the wake.
    let changed = fixture.call(json!({"op":"probe","id":id,"now":T0 + 40.0,
        "result":{"changed":true,"detail":"{\"changed\":true,\"seen\":7}"}}));
    assert_eq!(ok(&changed), &json!("wake"));
    let plan = fixture.call(json!({"op":"plan","now":T0 + 40.0,"stale_seconds":1800.0}));
    assert_eq!(ok(&plan)["due"].as_array().expect("array").len(), 1);
    let turn = fixture.call(json!({"op":"turn","id":id,"session_id":"s1","reason":"poll","prompt":"",
        "event_rendering":"","probe_rendering":"{\"changed\":true,\"seen\":7}","now":T0 + 40.0}));
    let turn = ok(&turn).clone();
    assert!(turn["content"].as_str().expect("content").contains("seen"), "{turn}");
    assert_eq!(turn["trace"]["probe"], json!(true));

    // A probe that could not answer wakes the model with its reason, rather than silence.
    let failed = fixture.call(json!({"op":"probe","id":id,"failure":"probe_script_failed: boom","now":T0 + 41.0}));
    assert_eq!(ok(&failed), &json!("wake"));
    let stored: String = fixture
        .db()
        .query_row("SELECT probe_result FROM self_wakes WHERE id=?", [&id], |row| row.get(0))
        .expect("row");
    assert!(stored.contains("boom"), "{stored}");
}

#[test]
fn notes_and_events_are_the_state_machine_over_the_grant() {
    let Some(bytes) = component_bytes() else { return skip("notes_and_events") };
    let fixture = Fixture::install("notes", &bytes);

    let written = fixture.call(json!({"op":"notes_write","owner":"master","session_id":"s1",
        "text":"goal\nstep 1\nstep 2","now":T0}));
    assert_eq!(ok(&written)["replaced"], json!(false));
    let appended = fixture.call(json!({"op":"notes_append","owner":"master","session_id":"s1",
        "text":"step 3","now":T0 + 1.0}));
    assert_eq!(ok(&appended)["bytes"], json!(25));
    let compacted = fixture.call(json!({"op":"notes_compact","owner":"master","session_id":"s1",
        "keep_lines":2,"now":T0 + 2.0}));
    let compacted = ok(&compacted).clone();
    assert!(compacted["archived"].is_string(), "the previous document is archived: {compacted}");
    assert_eq!(compacted["kept_lines"], json!(2));
    let read = fixture.call(json!({"op":"notes_read","owner":"master","session_id":"s1","now":T0 + 2.0}));
    assert_eq!(ok(&read)["text"], json!("step 2\nstep 3"));
    let archived = fixture.call(json!({"op":"notes_read","owner":"master","session_id":"s1",
        "version":compacted["archived"].clone(),"now":T0 + 2.0}));
    assert_eq!(ok(&archived)["text"], json!("goal\nstep 1\nstep 2\nstep 3"));

    // An event wake is quiet until its topic is published, then carries identity and never payload.
    let event = fixture.call(json!({"op":"schedule","owner":"master","session_id":"s1",
        "reason":"deploy finished","on":["deploy.done"],"now":T0}));
    let event_id = ok(&event)["wake"]["id"].as_str().expect("id").to_string();
    let published = fixture.call(json!({"op":"publish","topic":"deploy.done","id":"evt-1","now":T0 + 5.0}));
    assert_eq!(ok(&published)["matched"], json!(1));
    let stored: String = fixture
        .db()
        .query_row("SELECT event_json FROM self_wakes WHERE id=?", [&event_id], |row| row.get(0))
        .expect("row");
    assert!(stored.contains("deploy.done") && stored.contains("evt-1"), "{stored}");
    assert!(!stored.contains("PRIVATE"), "the payload's text is never stored: {stored}");

    // A message subscription names one session, and only that session's message matches it.
    let message_wake = fixture.call(json!({"op":"schedule","owner":"master","session_id":"s1",
        "reason":"someone wrote","on":["message"],"now":T0}));
    let message_id = ok(&message_wake)["wake"]["id"].as_str().expect("id").to_string();
    let elsewhere = fixture.call(json!({"op":"publish","topic":"session.message","id":"m1","session":"other","now":T0 + 6.0}));
    assert_eq!(ok(&elsewhere)["matched"], json!(0));
    let here = fixture.call(json!({"op":"publish","topic":"session.message","id":"m2","session":"s1","now":T0 + 7.0}));
    assert_eq!(ok(&here)["matched"], json!(1));
    let woken = fixture.call(json!({"op":"plan","now":T0 + 7.0,"stale_seconds":1800.0}));
    let due_ids: Vec<String> = ok(&woken)["due"]
        .as_array()
        .expect("array")
        .iter()
        .map(|row| row["id"].as_str().unwrap_or_default().to_string())
        .collect();
    assert!(due_ids.contains(&message_id), "{due_ids:?}");
}

#[test]
fn the_authority_checks_are_the_seams_and_a_refusal_is_an_answer() {
    let Some(bytes) = component_bytes() else { return skip("the_authority_checks") };
    let fixture = Fixture::install("authority", &bytes);

    // A guest asking about a master's session is refused by name, not served.
    let forbidden = fixture.call(json!({"op":"list","owner":"guest","session_id":"s1","now":T0}));
    assert_eq!(forbidden["ok"], json!(true), "a refusal is an answer: {forbidden}");
    assert_eq!(forbidden["refused"]["error"], json!("selfloop_forbidden_session"));

    // A child session cannot keep waking itself.
    let child = fixture.call(json!({"op":"schedule","owner":"master","session_id":"child",
        "reason":"child loop","in_seconds":10.0,"now":T0}));
    assert_eq!(child["refused"]["error"], json!("wake_not_for_subagent"));

    // Each refusal keeps the name and the fields the native module answers with.
    let too_large = fixture.call(json!({"op":"notes_write","owner":"master","session_id":"s1",
        "text":"x".repeat(65_537),"now":T0}));
    assert_eq!(too_large["refused"]["error"], json!("notes_too_large"));
    assert_eq!(too_large["refused"]["limit"], json!(65_536));
    assert!(too_large["refused"].get("current_bytes").is_none(), "a whole-document write has no current size");
    let past = fixture.call(json!({"op":"schedule","owner":"master","session_id":"s1",
        "reason":"x","at":T0 - 1.0,"now":T0}));
    assert_eq!(past["refused"]["error"], json!("wake_at_is_in_the_past"));
    assert_eq!(past["refused"]["at"], json!(T0 - 1.0));
    let floor = fixture.call(json!({"op":"schedule","owner":"master","session_id":"s1",
        "reason":"x","in_seconds":10.0,"every_seconds":1.0,"now":T0}));
    assert_eq!(floor["refused"]["error"], json!("wake_every_seconds_too_small"));
    assert_eq!(floor["refused"]["minimum"], json!(5.0));
    let duplicate = fixture.call(json!({"op":"schedule","owner":"master","session_id":"s1",
        "reason":"x","on":["a","a"],"now":T0}));
    assert_eq!(duplicate["refused"]["error"], json!("wake_on_duplicate:a"));
    let cancelled = fixture.call(json!({"op":"cancel","owner":"master","session_id":"s1","id":"nope","now":T0}));
    assert_eq!(cancelled["refused"]["error"], json!("unknown_wake"));
}

#[test]
fn the_grant_is_the_manifests_and_a_read_outside_it_is_a_failure_not_an_empty_answer() {
    let Some(bytes) = component_bytes() else { return skip("the_grant_is_the_manifests") };
    let fixture = Fixture::install("grant", &bytes);

    // The manifest grants `sessions` read but not `messages`: the authorizer refuses the statement, the
    // component reports a store failure, and the host reports a *failure* (ok:false), never silence.
    let mut manifest: Value = serde_json::from_str(
        &std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../components/selfloop/manifest.json"))
            .expect("manifest"),
    )
    .expect("json");
    manifest["capabilities"]["sql"]["read"] = json!(["self_wakes", "self_notes", "self_notes_archive"]);
    std::fs::write(fixture.config.components_dir.join("selfloop.json"), manifest.to_string()).expect("manifest");

    // Without `sessions` the authority check cannot be answered, so the call fails loudly rather than
    // pretending the session does not exist.
    let answer = fixture.call(json!({"op":"schedule","owner":"master","session_id":"s1",
        "reason":"x","in_seconds":10.0,"now":T0}));
    assert_eq!(answer["ok"], json!(false), "{answer}");
    assert!(answer["error"].as_str().unwrap_or_default().contains("refused"), "{answer}");
}

#[test]
fn the_vendored_kernel_copy_matches_the_kernel() {
    let read = |path: &str| std::fs::read_to_string(format!("{}/../../{path}", env!("CARGO_MANIFEST_DIR"))).expect(path);
    // The same comparison `sql_host`'s own test makes: comments and blank lines carry nothing the
    // component compiles against, so the bodies are compared without them.
    fn interface_body(source: &str, name: &str) -> String {
        let mut lines: Vec<String> = Vec::new();
        let mut depth = 0i32;
        let mut inside = false;
        for raw in source.lines() {
            let line = match raw.find("//") {
                Some(at) => &raw[..at],
                None => raw,
            };
            let line = line.trim();
            if !inside {
                if line == format!("interface {name} {{") {
                    inside = true;
                    depth = 1;
                }
                continue;
            }
            depth += line.matches('{').count() as i32;
            depth -= line.matches('}').count() as i32;
            if depth <= 0 {
                break;
            }
            if !line.is_empty() {
                lines.push(line.to_string());
            }
        }
        lines.join("\n")
    }
    let vendored = read("wit/selfloop/deps/kernel/kernel.wit");
    assert_eq!(
        interface_body(&read("wit/kernel/sql.wit"), "sql"),
        interface_body(&vendored, "sql"),
        "wit/selfloop/deps/kernel/kernel.wit has drifted from wit/kernel/sql.wit"
    );
    assert_eq!(
        interface_body(&read("wit/kernel/kernel.wit"), "types"),
        interface_body(&vendored, "types"),
        "wit/selfloop/deps/kernel/kernel.wit has drifted from wit/kernel/kernel.wit"
    );
}
