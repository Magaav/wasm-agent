//! `wa-core-pool-bench` - the caller the A2.3 instance pool was built for, outside the binary.
//!
//! Three things live here, all of them about the pool in `wa_capabilities::core_component`:
//!
//! - `bench <agent-core.wasm>`: the numbers docs/KERNEL.md ("A2.3") quotes - time to the first Lua
//!   statement cold, from a warm pool, and from an instance whose snapshot is already answered, plus
//!   linear memory per instance. Medians of five, printed as a table.
//! - `gate <agent-core.wasm> <script.lua> [args...]`: one script through `acquire -> run -> release`,
//!   which is what `scripts/test.sh`'s core-component blocks grep to prove the pooled path answers the
//!   same as `wa --core-component`.
//! - `concurrency <agent-core.wasm> <n> <script.lua>`: `n` callers holding `n` leases at once, and the
//!   assertion that each of them ran on an instance no other caller had used.
//!
//! The native interpreter a slot answers from is `core_component::boot_native_state` (the registry, its
//! own SQLite connection, `EMBEDDED`), because `wa-host`'s `boot_state` is in the binary and a benchmark
//! must not be the reason the binary grows a mode it does not serve yet.
use std::path::Path;
use std::sync::{Arc, Barrier};
use std::time::{Duration, Instant};
use wa_kernel_runtime::components::PoolLimits;
use wa_capabilities::core_component::{
    boot_native_state, CoreComponentPool, CorePoolConfig, NativeFactory, RunReport, Script,
};

/// The module the measured fixture loads through `EMBEDDED`. Reading it is a host answer the guest
/// snapshots per instance, so this is the fixture's evidence that the snapshot is real.
const FIXTURE_MODULE: &str = include_str!("../../../benchmarks/agent-core-pool/fixtures/pool-fixture-module.lua");
const FIXTURES: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../benchmarks/agent-core-pool/fixtures");
const RUNS: usize = 5;

fn embedded() -> Vec<(&'static str, &'static str)> {
    vec![("bench/pool-fixture-module.lua", FIXTURE_MODULE)]
}

/// One native interpreter, as a slot boots it: the registry on a fresh `Lua` with its own connection,
/// in the home this process resolved (`WASM_AGENT_HOME` first, as the binary does).
fn factory(db: &str) -> NativeFactory {
    let db = db.to_string();
    let home = wa_host_support::paths::resolve_home();
    Arc::new(move || boot_native_state(&home, &db, &[], &embedded()).expect("boot the native interpreter"))
}

/// A pool sized for exactly the instances a measurement asks for, so the pooling allocator reserves
/// what the run uses and the reservation number printed with the memory figures is the real one.
fn config(max_instances: usize, warm: usize) -> CorePoolConfig {
    let n = max_instances as u32;
    CorePoolConfig {
        limits: PoolLimits {
            component_instances: n,
            core_instances: n * 4 + 8,
            memories: n * 4 + 8,
            tables: n * 4 + 8,
            stacks: n * 4 + 8,
            gc_heaps: n * 2 + 8,
            max_memory_bytes: 256 << 20,
        },
        max_instances,
        warm,
        acquire_timeout: Duration::from_secs(30),
        memory_limit: 256 << 20,
    }
}

fn median(values: &mut [f64]) -> f64 {
    values.sort_by(|a, b| a.partial_cmp(b).expect("finite timings"));
    values[values.len() / 2]
}

fn read_wasm(path: &Path) -> Result<Vec<u8>, String> {
    std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))
}

fn fixture(name: &str) -> Result<String, String> {
    let path = Path::new(FIXTURES).join(name);
    std::fs::read_to_string(&path).map_err(|e| format!("read {}: {e}", path.display()))
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(command) = args.first().map(String::as_str) else {
        eprintln!("usage: wa-core-pool-bench bench|gate|concurrency <agent-core.wasm> ...");
        std::process::exit(2);
    };
    let result = match command {
        "bench" => match args.get(1) {
            Some(wasm) => bench(Path::new(wasm)),
            None => Err("bench needs the agent-core .wasm".to_string()),
        },
        "gate" => match (args.get(1), args.get(2)) {
            (Some(wasm), Some(script)) => gate(Path::new(wasm), script, &args[3..]),
            _ => Err("gate needs <agent-core.wasm> <script.lua> [args...]".to_string()),
        },
        "concurrency" => match (args.get(1), args.get(2), args.get(3)) {
            (Some(wasm), Some(count), Some(script)) => match count.parse::<usize>() {
                Ok(count) => concurrency(Path::new(wasm), count, script),
                Err(e) => Err(format!("concurrency: {count} is not a count: {e}")),
            },
            _ => Err("concurrency needs <agent-core.wasm> <n> <script.lua>".to_string()),
        },
        other => Err(format!("unknown command {other}")),
    };
    if let Err(error) = result {
        eprintln!("wa-core-pool-bench_failed: {error}");
        std::process::exit(1);
    }
}

