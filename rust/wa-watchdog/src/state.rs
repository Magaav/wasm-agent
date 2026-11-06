//! The supervisor's state machine, as a pure table, plus the records it writes.
//!
//! The table is the contract: `transition(phase, input)` says what a phase becomes and which *single* action
//! the supervisor then takes. It is here rather than inline in the loop so that the interesting part - a
//! swap that does not work, a stop that arrives during a backoff, a crash right after a swap settled - can
//! be tested without a process, a port or a clock.

use std::path::PathBuf;

use crate::json;
use crate::paths::JsonArray;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    /// Nothing is running and nothing was ever started (`init` wrote a config, `run` has not yet).
    Stopped,
    /// A kernel is starting and has not answered `/health` yet.
    Starting,
    /// The kernel answered `/health` with `ok: true`.
    Healthy,
    /// Waiting out the backoff delay before starting a kernel that exited.
    Backoff,
    /// A new binary is being switched in; the old one has been stopped and the new one is being proved.
    Swapping,
    /// The supervisor was asked to stop and is stopping its kernel.
    Stopping,
}

impl Phase {
    pub fn as_str(self) -> &'static str {
        match self {
            Phase::Stopped => "stopped",
            Phase::Starting => "starting",
            Phase::Healthy => "healthy",
            Phase::Backoff => "backoff",
            Phase::Swapping => "swapping",
            Phase::Stopping => "stopping",
        }
    }

    pub fn is_running(self) -> bool {
        matches!(self, Phase::Starting | Phase::Healthy | Phase::Swapping)
    }
}

/// What the supervisor observed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Input {
    /// The kernel process was started.
    Launched,
    /// The probe answered 200 and `ok: true`.
    HealthOk,
    /// The start did not answer within `start_timeout_ms`.
    StartTimedOut,
    /// The kernel process exited.
    Exited,
    /// A *running* kernel missed its health budget (`health_miss_limit` > 0).
    Unhealthy,
    /// A swap request was found on disk.
    SwapRequested,
    /// The swapped-in kernel answered `/health`.
    SwapProved,
    /// The swapped-in kernel did not answer within the window, or died.
    SwapFailed,
    /// A kernel that was swapped in exited before `stability_ms` elapsed.
    StabilityViolated,
    /// `stop` was found on disk.
    StopRequested,
    /// The kernel is gone and the supervisor is done.
    StopComplete,
}

/// The one thing the supervisor does next. One action per input: two actions would need an order, and an
/// order chosen inline is an order nobody tested.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    /// Nothing to do.
    None,
    /// Start the active kernel.
    Launch,
    /// Record the pid, reset the attempt counter, write `status.json`.
    MarkHealthy,
    /// Kill the kernel (it is not going to answer) and schedule a restart with backoff.
    KillAndRestart,
    /// Schedule a restart with backoff; the kernel is already gone.
    RestartLater,
    /// Record the request and switch: stop the old kernel, start the new one, prove it.
    BeginSwap,
    /// The new kernel answered: commit `current`, arm the stability window.
    SettleSwap,
    /// Put the previous kernel back and relaunch it.
    Rollback,
    /// A swap settled but the kernel died early: put the previous kernel back and relaunch it.
    RollbackToPrevious,
    /// Kill the kernel and leave.
    KillAndExit,
    /// Leave.
    Exit,
}

