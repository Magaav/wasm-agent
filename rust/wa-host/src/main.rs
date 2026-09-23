//! `wa` host: a Rust binary with vendored Lua, SQLite, HTTP and WASM plugins.
//!
//! The agent logic lives in Lua (`lua/`); this host only provides capabilities
//! (sqlite, http, wasmtime, sha256, uuid, time, files). No Python anywhere.
mod client_bridge;
mod graph;
mod host;
mod file_search;
mod http_transport;
mod operations;
mod lua;
mod node;
mod relay_client;
mod rendezvous;
mod plugins;
mod subagents;
mod serve;

use host::Host;
use lua::Lua;
use rusqlite::Connection;
use std::ffi::{c_int, c_void};
use std::path::PathBuf;
use std::sync::Mutex;

/// The Lua core is embedded so `wa` is a single self-contained binary that runs
/// from any working directory. WA_SCRIPT overrides the entry point with a file.
const EMBEDDED: &[(&str, &str)] = &[
    ("lua/vendor/json.lua", include_str!("../../../lua/vendor/json.lua")),
    ("lua/core/schema.sql", include_str!("../../../lua/core/schema.sql")),
    ("lua/core/skills.lua", include_str!("../../../lua/core/skills.lua")),
    ("lua/core/redact.lua", include_str!("../../../lua/core/redact.lua")),
    ("lua/core/telemetry.lua", include_str!("../../../lua/core/telemetry.lua")),
    ("lua/core/tool_output.lua", include_str!("../../../lua/core/tool_output.lua")),
    ("lua/core/file_tools.lua", include_str!("../../../lua/core/file_tools.lua")),
    ("lua/core/evidence_view.lua", include_str!("../../../lua/core/evidence_view.lua")),
    ("lua/core/diagnose.lua", include_str!("../../../lua/core/diagnose.lua")),
    ("lua/core/prefix_audit.lua", include_str!("../../../lua/core/prefix_audit.lua")),
    ("lua/core/platform.lua", include_str!("../../../lua/core/platform.lua")),    ("lua/core/paths.lua", include_str!("../../../lua/core/paths.lua")),
    ("lua/core/memory.lua", include_str!("../../../lua/core/memory.lua")),
    ("lua/core/tools.lua", include_str!("../../../lua/core/tools.lua")),
    ("lua/core/graph.lua", include_str!("../../../lua/core/graph.lua")),
    ("lua/core/users.lua", include_str!("../../../lua/core/users.lua")),
    ("lua/core/spells.lua", include_str!("../../../lua/core/spells.lua")),
    ("lua/core/nodes.lua", include_str!("../../../lua/core/nodes.lua")),
    ("lua/core/enrollment.lua", include_str!("../../../lua/core/enrollment.lua")),
    ("lua/core/state.lua", include_str!("../../../lua/core/state.lua")),
    ("lua/core/status.lua", include_str!("../../../lua/core/status.lua")),
    ("lua/core/update.lua", include_str!("../../../lua/core/update.lua")),
    ("lua/core/merge.lua", include_str!("../../../lua/core/merge.lua")),
    ("lua/core/toolchain.lua", include_str!("../../../lua/core/toolchain.lua")),
    ("lua/core/provider.lua", include_str!("../../../lua/core/provider.lua")),
    ("lua/core/model_window.lua", include_str!("../../../lua/core/model_window.lua")),
    ("lua/core/changeset.lua", include_str!("../../../lua/core/changeset.lua")),
    ("lua/core/effects.lua", include_str!("../../../lua/core/effects.lua")),
    ("lua/core/whatsapp.lua", include_str!("../../../lua/core/whatsapp.lua")),
    ("lua/core/subagents.lua", include_str!("../../../lua/core/subagents.lua")),
    ("lua/core/agent.lua", include_str!("../../../lua/core/agent.lua")),
    ("lua/core/cli_view.lua", include_str!("../../../lua/core/cli_view.lua")),
    ("lua/core/chat.lua", include_str!("../../../lua/core/chat.lua")),
    ("lua/core/server.lua", include_str!("../../../lua/core/server.lua")),
    ("lua/core/init.lua", include_str!("../../../lua/core/init.lua")),
];

