//! luarunner <guest.wasm> <script.lua> [granted-dir]
//! Hosts the Lua component and implements `host-call` generically (getenv, now, monotonic_ms,
//! sha256, read_file under the granted dir, sql_exec/sql_query on an in-memory SQLite, noop).
//! Prints compile / instantiate / first-run times and the script's result.
use anyhow::Result;
use std::time::Instant;
use wasmtime::component::{Component, HasSelf, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({ world: "lua-core", path: "../wit" });

struct State {
    wasi: WasiCtx,
    table: ResourceTable,
    granted: std::path::PathBuf,
    db: rusqlite::Connection,
    start: Instant,
    calls: u64,
}
impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

impl wa::spike::host_call::Host for State {
    fn call(&mut self, name: String, args: Vec<String>) -> Result<Vec<String>, String> {
        self.calls += 1;
        let arg = |i: usize| args.get(i).cloned().unwrap_or_default();
        match name.as_str() {
            "noop" => Ok(vec![]),
            "now" => Ok(vec![format!("{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs())]),
            "monotonic_ms" => Ok(vec![format!("{:.3}", self.start.elapsed().as_secs_f64() * 1000.0)]),
            "getenv" => Ok(std::env::var(arg(0)).map(|v| vec![v]).unwrap_or_default()),
            "sha256" => Ok(vec![hex(ring::digest::digest(&ring::digest::SHA256, arg(0).as_bytes()).as_ref())]),
            "read_file" => {
                let path = std::path::Path::new(&arg(0)).to_path_buf();
                let canon = path.canonicalize().map_err(|e| e.to_string())?;
                if !canon.starts_with(self.granted.canonicalize().map_err(|e| e.to_string())?) {
                    return Err("read_file outside the granted directory".into());
                }
                Ok(vec![std::fs::read_to_string(canon).map_err(|e| e.to_string())?])
            }
            "sql_exec" => {
                self.db.execute_batch(&arg(0)).map_err(|e| e.to_string())?;
                Ok(vec![r#"{"ok":true}"#.into()])
            }
            "sql_query" => {
                let mut stmt = self.db.prepare(&arg(0)).map_err(|e| e.to_string())?;
                let cols = stmt.column_count();
                let names: Vec<String> = (0..cols).map(|i| stmt.column_name(i).unwrap_or("").to_string()).collect();
                let mut rows = stmt.query([]).map_err(|e| e.to_string())?;
                let mut out = Vec::new();
                while let Some(row) = rows.next().map_err(|e| e.to_string())? {
                    let mut obj = serde_json::Map::new();
                    for (i, n) in names.iter().enumerate() {
                        let v: rusqlite::types::Value = row.get(i).map_err(|e| e.to_string())?;
                        let j = match v {
                            rusqlite::types::Value::Integer(x) => serde_json::json!(x),
                            rusqlite::types::Value::Real(x) => serde_json::json!(x),
                            rusqlite::types::Value::Text(x) => serde_json::json!(x),
                            _ => serde_json::Value::Null,
                        };
                        obj.insert(n.clone(), j);
                    }
                    out.push(serde_json::Value::Object(obj));
                }
                Ok(vec![serde_json::Value::Array(out).to_string()])
            }
            other => Err(format!("unknown host capability: {other}")),
        }
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let guest = &args[1];
    let script = std::fs::read_to_string(&args[2])?;
    let granted = std::path::PathBuf::from(args.get(3).cloned().unwrap_or_else(|| ".".into()));
    let mut config = Config::new();
    config.wasm_component_model(true);
    config.wasm_exceptions(true);
    let engine = Engine::new(&config)?;
    let t = Instant::now();
    let component = Component::from_file(&engine, guest)?;
    let compile_ms = t.elapsed().as_secs_f64() * 1000.0;
    let mut linker = Linker::<State>::new(&engine);
    // wasi-libc's exit() imports wasi:cli/exit's `exit-with-code`, an opt-in (unstable) function.
    let mut options = wasmtime_wasi::p2::bindings::sync::LinkOptions::default();
    options.cli_exit_with_code(true);
    wasmtime_wasi::p2::add_to_linker_with_options_sync(&mut linker, &options)?;
    LuaCore::add_to_linker::<State, HasSelf<State>>(&mut linker, |s| s)?;
    let state = State { wasi: WasiCtxBuilder::new().inherit_stdout().inherit_stderr().inherit_env().build(), table: ResourceTable::new(), granted, db: rusqlite::Connection::open_in_memory()?, start: Instant::now(), calls: 0 };
    let mut store = Store::new(&engine, state);
    let t = Instant::now();
    let core = LuaCore::instantiate(&mut store, &component, &linker)?;
    let inst_ms = t.elapsed().as_secs_f64() * 1000.0;
    let t = Instant::now();
    let trivial = core.call_run(&mut store, "return 1", "trivial")?;
    let trivial_ms = t.elapsed().as_secs_f64() * 1000.0;
    let t = Instant::now();
    let result = core.call_run(&mut store, &script, &args[2])?;
    let run_ms = t.elapsed().as_secs_f64() * 1000.0;
    println!("runner: compile {compile_ms:.0} ms | instantiate {inst_ms:.1} ms | trivial chunk {trivial_ms:.2} ms (new state + load + run) | script {run_ms:.0} ms | host calls {}", store.data().calls);
    match result {
        Ok(text) => println!("result: {text}"),
        Err(error) => println!("lua error: {error}"),
    }
    Ok(())
}
