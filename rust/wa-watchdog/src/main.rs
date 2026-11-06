//! `wa-watchdog`: the process outside the kernel.
//!
//! ```text
//! wa-watchdog run  [--config FILE] [--home DIR]      supervise the kernel in the foreground
//! wa-watchdog stop [--home DIR]                      ask the supervisor to stop its kernel and exit
//! wa-watchdog status [--json] [--home DIR]           what the supervisor last wrote down
//! wa-watchdog swap <binary> --sha256 <pin>           verify, stage, prove on a spare port, ask for the switch
//!                  [--arg <value>]... [--wait-ms N] [--spare-port N]
//! wa-watchdog verify <binary> --sha256 <pin>         the pin check alone
//! wa-watchdog init --kernel <path> [--port N]        write a config for a fresh home
//! wa-watchdog selftest-kernel [flags]                a fake kernel for tests (see src/selftest.rs)
//! ```
//!
//! Exit codes: `0` success, `1` refused or rolled back, `2` usage/config error, `3` the supervisor did not
//! answer in time (the request stays queued). They are distinct so a deploy script can tell "the new kernel
//! is not healthy" from "the watchdog is not running".

use std::path::PathBuf;
use std::time::Duration;

use wa_watchdog::config::Config;
use wa_watchdog::hash;
use wa_watchdog::health;
use wa_watchdog::json;
use wa_watchdog::paths::{Home, SwapRequest};
use wa_watchdog::state::{ActiveKernel, Status};
use wa_watchdog::supervisor::{now_ms, Event, Supervisor};
use wa_watchdog::swap;

const USAGE: &str = concat!(
    "wa-watchdog - start the kernel, restart it on a crash, replace its binary only after the new one answers /health\n",
    "\n",
    "usage:\n",
    "  wa-watchdog run    [--config FILE] [--home DIR]\n",
    "  wa-watchdog stop   [--home DIR] [--wait-ms N]\n",
    "  wa-watchdog status [--json] [--home DIR]\n",
    "  wa-watchdog swap <binary> --sha256 <pin> [--arg <value>]... [--wait-ms N] [--spare-port N] [--home DIR]\n",
    "  wa-watchdog verify <binary> --sha256 <pin>\n",
    "  wa-watchdog init   --kernel <path> [--kernel-arg <value>]... [--port N] [--client-port N] [--home DIR] [--force]\n",
    "  wa-watchdog selftest-kernel [--port N] [--health ok|fail|down|hang] [--unhealthy-on-port N] [--tag X] [--exit-after-ms N]\n",
    "\n",
    "The home is --home, then WA_WATCHDOG_HOME, then <WASM_AGENT_HOME or ~/.wasm-agent>/watchdog.\n",
);

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match dispatch(&args) {
        Ok(code) => code,
        Err(message) => {
            eprintln!("wa-watchdog: {message}");
            2
        }
    };
    std::process::exit(code);
}