// NOTE: this list is hand-maintained, and a module missing from it exists in the working
// tree and not in the shipped binary - which crash-loops a deployed node with
// "embedded module missing". scripts/test.sh now loads every lua/core/*.lua with
// WASM_AGENT_LUA_ROOT unset, so the list cannot drift silently again.
/// Source for one of the entry modules the host loads itself.
///
/// `dofile` prefers the on-disk copy when WASM_AGENT_LUA_ROOT is set, but these
/// two are read straight from the binary - so editing `lua/core/init.lua` had no
/// effect at all, which is exactly how a self-evolution run lost its budget: it
/// added a command, ran it, saw "unknown command", and went looking through the
/// Rust host for the reason. Dev mode has to cover every entry point or it is a
/// trap.
fn core_source(name: &str) -> String {
    if let Ok(root) = std::env::var("WASM_AGENT_LUA_ROOT") {
        let trimmed = root.trim_end_matches(['/', '\\']);
        if !trimmed.is_empty() {
            if let Ok(text) = std::fs::read_to_string(format!("{trimmed}/{name}")) {
                return text;
            }
        }
    }
    embedded(name).to_string()
}

fn embedded(name: &str) -> &'static str {
    EMBEDDED
        .iter()
        .find(|(key, _)| *key == name)
        .map(|(_, source)| *source)
        .unwrap_or_else(|| panic!("missing embedded module: {name}"))
}

fn flag(args: &[String], name: &str) -> Option<String> {
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == name {
            return iter.next().cloned();
        }
        if let Some(value) = arg.strip_prefix(&format!("{name}=")) {
            return Some(value.to_string());
        }
    }
    None
}

/// The user's home directory, which is where `~/.wasm-agent` lives.
///
/// Windows does not set `HOME`, and Git Bash sets it to a POSIX path
/// (`/c/Users/...`) that Rust cannot open - which silently disabled the whole
/// config file, leaving the agent in "no model configured" mode. Prefer an
/// explicit override, then the native Windows variables, then HOME.
pub(crate) fn resolve_home() -> String {
    if let Ok(value) = std::env::var("WASM_AGENT_HOME") {
        if !value.is_empty() {
            return value;
        }
    }
    if cfg!(windows) {
        if let Ok(value) = std::env::var("USERPROFILE") {
            if !value.is_empty() {
                return value;
            }
        }
        if let (Ok(drive), Ok(path)) = (std::env::var("HOMEDRIVE"), std::env::var("HOMEPATH")) {
            if !drive.is_empty() && !path.is_empty() {
                return format!("{drive}{path}");
            }
        }
    }
    std::env::var("HOME").unwrap_or_else(|_| ".".into())
}

fn db_path(args: &[String]) -> String {
    flag(args, "--db").unwrap_or_else(|| {
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        format!("{home}/.wasm-agent/memory.db")
    })
}

/// Open one interpreter's own SQLite connection to the node's database.
///
/// A file-backed database is opened normally, so every interpreter sees the same
/// WAL and only committed rows cross a transaction boundary. An in-memory database
/// gets a SHARED-CACHE URI, because plain `:memory:` would silently give each
/// interpreter its own empty database - a split ledger that looks correct from
/// inside each interpreter.
fn open_db(path: &str) -> Connection {
    let in_memory = path.is_empty() || path == ":memory:" || path == "file::memory:" || path == "file::memory:?cache=shared";
    let database = if in_memory {
        format!("file:wa-memory-{}?mode=memory&cache=shared", std::process::id())
    } else {
        path.to_string()
    };
    let flags = rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE
        | rusqlite::OpenFlags::SQLITE_OPEN_CREATE
        | rusqlite::OpenFlags::SQLITE_OPEN_URI;
    let connection = Connection::open_with_flags(&database, flags).expect("open database");
    connection
        .execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;\
             PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;",
        )
        .expect("pragma");
    connection
}

/// Load KEY=VALUE pairs from ~/.wasm-agent/env without overwriting real env.
/// Returns what it read so the Lua core can see the same values through
/// `host.getenv` (see the note on ENV_OVERRIDES in host.rs).
fn load_env_file() -> Vec<(String, String)> {
    let home = std::env::var("HOME").unwrap_or_default();
    let mut loaded = Vec::new();
    let Ok(text) = std::fs::read_to_string(format!("{home}/.wasm-agent/env")) else {
        return loaded;
    };
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some((key, value)) = line.split_once('=') {
            let key = key.trim();
            let value = value.trim().trim_matches(|c| c == '"' || c == '\'');
            if !key.is_empty() && std::env::var(key).is_err() {
                std::env::set_var(key, value);
                loaded.push((key.to_string(), value.to_string()));
            }
        }
    }
    loaded
}

