//! The supervisor: the loop that starts the kernel, probes it, restarts it with backoff, and performs the
//! switch half of a swap.
//!
//! The loop is `tick()` - one pass that looks, decides through [`crate::state::transition`], acts and reports
//! an [`Event`] - and `run()`, which calls `tick()` for ever. That split is why the interesting cases can be
//! tested without a fake clock: a test calls `tick()` between processes exiting on their own.

use std::path::PathBuf;
use std::process::Child;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::backoff::Backoff;
use crate::config::{Config, LaunchView};
use crate::health;
use crate::paths::Home;
use crate::proc;
use crate::state::{transition, Action, ActiveKernel, Input, LastExit, Phase, Status, SwapSummary};
use crate::paths::SwapRequest;
use crate::swap::{self, SwapResult};

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|elapsed| elapsed.as_millis() as u64).unwrap_or(0)
}

/// What happened in one pass. Every line is derived from what the supervisor observed, never from what the
/// kernel says: no message text, no prompt, no credential ever reaches this log.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Launched { pid: u32, binary: PathBuf, attempt: u32 },
    Healthy { pid: u32 },
    Exited { pid: u32, code: Option<i32>, uptime_ms: u64, restart_in_ms: u64, restarts: u64 },
    StartTimedOut { pid: u32, after_ms: u64, restart_in_ms: u64 },
    SwapStarted { id: String, previous: PathBuf, next: PathBuf },
    SwapSettled { id: String, active: PathBuf },
    SwapRolledBack { id: String, active: PathBuf, detail: String },
    StopRequested { kernel_pid: Option<u32> },
    Stopped,
    Note(String),
}

impl Event {
    pub fn line(&self) -> String {
        match self {
            Event::Launched { pid, binary, attempt } => {
                format!("started pid {pid} ({}) - attempt {attempt}", name_of(binary))
            }
            Event::Healthy { pid } => format!("pid {pid} answers /health ok:true"),
            Event::Exited { pid, code, uptime_ms, restart_in_ms, restarts } => format!(
                "pid {pid} exited after {uptime_ms}ms ({}); restart {restarts} in {restart_in_ms}ms",
                match code {
                    Some(code) => format!("code {code}"),
                    None => "a signal".to_string(),
                }
            ),
            Event::StartTimedOut { pid, after_ms, restart_in_ms } => {
                format!("pid {pid} did not answer /health within {after_ms}ms; restarting in {restart_in_ms}ms")
            }
            Event::SwapStarted { id, previous, next } => {
                format!("swap {id}: {} -> {}", name_of(previous), name_of(next))
            }
            Event::SwapSettled { id, active } => format!("swap {id} settled: {} is serving", name_of(active)),
            Event::SwapRolledBack { id, active, detail } => format!("swap {id} rolled back to {}: {detail}", name_of(active)),
            Event::StopRequested { kernel_pid } => match kernel_pid {
                Some(pid) => format!("stop requested; ending kernel pid {pid}"),
                None => "stop requested; no kernel is running".to_string(),
            },
            Event::Stopped => "stopped".to_string(),
            Event::Note(text) => text.clone(),
        }
    }
}

fn name_of(path: &std::path::Path) -> String {
    path.file_name().map(|name| name.to_string_lossy().to_string()).unwrap_or_else(|| path.display().to_string())
}

pub struct Supervisor {
    config: Config,
    home: Home,
    phase: Phase,
    child: Option<Child>,
    child_pid: Option<u32>,
    child_started: Instant,
    attempt: u32,
    restarts: u64,
    /// When the next launch may happen (`Instant::now()` while running).
    restart_at: Instant,
    probe_misses: u32,
    last_exit: Option<LastExit>,
    last_swap: Option<SwapSummary>,
    /// After a committed swap: the kernel to go back to, and when the swap counts as settled.
    stability: Option<(ActiveKernel, Instant)>,
    /// Set once `run` has decided to leave.
    pub exited: bool,
    last_status_write: Instant,
}

