//! `wa-fake-kernel`: run one component against the in-memory kernel, from a shell.
//!
//! ```text
//! wa-fake-kernel run <component.wasm> [options]
//! wa-fake-kernel build <component-dir> [--release]
//! ```
//!
//! What it is for: a component's author (or a node's operator) seeing one run without a node - the
//! same answers a test scripts, printed as a summary, with `--record` to keep the run as a `.wrz` and
//! `--replay` to run it again from that file. It never dials, never reads a secret and never writes
//! anything but the replay directory it is given.
//!
//! Exit codes: `0` the component ran to a clean exit with no replay mismatch, `1` it did not (the
//! outcome says why), `2` the command line was wrong.

use std::path::PathBuf;
use std::process::ExitCode;
use std::time::Duration;
use wa_fake_kernel::{FakeKernel, HttpRule, SttScript, WsRule};

const USAGE: &str = "\
usage: wa-fake-kernel run <component.wasm> [options]
       wa-fake-kernel build <component-dir> [--release]
       wa-fake-kernel help

run options:
  --name <name>            the component's name (default: the file stem)
  --config <json>          the JSON text `service.run(config)` receives
  --net <host:port>        grant one address (repeatable; also host:* and *.suffix:port)
  --storage                grant the component its own kv namespace
  --stt                    grant speech-to-text (a scripted recognizer)
  --secret <NAME=VALUE>    a secret `credentials.get` may read by name (never printed)
  --kv <KEY=VALUE>         a key already in the namespace (repeatable)
  --http <json>            script one answer: {\"method\",\"url\",\"status\",\"headers\",\"body\"}
  --ws <json>              script one socket: {\"url\",\"inbound\":[\"…\"],\"echo\":true}
  --speech <json>          script the recognizer: {\"text\",\"language\",\"segments\":[[start,end,text]],\"error\"}
  --record <dir>           write the run into a .wrz replay in that directory
  --replay <file.wrz>      answer host calls from that replay instead of the scripts
  --deadline-ms <n>        how long the run may take (default 60000)
  --logs                   print the component's captured log lines
  --json                   print the whole outcome as JSON
";

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("run") => run(&args[1..]),
        Some("build") => build(&args[1..]),
        Some("help") | Some("--help") | Some("-h") | None => {
            println!("{USAGE}");
            ExitCode::SUCCESS
        }
        Some(other) => {
            eprintln!("unknown command {other}\n\n{USAGE}");
            ExitCode::from(2)
        }
    }
}

fn build(args: &[String]) -> ExitCode {
    let Some(dir) = args.iter().find(|arg| !arg.starts_with("--")) else {
        eprintln!("build needs a component directory\n\n{USAGE}");
        return ExitCode::from(2);
    };
    let release = args.iter().any(|arg| arg == "--release");
    match wa_fake_kernel::build::build(std::path::Path::new(dir), release) {
        Ok(built) => {
            println!("built {} in {} ms ({} bytes)", built.wasm.display(), built.millis, built.bytes);
            println!("{}", built.wasm.display());
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("build failed: {error}");
            ExitCode::FAILURE
        }
    }
}

/// The options a `run` accepts, in the order they were given.
struct Options {
    wasm: PathBuf,
    name: Option<String>,
    config: String,
    net: Vec<String>,
    storage: bool,
    stt: bool,
    secrets: Vec<(String, String)>,
    kv: Vec<(String, String)>,
    http: Vec<HttpRule>,
    ws: Vec<WsRule>,
    speech: Option<SttScript>,
    record: Option<PathBuf>,
    replay: Option<PathBuf>,
    deadline: Duration,
    logs: bool,
    json: bool,
}

fn run(args: &[String]) -> ExitCode {
    let mut options = Options {
        wasm: PathBuf::new(),
        name: None,
        config: "{}".into(),
        net: Vec::new(),
        storage: false,
        stt: false,
        secrets: Vec::new(),
        kv: Vec::new(),
        http: Vec::new(),
        ws: Vec::new(),
        speech: None,
        record: None,
        replay: None,
        deadline: Duration::from_secs(60),
        logs: false,
        json: false,
    };
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].as_str();
        let mut value = || -> Option<String> {
            index += 1;
            args.get(index).cloned()
        };
        match arg {
            "--name" => options.name = value(),
            "--config" => match value() {
                Some(config) => options.config = config,
                None => return usage("--config needs JSON"),
            },
            "--net" => match value() {
                Some(address) => options.net.push(address),
                None => return usage("--net needs an address"),
            },
            "--storage" => options.storage = true,
            "--stt" => options.stt = true,
            "--secret" => match value().as_deref().and_then(split_pair) {
                Some(pair) => options.secrets.push(pair),
                None => return usage("--secret needs NAME=VALUE"),
            },
            "--kv" => match value().as_deref().and_then(split_pair) {
                Some(pair) => options.kv.push(pair),
                None => return usage("--kv needs KEY=VALUE"),
            },
            "--http" => match value().as_deref().and_then(http_rule) {
                Some(rule) => options.http.push(rule),
                None => return usage("--http needs {\"method\",\"url\",\"status\",\"body\"}"),
            },
            "--ws" => match value().as_deref().and_then(ws_rule) {
                Some(rule) => options.ws.push(rule),
                None => return usage("--ws needs {\"url\",\"inbound\":[...],\"echo\"}"),
            },
            "--speech" => match value().as_deref().and_then(speech_script) {
                Some(script) => options.speech = Some(script),
                None => return usage("--speech needs {\"text\",\"segments\":[[start,end,text]]}"),
            },
            "--record" => options.record = value().map(PathBuf::from),
            "--replay" => options.replay = value().map(PathBuf::from),
            "--deadline-ms" => match value().and_then(|text| text.parse().ok()) {
                Some(ms) => options.deadline = Duration::from_millis(ms),
                None => return usage("--deadline-ms needs a number"),
            },
            "--logs" => options.logs = true,
            "--json" => options.json = true,
            other if other.starts_with("--") => return usage(&format!("unknown option {other}")),
            other => options.wasm = PathBuf::from(other),
        }
        index += 1;
    }
    if options.wasm.as_os_str().is_empty() {
        return usage("run needs a .wasm file");
    }
    let name = options
        .name
        .clone()
        .or_else(|| options.wasm.file_stem().map(|stem| stem.to_string_lossy().replace('_', "-")))
        .unwrap_or_else(|| "component".into());

    let mut kernel = FakeKernel::new(&name);
    kernel
        .grant_net(&options.net.iter().map(String::as_str).collect::<Vec<_>>())
        .grant_storage(options.storage)
        .grant_stt(options.stt)
        .deadline(options.deadline);
    for (key, secret) in &options.secrets {
        kernel.secret(key, secret);
    }
    for (key, kv) in &options.kv {
        kernel.kv_put(key, kv);
    }
    for rule in options.http {
        kernel.http_response(rule);
    }
    for rule in options.ws {
        kernel.websocket(rule);
    }
    if let Some(script) = options.speech {
        kernel.speech(script);
    }
    if let Some(dir) = &options.record {
        kernel.record();
        if let Err(error) = std::fs::create_dir_all(dir) {
            eprintln!("record directory: {error}");
            return ExitCode::from(2);
        }
    }
    if let Some(path) = &options.replay {
        if let Err(error) = kernel.replay_from(path) {
            eprintln!("replay: {error}");
            return ExitCode::FAILURE;
        }
    }

    let outcome = kernel.run_file(&options.wasm, &options.config);
    // The ring is kept by the kernel; a record writes it out after the run, which is when every
    // call it made has happened.
    let mut saved = None;
    if let Some(dir) = &options.record {
        let label = options.wasm.file_stem().map(|stem| stem.to_string_lossy().to_string()).unwrap_or_else(|| name.clone());
        match kernel.save_replay(dir, &label) {
            Ok(path) => saved = Some(path),
            Err(error) => eprintln!("record: {error}"),
        }
    }

    let clean = outcome.outcome == "exit_0" && outcome.replay_mismatch.is_none();
    if options.json {
        println!(
            "{}",
            serde_json::json!({
                "name": name,
                "outcome": outcome.outcome,
                "health": outcome.health,
                "clean": clean,
                "records": outcome.records,
                "replay_mismatch": outcome.replay_mismatch,
                "calls": outcome.called(),
                "kv_keys": outcome.kv.keys().map(|key| String::from_utf8_lossy(key).into_owned()).collect::<Vec<_>>(),
                "replay_saved": saved.as_ref().map(|path| path.display().to_string()),
                "stdout_bytes": outcome.stdout.len(),
                "stderr_bytes": outcome.stderr.len(),
                "log_lines": outcome.logs.len(),
            })
        );
    } else {
        println!("component {name}: {}", outcome.outcome);
        println!("health: {}", if outcome.health.is_empty() { "(never reported)" } else { outcome.health.as_str() });
        println!("host calls: {} ({} recorded)", outcome.calls.len(), outcome.records);
        for call in outcome.called() {
            println!("  {call}");
        }
        if !outcome.kv.is_empty() {
            println!("kv keys left: {}", outcome.kv.keys().map(|key| String::from_utf8_lossy(key).into_owned()).collect::<Vec<_>>().join(", "));
        }
        if let Some(mismatch) = &outcome.replay_mismatch {
            println!("replay: {mismatch}");
        }
        if let Some(path) = &saved {
            println!("recorded: {}", path.display());
        }
        if options.logs {
            println!("--- logs");
            print!("{}", outcome.logs_text());
        }
    }
    if clean {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    }
}

