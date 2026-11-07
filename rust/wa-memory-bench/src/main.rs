//! The memory seam's measurements: what each operation costs through the component, on a store the
//! size of a real node's.
//!
//! The deadlines in `wa_kernel_runtime::memory_host` are **10 × the p99 measured here**, with a floor.
//! A deadline is a bound on a whole seam call — instantiate the component, open the scoped connection,
//! run the statements, cross the boundary with the answer — so the measurement has to be of a call,
//! not of a statement, and it has to run on a store where the indexes actually have to work.
//!
//! ```text
//! bash scripts/bench-memory-component.sh            # builds the component, seeds, prints the table
//! ```
//!
//! The store: 10 000 facts and 50 000 messages (FTS indexed) across 500 threads, which is a busy but
//! ordinary node. The numbers go into `REPORT.md` and docs/MEMORY.md; the derived deadline is compared
//! with the table the host ships, and a table that is tighter than 10 × the measured p99 exits
//! non-zero — a bound nobody re-measured should fail loudly, not quietly fall back.
use rusqlite::Connection;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Instant;
use wa_kernel_runtime::memory_host::{self, Config};

/// The store the numbers are quoted for. `--facts`/`--messages` exist so a different size can be
/// measured, but a deadline taken from another size is a different claim and the table says so.
const FACTS: i64 = 10_000;
const MESSAGES: i64 = 50_000;
const SESSIONS: i64 = 500;
/// How many calls each operation is sampled with, after two warm-up calls.
const ITERATIONS: usize = 200;

struct Args {
    db: PathBuf,
    component: PathBuf,
    manifest: PathBuf,
    iterations: usize,
}