/// The documented table. An input that is illegal for a phase is answered with `(phase, Action::Defer)`-like
/// no-ops only where waiting is the honest behaviour (see `SwapRequested` in `Backoff`); everything else
/// illegal is a no-op with no state change, and the caller logs it.
pub fn transition(phase: Phase, input: Input) -> (Phase, Action) {
    use Action::*;
    use Input::*;
    use Phase::*;
    match (phase, input) {
        // A kernel that was asked to start.
        (Stopped, Launched) | (Backoff, Launched) => (Starting, Launch),
        (Starting, Launched) => (Starting, None),
        (Starting, HealthOk) => (Healthy, MarkHealthy),
        (Starting, StartTimedOut) => (Backoff, KillAndRestart),
        (Starting, Exited) => (Backoff, RestartLater),

        // A kernel that is up.
        (Healthy, HealthOk) => (Healthy, None),
        (Healthy, Unhealthy) => (Backoff, KillAndRestart),
        (Healthy, Exited) => (Backoff, RestartLater),
        (Healthy, StabilityViolated) => (Starting, RollbackToPrevious),

        // Backoff: nothing is running, the clock decides when to come back.
        (Backoff, HealthOk) => (Backoff, None),
        (Backoff, StartTimedOut) | (Backoff, Exited) => (Backoff, None),
        (Backoff, Unhealthy) => (Backoff, None),
        // A swap needs a kernel to replace, and the supervisor is not running one here: the request stays on
        // disk and is picked up when a kernel starts. Answering it here would mean launching a candidate
        // that has never been proved against a working old kernel.
        (Backoff, SwapRequested) => (Backoff, None),

        // A swap, from a running kernel.
        (Starting, SwapRequested) | (Healthy, SwapRequested) => (Swapping, BeginSwap),
        (Swapping, SwapProved) => (Healthy, SettleSwap),
        (Swapping, SwapFailed) => (Starting, Rollback),
        (Swapping, Exited) => (Starting, Rollback),
        (Swapping, HealthOk) => (Swapping, None),
        (Swapping, StartTimedOut) | (Swapping, Unhealthy) => (Swapping, None),
        (Swapping, StabilityViolated) => (Starting, RollbackToPrevious),
        (Swapping, SwapRequested) => (Swapping, None),

        // Stopping wins over everything else, which is why it is checked first by the caller.
        (_, StopRequested) => match phase {
            Stopped => (Stopped, Exit),
            Backoff => (Stopping, Exit),
            _ => (Stopping, KillAndExit),
        },
        (Stopping, StopComplete) => (Stopped, Exit),
        (Stopping, _) => (Stopping, None),
        (Stopped, _) => (Stopped, Exit),
        // Everything else is an input this phase cannot use. It changes nothing: an observation that cannot
        // move the machine must not be able to.
        _ => (phase, None),
    }
}

/// The kernel the supervisor considers active: what to run, its pin, and its arguments AS WRITTEN.
#[derive(Debug, Clone, PartialEq)]
pub struct ActiveKernel {
    pub binary: PathBuf,
    /// The pin the binary was proved against, when it came through `swap`.
    pub sha256: Option<String>,
    /// Arguments with [`crate::config::PLACEHOLDERS`] intact, so one list starts the service instance and the
    /// proof instance on different ports. Empty means "use `kernel_args` from the config".
    pub args: Vec<String>,
}

impl ActiveKernel {
    pub fn to_json(&self) -> String {
        json::object(&[
            ("binary", self.binary.clone().into()),
            ("sha256", match &self.sha256 {
                Some(pin) => json::Json::Str(pin.clone()),
                None => json::Json::Null,
            }),
            ("args", json::Json::Raw(JsonArray(&self.args).render())),
        ])
    }

