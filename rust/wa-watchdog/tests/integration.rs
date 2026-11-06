//! End-to-end tests: real processes, real ports, two fake kernels.
//!
//! The fake kernel is this package's own `selftest-kernel` subcommand (src/selftest.rs), copied to two files
//! so the tests can tell which one is serving by the `tag` it reports. Everything here goes through the same
//! code the operator uses: `wa-watchdog run` supervises, `wa-watchdog swap` verifies and stages, and the
//! supervisor does the switch and the rollback.
//!
//! Timings are compressed through the config (tick, start timeout, swap window, stability window) so the
//! whole file runs in seconds, not minutes - but nothing is stubbed: the health probes are real HTTP requests
//! to a real socket, and the crash is a real process exiting.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use wa_watchdog::config::Config;
use wa_watchdog::health;
use wa_watchdog::json;
use wa_watchdog::paths::Home;
use wa_watchdog::state::Status;
use wa_watchdog::supervisor::{Event, Supervisor};
use wa_watchdog::swap::SwapResult;

const EXE: &str = env!("CARGO_BIN_EXE_wa-watchdog");

/// A directory of its own, removed on drop. No `tempfile` dependency: the crate has none.
struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new(name: &str) -> Scratch {
        let root = std::env::temp_dir().join(format!("wa-watchdog-it-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("create the scratch directory");
        Scratch { root }
    }

    fn path(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }

    /// A copy of the binary under `kernel`'s name, so "the old binary is still on disk" is a real question.
    fn kernel(&self, name: &str) -> PathBuf {
        let directory = self.root.join("kernels");
        std::fs::create_dir_all(&directory).expect("create the kernels directory");
        let target = directory.join(name);
        std::fs::copy(EXE, &target).expect("copy the watchdog binary as a fake kernel");
        target
    }

    /// Write `watchdog.conf` for a home inside this scratch directory.
    fn config(&self, kernel: &Path, args: &str, extra: &[(&str, String)]) -> Home {
        let home = Home::resolve(Some(self.root.join("home"))).expect("home");
        home.ensure().expect("home directories");
        // One line per key: the config refuses a key set twice (a knob a human believes they changed), and
        // tests override defaults, so a base key is dropped when the test names it.
        let mut lines: Vec<(String, String)> = vec![
            ("kernel".into(), kernel.display().to_string()),
            ("kernel_args".into(), args.to_string()),
            ("start_timeout_ms".into(), "15000".into()),
            ("tick_ms".into(), "25".into()),
            ("backoff_base_ms".into(), "100".into()),
            ("backoff_factor".into(), "2".into()),
            ("backoff_max_ms".into(), "400".into()),
            ("swap_health_window_ms".into(), "12000".into()),
            ("swap_wait_ms".into(), "20000".into()),
            ("stability_ms".into(), "0".into()),
        ];
        for (key, value) in extra {
            lines.retain(|(existing, _): &(String, String)| existing != key);
            lines.push((key.to_string(), value.clone()));
        }
        let text: String = lines.iter().map(|(key, value)| format!("{key} = {value}\n")).collect();
        std::fs::write(home.config_path(), text).expect("write the config");
        home
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        // `WA_WATCHDOG_KEEP=1` keeps a failed run's directory: a supervisor log is the whole diagnosis.
        if std::env::var("WA_WATCHDOG_KEEP").is_err() {
            let _ = std::fs::remove_dir_all(&self.root);
        } else {
            eprintln!("kept {}", self.root.display());
        }
    }
}

fn free_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind an ephemeral port");
    let port = listener.local_addr().expect("local addr").port();
    drop(listener);
    port
}

fn status(home: &Home) -> Option<Status> {
    Status::from_json(&home.read_status_text()?)
}

fn wait_for(what: &str, timeout: Duration, mut check: impl FnMut() -> bool) {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if check() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("timed out waiting for {what}");
}

fn tag(port: u16) -> Option<String> {
    let probe = health::probe(port, Duration::from_millis(500));
    json::field_str(&probe.body, "tag")
}

