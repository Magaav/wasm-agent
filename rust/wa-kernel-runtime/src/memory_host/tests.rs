//! The memory seam end to end: the installed component, over a scoped `wa:kernel/sql` grant, against
//! a real `memory.db`.
//!
//! These tests run the *built* artifact, so they are worth their minutes: the same code the node
//! would call, with the real schema, the real authorizer and the real epoch deadline. The artifact is
//! found by `component_bytes()` and SKIPPED (printed, and reported in REPORT.md) when this checkout
//! has not built the component — a skip is never counted as a pass.
//!
//! Every test builds its own `Config`, so nothing here rewrites a process-wide variable and the tests
//! are safe beside the rest of the crate's tests (a test that sets `WA_COMPONENTS_DIR` runs alone for
//! everybody, which is why the seam does not).
use super::*;
use std::path::{Path, PathBuf};

fn temp_dir(tag: &str) -> PathBuf {
    let base = std::env::temp_dir().join(format!(
        "wa-memory-host-{}-{}-{}",
        tag,
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
    ));
    let _ = std::fs::remove_dir_all(&base);
    std::fs::create_dir_all(&base).expect("temp dir");
    base
}

/// The built component, wherever this checkout put it. `WA_MEMORY_COMPONENT_WASM` wins (the Lua test
/// passes it), then the in-tree build, then the workspace target dir.
fn component_bytes() -> Option<Vec<u8>> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(path) = std::env::var("WA_MEMORY_COMPONENT_WASM") {
        candidates.push(PathBuf::from(path));
    }
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    candidates.push(manifest_dir.join("../components/memory/target/wasm32-wasip2/release/memory.wasm"));
    if let Ok(target) = std::env::var("CARGO_TARGET_DIR") {
        candidates.push(PathBuf::from(target).join("wasm32-wasip2/release/memory.wasm"));
    }
    candidates.into_iter().find_map(|path| std::fs::read(path).ok())
}

fn sha256_hex(bytes: &[u8]) -> String {
    use ring::digest::{digest, SHA256};
    digest(&SHA256, bytes).as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

/// The schema a migrated node has: `lua/core/schema.sql` plus the session columns `memory.setup()`
/// adds (the seam reads `user_id`, `node_id`, `title` and `updated_at`).
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
             ALTER TABLE sessions ADD COLUMN mode TEXT NOT NULL DEFAULT 'default';
             ALTER TABLE sessions ADD COLUMN summary TEXT NOT NULL DEFAULT '';
             ALTER TABLE sessions ADD COLUMN summarized_until INTEGER NOT NULL DEFAULT 0;
             ALTER TABLE sessions ADD COLUMN updated_at REAL NOT NULL DEFAULT 0;
             ALTER TABLE sessions ADD COLUMN worktree TEXT NOT NULL DEFAULT '';
             ALTER TABLE sessions ADD COLUMN interrupted_at REAL;
             ALTER TABLE sessions ADD COLUMN changed_at REAL NOT NULL DEFAULT 0;",
        )
        .expect("session columns");
}

/// A scratch store with the component installed the way a node installs it (bytes, pin, manifest).
struct Fixture {
    root: PathBuf,
    config: Config,
}

impl Fixture {
    fn install(tag: &str, bytes: &[u8]) -> Fixture {
        Fixture::install_with(tag, bytes, concat!(env!("CARGO_MANIFEST_DIR"), "/../components/memory/manifest.json"))
    }

    /// The same install for a fixture whose manifest differs (the `memory-crash` fixture grants only
    /// what it uses, so the test proves the crash path is within a real grant). The manifest is
    /// installed under the *installed* name (`memory.json`), which is what `load_in` reads.
    fn install_with(tag: &str, bytes: &[u8], manifest: &str) -> Fixture {
        let root = temp_dir(tag);
        let components = root.join("components");
        std::fs::create_dir_all(&components).expect("components dir");
        std::fs::write(components.join("memory.wasm"), bytes).expect("component");
        std::fs::write(components.join("memory.wasm.sha256"), format!("{}  memory.wasm\n", sha256_hex(bytes))).expect("pin");
        std::fs::copy(manifest, components.join("memory.json")).expect("manifest");
        create_database(&root.join("memory.db"));
        let config = Config {
            components_dir: components,
            db: root.join("memory.db"),
            wasm: None,
            manifest: None,
            // Not a deadline test: a loaded CI machine must not turn "slow" into "wedged". The
            // measured table is asserted by `the_measured_deadlines_are_the_per_operation_table`
            // and against real timings by `scripts/bench-memory-component.sh`.
            timeout_ms: Some(30_000),
        };
        Fixture { root, config }
    }

