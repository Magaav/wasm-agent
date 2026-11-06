//! `wa` host: a Rust binary with vendored Lua, SQLite, HTTP and WASM plugins.
//!
//! The agent logic lives in Lua (`lua/`); this host only provides capabilities
//! (sqlite, http, wasmtime, sha256, uuid, time, files). No Python anywhere.
//!
//! Since the split (docs/KERNEL.md) this binary is only the wiring: it resolves HOME, opens the
//! interpreter, dispatches the CLI and hands the run to a library crate. The capabilities themselves
//! live in `wa-capabilities`, the wasm runtime in `wa-kernel-runtime`, the policy in
//! `wa-governance`, the console in `wa-term`, the transport in `wa-rendezvous` and the Lua ABI,
//! paths and shared JSON answer in `wa-host-support`.
use wa_capabilities::{capabilities, client_bridge, core_component, graph, host, plugins, ripgrep, serve, subagents};
use wa_capabilities::host::Host;
use rusqlite::Connection;
// `wa dev` (docs/SERVICE-COMPONENTS.md): build a component crate and swap the running instance.
mod dev;
// The floor of the split: the Lua ABI, the host's paths and the shared JSON answer (docs/KERNEL.md).
use wa_host_support::lua::Lua;
use wa_host_support::paths::{private_dir, resolve_home};
// Node identity and its transport: the CLI dispatches `rendezvous`/`binding` commands through them.
use wa_rendezvous::{binding_runtime, node, rendezvous};
use std::ffi::{c_int, c_void};
use std::path::PathBuf;
use std::sync::Mutex;

// Generated from the Lua tree at build time: new modules ship without a second registry edit.
include!(concat!(env!("OUT_DIR"), "/embedded.rs"));

/// Source for one of the entry modules the host loads itself.
///
/// `dofile` prefers the on-disk copy when WASM_AGENT_LUA_ROOT is set, but these
/// two are read straight from the binary - so editing `lua/core/init.lua` had no
/// effect at all, which is exactly how a self-evolution run lost its budget: it
/// added a command, ran it, saw "unknown command", and went looking through the
/// Rust host for the reason. Dev mode has to cover every entry point or it is a
/// trap.
fn core_source(name: &str) -> String {
    if let Some(root) = lua_root() {
        return std::fs::read_to_string(format!("{root}/{name}")).unwrap_or_else(|error| {
            // The rule `dofile`'s bootstrap already follows, for the same reason: a set-but
            // unreadable root is an error, not a fallback. Falling back here would run
            // `lua/core/init.lua` - or server.lua, or subagents.lua - out of the binary while the
            // operator believes they are running the checkout, and the run would not say so.
            eprintln!("lua_root_unreadable: {root}/{name}: {error}");
            std::process::exit(2);
        });
    }
    match installed_tree() {
        Some(tree) => tree.files.get(name).cloned().unwrap_or_else(|| embedded(name).to_string()),
        None => embedded(name).to_string(),
    }
}

/// An installed Lua tree: Lua-only deploys install `lua-core/` beside the binary instead of
/// recompiling it (scripts/deploy.sh fast path). It replaces the compiled-in copy - not dev mode:
/// no WASM_AGENT_LUA_ROOT semantics, no checkout paths - and only when its manifest verifies:
/// every file's sha256, and the capability digest equal to this binary's own (a Lua change that
/// needs a host capability this binary lacks must not run on it). Anything else: the compiled-in
/// copy, with the reason on stderr once.
struct LuaTree {
    commit: String,
    files: std::collections::BTreeMap<String, String>,
}

fn lua_tree_dir() -> Option<std::path::PathBuf> {
    if let Ok(dir) = std::env::var("WA_LUA_TREE") {
        return (!dir.is_empty()).then(|| PathBuf::from(dir));
    }
    Some(std::env::current_exe().ok()?.parent()?.join("lua-core"))
}

fn load_lua_tree() -> Result<LuaTree, String> {
    let dir = lua_tree_dir().ok_or("no install directory")?;
    let manifest = std::fs::read_to_string(dir.join("manifest.txt")).map_err(|_| "no manifest".to_string())?;
    let (mut digest, mut commit, mut files) = (String::new(), String::new(), std::collections::BTreeMap::new());
    for line in manifest.lines() {
        if let Some(value) = line.strip_prefix("capabilities ") {
            digest = value.trim().to_string();
        } else if let Some(value) = line.strip_prefix("commit ") {
            commit = value.trim().to_string();
        } else if let Some((hash, name)) = line.split_once("  ") {
            if name.contains("..") || name.starts_with('/') {
                return Err(format!("unsafe path {name}"));
            }
            let text = std::fs::read_to_string(dir.join(name)).map_err(|_| format!("missing {name}"))?;
            let actual: String = ring::digest::digest(&ring::digest::SHA256, text.as_bytes()).as_ref().iter().map(|b| format!("{b:02x}")).collect();
            if actual != hash.trim() {
                return Err(format!("hash mismatch {name}"));
            }
            files.insert(name.to_string(), text);
        }
    }
    if digest != capabilities::digest() {
        return Err("capability digest differs from this binary (the tree needs a rebuild)".into());
    }
    if !files.contains_key("lua/core/init.lua") {
        return Err("incomplete tree (no lua/core/init.lua)".into());
    }
    Ok(LuaTree { commit, files })
}