/// An in-process supervisor, stopped on drop. Without this, a failing assertion would leave a fake kernel
/// running and holding a port for the rest of the session - which is exactly how a later run of this file
/// came to blame the wrong test for being slow.
struct Harness {
    supervisor: Supervisor,
    home: Home,
}

impl Harness {
    fn new(home: &Home) -> Harness {
        let config = Config::load(&home.config_path()).expect("load the config");
        Harness { supervisor: Supervisor::new(config, home.clone()), home: home.clone() }
    }

    fn tick(&mut self) -> Vec<Event> {
        self.supervisor.tick()
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        let _ = self.home.write_atomic(&self.home.stop_flag_path(), "stop\n");
        let _ = self.supervisor.tick();
    }
}

/// A supervisor child process, stopped on drop.
struct SupervisorProcess {
    child: Child,
    home: Home,
}

impl SupervisorProcess {
    fn start(home: &Home) -> SupervisorProcess {
        let log = std::fs::File::create(home.root().join("run.out")).expect("open the supervisor log");
        let child = Command::new(EXE)
            .args(["run", "--home", &home.root().display().to_string()])
            .stdout(Stdio::from(log.try_clone().expect("clone the log")))
            .stderr(Stdio::from(log))
            .spawn()
            .expect("start the supervisor");
        SupervisorProcess { child, home: home.clone() }
    }

    fn output(&self) -> String {
        std::fs::read_to_string(self.home.root().join("run.out")).unwrap_or_default()
    }
}

impl Drop for SupervisorProcess {
    fn drop(&mut self) {
        let _ = self.home.write_atomic(&self.home.stop_flag_path(), "stop\n");
        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline {
            if let Ok(Some(_)) = self.child.try_wait() {
                return;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
        panic!("the supervisor did not stop when asked; its output was:\n{}", self.output());
    }
}

fn swap_cli(home: &Home, binary: &Path, pin: &str, args: &[&str]) -> (i32, String) {
    let mut command = Command::new(EXE);
    command.args([
        "swap",
        &binary.display().to_string(),
        "--sha256",
        pin,
        "--home",
        &home.root().display().to_string(),
        "--wait-ms",
        "20000",
    ]);
    for arg in args {
        command.arg("--arg").arg(arg);
    }
    let output = command.output().expect("run the swap command");
    let mut text = String::from_utf8_lossy(&output.stdout).to_string();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    (output.status.code().unwrap_or(-1), text)
}

fn sha256_of(path: &Path) -> String {
    wa_watchdog::hash::sha256_file(path).expect("hash the candidate")
}

// ---------------------------------------------------------------------------------------------------------
// 1. start and health
// ---------------------------------------------------------------------------------------------------------

#[test]
fn it_starts_the_kernel_and_reports_it_healthy() {
    let scratch = Scratch::new("start");
    let kernel = scratch.kernel("wa-a");
    let port = free_port();
    let client = free_port();
    let home = scratch.config(
        &kernel,
        "selftest-kernel --port {port} --tag a",
        &[("port", port.to_string()), ("client_port", client.to_string())],
    );
    let mut harness = Harness::new(&home);
    let mut events = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline && !events.iter().any(|event| matches!(event, Event::Healthy { .. })) {
        events.extend(harness.tick());
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        events.iter().any(|event| matches!(event, Event::Healthy { .. })),
        "the kernel became healthy; events: {:?}\nlog:\n{}",
        events,
        Home::tail(&home.log_path("kernel"), 10)
    );
    assert_eq!(tag(port).as_deref(), Some("a"), "the kernel's own /health is answering");
    let record = status(&home).expect("a status record");
    assert_eq!(record.state, "healthy");
    assert_eq!(record.kernel.as_deref(), Some(kernel.as_path()));
    assert!(record.kernel_pid.is_some(), "the kernel pid is recorded: {record:?}");
    assert!(home.kernel_pid_path().is_file(), "kernel.pid is written for the install tooling");
    // The one-line `current` file names the binary that is running.
    assert_eq!(
        std::fs::read_to_string(home.current_path()).expect("current").trim(),
        kernel.display().to_string()
    );

    // A stop request ends the kernel and the supervisor.
    home.write_atomic(&home.stop_flag_path(), "stop\n").expect("write the stop flag");
    let events = harness.tick();
    assert!(matches!(events.last(), Some(Event::Stopped)), "{events:?}");
    assert!(harness.supervisor.exited);
    assert_eq!(status(&home).expect("a status record").state, "stopped");
    assert!(!home.stop_flag_path().exists(), "the flag is consumed, so `stop` cannot be answered twice");
    assert!(!health::probe(port, Duration::from_millis(300)).answers(), "the kernel is gone");
}

#[test]
fn a_second_supervisor_refuses_a_port_that_already_answers() {
    let scratch = Scratch::new("second");
    let kernel = scratch.kernel("wa-a");
    let port = free_port();
    let home = scratch.config(&kernel, "selftest-kernel --port {port}", &[("port", port.to_string())]);
    // Something already serves /health there: the supervisor must refuse to start a second kernel beside it,
    // because a kernel that cannot bind is answered by the node it failed to replace.
    let listener = TcpListener::bind(("127.0.0.1", port)).expect("bind the service port");
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten().take(8) {
            let mut stream = stream;
            let mut buffer = [0u8; 1024];
            let _ = stream.read(&mut buffer);
            let body = "{\"ok\":true,\"state\":\"idle\"}";
            let _ = stream.write_all(
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .as_bytes(),
            );
        }
    });
    let config = Config::load(&home.config_path()).expect("load the config");
    let mut supervisor = Supervisor::new(config, home.clone());
    let error = supervisor.run(|_| {}).expect_err("a served port must be refused");
    assert!(error.contains("already answers /health"), "{error}");
}