    fn manifest_path(&self) -> PathBuf {
        self.config.components_dir.join("memory.json")
    }

    fn call(&self, value: serde_json::Value) -> serde_json::Value {
        call_with(&self.config, &value)
    }
}

fn ok(answer: &serde_json::Value) -> &serde_json::Value {
    assert_eq!(answer["ok"], serde_json::json!(true), "{answer}");
    &answer["result"]
}

fn skip(test: &str) {
    println!("SKIP {test}: no built memory component (build it with `cargo build --target wasm32-wasip2 --release` in rust/components/memory, or set WA_MEMORY_COMPONENT_WASM)");
}

#[test]
fn the_seam_answers_remember_recall_list_forget_over_the_scoped_grant() {
    let Some(bytes) = component_bytes() else { return skip("the_seam_answers_remember_recall_list_forget") };
    let fixture = Fixture::install("seam", &bytes);

    let first = ok(&fixture.call(json!({"op":"remember","content":"the deploy token lives in the vault","scope":"global","tags":["deploy"],"origin":"node-test"}))).clone();
    assert_eq!(first["written"], json!(true));
    let first_id = first["id"].as_str().expect("an id").to_string();
    assert_eq!(first_id.len(), 36, "a uuid-shaped id: {first_id}");

    // The same fact again is idempotent, and nothing is journalled.
    let repeat = ok(&fixture.call(json!({"op":"remember","content":"the deploy token lives in the vault","scope":"global","origin":"node-test"}))).clone();
    assert_eq!(repeat["written"], json!(false));
    assert_eq!(repeat["id"].as_str(), Some(first_id.as_str()));

    let second = ok(&fixture.call(json!({"op":"remember","content":"the vault rotates on Mondays","tags":[],"origin":"node-test"}))).clone();
    assert_eq!(second["written"], json!(true));

    let hits = ok(&fixture.call(json!({"op":"recall","text":"vault token","limit":10}))).clone();
    let rows = hits.as_array().expect("an array");
    assert!(!rows.is_empty(), "the FTS match finds the fact: {hits}");
    assert!(rows[0]["rank"].is_number(), "rank is the raw bm25: {hits}");

    let listed = ok(&fixture.call(json!({"op":"list","limit":10}))).clone();
    assert_eq!(listed.as_array().expect("an array").len(), 2);

    let forgotten = ok(&fixture.call(json!({"op":"forget","id":first_id,"origin":"node-test"}))).clone();
    assert_eq!(forgotten["retired"], json!(true));
    let after = ok(&fixture.call(json!({"op":"list","limit":10}))).clone();
    assert_eq!(after.as_array().expect("an array").len(), 1);
    let gone = ok(&fixture.call(json!({"op":"recall","text":"deploy token","limit":10}))).clone();
    let gone = gone.as_array().expect("an array");
    assert!(
        gone.iter().all(|row| !row["content"].as_str().unwrap_or_default().contains("deploy token lives")),
        "a forgotten fact is not recalled: {gone:?}"
    );

    // Both mutations are journalled with this node's origin, exactly as the native path does.
    let connection = rusqlite::Connection::open(fixture.root.join("memory.db")).expect("open");
    let entries: i64 = connection
        .query_row("SELECT COUNT(*) FROM journal WHERE kind='memory' AND origin='node-test'", [], |row| row.get(0))
        .expect("journal");
    assert_eq!(entries, 3, "two upserts and one delete");
}

