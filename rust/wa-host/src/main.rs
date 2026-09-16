//! `wa` host: a Rust binary with vendored Lua, SQLite, HTTP and WASM plugins.
//!
//! The agent logic lives in Lua (`lua/`); this host only provides capabilities
//! (sqlite, http, wasmtime, sha256, uuid, time, files). No Python anywhere.
mod host;
mod lua;
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
    let host = Box::into_raw(Box::new(Host { db: Mutex::new(connection), plugins: Mutex::new(plugin_registry) }));

    let lua = Lua::new();
    lua.push_table();
    lua.register_with_upvalue("sql_exec", host::sql_exec, host as *mut c_void);
    lua.register_with_upvalue("sql_query", host::sql_query, host as *mut c_void);
    lua.register("sha256", host::sha256);
    lua.register("uuid", host::uuid);
    lua.register("read_file", host::read_file);
    lua.register("http", host::http);
    lua.register("http_stream", host::http_stream);
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
        serve::run(&lua, port, PathBuf::from(ui));
        return;
    }

    if let Err(error) = lua.do_string(embedded("lua/core/init.lua"), "lua/core/init.lua") {
        eprintln!("lua error: {error}");
        std::process::exit(1);
    }
}