fn usage(message: &str) -> ExitCode {
    eprintln!("{message}\n\n{USAGE}");
    ExitCode::from(2)
}

fn split_pair(text: &str) -> Option<(String, String)> {
    let (key, value) = text.split_once('=')?;
    (!key.is_empty()).then(|| (key.to_string(), value.to_string()))
}

fn http_rule(text: &str) -> Option<HttpRule> {
    let value: serde_json::Value = serde_json::from_str(text).ok()?;
    let method = value["method"].as_str().unwrap_or("GET");
    let url = value["url"].as_str()?;
    let mut rule = HttpRule::status(method, url, value["status"].as_u64().unwrap_or(200) as u16, value["body"].as_str().unwrap_or_default().as_bytes());
    if let Some(headers) = value["headers"].as_object() {
        for (name, header) in headers {
            if let Some(header) = header.as_str() {
                rule = rule.with_header(name, header);
            }
        }
    }
    Some(rule)
}

fn ws_rule(text: &str) -> Option<WsRule> {
    let value: serde_json::Value = serde_json::from_str(text).ok()?;
    let mut rule = WsRule::new(value["url"].as_str()?);
    let frames: Vec<Vec<u8>> = value["inbound"].as_array().into_iter().flatten().map(|frame| frame.as_str().unwrap_or_default().as_bytes().to_vec()).collect();
    let borrowed: Vec<&[u8]> = frames.iter().map(Vec::as_slice).collect();
    rule = rule.delivering(&borrowed);
    if value["echo"].as_bool().unwrap_or(false) {
        rule = rule.echoing();
    }
    Some(rule)
}

fn speech_script(text: &str) -> Option<SttScript> {
    let value: serde_json::Value = serde_json::from_str(text).ok()?;
    let mut script = SttScript::text(value["text"].as_str().unwrap_or_default());
    if let Some(language) = value["language"].as_str() {
        script = script.language(language);
    }
    if let Some(ms) = value["elapsed_ms"].as_u64() {
        script = script.elapsed_ms(ms);
    }
    for segment in value["segments"].as_array().into_iter().flatten() {
        let start = segment[0].as_u64().unwrap_or(0);
        let end = segment[1].as_u64().unwrap_or(0);
        script = script.segment(start, end, segment[2].as_str().unwrap_or_default());
    }
    if let Some(error) = value["error"].as_str() {
        script = script.failing(error);
    }
    Some(script)
}
