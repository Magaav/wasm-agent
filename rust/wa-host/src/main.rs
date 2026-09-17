//! `wa` host: a Rust binary with vendored Lua, SQLite, HTTP and WASM plugins.
//!
//! The agent logic lives in Lua (`lua/`); this host only provides capabilities
//! (sqlite, http, wasmtime, sha256, uuid, time, files). No Python anywhere.
mod client_bridge;
mod host;
mod lua;
mod node;
mod relay_client;
mod rendezvous;
mod plugins;
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
    ("lua/core/memory.lua", include_str!("../../../lua/core/memory.lua")),
    ("lua/core/tools.lua", include_str!("../../../lua/core/tools.lua")),
    ("lua/core/users.lua", include_str!("../../../lua/core/users.lua")),
    ("lua/core/spells.lua", include_str!("../../../lua/core/spells.lua")),
    ("lua/core/nodes.lua", include_str!("../../../lua/core/nodes.lua")),
    ("lua/core/state.lua", include_str!("../../../lua/core/state.lua")),
    ("lua/core/provider.lua", include_str!("../../../lua/core/provider.lua")),
    ("lua/core/agent.lua", include_str!("../../../lua/core/agent.lua")),
    ("lua/core/chat.lua", include_str!("../../../lua/core/chat.lua")),
    ("lua/core/server.lua", include_str!("../../../lua/core/server.lua")),
    ("lua/core/init.lua", include_str!("../../../lua/core/init.lua")),
];

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
fn resolve_home() -> String {
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

/// Load KEY=VALUE pairs from ~/.wasm-agent/env without overwriting real env.
fn load_env_file() {
    let home = std::env::var("HOME").unwrap_or_default();
    let Ok(text) = std::fs::read_to_string(format!("{home}/.wasm-agent/env")) else {
        return;
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
            }
        }
    }
}

fn main() {
    // Publish the resolved home through HOME before anything reads it: the Lua
    // core, the node key, the plugin directory and the config file all derive
    // their paths from HOME, so one resolution here fixes them together.
    let home = resolve_home();
    std::env::set_var("HOME", &home);
    load_env_file();
    let args: Vec<String> = std::env::args().skip(1).collect();
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
    if let Some(parent) = std::path::Path::new(&db).parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let connection = Connection::open(&db).expect("open database");
    connection
        .execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;\
             PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;",
        )
        .expect("pragma");
    let plugin_registry = plugins::PluginRegistry::load(&plugins::plugin_dir());
    let bridge = std::sync::Arc::new(client_bridge::Bridge::new());
    let host = Box::into_raw(Box::new(Host {
        db: Mutex::new(connection),
        plugins: Mutex::new(plugin_registry),
        client: bridge.clone(),
    }));

    let lua = Lua::new();
    lua.push_table();
    lua.register_with_upvalue("sql_exec", host::sql_exec, host as *mut c_void);
    lua.register_with_upvalue("sql_query", host::sql_query, host as *mut c_void);
    lua.register("sha256", host::sha256);
    lua.register("uuid", host::uuid);
    lua.register("read_file", host::read_file);
    lua.register("write_file", host::write_file);
    lua.register("exec", host::exec);
    lua.register("sleep", host::sleep);
    lua.register("node_identity", host::node_identity);
    lua.register("sign", host::sign);
    lua.register("verify", host::verify);
    lua.register_with_upvalue("client", host::client, host as *mut c_void);
    lua.register_with_upvalue("client_status", host::client_status, host as *mut c_void);
    lua.register("http", host::http);
    lua.register("http_stream", host::http_stream);
    lua.register("relay", host::relay);
    lua.register_with_upvalue("plugins", host::plugins, host as *mut c_void);
    lua.register_with_upvalue("invoke", host::invoke, host as *mut c_void);
    lua.register("stream", host::stream);
    lua.register("now", host::now);
    lua.register("log", host::log);
    lua.set_global("host");

    lua.push_table();
    for (index, arg) in lua_args.iter().enumerate() {
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
    let bootstrap = "function dofile(path) local source = EMBEDDED[path]; \
         if not source then error('embedded module missing: ' .. tostring(path)) end; \
         return assert(load(source, '@' .. path))() end";
    if let Err(error) = lua.do_string(bootstrap, "bootstrap") {
        eprintln!("lua error: {error}");
        std::process::exit(1);
    }

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
        if let Err(error) = lua.do_string(embedded("lua/core/server.lua"), "lua/core/server.lua") {
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
        serve::run(&lua, port, PathBuf::from(ui));
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

    if let Err(error) = lua.do_string(embedded("lua/core/init.lua"), "lua/core/init.lua") {
        eprintln!("lua error: {error}");
        std::process::exit(1);
    }
}