#[test]
fn sessions_carry_the_derived_state_and_transcript_search_finds_a_message() {
    let Some(bytes) = component_bytes() else { return skip("sessions_carry_the_derived_state") };
    let fixture = Fixture::install("sessions", &bytes);
    let db = fixture.root.join("memory.db");
    {
        let connection = rusqlite::Connection::open(&db).expect("open");
        connection
            .execute_batch(
                "INSERT INTO sessions(id,route_id,objective,started_at,ended_at,user_id,title,updated_at) \
                 VALUES('s1','','',100.0,NULL,'master','a thread',100.0);
                 INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,ok,created_at,phase) \
                 VALUES('msg1','s1',1,'user','where is the vault','[]','','',1,101.0,''),
                       ('msg2','s1',2,'assistant','no idea','[]','','',0,102.0,'');
                 INSERT INTO messages_fts(content,session_id,message_id) VALUES('where is the vault','s1','msg1');",
            )
            .expect("fixture rows");
    }
    let sessions = ok(&fixture.call(json!({"op":"sessions","limit":10,"states":true}))).clone();
    let row = &sessions.as_array().expect("an array")[0];
    assert_eq!(row["id"], json!("s1"));
    assert_eq!(row["message_count"], json!(2));
    assert_eq!(row["state"], json!("failed"), "the last row is a failed assistant turn: {row}");
    assert_eq!(row["last_role"], json!("assistant"));
    assert!(row["last_trace"].is_null(), "a missing trace stays absent, not invented");

    let hits = ok(&fixture.call(json!({"op":"search_messages","text":"vault","limit":5}))).clone();
    let hit = &hits.as_array().expect("an array")[0];
    assert_eq!(hit["id"], json!("msg1"));
    assert_eq!(hit["user_id"], json!("master"));
    assert_eq!(hit["title"], json!("a thread"));
}

#[test]
fn retention_decides_and_never_deletes() {
    let Some(bytes) = component_bytes() else { return skip("retention_decides_and_never_deletes") };
    let fixture = Fixture::install("retention", &bytes);
    let connection = rusqlite::Connection::open(fixture.root.join("memory.db")).expect("open");
    connection
        .execute_batch(
            "INSERT INTO memories(id,scope,content,tags,source,created_at,updated_at,deleted_at,content_sha256) \
             VALUES('m1','global','old news','[]','user',1.0,1.0,2.0,'abc');",
        )
        .expect("a forgotten row");
    let plan = ok(&fixture.call(json!({"op":"retention","older_than_seconds":86400}))).clone();
    assert_eq!(plan["refused"], json!("retention_evidence_admission_required"));
    assert_eq!(plan["eligible"], json!(1));
    let left: i64 = connection.query_row("SELECT COUNT(*) FROM memories", [], |row| row.get(0)).expect("count");
    assert_eq!(left, 1, "a retention decision retires nothing");
}

#[test]
fn a_grant_with_no_tables_refuses_and_names_the_reason() {
    let Some(bytes) = component_bytes() else { return skip("a_grant_with_no_tables_refuses") };
    let fixture = Fixture::install("empty-grant", &bytes);
    std::fs::write(
        fixture.manifest_path(),
        json!({"name":"memory","kind":"memory","capabilities": {"sql": {"database": "memory"}}}).to_string(),
    )
    .expect("manifest");
    let answer = fixture.call(json!({"op":"list","limit":5}));
    assert_eq!(answer["ok"], json!(false), "{answer}");
    let error = answer["error"].as_str().expect("a reason");
    assert!(error.starts_with("sql_policy_refused:"), "{answer}");
}

#[test]
fn a_missing_component_is_a_named_failure_not_an_empty_store() {
    let root = temp_dir("missing");
    let config = Config {
        components_dir: root.join("components"),
        db: root.join("memory.db"),
        wasm: None,
        manifest: None,
        timeout_ms: None,
    };
    let answer = call_with(&config, &json!({"op":"recall","text":"anything"}));
    assert_eq!(answer["ok"], json!(false), "{answer}");
    assert!(answer["error"].as_str().unwrap_or_default().starts_with("component_unavailable:"), "{answer}");
}

#[test]
fn a_wedged_component_is_stopped_by_its_deadline_and_named() {
    let Some(wedge) = fixture_wasm("WA_MEMORY_WEDGE_COMPONENT_WASM", "memory-wedge") else { return skip("a_wedged_component_is_stopped_by_its_deadline") };
    let bytes = std::fs::read(&wedge).expect("the wedge fixture");
    let mut fixture = Fixture::install("wedge", &bytes);
    fixture.config.timeout_ms = Some(300);
    let started = std::time::Instant::now();
    let answer = fixture.call(json!({"op":"recall","text":"anything"}));
    let elapsed = started.elapsed();
    assert_eq!(answer["ok"], json!(false), "{answer}");
    let error = answer["error"].as_str().unwrap_or_default();
    assert!(error.starts_with("component_wedged:"), "{answer}");
    assert!(elapsed < std::time::Duration::from_secs(5), "the deadline stopped it: {elapsed:?}");
}

