//! `wa` host: a Rust binary with vendored Lua, SQLite and HTTP capabilities.
//!
//! The agent logic lives in Lua (`lua/`); this host only provides capabilities
//! (sqlite, sha256, uuid, time, files, http). No Python anywhere.
mod host;
mod lua;

use host::Host;
use lua::Lua;
use rusqlite::Connection;
use std::ffi::{c_int, c_void};
use std::sync::Mutex;

fn db_path(args: &[String]) -> String {
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--db" {
            if let Some(path) = iter.next() {
                return path.clone();
            }
        }
        if let Some(path) = arg.strip_prefix("--db=") {
            return path.to_string();
        }
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    format!("{home}/.wasm-agent/memory.db")
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
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
    let host = Box::into_raw(Box::new(Host { db: Mutex::new(connection) }));

    let lua = Lua::new();
    lua.push_table();
    lua.register_with_upvalue("sql_exec", host::sql_exec, host as *mut c_void);
    lua.register_with_upvalue("sql_query", host::sql_query, host as *mut c_void);
    lua.register("sha256", host::sha256);
    lua.register("uuid", host::uuid);
    lua.register("read_file", host::read_file);
    lua.register("now", host::now);
    lua.register("log", host::log);
    lua.set_global("host");

    lua.push_table();
    for (index, arg) in lua_args.iter().enumerate() {
        lua.push_string(arg);
        lua.raw_seti((index + 1) as c_int);
    }
    lua.set_global("args");

    let script = std::env::var("WA_SCRIPT").unwrap_or_else(|_| "lua/core/init.lua".to_string());
    let source = std::fs::read_to_string(&script).unwrap_or_else(|e| panic!("read {script}: {e}"));
    if let Err(error) = lua.do_string(&source, &script) {
        eprintln!("lua error: {error}");
        std::process::exit(1);
    }
}