fn installed_tree() -> Option<&'static LuaTree> {
    static TREE: std::sync::OnceLock<Option<LuaTree>> = std::sync::OnceLock::new();
    TREE.get_or_init(|| match load_lua_tree() {
        Ok(tree) => Some(tree),
        Err(reason) => {
            if reason != "no manifest" {
                eprintln!("lua: installed tree ignored ({reason}); using the compiled-in core");
            }
            None
        }
    })
    .as_ref()
}

/// The Lua root in force, if there is one: `WASM_AGENT_LUA_ROOT` set to something
/// that can name a directory. The entry modules, `dofile`'s bootstrap rule and the
/// notice a script run prints when its modules come from the binary all ask here, so
/// they cannot disagree about which copy of the Lua is being loaded.
fn lua_root() -> Option<String> {
    let root = std::env::var("WASM_AGENT_LUA_ROOT").ok()?;
    let trimmed = root.trim_end_matches(['/', '\\']);
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
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
            // FULL, not NORMAL: in WAL mode NORMAL can lose the last commits on power loss, and the
            // node's durable records (claims, operations, receipts) must survive a reboot.
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;\
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
    let args: Vec<String> = std::env::args().skip(1).collect();
    // `wa dev` before anything that touches the node. It builds and runs a component crate from its
    // own `.wa-dev/` directory, so it needs no database, no graph, no Lua tree, and - since it is a
    // development loop - no node environment file either: a dev run must not pick up a node's
    // secrets. It exits on its own when told `--once`; in watch mode it owns the terminal.
    if args.first().is_some_and(|arg| arg == "dev") {
        if args.iter().any(|arg| arg == "--help" || arg == "-h") {
            println!("usage: wa dev <component-dir> [--once] [--config <json>] [--net <host:port>] [--release] [--restart]
  build a component crate on change and hot-swap the running instance (docs/SERVICE-COMPONENTS.md)");
            return;
        }
        std::process::exit(dev::run(&args[1..]));
    }
    // Publish the resolved home through HOME before anything reads it: the Lua
    // core, the node key, the plugin directory and the config file all derive
    // their paths from HOME, so one resolution here fixes them together.
    let home = resolve_home();
    std::env::set_var("HOME", &home);
    let from_file = load_env_file();
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
    if args.first().is_some_and(|arg| arg == "--capability-digest") {
        println!("{}", capabilities::digest());
        return;
    }
    if args.first().is_some_and(|arg| arg == "--lua-tree") {
        match load_lua_tree() {
            Ok(tree) => println!("installed lua tree: commit {} ({} files) at {}", tree.commit, tree.files.len(), lua_tree_dir().map(|d| d.display().to_string()).unwrap_or_default()),
            Err(reason) => println!("compiled-in lua core ({reason})"),
        }
        return;
    }
    if args.iter().any(|arg| arg == "--version" || arg == "-v") {
        println!("wasm-agent {}", env!("CARGO_PKG_VERSION"));
        return;
    }
    // Every node and node-thread gets rg, including service launches with a sparse PATH. Installation
    // happens before model execution and a failure is said out loud - but it no longer stops the node:
    // offline, firewalled or with GitHub down, exiting here put a service into a restart loop it could
    // never leave, while the `grep` tool has its own built-in search and only a bare `rg` in `bash` needs it.
    if let Err(error) = ripgrep::ensure(std::path::Path::new(&home)) {
        eprintln!("ripgrep_unavailable: {error:#} (continuing: the grep tool does not need it; `rg` in bash will fail)");
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
        private_dir(parent);
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
    // so a retired node-thread leaves no connection and no open transaction behind.
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
    // Every `host.*` function comes from the one registry in `capabilities.rs`. Registration and
    // the inventory are the same act: a capability this list does not name cannot be called, so
    // the CLI, `/health` and the codemode sandbox cannot drift from what is actually registered.
    capabilities::register(&lua, host_ptr);
    lua.set_global("host");

    lua.push_table();
    for (index, arg) in boot_args.iter().enumerate() {
        lua.push_string(arg);
        lua.raw_seti((index + 1) as c_int);
    }
    lua.set_global("args");

    // The shipping copy: the verified installed Lua tree when there is one, else compiled in.
    lua.push_table();
    for (name, source) in EMBEDDED {
        lua.push_string(source);
        lua.set_field(-2, name);
    }
    if let Some(tree) = installed_tree() {
        for (name, source) in &tree.files {
            lua.push_string(source);
            lua.set_field(-2, name);
        }
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
    let interpreter_factory: std::sync::Arc<dyn Fn() -> Lua + Send + Sync> = std::sync::Arc::new(move || {
        let state = boot_state();
        // A pool node-thread or a child interpreter must never take the process down
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
    binding_runtime::set_factory(interpreter_factory.clone());
    let factory_for_subagents = interpreter_factory.clone();
    subagents::set_factory(Box::new(move || factory_for_subagents()));

    // The same run inside the agent-core component: every `host.*` crosses wa:kernel/host.call
    // into this interpreter (core_component.rs, docs/KERNEL.md "A2.1").
    if lua_args.first().is_some_and(|arg| arg == "--core-component") {
        if lua_root().is_none() {
            eprintln!("lua root unset: using embedded modules; edits under lua/ are NOT under test");
        }
        let code = core_component::run_cli(lua, &lua_args[1..]);
        host::restore_input();
        std::process::exit(code);
    }
    if let Ok(script) = std::env::var("WA_SCRIPT") {
        // Say which copy of the Lua this run will load, before it loads any.
        //
        // With no root, `dofile` resolves every module from the copy compiled into this binary, so
        // a focused test written to exercise an edit under `lua/` runs green while never loading
        // that edit - one node-thread lost a whole green run (28 checks) to the binary's own
        // `update.lua`, and the only tell was a line number in a message. One line on stderr, once,
        // and only for a script run: an installed node runs without a root by design, and a root
        // that IS set is still preferred for the modules, so there is nothing to warn about then.
        if lua_root().is_none() {
            eprintln!("lua root unset: using embedded modules; edits under lua/ are NOT under test");
        }
        let source = std::fs::read_to_string(&script).unwrap_or_else(|e| panic!("read {script}: {e}"));
        if let Err(error) = lua.do_string(&source, &script) {
            host::restore_input();
            eprintln!("lua error: {error}");
            std::process::exit(1);
        }
        host::restore_input();
        return;
    }

    let command = lua_args.first().map(String::as_str).unwrap_or("");
    // A server command asked for help must answer and exit, never start: `wa rendezvous --help`
    // used to bind its port and block in accept() forever - and an agent reading usage before using a
    // command (which is what it should do) then hung its own run on a tool call that never returns.
    if (command == "serve" || command == "rendezvous")
        && lua_args.iter().skip(1).any(|arg| arg == "--help" || arg == "-h")
    {
        if command == "serve" {
            println!("usage: wa serve [--port 8799] [--ui <dir>] [--client-port 8800]\n  run this node's HTTP server and web UI (blocks until stopped)");
        } else {
            println!("usage: wa rendezvous [--port 8890] [--bind 127.0.0.1] [--db <path>]\n  run a rendezvous server that nodes register with (blocks until stopped)");
        }
        return;
    }

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
        binding_runtime::set_serving();
        if binding_runtime::present() {
            if let Err(error)=binding_runtime::transport("serve"){eprintln!("binding_transport:{error}");std::process::exit(2);}
        } else {
            // A node that is already serving when it is bound must still begin ticking once
            // `binding.json` appears: `/bind` on a live node writes it after this point, and a bind
            // driven from a CLI exits with the request merely submitted. Without this the node serves
            // forever with the registry saying `accepted` and no outbound runtime at all - no
            // pending->accepted flip, no `/register`, `active`/`registered` false (measured 2026-11-01).
            std::thread::Builder::new().name("wa-binding-appear".into()).spawn(|| {
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(2));
                    if !binding_runtime::present() { continue; }
                    // Never exits the node from here: it is already serving, so a refused lease is a
                    // reported state, not a reason to take the UI down.
                    match binding_runtime::transport("serve") {
                        Ok(_)=>return,
                        Err(error)=>{eprintln!("binding_transport:{error}"); std::thread::sleep(std::time::Duration::from_secs(15));}
                    }
                }
            }).ok();
        }
        if let Ok(rendezvous_url) = std::env::var("WASM_AGENT_RENDEZVOUS") {
            if !rendezvous_url.is_empty() {
                node::spawn_heartbeat(rendezvous_url);
            }
        }
        // The pool builds its own interpreters on demand from the factory registered above, so what it needs is a way to make one
        // rather than a pile of them up front. The host pointer travels as a usize because it is a leaked raw
        // pointer for the life of the process; a newtype with an unsafe Send would be the same claim with
        // more ceremony.
        let factory_for_serve = interpreter_factory.clone();
        // Keep the graph fresh for the life of the node. The scheduler does the initial index on its
        // own thread (through the graph component), so a large tree never delays the port coming up.
        graph::watch_configured();
        serve::run(lua, Box::new(move || factory_for_serve()), port, PathBuf::from(ui));
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
        host::restore_input();
        eprintln!("lua error: {error}");
        std::process::exit(1);
    }
    host::restore_input();
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