impl Supervisor {
    pub fn new(config: Config, home: Home) -> Supervisor {
        Supervisor {
            config,
            home,
            phase: Phase::Stopped,
            child: None,
            child_pid: None,
            child_started: Instant::now(),
            attempt: 0,
            restarts: 0,
            restart_at: Instant::now(),
            probe_misses: 0,
            last_exit: None,
            last_swap: None,
            stability: None,
            exited: false,
            last_status_write: Instant::now(),
        }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    /// The kernel that should be running: the recorded one, else the configured one. On the very first start
    /// the configured kernel is recorded, so `current` is never empty while a kernel is up.
    pub fn active(&self) -> Option<ActiveKernel> {
        if let Some(active) = self.home.read_current() {
            return Some(active);
        }
        self.config.kernel.as_ref().map(|binary| ActiveKernel {
            binary: binary.clone(),
            sha256: None,
            args: if self.config.kernel_args.is_empty() { Vec::new() } else { self.config.kernel_args.clone() },
        })
    }

    pub fn status(&self) -> Status {
        let active = self.active();
        Status {
            state: self.phase.as_str(),
            supervisor_pid: std::process::id(),
            kernel_pid: self.child_pid,
            kernel: active.as_ref().map(|active| active.binary.clone()),
            sha256: active.as_ref().and_then(|active| active.sha256.clone()),
            port: self.config.port,
            restarts: self.restarts,
            attempt: self.attempt,
            updated_ms: now_ms(),
            last_exit: self.last_exit.clone(),
            last_swap: self.last_swap.clone(),
            supervisor_alive: true,
        }
    }

    fn backoff(&self) -> Backoff {
        Backoff::new(self.config.backoff_base_ms, self.config.backoff_factor, self.config.backoff_max_ms)
    }

    fn write_status(&mut self, force: bool) {
        if !force && self.last_status_write.elapsed() < Duration::from_millis(1_000) {
            return;
        }
        let _ = self.home.write_status(&self.status());
        self.last_status_write = Instant::now();
    }

    /// Arguments for one launch of `active`, with the placeholders resolved for either the service instance
    /// or (from `swap::prove`) the proof instance.
    fn resolve(&self, active: &ActiveKernel, view: &LaunchView) -> Result<Vec<String>, String> {
        if active.args.is_empty() {
            self.config.resolve_args(view)
        } else {
            let mut scoped = self.config.clone();
            scoped.kernel_args = active.args.clone();
            scoped.resolve_args(view)
        }
    }

    fn launch(&mut self, active: &ActiveKernel) -> Result<u32, String> {
        let view = LaunchView::service(&self.config);
        let args = self.resolve(active, &view)?;
        let log = self.home.log_path("kernel");
        let env: Vec<(String, String)> = self.config.env.clone();
        let child = proc::spawn(&proc::Spawn {
            binary: &active.binary,
            args: &args,
            log: &log,
            env: &env,
            env_remove: &[],
            work_dir: self.config.work_dir.as_deref(),
        })
        .map_err(|error| format!("cannot start {}: {error}", active.binary.display()))?;
        let pid = child.id();
        self.child = Some(child);
        self.child_pid = Some(pid);
        self.child_started = Instant::now();
        self.phase = Phase::Starting;
        self.probe_misses = 0;
        Ok(pid)
    }

    fn stop_child(&mut self) -> Option<u32> {
        let mut child = self.child.take()?;
        let pid = self.child_pid.take();
        proc::kill_and_wait(&mut child);
        let _ = std::fs::remove_file(self.home.kernel_pid_path());
        pid
    }

    fn probe(&self) -> health::Probe {
        health::probe(self.config.port, Duration::from_millis(2_000))
    }

    /// One pass. Returns the events worth logging; an empty vec means "nothing changed".
    pub fn tick(&mut self) -> Vec<Event> {
        let mut events = Vec::new();

        // 1. A stop request wins over everything: it is the operator, and the loop is the only place that
        //    holds the kernel's pid.
        if self.home.stop_requested() && !self.exited {
            let (next, _) = transition(self.phase, Input::StopRequested);
            let pid = self.stop_child();
            events.push(Event::StopRequested { kernel_pid: pid });
            self.phase = next;
            self.exited = true;
            let _ = std::fs::remove_file(self.home.stop_flag_path());
            let _ = std::fs::remove_file(self.home.supervisor_pid_path());
            self.phase = Phase::Stopped;
            self.write_status(true);
            events.push(Event::Stopped);
            return events;
        }

        // 2. Did the kernel exit? An exit is settled here, once: it is the input that must not be missed
        //    between two passes, and `try_wait` is what makes a supervisor honest about a kernel it did not
        //    see die.
        if self.phase != Phase::Swapping {
            if let Some(child) = self.child.as_mut() {
                if let Ok(Some(status)) = child.try_wait() {
                    let pid = self.child_pid.take().unwrap_or(0);
                    self.child = None;
                    let uptime_ms = self.child_started.elapsed().as_millis() as u64;
                    let exit = LastExit { pid, code: status.code(), uptime_ms, at_ms: now_ms() };
                    self.last_exit = Some(exit.clone());

                    // A kernel that was swapped in and then died inside the stability window is the case the
                    // old binary was kept for: go back to it without waiting for a backoff.
                    let recent_swap = self
                        .stability
                        .as_ref()
                        .is_some_and(|(_, settled_until)| Instant::now() < *settled_until)
                        && self.phase == Phase::Healthy;
                    if recent_swap {
                        let (previous, _) = self.stability.take().expect("a recent swap is a recorded swap");
                        let _ = self.stop_child();
                        let _ = self.home.write_current(&previous);
                        self.attempt = 0;
                        self.restart_at = Instant::now();
                        let detail = format!("the swapped-in kernel exited after {uptime_ms}ms (stability window)");
                        self.record_rollback(&detail, &previous, &mut events);
                        self.phase = Phase::Backoff;
                    } else {
                        let (next, _) = transition(self.phase, Input::Exited);
                        self.phase = next;
                        self.restarts += 1;
                        self.attempt = self.attempt.saturating_add(1);
                        let delay = self.backoff().delay_ms(self.attempt.saturating_sub(1));
                        self.restart_at = Instant::now() + Duration::from_millis(delay);
                        events.push(Event::Exited {
                            pid,
                            code: exit.code,
                            uptime_ms,
                            restart_in_ms: delay,
                            restarts: self.restarts,
                        });
                    }
                }
            }
        }

        // 3. A swap request. Only while a kernel is running: the table says a request waits in `Backoff`,
        //    because a swap needs something to replace.
        if self.child.is_some() && matches!(self.phase, Phase::Starting | Phase::Healthy) {
            if let Some((path, request)) = swap::pending_requests(&self.home).into_iter().next() {
                if let Some(claimed) = swap::claim(&path) {
                    self.perform_swap(request, &mut events);
                    let _ = std::fs::remove_file(claimed);
                } else {
                    events.push(Event::Note(format!("swap request {} is already claimed", request.id)));
                }
            }
        }

        // 4. Start what is not running.
        if self.child.is_none() && !self.exited && self.phase != Phase::Swapping && Instant::now() >= self.restart_at {
            match self.active() {
                Some(active) => {
                    if let Some(active) = self.adopt_configured_kernel(active) {
                        match self.launch(&active) {
                            Ok(pid) => events.push(Event::Launched {
                                pid,
                                binary: active.binary.clone(),
                                attempt: self.attempt,
                            }),
                            Err(error) => {
                                self.phase = Phase::Backoff;
                                self.attempt = self.attempt.saturating_add(1);
                                let delay = self.backoff().delay_ms(self.attempt.saturating_sub(1));
                                self.restart_at = Instant::now() + Duration::from_millis(delay);
                                events.push(Event::Note(format!("{error}; retrying in {delay}ms")));
                            }
                        }
                    }
                }
                None => {
                    self.exited = true;
                    events.push(Event::Note("no kernel is configured: set `kernel` in the config (or run `wa-watchdog init`)".into()));
                }
            }
        }

        // 5. Health.
        match self.phase {
            Phase::Starting => {
                let elapsed = self.child_started.elapsed();
                if elapsed >= Duration::from_millis(self.config.start_timeout_ms) {
                    let pid = self.stop_child().unwrap_or(0);
                    self.phase = Phase::Backoff;
                    self.restarts += 1;
                    self.attempt = self.attempt.saturating_add(1);
                    let delay = self.backoff().delay_ms(self.attempt.saturating_sub(1));
                    self.restart_at = Instant::now() + Duration::from_millis(delay);
                    events.push(Event::StartTimedOut {
                        pid,
                        after_ms: elapsed.as_millis() as u64,
                        restart_in_ms: delay,
                    });
                } else {
                    let probe = self.probe();
                    if probe.ready() {
                        let pid = self.child_pid.unwrap_or(0);
                        self.phase = Phase::Healthy;
                        self.attempt = 0;
                        self.probe_misses = 0;
                        let _ = self.home.write_pid(&self.home.kernel_pid_path(), pid);
                        events.push(Event::Healthy { pid });
                    }
                }
            }
            Phase::Healthy if self.config.health_miss_limit > 0 => {
                // Off by default, and this is the reason: a busy node answers `ok:false` while a run is
                // stalled, and killing it for that would interrupt the turn the node exists for.
                let healthy = self.probe().ready();
                if healthy {
                    self.probe_misses = 0;
                } else {
                    self.probe_misses += 1;
                    if self.probe_misses >= self.config.health_miss_limit {
                        let pid = self.stop_child().unwrap_or(0);
                        self.phase = Phase::Backoff;
                        self.restarts += 1;
                        self.attempt = self.attempt.saturating_add(1);
                        let delay = self.backoff().delay_ms(self.attempt.saturating_sub(1));
                        self.restart_at = Instant::now() + Duration::from_millis(delay);
                        events.push(Event::Note(format!(
                            "pid {pid} missed {} health probes; restarting in {delay}ms",
                            self.probe_misses
                        )));
                    }
                }
            }
            Phase::Healthy => {
                if let Some((_, settled_until)) = &self.stability {
                    if Instant::now() >= *settled_until {
                        self.stability = None;
                    }
                }
            }
            _ => {}
        }

        if !events.is_empty() {
            self.write_status(true);
        } else {
            self.write_status(false);
        }
        events
    }

    /// First start: record the configured kernel so `current` answers "what is running" from then on.
    fn adopt_configured_kernel(&self, active: ActiveKernel) -> Option<ActiveKernel> {
        if self.home.read_current().is_none() {
            let _ = self.home.write_current(&active);
        }
        Some(active)
    }

    /// The switch half of a swap: stop the old kernel, start the new one, wait for it, roll back if it does
    /// not answer. Blocking for up to `swap_health_window_ms` (plus the rollback's own start), which is the
    /// one thing a supervisor may do slowly - nothing else is being served while it does.
    fn perform_swap(&mut self, request: SwapRequest, events: &mut Vec<Event>) {
        let previous = match self.active() {
            Some(active) => active,
            None => {
                events.push(Event::Note(format!("swap {} refused: no kernel is recorded to replace", request.id)));
                return;
            }
        };
        let (_, action) = transition(self.phase, Input::SwapRequested);
        if action != Action::BeginSwap {
            // Put the request back: it is not refused, it is early.
            let claimed = self.home.requests_dir().join(format!("{}.claimed", request.id));
            let _ = std::fs::rename(claimed, self.home.requests_dir().join(format!("{}.json", request.id)));
            events.push(Event::Note(format!("swap {} waits: the supervisor is {}", request.id, self.phase.as_str())));
            return;
        }
        let next = ActiveKernel { binary: request.binary.clone(), sha256: Some(request.sha256.clone()), args: request.args.clone() };
        events.push(Event::SwapStarted {
            id: request.id.clone(),
            previous: previous.binary.clone(),
            next: next.binary.clone(),
        });
        self.phase = Phase::Swapping;
        self.stability = None;
        self.stop_child();

        let mut detail = String::new();
        let mut proved = false;
        // The kernel that was just killed may not have released the port yet, and a probe against a port in
        // that state is answered with a reset - which would read as "the new kernel is unwell". Wait for the
        // port to be bindable first; that is the same question the new kernel is about to ask the OS.
        let freed = proc::wait_port_bindable(
            self.config.port,
            Duration::from_millis(self.config.swap_health_window_ms.min(10_000)),
        );
        if !freed {
            detail = format!("the previous kernel did not release port {} for the new one", self.config.port);
        }
        match if freed { self.launch(&next) } else { Err(detail.clone()) } {
            Ok(_) => {
                let deadline = Instant::now() + Duration::from_millis(self.config.swap_health_window_ms);
                let interval = Duration::from_millis(self.config.tick_ms.clamp(20, 250));
                loop {
                    if let Some(child) = self.child.as_mut() {
                        if let Ok(Some(status)) = child.try_wait() {
                            detail = format!("the new kernel exited ({status}) before answering /health");
                            self.child = None;
                            self.child_pid = None;
                            break;
                        }
                    }
                    let probe = self.probe();
                    if probe.ready() {
                        proved = true;
                        break;
                    }
                    if Instant::now() >= deadline {
                        detail = format!(
                            "the new kernel did not answer /health within {}ms ({})",
                            self.config.swap_health_window_ms,
                            probe.why_not()
                        );
                        break;
                    }
                    std::thread::sleep(interval);
                }
            }
            Err(error) => detail = error,
        }

        if proved {
            let _ = self.home.write_current(&next);
            self.phase = Phase::Healthy;
            self.attempt = 0;
            let pid = self.child_pid.unwrap_or(0);
            let _ = self.home.write_pid(&self.home.kernel_pid_path(), pid);
            self.stability = if self.config.rollback_on_early_crash && self.config.stability_ms > 0 {
                Some((previous.clone(), Instant::now() + Duration::from_millis(self.config.stability_ms)))
            } else {
                None
            };
            self.last_swap = Some(SwapSummary {
                id: request.id.clone(),
                ok: true,
                rolled_back: false,
                previous: previous.binary.clone(),
                active: next.binary.clone(),
                detail: format!("proved on :{}", self.config.port),
                at_ms: now_ms(),
            });
            events.push(Event::SwapSettled { id: request.id.clone(), active: next.binary.clone() });
            let _ = swap::write_result(
                &self.home,
                &SwapResult {
                    id: request.id.clone(),
                    ok: true,
                    rolled_back: false,
                    previous: previous.binary.clone(),
                    active: next.binary.clone(),
                    detail: format!("proved on :{}", self.config.port),
                    at_ms: now_ms(),
                },
            );
        } else {
            // Roll back: the old binary is still on disk and is what the record names, so this is a path
            // change plus a restart - never a rebuild. The candidate that is being stopped has the same
            // port-release problem as the kernel before it, so this waits for the port too.
            self.stop_child();
            let _ = self.home.write_current(&previous);
            let _ = proc::wait_port_bindable(
                self.config.port,
                Duration::from_millis(self.config.swap_health_window_ms.min(10_000)),
            );
            let restored = match self.launch(&previous) {
                Ok(_) => {
                    let deadline = Instant::now() + Duration::from_millis(self.config.start_timeout_ms);
                    let interval = Duration::from_millis(self.config.tick_ms.clamp(20, 250));
                    let mut healthy = false;
                    while Instant::now() < deadline {
                        if let Some(child) = self.child.as_mut() {
                            if let Ok(Some(_)) = child.try_wait() {
                                self.child = None;
                                self.child_pid = None;
                                break;
                            }
                        }
                        if self.probe().ready() {
                            healthy = true;
                            break;
                        }
                        std::thread::sleep(interval);
                    }
                    healthy
                }
                Err(_) => false,
            };
            if restored {
                self.phase = Phase::Healthy;
                self.attempt = 0;
                let pid = self.child_pid.unwrap_or(0);
                let _ = self.home.write_pid(&self.home.kernel_pid_path(), pid);
            } else {
                self.phase = Phase::Starting;
                self.restart_at = Instant::now();
            }
            let detail = format!(
                "{detail}; the previous kernel {}",
                if restored { "is serving again" } else { "did not answer either" }
            );
            self.record_rollback(&detail, &previous, events);
            let _ = swap::write_result(
                &self.home,
                &SwapResult {
                    id: request.id.clone(),
                    ok: false,
                    rolled_back: true,
                    previous: previous.binary.clone(),
                    active: previous.binary.clone(),
                    detail: detail.clone(),
                    at_ms: now_ms(),
                },
            );
        }
    }

    fn record_rollback(&mut self, detail: &str, previous: &ActiveKernel, events: &mut Vec<Event>) {
        let id = self.last_swap.as_ref().map(|swap| swap.id.clone()).unwrap_or_else(|| "swap".to_string());
        self.last_swap = Some(SwapSummary {
            id: id.clone(),
            ok: false,
            rolled_back: true,
            previous: previous.binary.clone(),
            active: previous.binary.clone(),
            detail: detail.to_string(),
            at_ms: now_ms(),
        });
        events.push(Event::SwapRolledBack { id: id.clone(), active: previous.binary.clone(), detail: detail.to_string() });
        // The caller may already have read the "proved" result, so the late rollback is its own file: a
        // record is never rewritten to say something else.
        let _ = swap::write_result(
            &self.home,
            &SwapResult {
                id: format!("{id}.rollback"),
                ok: false,
                rolled_back: true,
                previous: previous.binary.clone(),
                active: previous.binary.clone(),
                detail: detail.to_string(),
                at_ms: now_ms(),
            },
        );
    }

    /// Run until `stop` (or until no kernel is configured). `report` receives every event plus the tick's
    /// cadence; it is the caller's job to write them somewhere durable.
    pub fn run(&mut self, mut report: impl FnMut(&Event)) -> Result<(), String> {
        if self.active().is_none() {
            return Err("no kernel is configured: set `kernel` in the config (or run `wa-watchdog init`)".to_string());
        }
        // A second kernel started beside a live one cannot bind the port, and its health would be answered by
        // the node it failed to replace (docs/SENTINEL.md: an upgrade that "verified" the wrong pid). Refuse
        // before anything is spawned.
        if self.probe().answers() {
            return Err(format!(
                "port {} already answers /health: another kernel is serving; stop it (or its supervisor) first",
                self.config.port
            ));
        }
        self.home.ensure().map_err(|error| format!("cannot prepare {}: {error}", self.home.root().display()))?;
        self.home
            .write_pid(&self.home.supervisor_pid_path(), std::process::id())
            .map_err(|error| format!("cannot write the supervisor pid: {error}"))?;
        self.phase = Phase::Stopped;
        while !self.exited {
            for event in self.tick() {
                report(&event);
            }
            if self.exited {
                break;
            }
            std::thread::sleep(Duration::from_millis(self.config.tick_ms.clamp(10, 2_000)));
        }
        Ok(())
    }
}