fn parse_args() -> Result<Args, String> {
    let mut db: Option<PathBuf> = None;
    let mut component: Option<PathBuf> = None;
    let mut manifest: Option<PathBuf> = None;
    let mut iterations = ITERATIONS;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        let mut value = |what: &str| args.next().ok_or_else(|| format!("{what} needs a value"));
        match arg.as_str() {
            "--db" => db = Some(PathBuf::from(value("--db")?)),
            "--component" => component = Some(PathBuf::from(value("--component")?)),
            "--manifest" => manifest = Some(PathBuf::from(value("--manifest")?)),
            "--iterations" => {
                iterations = value("--iterations")?.parse::<usize>().map_err(|error| error.to_string())?
            }
            "-h" | "--help" => {
                println!("wa-memory-bench --db <store> --component <memory.wasm> --manifest <memory.json> [--iterations N]");
                std::process::exit(0);
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    Ok(Args {
        db: db.ok_or("--db is required")?,
        component: component.ok_or("--component is required")?,
        manifest: manifest.ok_or("--manifest is required")?,
        iterations: iterations.max(1),
    })
}

/// The schema a node runs (`lua/core/schema.sql`) plus the session columns `memory.setup()` adds, so
/// the statements the component sends are the statements a real store answers.
fn create_database(path: &Path) {
    if path.exists() {
        return;
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).expect("the store's directory");
    }
    let schema = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../../lua/core/schema.sql"))
        .expect("the node's schema is readable");
    let connection = Connection::open(path).expect("open db");
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

fn count(connection: &Connection, table: &str) -> i64 {
    connection.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| row.get(0)).expect("count")
}

/// 10 000 facts: distinct text (so no dedupe), a share of them a guest's own scope, tags on some, and
/// an updated_at spread over a month so the recency term of the ranking has something to order.
fn seed_facts(connection: &Connection, facts: i64) {
    let words = [
        "deploy", "vault", "token", "release", "backup", "rotation", "standby", "migration",
        "deadline", "postgres", "wasmtime", "component", "journal", "replica", "sentinel", "kernel",
        "timeout", "socket", "package", "manifest", "grant", "audit", "session", "memory",
    ];
    let transaction = format!("INSERT INTO memories(id,scope,content,tags,source,created_at,updated_at,content_sha256) \
                               VALUES('fact-{facts}','global','seed','[]','user',0.0,0.0,'sha-{facts}')");
    let _ = transaction; // the schema's uniqueness is on (scope, content_sha256); ids are what we set
    let started = Instant::now();
    connection.execute_batch("BEGIN IMMEDIATE").expect("begin");
    {
        let mut insert = connection
            .prepare(
                "INSERT INTO memories(id,scope,content,tags,source,created_at,updated_at,content_sha256) \
                 VALUES(?,?,?,?,?,?,?,?)",
            )
            .expect("prepare memories");
        let mut index = connection
            .prepare("INSERT INTO memories_fts(content,tags,memory_id) VALUES(?,?,?)")
            .expect("prepare memories_fts");
        let now = 1_700_000_000.0_f64;
        for n in 0..facts {
            let a = words[(n * 7) as usize % words.len()];
            let b = words[(n * 13 + 5) as usize % words.len()];
            let c = words[(n * 29 + 11) as usize % words.len()];
            let content = format!("{a} {b}: the {c} note number {n} for the {a} runbook");
            let tags = format!(r#"["{a}","{c}"]"#);
            let scope = if n % 20 == 0 { format!("user:guest{}", n % 5) } else { "global".to_string() };
            let stamp = now - (facts - n) as f64 * 240.0;
            insert
                .execute(rusqlite::params![
                    format!("fact-{n:06}"),
                    scope,
                    content,
                    tags,
                    "user",
                    stamp,
                    stamp,
                    format!("sha-{n:06}")
                ])
                .expect("a fact");
            index
                .execute(rusqlite::params![content, a, format!("fact-{n:06}")])
                .expect("its search entry");
        }
    }
    connection.execute_batch("COMMIT").expect("commit");
    println!("seeded {} facts in {:?}", facts, started.elapsed());
}

/// 500 threads of 100 messages, every message in the FTS index, a failed assistant turn at the end of
/// every tenth thread so `sessions(states: true)` classifies a mix instead of one state.
fn seed_messages(connection: &Connection, messages: i64, sessions: i64) {
    let words = [
        "deploy", "vault", "token", "release", "backup", "rotation", "standby", "migration",
        "deadline", "postgres", "wasmtime", "component", "journal", "replica", "sentinel", "kernel",
        "timeout", "socket", "package", "manifest", "grant", "audit", "session", "memory",
    ];
    let per_session = (messages / sessions).max(1);
    let started = Instant::now();
    connection.execute_batch("BEGIN IMMEDIATE").expect("begin");
    {
        let mut thread = connection
            .prepare(
                "INSERT INTO sessions(id,route_id,objective,started_at,ended_at,user_id,node_id,title,mode,updated_at) \
                 VALUES(?,?,?,?,NULL,?,?,?,?,?)",
            )
            .expect("prepare sessions");
        let mut message = connection
            .prepare(
                "INSERT INTO messages(id,session_id,seq,role,content,tool_calls,tool_call_id,tool_name,ok,created_at,phase,trace) \
                 VALUES(?,?,?,?,?,'[]','','',?,?,'','[]')",
            )
            .expect("prepare messages");
        let mut index = connection
            .prepare("INSERT INTO messages_fts(content,session_id,message_id) VALUES(?,?,?)")
            .expect("prepare messages_fts");
        let now = 1_700_000_000.0_f64;
        let mut seq = 0i64;
        for s in 0..sessions {
            let id = format!("thread-{s:04}");
            let user = if s % 10 == 0 { "guest" } else { "master" };
            thread
                .execute(rusqlite::params![
                    id,
                    "",
                    "",
                    now - 10_000.0 + s as f64,
                    user,
                    "",
                    format!("thread {s} about the deploy vault"),
                    "default",
                    now - 1_000.0 + s as f64
                ])
                .expect("a thread");
            for m in 0..per_session {
                seq += 1;
                let role = if m % 2 == 0 { "user" } else { "assistant" };
                let ok = if m + 1 == per_session && s % 10 == 0 { 0 } else { 1 };
                // Varied vocabulary, not one sentence repeated: a real transcript shares words, so a
                // three-term query has to be selective and a single common word has to match most of
                // the store. Both shapes are measured below; a seed where every row matches every
                // query would quote one (slow) number as if it were the only one.
                let content = format!(
                    "{a} {b} {c} in thread {s}, step {seq}: the {d} note about the {a} runbook",
                    a = words[(seq * 7) as usize % words.len()],
                    b = words[(seq * 13 + 5) as usize % words.len()],
                    c = words[(seq * 29 + 11) as usize % words.len()],
                    d = words[(seq * 3 + 17) as usize % words.len()],
                );
                let mid = format!("msg-{seq:07}");
                message
                    .execute(rusqlite::params![mid, id, m + 1, role, content, ok, now - 9_000.0 + seq as f64])
                    .expect("a message");
                index
                    .execute(rusqlite::params![content, id, mid])
                    .expect("its search entry");
            }
        }
    }
    connection.execute_batch("COMMIT").expect("commit");
    println!("seeded {} messages across {} threads in {:?}", messages, sessions, started.elapsed());
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let rank = ((p / 100.0) * sorted.len() as f64).ceil().max(1.0) as usize;
    sorted[rank.min(sorted.len()) - 1]
}

struct Sample {
    label: &'static str,
    calls: usize,
    p50: f64,
    p99: f64,
    max: f64,
    /// What the host ships as this operation's deadline.
    deadline: u64,
    /// 10 × p99, the number the deadline is supposed to be.
    derived: f64,
}

fn main() {
    let args = match parse_args() {
        Ok(args) => args,
        Err(error) => {
            eprintln!("wa-memory-bench: {error}");
            std::process::exit(2);
        }
    };
    create_database(&args.db);
    {
        let connection = Connection::open(&args.db).expect("open db");
        if count(&connection, "memories") < FACTS {
            seed_facts(&connection, FACTS);
        }
        if count(&connection, "messages") < MESSAGES {
            seed_messages(&connection, MESSAGES, SESSIONS);
        }
        println!(
            "store: {} facts, {} messages, {} threads",
            count(&connection, "memories"),
            count(&connection, "messages"),
            count(&connection, "sessions")
        );
    }

    let config = Config {
        components_dir: args.db.parent().unwrap_or(Path::new(".")).to_path_buf(),
        db: args.db.clone(),
        wasm: Some(args.component.clone()),
        manifest: Some(args.manifest.clone()),
        // No override: the host's own measured table is the one under test.
        timeout_ms: None,
    };

    // One call per operation, checked before measuring: a bench that measures a fallback (a missing
    // component, a refused grant) would produce plausible numbers for the wrong thing.
    let probe = memory_host::call_with(&config, &json!({"op":"retention","older_than_seconds":0}));
    assert_eq!(probe["ok"], json!(true), "the component answered: {probe}");

    // What `forget` removes: rows nothing else references, created here so the write has real work.
    let forgettable: Vec<String> = (0..args.iterations).map(|n| format!("forget-{n:04}")).collect();
    {
        let connection = Connection::open(&args.db).expect("open db");
        connection.execute_batch("BEGIN IMMEDIATE").expect("begin");
        for id in &forgettable {
            connection
                .execute(
                    "INSERT INTO memories(id,scope,content,tags,source,created_at,updated_at,content_sha256) \
                     VALUES(?,'global',?,'[]','user',1.0,1.0,?)",
                    rusqlite::params![id, format!("the row {id} that a forget retires"), format!("sha-{id}")],
                )
                .expect("a forgettable fact");
        }
        connection.execute_batch("COMMIT").expect("commit");
    }

    let mut samples: Vec<Sample> = Vec::new();
    let mut failures: Vec<String> = Vec::new();
    // `op` is the operation name the host's deadline table is keyed by; `label` is what the table
    // prints (the two recall passes are one operation and one deadline).
    let mut measure = |op: &'static str, label: &'static str, requests: Vec<Value>| {
        // Two warm-up calls: the first one in the process pays the component's compilation.
        for request in requests.iter().take(2) {
            let answer = memory_host::call_with(&config, request);
            assert_eq!(answer["ok"], json!(true), "{label} answered: {answer}");
        }
        let mut times = Vec::with_capacity(requests.len());
        for request in &requests {
            let started = Instant::now();
            let answer = memory_host::call_with(&config, request);
            times.push(started.elapsed().as_secs_f64() * 1000.0);
            if answer["ok"] != json!(true) {
                failures.push(format!("{label}: {}", answer["error"]));
                break;
            }
        }
        let mut sorted = times.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        let p99 = percentile(&sorted, 99.0);
        samples.push(Sample {
            label,
            calls: times.len(),
            p50: percentile(&sorted, 50.0),
            p99,
            max: sorted.last().copied().unwrap_or(0.0),
            deadline: memory_host::measured_deadline_ms(op),
            derived: p99 * 10.0,
        });
    };

    let recall_term: Vec<Value> = (0..args.iterations).map(|n| json!({"op":"recall","text":"vault rotation","limit":10,"_":n})).collect();
    let recall_question: Vec<Value> = (0..args.iterations)
        .map(|n| json!({"op":"recall","text":"what did I ask you to remember about the deploy vault rotation","limit":5,"_":n}))
        .collect();
    // One common word: every fact and every message contains "the", so the term matches the whole
    // store and bm25 has to score all of it. This is the shape a user's "the" (or any stopword-like
    // term their transcript is full of) really has, and it is the slow end of the spread.
    let recall_common: Vec<Value> = (0..args.iterations).map(|n| json!({"op":"recall","text":"the","limit":10,"_":n})).collect();
    let search: Vec<Value> = (0..args.iterations).map(|n| json!({"op":"search_messages","text":"vault deploy token","limit":20,"_":n})).collect();
    let search_common: Vec<Value> = (0..args.iterations).map(|n| json!({"op":"search_messages","text":"the","limit":20,"_":n})).collect();
    let sessions: Vec<Value> = (0..args.iterations).map(|n| json!({"op":"sessions","limit":30,"states":true,"_":n})).collect();
    let list: Vec<Value> = (0..args.iterations).map(|n| json!({"op":"list","limit":50,"_":n})).collect();
    let remember: Vec<Value> = (0..args.iterations)
        .map(|n| json!({"op":"remember","content":format!("bench fact {n}: the sentinel rotated the deploy token"),"scope":"global","tags":["bench"],"origin":"node-bench"}))
        .collect();
    let forget: Vec<Value> = forgettable.iter().map(|id| json!({"op":"forget","id":id,"origin":"node-bench"})).collect();

    measure("remember", "remember", remember);
    measure("recall", "recall (term)", recall_term);
    measure("recall", "recall (question)", recall_question);
    measure("recall", "recall (common word)", recall_common);
    measure("search_messages", "search (3 terms)", search);
    measure("search_messages", "search (common word)", search_common);
    measure("sessions", "sessions", sessions);
    measure("list", "list", list);
    measure("forget", "forget", forget);

    println!();
    println!("{:<20} {:>6} {:>9} {:>9} {:>9} {:>12} {:>10} {:>8}", "op", "calls", "p50 ms", "p99 ms", "max ms", "10 × p99 ms", "table ms", "verdict");
    let mut too_tight = false;
    for sample in &samples {
        let fits = sample.deadline as f64 >= sample.derived && sample.deadline >= memory_host::DEADLINE_FLOOR_MS;
        too_tight |= !fits;
        println!(
            "{:<20} {:>6} {:>9.2} {:>9.2} {:>9.2} {:>12.1} {:>10} {:>8}",
            sample.label,
            sample.calls,
            sample.p50,
            sample.p99,
            sample.max,
            sample.derived,
            sample.deadline,
            if fits { "ok" } else { "TOO TIGHT" }
        );
    }
    println!();
    println!(
        "floor: {} ms (memory_host::DEADLINE_FLOOR_MS); store: {} facts / {} messages; iterations: {}",
        memory_host::DEADLINE_FLOOR_MS, FACTS, MESSAGES, args.iterations
    );
    if !failures.is_empty() {
        eprintln!("a call failed while measuring: {}", failures.join("; "));
        std::process::exit(1);
    }
    if too_tight {
        eprintln!("the shipped deadline is tighter than 10 × the measured p99: re-measure, then update `measured_deadline_ms`");
        std::process::exit(1);
    }
}