// ------------------------------------------------------------------------- the crash between the write
//                                                                           and the journal entry

/// A fixture component, wherever this checkout put it: the env var wins (the Lua/CI path), then the
/// in-tree build, then the workspace target dir. The crate is `memory-wedge`/`memory-crash`, the
/// artifact `memory_wedge.wasm`/`memory_crash.wasm` (a `cdylib` is named with underscores).
fn fixture_wasm(env_key: &str, name: &str) -> Option<PathBuf> {
    let substituted = name.replace('-', "_");
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(path) = std::env::var(env_key) {
        candidates.push(PathBuf::from(path));
    }
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    for file in [name, substituted.as_str()] {
        candidates.push(manifest_dir.join(format!("../components/{name}/target/wasm32-wasip2/release/{file}.wasm")));
    }
    if let Ok(target) = std::env::var("CARGO_TARGET_DIR") {
        for file in [name, substituted.as_str()] {
            candidates.push(PathBuf::from(&target).join(format!("wasm32-wasip2/release/{file}.wasm")));
        }
    }
    candidates.into_iter().find(|path| path.is_file())
}

fn memory_rows(db: &Path) -> (i64, i64) {
    let connection = rusqlite::Connection::open(db).expect("open");
    let memories: i64 = connection.query_row("SELECT COUNT(*) FROM memories", [], |row| row.get(0)).expect("count");
    let journal: i64 = connection.query_row("SELECT COUNT(*) FROM journal", [], |row| row.get(0)).expect("count");
    (memories, journal)
}

fn crash_fixture(tag: &str) -> Option<Fixture> {
    let Some(bytes) = fixture_wasm("WA_MEMORY_CRASH_COMPONENT_WASM", "memory-crash") else {
        println!(
            "SKIP {tag}: no crash fixture (build rust/components/memory-crash for wasm32-wasip2, or set WA_MEMORY_CRASH_COMPONENT_WASM)"
        );
        return None;
    };
    let bytes = std::fs::read(&bytes).expect("the crash fixture");
    let mut fixture = Fixture::install_with(
        tag,
        &bytes,
        concat!(env!("CARGO_MANIFEST_DIR"), "/../components/memory-crash/manifest.json"),
    );
    fixture.config.timeout_ms = Some(400);
    Some(fixture)
}

#[test]
fn a_guest_killed_between_the_write_and_the_journal_entry_leaves_neither() {
    // The guest writes the fact and its index row inside the kernel's unit of work, then spins: the
    // caller's epoch deadline kills it *mid-call*, exactly where a crash between "the row is there"
    // and "the journal entry is there" would sit. Before the unit of work existed, the component's
    // transaction had already committed by the time the kernel journaled, so this window was real.
    let Some(fixture) = crash_fixture("a_guest_killed_between_the_write_and_the_journal_entry") else { return };
    let db = fixture.root.join("memory.db");
    let answer = fixture.call(json!({"op":"remember","content":"wedge here","origin":"node-crash"}));
    assert_eq!(answer["ok"], json!(false), "{answer}");
    let error = answer["error"].as_str().unwrap_or_default();
    assert!(error.starts_with("component_wedged:"), "the guest was stopped by its deadline: {answer}");
    let (memories, journal) = memory_rows(&db);
    assert_eq!(memories, 0, "the fact written before the crash is not visible");
    assert_eq!(journal, 0, "and neither is a replication entry for it");
}

#[test]
fn a_journal_the_kernel_refuses_rolls_the_memory_back_with_it() {
    // The same unit of work, with a mutation whose entry the kernel cannot write: the fact must not
    // survive a refused journal. This is "both or neither" from the other side — the old seam stored
    // the memory and reported `journalled: false`.
    let Some(fixture) = crash_fixture("a_journal_the_kernel_refuses_rolls_the_memory_back") else { return };
    let db = fixture.root.join("memory.db");
    let answer = fixture.call(json!({"op":"remember","content":"needs a journal","origin":"node-crash"}));
    assert_eq!(answer["ok"], json!(false), "{answer}");
    let error = answer["error"].as_str().unwrap_or_default();
    assert!(error.starts_with("sql_policy_refused:sql_journal_payload_invalid"), "{answer}");
    let (memories, journal) = memory_rows(&db);
    assert_eq!(memories, 0, "the fact was rolled back with the refused entry");
    assert_eq!(journal, 0);
}

