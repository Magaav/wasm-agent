use serde_json::{json, Value};
use std::{
    env, fs,
    io::{self, Write},
    path::PathBuf,
    time::Duration,
};
use wa_operation::{Manager, Spec};

const PHASES: [&str; 8] = [
    "setup_ms",
    "accepted_record_ms",
    "spawn_ms",
    "execution_ms",
    "drain_cleanup_ms",
    "output_sync_ms",
    "unattributed_ms",
    "total_ms",
];

fn fixture(mode: &str) -> bool {
    match mode {
        "noop" => {}
        "delay" => std::thread::sleep(Duration::from_millis(10)),
        "output" => {
            io::stdout().write_all(&vec![b'x'; 64 * 1024]).unwrap();
            io::stdout().flush().unwrap();
        }
        "fail" => std::process::exit(7),
        "sleep" => std::thread::sleep(Duration::from_secs(30)),
        _ => return false,
    }
    true
}

fn direct(mode: &str) -> Spec {
    Spec::command(
        env::current_exe().unwrap().to_string_lossy(),
        vec!["--fixture".into(), mode.into()],
    )
}

fn shell(command: &str) -> Spec {
    #[cfg(windows)]
    let program =
        PathBuf::from(env::var("ProgramFiles").unwrap_or_else(|_| "C:/Program Files".into()))
            .join("Git/bin/bash.exe");
    #[cfg(not(windows))]
    let program = PathBuf::from("/bin/sh");
    Spec::command(program.to_string_lossy(), vec!["-c".into(), command.into()])
}

fn percentile(values: &[u64], p: f64) -> Option<u64> {
    if values.is_empty() {
        return None;
    }
    let mut sorted = values.to_vec();
    sorted.sort_unstable();
    let index = ((sorted.len() as f64 * p).ceil() as usize).saturating_sub(1);
    sorted.get(index).copied()
}

fn summarize(samples: &[Value]) -> Value {
    let complete = samples.iter().filter(|s| s["complete"] == true).count();
    let phases = PHASES
        .iter()
        .map(|name| {
            let values: Vec<u64> = samples.iter().filter_map(|s| s[*name].as_u64()).collect();
            (
                (*name).to_string(),
                json!({
                    "samples":values.len(),
                    "p50":percentile(&values,0.5),
                    "p95":percentile(&values,0.95),
                    "max":values.iter().max(),
                }),
            )
        })
        .collect::<serde_json::Map<_, _>>();
    json!({"samples":samples.len(),"complete":complete,"phases":phases})
}

fn run_case(manager: &Manager, runs: usize, mut make: impl FnMut() -> Spec) -> io::Result<Value> {
    let mut timings = Vec::with_capacity(runs);
    let mut outcomes = serde_json::Map::new();
    for _ in 0..runs {
        let id = manager.start(make())?;
        let state = manager.wait(&id, Duration::from_secs(35))?;
        if state["settled"] != true {
            return Err(io::Error::other("benchmark_operation_did_not_settle"));
        }
        let outcome = state["state"].as_str().unwrap_or("unknown").to_string();
        let count = outcomes.get(&outcome).and_then(Value::as_u64).unwrap_or(0) + 1;
        outcomes.insert(outcome, json!(count));
        timings.push(state["timing"].clone());
    }
    let mut summary = summarize(&timings);
    summary["outcomes"] = Value::Object(outcomes);
    Ok(summary)
}

fn main() -> io::Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.get(1).map(String::as_str) == Some("--fixture") {
        if fixture(args.get(2).map(String::as_str).unwrap_or("")) {
            return Ok(());
        }
        return Err(io::Error::other("unknown_fixture"));
    }

    let runs = env::var("WA_OPERATION_BENCH_RUNS")
        .ok()
        .and_then(|v| v.parse::<usize>().ok())
        .unwrap_or(7)
        .clamp(1, 50);
    let root = env::temp_dir().join(format!("wa-operation-phase-bench-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let manager = Manager::new(&root);
    let result = (|| -> io::Result<Value> {
        let mut cases = serde_json::Map::new();
        cases.insert(
            "direct_noop".into(),
            run_case(&manager, runs, || direct("noop"))?,
        );
        cases.insert(
            "shell_noop".into(),
            run_case(&manager, runs, || shell(":"))?,
        );
        cases.insert(
            "direct_delay_10ms".into(),
            run_case(&manager, runs, || direct("delay"))?,
        );
        cases.insert(
            "output_64k".into(),
            run_case(&manager, runs, || direct("output"))?,
        );
        cases.insert(
            "failure".into(),
            run_case(&manager, runs, || direct("fail"))?,
        );
        cases.insert(
            "timeout".into(),
            run_case(&manager, 3.min(runs), || {
                let mut spec = direct("sleep");
                spec.timeout = Duration::from_millis(50);
                spec
            })?,
        );
        cases.insert(
            "background_cleanup".into(),
            run_case(&manager, 3.min(runs), || {
                let mut spec = shell("sleep 30 & printf ready");
                spec.timeout = Duration::from_millis(300);
                spec
            })?,
        );
        Ok(
            json!({"schema":"wasm-agent.operation-phase-bench/v1","model_calls":0,
            "runs_per_short_case":runs,"scope":"executor phase latency only; not command throughput or task quality",
            "cases":cases}),
        )
    })();
    if result.is_ok() {
        let _ = fs::remove_dir_all(&root);
    } else {
        eprintln!("operation phase benchmark evidence: {}", root.display());
    }
    println!("{}", serde_json::to_string_pretty(&result?)?);
    Ok(())
}