fn main() {
    // Publish the resolved home through HOME before anything reads it: the Lua
    // core, the node key, the plugin directory and the config file all derive
    // their paths from HOME, so one resolution here fixes them together.
    let home = resolve_home();
    std::env::set_var("HOME", &home);
    let from_file = load_env_file();
    let args: Vec<String> = std::env::args().skip(1).collect();
    // A detached launcher must not change the node's worktree/branch identity.
    // The deployment gate writes this explicit location; CLI one-shot commands
    // still use their caller's cwd, and scratch binaries have no such marker.
    if args.first().is_some_and(|arg| arg == "serve") {
        if let Some(marker) = std::env::current_exe().ok().and_then(|p| p.parent().map(|dir| dir.join("runtime-worktree.txt"))) {
            if let Ok(path) = std::fs::read_to_string(marker) {
                if let Err(error) = std::env::set_current_dir(path.trim()) {
                    eprintln!("runtime_worktree_unavailable: {error}"); std::process::exit(2);
                }
            }
        }
    }
    if args.iter().any(|arg| arg == "--version" || arg == "-v") {
        println!("wasm-agent {}", env!("CARGO_PKG_VERSION"));
        return;
    }

    // The host consumes --db; the Lua core gets the rest.
    let mut lua_args: Vec<String> = Vec::new();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--db" {
            iter.next();
            continue;
        }
        if arg.starts_with("--db=") {
            continue;
        }
        lua_args.push(arg.clone());
    }

    let db = db_path(&args);
    std::env::set_var("WASM_AGENT_DB", &db);
    // Hand the Lua core the same view the host resolved, in one place.
    let mut resolved: std::collections::HashMap<String, String> = from_file.into_iter().collect();
    resolved.insert("HOME".to_string(), home.clone());
    resolved.insert("WASM_AGENT_DB".to_string(), db.clone());
    host::set_env_overrides(resolved);
    // The graph lives beside the ledger and indexes the runtime worktree (the node's cwd), which is
    // the source this binary is actually running from. Both are overridable for tests and dev.
    let graph_root = std::env::var("WA_GRAPH_ROOT")
        .ok()
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let graph_db = std::env::var("WA_GRAPH_DB")
        .ok()
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(format!("{home}/.wasm-agent/graph.db")));
    graph::configure(graph_root.clone(), graph_db.clone());
    if let Some(parent) = std::path::Path::new(&db).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // Every interpreter gets its OWN SQLite connection to the same WAL database.
    // One shared connection made a transaction an interpreter held open visible to
    // every other interpreter, and let a rollback there erase a peer's committed
    // row. The plugin runtime and the client bridge are process-wide, so they are
    // shared behind an Arc; only the database connection is per-interpreter.
    let plugin_registry = plugins::PluginRegistry::load(&plugins::plugin_dir());
    let shared_plugins = std::sync::Arc::new(Mutex::new(plugin_registry));
    let bridge = std::sync::Arc::new(client_bridge::Bridge::new());
    let shared_client = bridge.clone();

    // One boot sequence, called once per interpreter. Each call opens its own
    // connection and boxes a Host that the interpreter owns and drops with itself,
    // so a retired worker leaves no connection and no open transaction behind.
    let boot_args = lua_args.clone();
    let db_for_boot = db.clone();
    let boot_state = move || -> Lua {
    let connection = open_db(&db_for_boot);
    let host: Box<Host> = Box::new(Host {
        db: Mutex::new(connection),
        plugins: shared_plugins.clone(),
        client: shared_client.clone(),
    });
    // A pointer into the box's allocation; moving the box into the interpreter does
    // not move the Host, so every host function's upvalue stays valid for the
    // interpreter's whole life.
    let host_ptr = (&*host) as *const Host as *mut c_void;
    let mut lua = Lua::new();
    lua.push_table();
    lua.register_with_upvalue("sql_exec", host::sql_exec, host_ptr);
    lua.register_with_upvalue("sql_query", host::sql_query, host_ptr);
    lua.register("db_ready", host::db_ready);
    lua.register("mark_db_ready", host::mark_db_ready);
    lua.register("getenv", host::getenv);
    lua.register("paths", host::paths);
    lua.register("platform", host::platform);
    lua.register("grep", host::grep);
    lua.register("list_dir", host::list_dir);
    lua.register("graph_index", graph::graph_index);
    lua.register("graph_query", graph::graph_query);
    lua.register("graph_explain", graph::graph_explain);
    lua.register("graph_path", graph::graph_path);
    lua.register("graph_caps", graph::graph_caps);
    lua.register("graph_stats", graph::graph_stats);
    lua.register("graph_status", graph::graph_status);
    lua.register("sha256", host::sha256);
    lua.register("uuid", host::uuid);
    lua.register("read_file", host::read_file);
    lua.register("write_file", host::write_file);
    lua.register("exec", host::exec);
    lua.register("operation", host::operation);
    lua.register("jobs", host::jobs);
    lua.register("subagent", host::subagent);
    lua.register("run_cancelled", host::run_cancelled);
    lua.register("sleep", host::sleep);
    lua.register("node_identity", host::node_identity);
    lua.register("sign", host::sign);
    lua.register("verify", host::verify);
    lua.register_with_upvalue("client", host::client, host_ptr);
    lua.register_with_upvalue("client_status", host::client_status, host_ptr);
    lua.register("http", host::http);
    lua.register("http_stream", host::http_stream);
    lua.register("beat", host::beat);
    // The one capability that draws: the CLI's status line keeps moving while the interpreter
    // is blocked inside a call, which nothing on the Lua side can do for itself.
    lua.register("ticker", host::ticker);
    lua.register("relay", host::relay);
    lua.register_with_upvalue("plugins", host::plugins, host_ptr);
    lua.register_with_upvalue("invoke", host::invoke, host_ptr);
    lua.register("stream", host::stream);
    lua.register("now", host::now);
    lua.register("monotonic_ms", host::monotonic_ms);
    lua.register("runtime_info", host::runtime_info);
    lua.register("exec_timeout", host::exec_timeout);
    lua.register("log", host::log);
    lua.set_global("host");

    lua.push_table();
    for (index, arg) in boot_args.iter().enumerate() {
        lua.push_string(arg);
        lua.raw_seti((index + 1) as c_int);
    }
    lua.set_global("args");

    lua.push_table();
    for (name, source) in EMBEDDED {
        lua.push_string(source);
        lua.set_field(-2, name);
    }
    lua.set_global("EMBEDDED");
    // `dofile` reads the embedded copy by default, so `wa` is one self-contained
    // binary. With WASM_AGENT_LUA_ROOT set it prefers the files on disk instead,
    // which is what lets an agent iterate on the Lua core without a rebuild (and
    // therefore without a Rust toolchain, e.g. on a Windows node).
      // A set-but-unreadable root is an error, not a fallback. Falling back would run
      // the copy baked into the binary while the operator believes they are testing
      // the files on disk - which is how two tests in the image branch passed while
      // loading code that did not contain the feature they were testing. The fallback
      // stays for the shipping case, where no root is set at all.
    let bootstrap = "LOADED_SOURCES = {}; function dofile(path) \
         local root = host.getenv('WASM_AGENT_LUA_ROOT'); \
         if root and root ~= '' then \
           local text = host.read_file(root .. '/' .. path); \
           if not text then error('lua_root_unreadable: ' .. root .. '/' .. path) end; \
           LOADED_SOURCES[path] = host.sha256(text); \
             return assert(load(text, '@' .. root .. '/' .. path))() \
         end; \
         local source = EMBEDDED[path]; \
         if not source then error('embedded module missing: ' .. tostring(path)) end; \
         LOADED_SOURCES[path] = host.sha256(source); \
         return assert(load(source, '@' .. path))() end";
    if let Err(error) = lua.do_string(bootstrap, "bootstrap") {
        eprintln!("lua error: {error}");
        std::process::exit(1);
    }
        lua.own(host as Box<dyn std::any::Any + Send>);
        lua
    };
    let lua = boot_state();

    // A fresh, initialized interpreter: the boot sequence plus the modules an
    // interpreter needs to answer a request or run a subagent. Built once and
    // shared so `serve`, ordinary CLI runs and the subagent runtime cannot drift.
    // The factory is registered with the runtime here, before any command runs,
    // so a child is never left unable to build its own interpreter.
    let worker: std::sync::Arc<dyn Fn() -> Lua + Send + Sync> = std::sync::Arc::new(move || {
        let state = boot_state();
        // A pool worker or a child interpreter must never take the process down
        // with it: an interpreter that cannot load its module reports the failure
        // and runs on, so a spawned child settles as failed rather than killing
        // the parent and every sibling. The main serve interpreter still exits on
        // a broken module above.
        if let Err(error) = state.do_string(&core_source("lua/core/server.lua"), "lua/core/server.lua") {
            eprintln!("lua error: {error}");
        }
        if let Err(error) = state.do_string(&core_source("lua/core/subagents.lua"), "lua/core/subagents.lua") {
            eprintln!("lua error: {error}");
        }
        state
    });
    let worker_for_subagents = worker.clone();
    subagents::set_factory(Box::new(move || worker_for_subagents()));

    if let Ok(script) = std::env::var("WA_SCRIPT") {
        let source = std::fs::read_to_string(&script).unwrap_or_else(|e| panic!("read {script}: {e}"));
        if let Err(error) = lua.do_string(&source, &script) {
            eprintln!("lua error: {error}");
            std::process::exit(1);
        }
        return;
    }

    let command = lua_args.first().map(String::as_str).unwrap_or("");
    if command == "serve" {
        if let Err(error) = lua.do_string(&core_source("lua/core/server.lua"), "lua/core/server.lua") {
            eprintln!("lua error: {error}");
            std::process::exit(1);
        }
        if let Err(error) = lua.do_string(&core_source("lua/core/subagents.lua"), "lua/core/subagents.lua") {
            eprintln!("lua error: {error}");
            std::process::exit(1);
        }
        let port = flag(&lua_args, "--port").and_then(|value| value.parse().ok()).unwrap_or(8799);
        let ui = flag(&lua_args, "--ui")
            .or_else(|| std::env::var("WASM_AGENT_UI").ok())
            .unwrap_or_else(|| "ui".to_string());
        let client_port = flag(&lua_args, "--client-port")
            .or_else(|| std::env::var("WASM_AGENT_CLIENT_PORT").ok())
            .and_then(|value| value.parse().ok())
            .unwrap_or(8800);
        client_bridge::serve(client_port, bridge.clone());
        if let Ok(rendezvous_url) = std::env::var("WASM_AGENT_RENDEZVOUS") {
            if !rendezvous_url.is_empty() {
                node::spawn_heartbeat(rendezvous_url);
            }
        }
        // The pool builds its own interpreters on demand from the factory registered above, so what it needs is a way to make one
        // rather than a pile of them up front. The host pointer travels as a usize because it is a leaked raw
        // pointer for the life of the process; a newtype with an unsafe Send would be the same claim with
        // more ceremony.
        let worker_for_serve = worker.clone();
        // Keep the graph fresh for the life of the node. The watcher does the initial index on its
        // own thread, so a large tree never delays the port coming up; `WA_GRAPH_WATCH=0` disables it.
        let _graph_watch = if std::env::var("WA_GRAPH_WATCH").map(|value| value != "0").unwrap_or(true) {
            match wa_graph::watch::spawn(graph_root.clone(), graph_db.clone()) {
                Ok(handle) => Some(handle),
                Err(error) => {
                    eprintln!("graph_watch_unavailable: {error}");
                    None
                }
            }
        } else {
            None
        };
        serve::run(lua, Box::new(move || worker_for_serve()), port, PathBuf::from(ui));
        return;
    }

    if command == "rendezvous" {
        let port = flag(&lua_args, "--port").and_then(|value| value.parse().ok()).unwrap_or(8890);
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
        let db = flag(&lua_args, "--db")
            .unwrap_or_else(|| format!("{home}/.wasm-agent/rendezvous.db"));
        if let Some(parent) = std::path::Path::new(&db).parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let bind = flag(&lua_args, "--bind").unwrap_or_else(|| "127.0.0.1".into());
        rendezvous::run(&bind, port, &db);
        return;
    }

    if command == "node" {
        match node::Identity::load() {
            Ok(identity) => {
                if lua_args.get(1).map(String::as_str) == Some("sign") {
                    let message = lua_args.get(2).cloned().unwrap_or_default();
                    println!("{}", identity.sign(&message));
                } else {
                    println!(
                        "{}",
                        serde_json::json!({
                            "node_id": identity.node_id,
                            "public_key": identity.public_key,
                        })
                    );
                }
            }
            Err(error) => {
                eprintln!("node identity: {error}");
                std::process::exit(1);
            }
        }
        return;
    }

    if let Err(error) = lua.do_string(&core_source("lua/core/subagents.lua"), "lua/core/subagents.lua") {
        eprintln!("lua error: {error}");
        std::process::exit(1);
    }
    if let Err(error) = lua.do_string(&core_source("lua/core/init.lua"), "lua/core/init.lua") {
        eprintln!("lua error: {error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod db_tests {
    use super::*;

    /// Each interpreter owns its own connection to the same WAL file, so a
    /// transaction one holds open is invisible to another; closing a connection
    /// rolls back a transaction it left open; and repeated open/close is clean.
    #[test]
    fn per_interpreter_connections_are_isolated_and_drop_rolls_back() {
        let dir = std::env::temp_dir().join(format!("wa-db-life-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("memory.db").to_string_lossy().to_string();
        {
            let setup = open_db(&path);
            setup.execute_batch("CREATE TABLE IF NOT EXISTS t(k TEXT PRIMARY KEY)").unwrap();
        }
        // Repeated create/drop: the pool spawns and retires interpreters all day.
        for _ in 0..8 {
            let connection = open_db(&path);
            let _: i64 = connection.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
        }
        let a = open_db(&path);
        let b = open_db(&path);
        a.execute_batch("BEGIN IMMEDIATE").unwrap();
        a.execute("INSERT INTO t(k) VALUES('a')", []).unwrap();
        let visible: i64 = b.query_row("SELECT COUNT(*) FROM t WHERE k='a'", [], |row| row.get(0)).unwrap();
        assert_eq!(visible, 0, "an uncommitted row must not be visible on another interpreter's connection");
        a.execute_batch("ROLLBACK").unwrap();
        // A transaction left open is rolled back when the interpreter's connection closes.
        a.execute_batch("BEGIN IMMEDIATE").unwrap();
        a.execute("INSERT INTO t(k) VALUES('b')", []).unwrap();
        drop(a);
        let after: i64 = b.query_row("SELECT COUNT(*) FROM t WHERE k='b'", [], |row| row.get(0)).unwrap();
        assert_eq!(after, 0, "closing a connection must roll back its open transaction");
        // A statement error is RETURNED, not forced into a rollback: the caller can
        // recover inside the transaction. BEGIN; INSERT A; a bad statement; INSERT B;
        // explicit ROLLBACK must remove BOTH rows. A forced rollback here would have
        // ended the transaction, made INSERT B autocommit, and left it behind.
        b.execute_batch("BEGIN IMMEDIATE").unwrap();
        b.execute("INSERT INTO t(k) VALUES('c')", []).unwrap();
        let bad = b.execute("INSERT INTO no_such_table(k) VALUES('x')", []);
        assert!(bad.is_err(), "a bad statement must return an error");
        assert!(!b.is_autocommit(), "a returned statement error must not end the transaction");
        b.execute("INSERT INTO t(k) VALUES('d')", []).unwrap();
        b.execute_batch("ROLLBACK").unwrap();
        let recovered: i64 = b.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
        assert_eq!(recovered, 0, "an explicit rollback must remove both rows, not leave the second autocommitted");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// `:memory:` must be one shared database, not a silent per-interpreter split.
    #[test]
    fn an_in_memory_database_is_shared_not_split() {
        let first = open_db(":memory:");
        let second = open_db(":memory:");
        first.execute_batch("CREATE TABLE IF NOT EXISTS mem(k TEXT PRIMARY KEY)").unwrap();
        first.execute("INSERT INTO mem(k) VALUES('x')", []).unwrap();
        let seen: i64 = second.query_row("SELECT COUNT(*) FROM mem", [], |row| row.get(0)).unwrap();
        assert_eq!(seen, 1, "an in-memory database must be shared across interpreters");
    }
}