#[test]
fn a_remember_and_its_journal_entry_are_one_unit_through_the_real_component() {
    // The positive half: the real component's `remember` leaves both rows, and the entry carries this
    // node's origin, the log's verb and the payload a peer applies.
    let Some(bytes) = component_bytes() else { return skip("a_remember_and_its_journal_entry_are_one_unit") };
    let fixture = Fixture::install("one-unit", &bytes);
    let written = ok(&fixture.call(json!({"op":"remember","content":"one unit, both rows","origin":"node-unit"}))).clone();
    assert_eq!(written["written"], json!(true));
    assert_eq!(written["journalled"], json!(true), "the entry lands in the same transaction: {written}");
    let id = written["id"].as_str().expect("an id");
    let connection = rusqlite::Connection::open(fixture.root.join("memory.db")).expect("open");
    let (kind, entity, op, origin, payload): (String, String, String, String, String) = connection
        .query_row("SELECT kind,entity_id,op,origin,payload FROM journal", [], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?))
        })
        .expect("the journal row");
    assert_eq!((kind.as_str(), entity.as_str(), op.as_str(), origin.as_str()), ("memory", id, "upsert", "node-unit"));
    let payload: serde_json::Value = serde_json::from_str(&payload).expect("the entry's payload is JSON");
    assert_eq!(payload["id"], json!(id));
    assert_eq!(payload["content"], json!("one unit, both rows"));
    // A repeat of the same fact writes nothing, so it owes no entry.
    let repeat = ok(&fixture.call(json!({"op":"remember","content":"one unit, both rows","origin":"node-unit"}))).clone();
    assert_eq!((repeat["written"].clone(), repeat["journalled"].clone()), (json!(false), json!(false)));
    let entries: i64 = connection.query_row("SELECT COUNT(*) FROM journal", [], |row| row.get(0)).expect("count");
    assert_eq!(entries, 1);
}

#[test]
fn the_measured_deadlines_are_the_per_operation_table_with_a_floor() {
    // The table in `memory_host.rs` is derived, not guessed: 10 × the p99 each operation measured
    // through the component on the bench store (10 000 facts, 50 000 messages, FTS), with a floor.
    // `scripts/bench-memory-component.sh` prints the timings; these are the numbers it produced on
    // the reference store (REPORT.md). A change to either side has to change this test.
    let measured_p99_ms: &[(&str, u64)] = &[
        ("remember", 7),
        ("recall", 120),
        ("forget", 24),
        ("list", 21),
        ("search_messages", 455),
        ("sessions", 31),
        ("retention", 4),
    ];
    for (op, p99) in measured_p99_ms {
        let deadline = measured_deadline_ms(op);
        assert!(deadline >= DEADLINE_FLOOR_MS, "{op}: {deadline} is under the floor");
        assert!(deadline >= 10 * p99, "{op}: {deadline} ms is less than 10 × p99 ({p99} ms)");
    }
    // The floor is what covers an operation that measures faster than a tenth of it.
    assert_eq!(measured_deadline_ms("remember"), DEADLINE_FLOOR_MS);
    assert_eq!(measured_deadline_ms("sessions"), DEADLINE_FLOOR_MS);
    // An operation the table has never measured keeps the old default, not an invented one.
    assert_eq!(measured_deadline_ms("no_such_op"), 2_000);
    // The operator's override replaces the table for every operation.
    let config = Config {
        components_dir: PathBuf::from("."),
        db: PathBuf::from("."),
        wasm: None,
        manifest: None,
        timeout_ms: Some(7),
    };
    assert_eq!(config.deadline_ms("recall"), 7);
    assert_eq!(config.deadline_ms("sessions"), 7);
    // The statement guard is the caller's deadline plus a margin: the guest is stopped first.
    assert!(STATEMENT_MARGIN_MS > 0);
}