/// One script through `acquire -> run_script -> release`: the pooled equivalent of
/// `wa --core-component <wasm> <script>`, with the report on stderr so the script's own output stays
/// exactly what a caller greps.
fn gate(wasm: &Path, script: &str, script_args: &[String]) -> Result<(), String> {
    let bytes = read_wasm(wasm)?;
    let db = std::env::var("WA_AGENT_DB").unwrap_or_else(|_| ":memory:".to_string());
    let source = std::fs::read_to_string(script).map_err(|e| format!("read {script}: {e}"))?;
    let started = Instant::now();
    let pool = CoreComponentPool::new(factory(&db), &bytes, config(1, 1)).map_err(|e| format!("pool: {e}"))?;
    let mut lease = pool.acquire().map_err(|e| format!("acquire: {e}"))?;
    let report = lease.run_script(Script::source(script, &source), script_args).map_err(|e| format!("run: {e}"))?;
    eprintln!(
        "pool_timing: pool={:.1}ms run={:.1}ms first_host_call={:?} host_calls={} memory={}B runs_on_instance={} compiled_from={}",
        started.elapsed().as_secs_f64() * 1000.0,
        report.run_ms,
        report.first_host_call_ms.map(|ms| (ms * 100.0).round() / 100.0),
        report.host_calls,
        report.memory_bytes,
        report.runs_on_instance,
        pool.compiled_from()
    );
    drop(lease);
    if report.code != 0 {
        std::process::exit(report.code);
    }
    Ok(())
}

/// `n` callers, `n` leases held at the same time, one instance each.
fn concurrency(wasm: &Path, callers: usize, script: &str) -> Result<(), String> {
    if callers == 0 {
        return Err("concurrency needs at least one caller".to_string());
    }
    let bytes = read_wasm(wasm)?;
    let db = std::env::var("WA_AGENT_DB").unwrap_or_else(|_| ":memory:".to_string());
    let source = std::fs::read_to_string(script).map_err(|e| format!("read {script}: {e}"))?;
    let pool = Arc::new(
        CoreComponentPool::new(factory(&db), &bytes, config(callers, callers)).map_err(|e| format!("pool: {e}"))?,
    );
    // Callers + this thread: every caller holds its lease before any of them runs.
    let barrier = Arc::new(Barrier::new(callers + 1));
    let reports: Vec<RunReport> = std::thread::scope(|scope| {
        let mut handles = Vec::with_capacity(callers);
        for _ in 0..callers {
            let pool = Arc::clone(&pool);
            let barrier = Arc::clone(&barrier);
            let source = &source;
            handles.push(scope.spawn(move || {
                let mut lease = pool.acquire().expect("acquire an instance");
                barrier.wait();
                let report = lease.run_script(Script::source("pool-concurrency", source), &[]).expect("run the script");
                (report, lease.runs())
            }));
        }
        barrier.wait();
        handles
            .into_iter()
            .map(|handle| handle.join().expect("caller thread").0)
            .collect()
    });
    let stats = pool.stats();
    if let Some(failed) = reports.iter().find(|report| report.code != 0) {
        return Err(format!("a concurrent run answered {} instead of 0", failed.code));
    }
    let shared: Vec<u64> = reports.iter().map(|report| report.runs_on_instance).filter(|runs| *runs != 1).collect();
    if !shared.is_empty() {
        return Err(format!(
            "callers shared an instance: {shared:?} of {} report more than one run",
            reports.len()
        ));
    }
    if stats.peak_leased != callers || stats.created != callers {
        return Err(format!(
            "expected {callers} instances leased at once, saw peak_leased={} created={}",
            stats.peak_leased, stats.created
        ));
    }
    let mut firsts: Vec<f64> = reports.iter().filter_map(|report| report.first_host_call_ms).collect();
    let first = if firsts.len() == reports.len() { format!("{:.2}ms", median(&mut firsts)) } else { "n/a".to_string() };
    println!(
        "pool concurrency ok: callers={callers} instances={} peak_leased={} runs={} first_statement_median={first}",
        stats.created, stats.peak_leased, stats.runs
    );
    Ok(())
}