    pub fn from_json(text: &str) -> Option<ActiveKernel> {
        Some(ActiveKernel {
            binary: PathBuf::from(json::field_str(text, "binary")?),
            sha256: json::field_str(text, "sha256"),
            args: crate::paths::args_from_json(text),
        })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct LastExit {
    pub pid: u32,
    /// `None` when the process was ended by a signal (Unix) - the exit code does not exist then.
    pub code: Option<i32>,
    pub uptime_ms: u64,
    pub at_ms: u64,
}

impl LastExit {
    fn to_json(&self) -> String {
        json::object(&[
            ("pid", self.pid.into()),
            ("code", match self.code {
                Some(code) => json::Json::Int(code as i64),
                None => json::Json::Null,
            }),
            ("uptime_ms", self.uptime_ms.into()),
            ("at_ms", self.at_ms.into()),
        ])
    }
}

/// The outcome of the last swap, as the supervisor saw it (the CLI writes its own copy in `results/`).
#[derive(Debug, Clone, PartialEq)]
pub struct SwapSummary {
    pub id: String,
    pub ok: bool,
    pub rolled_back: bool,
    pub previous: PathBuf,
    pub active: PathBuf,
    /// One line, no message text and no secrets: why it was rolled back, or "proved".
    pub detail: String,
    pub at_ms: u64,
}

impl SwapSummary {
    pub fn to_json(&self) -> String {
        json::object(&[
            ("id", self.id.clone().into()),
            ("ok", self.ok.into()),
            ("rolled_back", self.rolled_back.into()),
            ("previous", self.previous.clone().into()),
            ("active", self.active.clone().into()),
            ("detail", self.detail.clone().into()),
            ("at_ms", self.at_ms.into()),
        ])
    }
}

/// `status.json`: what the watchdog is doing, for a script or a human. Deliberately flat - every field is
/// a scalar or a small object this crate wrote.
#[derive(Debug, Clone, PartialEq)]
pub struct Status {
    pub state: &'static str,
    pub supervisor_pid: u32,
    pub kernel_pid: Option<u32>,
    pub kernel: Option<PathBuf>,
    pub sha256: Option<String>,
    pub port: u16,
    pub restarts: u64,
    pub attempt: u32,
    pub updated_ms: u64,
    pub last_exit: Option<LastExit>,
    pub last_swap: Option<SwapSummary>,
    /// `false` while `run` has not written a status at all (a fresh home).
    pub supervisor_alive: bool,
}

impl Status {
    pub fn to_json(&self) -> String {
        json::object(&[
            ("state", self.state.into()),
            ("supervisor_pid", self.supervisor_pid.into()),
            ("supervisor_alive", self.supervisor_alive.into()),
            ("kernel_pid", match self.kernel_pid {
                Some(pid) => json::Json::UInt(pid as u64),
                None => json::Json::Null,
            }),
            ("kernel", match &self.kernel {
                Some(path) => json::Json::Str(path.display().to_string()),
                None => json::Json::Null,
            }),
            ("sha256", match &self.sha256 {
                Some(pin) => json::Json::Str(pin.clone()),
                None => json::Json::Null,
            }),
            ("port", self.port.into()),
            ("restarts", self.restarts.into()),
            ("attempt", self.attempt.into()),
            ("updated_ms", self.updated_ms.into()),
            ("last_exit", match &self.last_exit {
                Some(exit) => json::Json::Raw(exit.to_json()),
                None => json::Json::Null,
            }),
            ("last_swap", match &self.last_swap {
                Some(swap) => json::Json::Raw(swap.to_json()),
                None => json::Json::Null,
            }),
        ])
    }

    /// A one-line human answer, for a terminal. No sentence here claims a run: it describes a file.
    pub fn summary(&self) -> String {
        let kernel = match (&self.kernel, self.kernel_pid) {
            (Some(path), Some(pid)) => format!("{} (pid {pid})", path.display()),
            (Some(path), None) => path.display().to_string(),
            _ => "none".to_string(),
        };
        let mut line = format!(
            "watchdog: {} - kernel {kernel} on :{}, restarts {}, attempt {}",
            self.state, self.port, self.restarts, self.attempt
        );
        if let Some(exit) = &self.last_exit {
            line.push_str(&format!(
                "; last exit {} after {}ms",
                match exit.code {
                    Some(code) => format!("code {code}"),
                    None => "a signal".to_string(),
                },
                exit.uptime_ms
            ));
        }
        if let Some(swap) = &self.last_swap {
            line.push_str(&format!(
                "; last swap {} {}: {}",
                swap.id,
                if swap.ok { "proved" } else { "rolled back" },
                swap.detail
            ));
        }
        if !self.supervisor_alive {
            line.push_str("; no supervisor status has been written yet");
        }
        line
    }

    pub fn from_json(text: &str) -> Option<Status> {
        Some(Status {
            state: known_state(&json::field_str(text, "state")?)?,
            supervisor_pid: json::field_u64(text, "supervisor_pid")? as u32,
            supervisor_alive: json::field_bool(text, "supervisor_alive").unwrap_or(false),
            kernel_pid: json::field_u64(text, "kernel_pid").map(|pid| pid as u32),
            kernel: json::field_str(text, "kernel").map(PathBuf::from),
            sha256: json::field_str(text, "sha256"),
            port: json::field_u64(text, "port")? as u16,
            restarts: json::field_u64(text, "restarts").unwrap_or(0),
            attempt: json::field_u64(text, "attempt").unwrap_or(0) as u32,
            updated_ms: json::field_u64(text, "updated_ms").unwrap_or(0),
            last_exit: json::field(text, "last_exit").and_then(|raw| {
                Some(LastExit {
                    pid: json::field_u64(raw, "pid")? as u32,
                    code: json::field(raw, "code").and_then(|value| value.trim().parse::<i32>().ok()),
                    uptime_ms: json::field_u64(raw, "uptime_ms").unwrap_or(0),
                    at_ms: json::field_u64(raw, "at_ms").unwrap_or(0),
                })
            }),
            last_swap: json::field(text, "last_swap").and_then(|raw| {
                Some(SwapSummary {
                    id: json::field_str(raw, "id")?,
                    ok: json::field_bool(raw, "ok")?,
                    rolled_back: json::field_bool(raw, "rolled_back").unwrap_or(false),
                    previous: PathBuf::from(json::field_str(raw, "previous").unwrap_or_default()),
                    active: PathBuf::from(json::field_str(raw, "active").unwrap_or_default()),
                    detail: json::field_str(raw, "detail").unwrap_or_default(),
                    at_ms: json::field_u64(raw, "at_ms").unwrap_or(0),
                })
            }),
        })
    }
}

/// A state word this crate writes, as the static string the rest of the crate compares against.
fn known_state(word: &str) -> Option<&'static str> {
    match word {
        "stopped" => Some("stopped"),
        "starting" => Some("starting"),
        "healthy" => Some("healthy"),
        "backoff" => Some("backoff"),
        "swapping" => Some("swapping"),
        "stopping" => Some("stopping"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The table, written out as the table. Each row is a claim a reader of the docs can check.
    #[test]
    fn the_documented_transitions_hold() {
        use Action::*;
        use Input::*;
        use Phase::*;
        let cases: &[(Phase, Input, Phase, Action)] = &[
            (Stopped, Launched, Starting, Launch),
            (Starting, HealthOk, Healthy, MarkHealthy),
            (Starting, StartTimedOut, Backoff, KillAndRestart),
            (Starting, Exited, Backoff, RestartLater),
            (Healthy, Exited, Backoff, RestartLater),
            (Healthy, Unhealthy, Backoff, KillAndRestart),
            (Backoff, Launched, Starting, Launch),
            (Healthy, SwapRequested, Swapping, BeginSwap),
            (Swapping, SwapProved, Healthy, SettleSwap),
            (Swapping, SwapFailed, Starting, Rollback),
            (Healthy, StabilityViolated, Starting, RollbackToPrevious),
            (Backoff, StopRequested, Stopping, Exit),
            (Starting, StopRequested, Stopping, KillAndExit),
            (Healthy, StopRequested, Stopping, KillAndExit),
            (Swapping, StopRequested, Stopping, KillAndExit),
            (Stopping, StopComplete, Stopped, Exit),
        ];
        for (phase, input, expected_phase, expected_action) in cases {
            assert_eq!(transition(*phase, *input), (*expected_phase, *expected_action), "{phase:?} + {input:?}");
        }
    }

    #[test]
    fn a_swap_request_waits_while_no_kernel_runs() {
        // The dangerous alternative: launching a candidate nobody proved beside a kernel that is down, or
        // answering the request with an old kernel still holding the port.
        assert_eq!(transition(Phase::Backoff, Input::SwapRequested), (Phase::Backoff, Action::None));
        // And it is not answered twice: a request arriving during a swap is ignored, not queued behind it.
        assert_eq!(transition(Phase::Swapping, Input::SwapRequested), (Phase::Swapping, Action::None));
    }

    #[test]
    fn an_illegal_input_changes_nothing() {
        // A verdict, a crash or a launch in a phase that cannot use it must not invent progress: the actions
        // for the legal inputs are covered by the table test above, and this is the other half - the inputs
        // that arrive late, or twice, or in the wrong phase.
        let cases: &[(Phase, Input)] = &[
            (Phase::Stopped, Input::HealthOk),
            (Phase::Stopped, Input::SwapProved),
            (Phase::Starting, Input::SwapProved),
            (Phase::Starting, Input::StopComplete),
            (Phase::Healthy, Input::SwapFailed),
            (Phase::Backoff, Input::SwapProved),
            (Phase::Backoff, Input::StartTimedOut),
            (Phase::Swapping, Input::StopComplete),
            (Phase::Swapping, Input::SwapRequested),
            (Phase::Stopping, Input::HealthOk),
            (Phase::Stopping, Input::Launched),
        ];
        for (phase, input) in cases {
            assert_eq!(transition(*phase, *input).0, *phase, "{phase:?} + {input:?} must not change the phase");
        }
    }

    #[test]
    fn a_status_round_trips_through_its_json() {
        let status = Status {
            state: "healthy",
            supervisor_pid: 41,
            kernel_pid: Some(42),
            kernel: Some(PathBuf::from("/opt/wa/wa")),
            sha256: Some("ef".repeat(32)),
            port: 8799,
            restarts: 3,
            attempt: 0,
            updated_ms: 1_700_000_000_000,
            last_exit: Some(LastExit { pid: 40, code: Some(1), uptime_ms: 250, at_ms: 1_699_999_999_000 }),
            last_swap: Some(SwapSummary {
                id: "swap-7".into(),
                ok: false,
                rolled_back: true,
                previous: PathBuf::from("/opt/wa/bin/aaa/wa"),
                active: PathBuf::from("/opt/wa/bin/bbb/wa"),
                detail: "the new kernel did not answer /health".into(),
                at_ms: 1_700_000_000_000,
            }),
            supervisor_alive: true,
        };
        let parsed = Status::from_json(&status.to_json()).expect("status round trip");
        assert_eq!(parsed, status);
        assert!(status.summary().contains("restarts 3"), "{}", status.summary());
        assert!(status.summary().contains("rolled back"), "{}", status.summary());
    }
}