fn dispatch(args: &[String]) -> Result<i32, String> {
    let Some(command) = args.first().map(|text| text.as_str()) else {
        print!("{USAGE}");
        return Ok(2);
    };
    let rest = &args[1..];
    match command {
        "run" | "supervise" => cmd_run(rest),
        "stop" => cmd_stop(rest),
        "status" => cmd_status(rest),
        "swap" => cmd_swap(rest),
        "verify" => cmd_verify(rest),
        "init" => cmd_init(rest),
        "selftest-kernel" => Ok(wa_watchdog::selftest::run(rest)),
        "-h" | "--help" | "help" => {
            print!("{USAGE}");
            Ok(0)
        }
        "--version" | "version" => {
            println!("wa-watchdog {}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        other => Err(format!("unknown command `{other}` (see --help)")),
    }
}

/// Flags shared by every command: `--home DIR` and `--config FILE`. Everything else is command-specific.
#[derive(Default)]
struct Common {
    home: Option<PathBuf>,
    config: Option<PathBuf>,
    json: bool,
    wait_ms: Option<u64>,
    spare_port: Option<u16>,
    force: bool,
    kernel: Option<PathBuf>,
    kernel_args: Vec<String>,
    port: Option<u16>,
    client_port: Option<u16>,
    pin: Option<String>,
    positional: Vec<String>,
}

fn parse_flags(args: &[String]) -> Result<Common, String> {
    let mut common = Common::default();
    let mut index = 0;
    let value = |index: &mut usize, flag: &str| -> Result<String, String> {
        *index += 1;
        args.get(*index).cloned().ok_or_else(|| format!("{flag} needs a value"))
    };
    while index < args.len() {
        let flag = args[index].clone();
        match flag.as_str() {
            "--home" => common.home = Some(PathBuf::from(value(&mut index, &flag)?)),
            "--config" => common.config = Some(PathBuf::from(value(&mut index, &flag)?)),
            "--json" => common.json = true,
            "--force" => common.force = true,
            "--wait-ms" => common.wait_ms = Some(number(&value(&mut index, &flag)?, &flag)?),
            "--spare-port" => common.spare_port = Some(number(&value(&mut index, &flag)?, &flag)? as u16),
            "--kernel" => common.kernel = Some(PathBuf::from(value(&mut index, &flag)?)),
            "--kernel-arg" | "--arg" => common.kernel_args.push(value(&mut index, &flag)?),
            "--port" => common.port = Some(number(&value(&mut index, &flag)?, &flag)? as u16),
            "--client-port" => common.client_port = Some(number(&value(&mut index, &flag)?, &flag)? as u16),
            "--sha256" => common.pin = Some(value(&mut index, &flag)?),
            other if other.starts_with("--") => return Err(format!("unknown flag `{other}` (see --help)")),
            _ => common.positional.push(flag),
        }
        index += 1;
    }
    Ok(common)
}

fn number(text: &str, flag: &str) -> Result<u64, String> {
    text.parse::<u64>().map_err(|_| format!("{flag} expects a whole number, found {text:?}"))
}

fn home_of(common: &Common) -> Result<Home, String> {
    Home::resolve(common.home.clone())
}

fn config_path(common: &Common, home: &Home) -> PathBuf {
    common.config.clone().unwrap_or_else(|| home.config_path())
}

/// `run` and `swap` both need a config; `status` and `stop` do not (they must answer about a home whose
/// config a human is still editing).
fn load_config(common: &Common, home: &Home) -> Result<Config, String> {
    let path = config_path(common, home);
    if !path.is_file() {
        return Err(format!("no config at {} (write one with `wa-watchdog init --kernel <path>`)", path.display()));
    }
    Config::load(&path)
}

fn cmd_run(args: &[String]) -> Result<i32, String> {
    let common = parse_flags(args)?;
    let home = home_of(&common)?;
    let config = load_config(&common, &home)?;
    home.ensure().map_err(|error| format!("cannot prepare {}: {error}", home.root().display()))?;
    if home.supervisor_pid_path().exists() && !common.force {
        let pid = std::fs::read_to_string(home.supervisor_pid_path()).unwrap_or_default();
        return Err(format!(
            "{} names supervisor pid {}; one supervisor per home (stop it, or pass --force after checking)",
            home.supervisor_pid_path().display(),
            pid.trim()
        ));
    }
    let log = home.log_path("supervisor");
    let started = std::time::Instant::now();
    let mut supervisor = Supervisor::new(config, home.clone());
    let report = |event: &Event| {
        let line = format!("[+{:>6}ms] {}\n", started.elapsed().as_millis(), event.line());
        print!("{line}");
        use std::io::Write;
        let _ = std::io::stdout().flush();
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(&log) {
            let _ = file.write_all(line.as_bytes());
        }
    };
    supervisor.run(report)?;
    Ok(0)
}

fn cmd_stop(args: &[String]) -> Result<i32, String> {
    let common = parse_flags(args)?;
    let home = home_of(&common)?;
    if !home.root().exists() {
        println!("wa-watchdog: no home at {} - nothing to stop", home.root().display());
        return Ok(0);
    }
    home.ensure().map_err(|error| format!("cannot prepare {}: {error}", home.root().display()))?;
    let pid = home.supervisor_pid_path();
    if !pid.exists() {
        println!("wa-watchdog: no supervisor pid at {} - nothing is running", pid.display());
        let _ = std::fs::remove_file(home.stop_flag_path());
        return Ok(0);
    }
    home.write_atomic(&home.stop_flag_path(), &format!("stop requested at {}ms\n", now_ms()))
        .map_err(|error| format!("cannot write the stop flag: {error}"))?;
    let wait = Duration::from_millis(common.wait_ms.unwrap_or(30_000));
    let deadline = std::time::Instant::now() + wait;
    while std::time::Instant::now() < deadline {
        if !pid.exists() && !home.stop_flag_path().exists() {
            println!("wa-watchdog: stopped");
            return Ok(0);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    Err(format!("the supervisor did not act on `stop` within {}ms; its pid file is {}", wait.as_millis(), pid.display()))
}

fn cmd_status(args: &[String]) -> Result<i32, String> {
    let common = parse_flags(args)?;
    let home = home_of(&common)?;
    let Some(text) = home.read_status_text() else {
        if common.json {
            println!(
                "{}",
                json::object(&[
                    ("state", "unknown".into()),
                    ("supervisor_alive", false.into()),
                    ("home", home.root().into()),
                ])
            );
        } else {
            println!(
                "watchdog: no status at {} - no supervisor has run here (or `wa-watchdog status --home` is the wrong home)",
                home.status_path().display()
            );
        }
        return Ok(1);
    };
    match Status::from_json(&text) {
        Some(status) => {
            if common.json {
                println!("{text}");
            } else {
                println!("{}", status.summary());
            }
            Ok(if status.state == "healthy" && status.supervisor_alive { 0 } else { 1 })
        }
        None => {
            if common.json {
                println!("{text}");
            } else {
                println!("watchdog: {} cannot be read as a status record", home.status_path().display());
            }
            Ok(1)
        }
    }
}

fn cmd_verify(args: &[String]) -> Result<i32, String> {
    let common = parse_flags(args)?;
    let Some(binary) = common.positional.first() else {
        return Err("verify needs a binary path".to_string());
    };
    let Some(pin) = &common.pin else {
        return Err("verify needs --sha256 <pin>".to_string());
    };
    let pin = swap::parse_pin(pin)?;
    match swap::verify_pin(&PathBuf::from(binary), &pin) {
        Ok(()) => {
            println!("sha256 {pin} verified: {binary}");
            Ok(0)
        }
        Err(error) => {
            eprintln!("wa-watchdog: {error}");
            Ok(1)
        }
    }
}

fn cmd_swap(args: &[String]) -> Result<i32, String> {
    let common = parse_flags(args)?;
    let home = home_of(&common)?;
    let Some(binary) = common.positional.first() else {
        return Err("swap needs the new binary's path".to_string());
    };
    let binary = PathBuf::from(binary);
    let Some(raw_pin) = &common.pin else {
        return Err("swap needs --sha256 <the pin these bytes were published with>".to_string());
    };
    let pin = swap::parse_pin(raw_pin)?;
    let mut config = load_config(&common, &home)?;
    if let Some(port) = common.spare_port {
        config.spare_port = port;
    }
    // The proof must prove the candidate AS IT WILL BE RUN. Without `--arg` that is the recorded line; with
    // `--arg` it is the caller's line. Proving the old line instead proves the wrong launcher - measured on
    // this crate's own test: a candidate that answers 503 "proved" because it was started with the healthy
    // kernel's arguments, and the swap only failed after the old kernel had been stopped.
    if !common.kernel_args.is_empty() {
        config.kernel_args = common.kernel_args.clone();
    }
    home.ensure().map_err(|error| format!("cannot prepare {}: {error}", home.root().display()))?;

    // 1. the pin, before anything else is touched.
    if let Err(error) = swap::verify_pin(&binary, &pin) {
        eprintln!("wa-watchdog: refused: {error}");
        return Ok(1);
    }
    // 2. the staging copy, verified again: this is the file that will run.
    let staged = match swap::stage(&config, &home, &binary, &pin) {
        Ok(staged) => staged,
        Err(error) => {
            eprintln!("wa-watchdog: refused: {error}");
            return Ok(1);
        }
    };
    println!("staged {} as {} (sha256 {})", binary.display(), staged.display(), &pin[..12]);

    // 3. the proof, while the running kernel is untouched.
    let id = format!("swap-{:013}-{}", now_ms(), std::process::id());
    let proof = swap::prove(&config, &home, &staged, &id);
    if !proof.ok {
        eprintln!("wa-watchdog: refused: {} - see {}", proof.detail, proof.log.display());
        let tail = Home::tail(&proof.log, 5);
        for line in tail.lines() {
            eprintln!("    {line}");
        }
        return Ok(1);
    }
    println!("proved on :{} ({})", proof.port, proof.detail);

    // 4. the request. The arguments are the recorded ones, so a kernel that needs `--ui` keeps it; new bytes
    //    that need a different line say so with `--arg`.
    let recorded = home.read_current();
    let args = if !common.kernel_args.is_empty() {
        common.kernel_args.clone()
    } else if let Some(recorded) = &recorded {
        recorded.args.clone()
    } else {
        config.kernel_args.clone()
    };
    let request = SwapRequest { id: id.clone(), binary: staged.clone(), sha256: pin.clone(), args, at_ms: now_ms() };
    swap::write_request(&home, &request).map_err(|error| format!("cannot write the swap request: {error}"))?;
    println!("asked the supervisor to switch to {} (request {id})", staged.display());

    // 5. the verdict.
    let wait = Duration::from_millis(common.wait_ms.unwrap_or(config.swap_wait_ms));
    match swap::wait_result(&home, &id, wait) {
        Some(result) => {
            if result.ok {
                println!("swap {id}: {} is serving", result.active.display());
                Ok(0)
            } else {
                eprintln!("swap {id}: rolled back to {} ({})", result.active.display(), result.detail);
                Ok(1)
            }
        }
        None => {
            eprintln!(
                "swap {id}: the supervisor has not answered within {}ms; the request is queued at {} and will be answered on its next pass",
                wait.as_millis(),
                home.requests_dir().join(format!("{id}.json")).display()
            );
            Ok(3)
        }
    }
}

fn cmd_init(args: &[String]) -> Result<i32, String> {
    let common = parse_flags(args)?;
    let home = home_of(&common)?;
    let Some(kernel) = &common.kernel else {
        return Err("init needs --kernel <path to the kernel binary>".to_string());
    };
    if !kernel.is_file() {
        return Err(format!("{} is not a file", kernel.display()));
    }
    home.ensure().map_err(|error| format!("cannot prepare {}: {error}", home.root().display()))?;
    let path = config_path(&common, &home);
    if path.exists() && !common.force {
        return Err(format!("{} already exists; pass --force to replace it", path.display()));
    }
    let mut config = Config { kernel: Some(kernel.clone()), ..Config::default() };
    if !common.kernel_args.is_empty() {
        config.kernel_args = common.kernel_args.clone();
    }
    if let Some(port) = common.port {
        config.port = port;
    }
    if let Some(port) = common.client_port {
        config.client_port = port;
    }
    home.write_atomic(&path, &config.render()).map_err(|error| format!("cannot write {}: {error}", path.display()))?;
    // Record the pin of the bytes the config names, so `status` can say what is running even before the first
    // swap. A failure here is not fatal: the pin is a convenience, not the identity of the process.
    let pin = hash::sha256_file(kernel).ok();
    let _ = home.write_current(&ActiveKernel { binary: kernel.clone(), sha256: pin, args: config.kernel_args.clone() });
    println!("wrote {}", path.display());
    println!("start it with: wa-watchdog run --home {}", home.root().display());
    Ok(0)
}

/// Kept so the binary can answer "is this a sensible kernel to start" without a second implementation of the
/// probe; used by the docs and by operators, not by the supervisor's loop.
#[allow(dead_code)]
fn probe_once(port: u16) -> health::Probe {
    health::probe(port, Duration::from_millis(2_000))
}