/// The numbers, medians of five, as a table a document can quote verbatim.
fn bench(wasm: &Path) -> Result<(), String> {
    let bytes = read_wasm(wasm)?;
    let script = fixture("first-statement.lua")?;
    let db = ":memory:";

    // The native interpreter a slot boots from the factory: what a pool keeps instead of rebuilding.
    let mut native_ms = Vec::new();
    let home = wa_host_support::paths::resolve_home();
    for _ in 0..RUNS {
        let started = Instant::now();
        let lua = boot_native_state(&home, db, &[], &embedded()).expect("boot the native interpreter");
        native_ms.push(started.elapsed().as_secs_f64() * 1000.0);
        drop(lua);
    }
    println!("agent-core pool measurements (medians of {RUNS}, wasmtime pooling allocator)");
    println!("| measurement | value |");
    println!("| --- | --- |");
    println!("| native interpreter boot (per instance, not per run) | {:.2} ms |", median(&mut native_ms));

    // Cold: a new pool (engine + compiled component + one instance) and then the run. The first
    // iteration pays the compile; the median is what a cache-warm node pays. `WA_CORE_CACHE=0` makes
    // every iteration a real compile, which is the other number this reports.
    let mut cold_first_statement = Vec::new();
    let mut cold_runs = Vec::new();
    let mut pool_ms = Vec::new();
    for iteration in 0..RUNS {
        let started = Instant::now();
        let pool = CoreComponentPool::new(factory(db), &bytes, config(1, 0)).map_err(|e| format!("pool: {e}"))?;
        let mut lease = pool.acquire().map_err(|e| format!("acquire: {e}"))?;
        let report = lease.run_script(Script::source("first-statement.lua", &script), &[]).map_err(|e| format!("run: {e}"))?;
        let total = started.elapsed().as_secs_f64() * 1000.0;
        if iteration == 0 {
            println!("| first cold load+run (compile {}) | {:.1} ms |", pool.compiled_from(), total);
        }
        pool_ms.push(total);
        cold_runs.push(report.run_ms);
        cold_first_statement.push(report.first_host_call_ms.unwrap_or(f64::NAN));
    }
    println!("| cold: new pool (engine+compile+instance+run) | {:.1} ms |", median(&mut pool_ms));
    println!("| cold: to first Lua statement | {:.2} ms |", median(&mut cold_first_statement));
    println!("| cold: run (after the first statement) | {:.2} ms |", median(&mut cold_runs));

    // Pooled: five instances created on demand and run once each, so every one of these numbers is a
    // fresh guest boot (the idle list is LIFO: a second run would reuse the instance and its snapshot,
    // which is the next measurement, not this one).
    let pool = CoreComponentPool::new(factory(db), &bytes, config(RUNS * 2, 0)).map_err(|e| format!("pool: {e}"))?;
    let mut leases = Vec::with_capacity(RUNS);
    for _ in 0..RUNS {
        let started = Instant::now();
        let lease = pool.acquire().map_err(|e| format!("acquire: {e}"))?;
        let acquire_ms = started.elapsed().as_secs_f64() * 1000.0;
        leases.push((lease, acquire_ms));
    }
    let mut pooled_first_statement = Vec::new();
    let mut pooled_runs = Vec::new();
    let mut pooled_calls = Vec::new();
    for (lease, acquire_ms) in leases.iter_mut() {
        let report = lease.run_script(Script::source("first-statement.lua", &script), &[]).map_err(|e| format!("run: {e}"))?;
        pooled_first_statement.push(*acquire_ms + report.first_host_call_ms.unwrap_or(f64::NAN));
        pooled_runs.push(report.run_ms);
        pooled_calls.push(report.host_calls as f64);
    }
    let pooled_host_calls = median(&mut pooled_calls);
    println!("| pooled: acquire + to first Lua statement (unrun instance) | {:.2} ms |", median(&mut pooled_first_statement));
    println!("| pooled: run (after the first statement) | {:.2} ms |", median(&mut pooled_runs));

    // Snapshotted: the same instance, runs 2..n, so the guest's boot (registry names and the EMBEDDED
    // module sources) is answered from the instance's own snapshot instead of the kernel.
    let mut snap_first_statement = Vec::new();
    let mut snap_runs = Vec::new();
    let mut snap_calls = Vec::new();
    for _ in 0..RUNS {
        let (lease, _) = &mut leases[0];
        let report = lease.run_script(Script::source("first-statement.lua", &script), &[]).map_err(|e| format!("run: {e}"))?;
        snap_first_statement.push(report.first_host_call_ms.unwrap_or(f64::NAN));
        snap_runs.push(report.run_ms);
        snap_calls.push(report.host_calls as f64);
    }
    let snap_host_calls = median(&mut snap_calls);
    println!("| snapshotted: to first Lua statement (warm instance) | {:.2} ms |", median(&mut snap_first_statement));
    println!("| snapshotted: run (after the first statement) | {:.2} ms |", median(&mut snap_runs));
    println!(
        "| host calls per run: pooled ({pooled_host_calls:.0}) -> snapshotted ({snap_host_calls:.0}) | {} fewer |",
        pooled_host_calls - snap_host_calls
    );
    drop(leases);

    // Memory per instance: the limiter's view after a run, one instance at a time.
    let memory_pool = CoreComponentPool::new(factory(db), &bytes, config(8, 0)).map_err(|e| format!("pool: {e}"))?;
    let mut per_instance = Vec::new();
    for _ in 0..8 {
        let mut lease = memory_pool.acquire().map_err(|e| format!("acquire: {e}"))?;
        per_instance.push(lease.run_script(Script::source("first-statement.lua", &script), &[]).map_err(|e| format!("run: {e}"))?.memory_bytes as f64);
    }
    let limits = config(8, 0).limits;
    println!(
        "| pooling allocator reservation ({} instances x {:.0} MiB max) | {:.0} MiB virtual |",
        limits.component_instances,
        limits.max_memory_bytes as f64 / (1024.0 * 1024.0),
        limits.component_instances as f64 * limits.max_memory_bytes as f64 / (1024.0 * 1024.0)
    );
    Ok(())
}