// ---------------------------------------------------------------------------------------------------------
// 2. crash and backoff
// ---------------------------------------------------------------------------------------------------------

#[test]
fn a_crashing_kernel_is_restarted_with_a_growing_backoff() {
    let scratch = Scratch::new("crash");
    let kernel = scratch.kernel("wa-crash");
    let port = free_port();
    let home = scratch.config(
        &kernel,
        "selftest-kernel --port {port} --health ok --exit-after-ms 300",
        &[("port", port.to_string())],
    );
    let mut harness = Harness::new(&home);
    let mut events = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(25);
    while Instant::now() < deadline {
        events.extend(harness.tick());
        let exits = events
            .iter()
            .filter(|event| matches!(event, Event::Exited { .. }))
            .count();
        if exits >= 4 {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let delays: Vec<u64> = events
        .iter()
        .filter_map(|event| match event {
            Event::Exited { restart_in_ms, .. } => Some(*restart_in_ms),
            _ => None,
        })
        .collect();
    assert!(delays.len() >= 4, "the kernel kept crashing and was restarted: {events:?}");
    assert_eq!(&delays[..4], &[100, 200, 400, 400], "backoff doubles up to the ceiling: {delays:?}");
    let record = status(&home).expect("a status record");
    assert!(record.restarts >= 4, "{record:?}");
    assert_eq!(record.state, "backoff");
    home.write_atomic(&home.stop_flag_path(), "stop\n").expect("write the stop flag");
    harness.tick();
}

// ---------------------------------------------------------------------------------------------------------
// 3. swap to a healthy binary, through the CLI, with the supervisor as a separate process
// ---------------------------------------------------------------------------------------------------------

#[test]
fn a_swap_to_a_healthy_binary_switches_and_keeps_the_old_one() {
    let scratch = Scratch::new("swap-ok");
    let kernel_a = scratch.kernel("wa-a");
    let kernel_b = scratch.kernel("wa-b");
    let port = free_port();
    let client = free_port();
    let home = scratch.config(
        &kernel_a,
        "selftest-kernel --port {port} --tag a",
        &[("port", port.to_string()), ("client_port", client.to_string())],
    );
    let supervisor = SupervisorProcess::start(&home);
    wait_for("the supervisor to report healthy", Duration::from_secs(20), || {
        status(&home).map(|record| record.state == "healthy").unwrap_or(false)
    });
    assert_eq!(tag(port).as_deref(), Some("a"));

    let pin = sha256_of(&kernel_b);
    let (code, output) = swap_cli(&home, &kernel_b, &pin, &["selftest-kernel", "--port", "{port}", "--tag", "b"]);
    assert_eq!(code, 0, "the swap is expected to succeed:\n{output}\n{}", supervisor.output());
    assert_eq!(tag(port).as_deref(), Some("b"), "the new kernel is serving: {output}");

    let record = status(&home).expect("a status record");
    assert_eq!(record.state, "healthy");
    assert_eq!(record.sha256.as_deref(), Some(pin.as_str()), "the record names the pin that was proved");
    let staged = home.bin_dir().join(&pin[..12]).join("wa-b");
    assert_eq!(record.kernel.as_deref(), Some(staged.as_path()));
    assert!(staged.is_file(), "the new bytes are staged by pin");
    assert!(kernel_a.is_file(), "the previous binary is kept for a rollback");
    let swap = record.last_swap.expect("a swap summary");
    assert!(swap.ok && !swap.rolled_back, "{swap:?}");
    assert_eq!(swap.previous, kernel_a);
    let result = std::fs::read_to_string(home.results_dir().join(format!("{}.json", swap.id))).expect("a result file");
    assert_eq!(SwapResult::from_json(&result).map(|result| result.ok), Some(true));
    drop(supervisor);
    assert!(!health::probe(port, Duration::from_millis(500)).answers(), "the stop ended the kernel");
}

// ---------------------------------------------------------------------------------------------------------
// 4. the new binary proves on a spare port and fails on the service port: rollback
// ---------------------------------------------------------------------------------------------------------

#[test]
fn a_swap_whose_new_kernel_is_unwell_on_the_service_port_rolls_back_to_the_old_one() {
    let scratch = Scratch::new("swap-rollback");
    let kernel_a = scratch.kernel("wa-a");
    let kernel_b = scratch.kernel("wa-b");
    let port = free_port();
    let client = free_port();
    let home = scratch.config(
        &kernel_a,
        "selftest-kernel --port {port} --tag a",
        &[("port", port.to_string()), ("client_port", client.to_string())],
    );
    let supervisor = SupervisorProcess::start(&home);
    wait_for("the supervisor to report healthy", Duration::from_secs(20), || {
        status(&home).map(|record| record.state == "healthy").unwrap_or(false)
    });
    assert_eq!(tag(port).as_deref(), Some("a"));

    // This kernel answers `ok:false` when the port it bound is the SERVICE port - so it proves on the spare
    // port (the first half of a swap succeeds) and then fails on the port that matters.
    let pin = sha256_of(&kernel_b);
    let (code, output) = swap_cli(
        &home,
        &kernel_b,
        &pin,
        &["selftest-kernel", "--port", "{port}", "--tag", "b", "--unhealthy-on-port", "{service_port}"],
    );
    assert_eq!(code, 1, "the swap must report a rollback, not success:\n{output}\n{}", supervisor.output());
    assert!(output.contains("rolled back"), "{output}");
    assert_eq!(tag(port).as_deref(), Some("a"), "the previous kernel is serving again:\n{output}");

    wait_for("the status to report the rollback", Duration::from_secs(20), || {
        status(&home).and_then(|record| record.last_swap).map(|swap| !swap.ok && swap.rolled_back).unwrap_or(false)
    });
    let record = status(&home).expect("a status record");
    assert_eq!(record.state, "healthy", "the old kernel is healthy again: {record:?}");
    let rollback = record.last_swap.expect("a swap summary");
    assert!(rollback.rolled_back, "{rollback:?}");
    assert_eq!(rollback.active, kernel_a, "the record names the binary that is running");
    assert!(kernel_a.is_file() && kernel_b.is_file(), "both binaries are still on disk");
    assert_eq!(
        std::fs::read_to_string(home.current_path()).expect("current").trim(),
        kernel_a.display().to_string(),
        "`current` was put back"
    );
    let rollback_file = home.results_dir().join(format!("{}.rollback.json", rollback.id));
    assert!(rollback_file.is_file(), "the late rollback is its own record: {}", rollback_file.display());
    drop(supervisor);
}

// ---------------------------------------------------------------------------------------------------------
// 5. refusals: a wrong pin, and a candidate that cannot answer at all
// ---------------------------------------------------------------------------------------------------------

#[test]
fn a_wrong_pin_is_refused_and_the_running_kernel_is_untouched() {
    let scratch = Scratch::new("swap-pin");
    let kernel_a = scratch.kernel("wa-a");
    let kernel_b = scratch.kernel("wa-b");
    let port = free_port();
    let home = scratch.config(&kernel_a, "selftest-kernel --port {port} --tag a", &[("port", port.to_string())]);
    let supervisor = SupervisorProcess::start(&home);
    wait_for("the supervisor to report healthy", Duration::from_secs(20), || {
        status(&home).map(|record| record.state == "healthy").unwrap_or(false)
    });

    let wrong = "00".repeat(32);
    let (code, output) = swap_cli(&home, &kernel_b, &wrong, &["selftest-kernel", "--port", "{port}", "--tag", "b"]);
    assert_eq!(code, 1, "{output}");
    assert!(output.contains("sha256_mismatch"), "the refusal names the mismatch: {output}");
    assert!(output.contains(&sha256_of(&kernel_b)), "the refusal names the real digest: {output}");
    assert_eq!(tag(port).as_deref(), Some("a"), "nothing was touched");
    assert!(wa_watchdog::swap::pending_requests(&home).is_empty(), "no request was queued");
    assert!(!home.bin_dir().join(&sha256_of(&kernel_b)[..12]).exists(), "nothing was staged");
    drop(supervisor);
}

#[test]
fn a_candidate_that_cannot_answer_is_refused_before_the_running_kernel_is_touched() {
    let scratch = Scratch::new("swap-unproved");
    let kernel_a = scratch.kernel("wa-a");
    let kernel_b = scratch.kernel("wa-b");
    let port = free_port();
    let home = scratch.config(&kernel_a, "selftest-kernel --port {port} --tag a", &[("port", port.to_string())]);
    let supervisor = SupervisorProcess::start(&home);
    wait_for("the supervisor to report healthy", Duration::from_secs(20), || {
        status(&home).map(|record| record.state == "healthy").unwrap_or(false)
    });
    let pin = sha256_of(&kernel_b);
    // 503 on every port: it binds and answers, and says it is not the service.
    let (code, output) = swap_cli(&home, &kernel_b, &pin, &["selftest-kernel", "--port", "{port}", "--health", "down"]);
    assert_eq!(code, 1, "{output}");
    assert!(output.contains("refused"), "{output}");
    assert_eq!(tag(port).as_deref(), Some("a"), "the running kernel was never stopped");
    assert!(wa_watchdog::swap::pending_requests(&home).is_empty(), "a candidate that cannot start is not queued");
    let record = status(&home).expect("a status record");
    assert_eq!(record.state, "healthy");
    assert!(record.last_swap.is_none(), "no swap was attempted: {record:?}");
    drop(supervisor);
}

// ---------------------------------------------------------------------------------------------------------
// 6. a kernel that answers and then dies inside the stability window is rolled back automatically
// ---------------------------------------------------------------------------------------------------------

#[test]
fn a_swapped_in_kernel_that_dies_early_is_rolled_back_to_the_previous_binary() {
    let scratch = Scratch::new("swap-early-crash");
    let kernel_a = scratch.kernel("wa-a");
    let kernel_b = scratch.kernel("wa-b");
    let port = free_port();
    let home = scratch.config(
        &kernel_a,
        "selftest-kernel --port {port} --tag a",
        &[("port", port.to_string()), ("stability_ms", "15000".to_string())],
    );
    let supervisor = SupervisorProcess::start(&home);
    wait_for("the supervisor to report healthy", Duration::from_secs(20), || {
        status(&home).map(|record| record.state == "healthy").unwrap_or(false)
    });
    let pin = sha256_of(&kernel_b);
    // Answers /health as soon as it binds, and exits 3s later - after the swap has settled and well inside
    // the 15s stability window, which is what must notice the death.
    let (code, output) = swap_cli(
        &home,
        &kernel_b,
        &pin,
        &["selftest-kernel", "--port", "{port}", "--tag", "b", "--exit-after-ms", "3000"],
    );
    assert_eq!(code, 0, "the switch itself succeeded:\n{output}");
    wait_for("the automatic rollback", Duration::from_secs(25), || {
        status(&home)
            .map(|record| record.last_swap.as_ref().map(|swap| swap.rolled_back).unwrap_or(false))
            .unwrap_or(false)
    });
    wait_for("the previous kernel to answer again", Duration::from_secs(20), || tag(port).as_deref() == Some("a"));
    let record = status(&home).expect("a status record");
    assert_eq!(record.state, "healthy");
    assert_eq!(record.kernel.as_deref(), Some(kernel_a.as_path()));
    assert_eq!(
        std::fs::read_to_string(home.current_path()).expect("current").trim(),
        kernel_a.display().to_string()
    );
    let summary = record.last_swap.expect("a swap summary");
    assert!(summary.rolled_back, "{summary:?}");
    assert!(summary.detail.contains("stability window"), "{summary:?}");
    assert!(home.results_dir().join(format!("{}.rollback.json", summary.id)).is_file());
    drop(supervisor);
}

// ---------------------------------------------------------------------------------------------------------
// 7. the CLI's own surfaces
// ---------------------------------------------------------------------------------------------------------

#[test]
fn status_and_stop_answer_without_a_supervisor() {
    let scratch = Scratch::new("cli");
    let kernel = scratch.kernel("wa-a");
    let port = free_port();
    let home = scratch.config(&kernel, "selftest-kernel --port {port}", &[("port", port.to_string())]);
    let home_arg = home.root().display().to_string();
    let status = Command::new(EXE).args(["status", "--home", &home_arg]).output().expect("run status");
    assert_eq!(status.status.code(), Some(1), "a home with no status is not healthy");
    assert!(String::from_utf8_lossy(&status.stdout).contains("no status"), "{}", String::from_utf8_lossy(&status.stdout));
    let status = Command::new(EXE).args(["status", "--json", "--home", &home_arg]).output().expect("run status --json");
    let text = String::from_utf8_lossy(&status.stdout).to_string();
    assert_eq!(json::field_bool(&text, "supervisor_alive"), Some(false), "{text}");
    let stop = Command::new(EXE).args(["stop", "--home", &home_arg]).output().expect("run stop");
    assert_eq!(stop.status.code(), Some(0), "stopping what is not running is not an error");
    assert!(String::from_utf8_lossy(&stop.stdout).contains("nothing"), "{}", String::from_utf8_lossy(&stop.stdout));
    // `init` writes a config that `run` accepts, and the pin it records is the binary's own.
    let home2 = Home::resolve(Some(scratch.path("home2"))).expect("home");
    let init = Command::new(EXE)
        .args(["init", "--kernel", &kernel.display().to_string(), "--port", &port.to_string(), "--home", &home2.root().display().to_string()])
        .output()
        .expect("run init");
    assert_eq!(init.status.code(), Some(0), "{}", String::from_utf8_lossy(&init.stderr));
    let config = Config::load(&home2.config_path()).expect("the written config parses");
    assert_eq!(config.kernel.as_deref(), Some(kernel.as_path()));
    assert_eq!(config.port, port);
    assert_eq!(home2.read_current().expect("a recorded kernel").binary, kernel);
    let verify = Command::new(EXE)
        .args(["verify", &kernel.display().to_string(), "--sha256", &sha256_of(&kernel)])
        .output()
        .expect("run verify");
    assert_eq!(verify.status.code(), Some(0));
    let verify = Command::new(EXE)
        .args(["verify", &kernel.display().to_string(), "--sha256", &"00".repeat(32)])
        .output()
        .expect("run verify");
    assert_eq!(verify.status.code(), Some(1), "a wrong pin is a refusal, not an error");
}
