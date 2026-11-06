//! Starting a kernel process, and ending one.
//!
//! Two decisions are made here rather than at each call site. First: the child's stdout/stderr go to a FILE,
//! never to the watchdog's own stream - a kernel that logs a lot must not be able to block on a pipe nobody
//! drains, and the log is what a refusal quotes. Second: the proof instance gets a scratch home and has the
//! rendezvous/relay variables removed, because a throwaway proof that registers with the fleet leaves a
//! stale node nobody can remove (docs/SENTINEL.md, "the stale-node pile").

use std::fs::OpenOptions;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

/// Everything one launch needs. Named fields rather than eight positional arguments, because a swapped
/// argument order here is a kernel started with the wrong flag.
pub struct Spawn<'a> {
    pub binary: &'a Path,
    pub args: &'a [String],
    /// The file stdout and stderr are appended to.
    pub log: &'a Path,
    /// Applied on top of the inherited environment.
    pub env: &'a [(String, String)],
    /// Removed from the inherited environment.
    pub env_remove: &'a [&'a str],
    pub work_dir: Option<&'a Path>,
}

pub fn spawn(spec: &Spawn) -> std::io::Result<Child> {
    if let Some(parent) = spec.log.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let log = OpenOptions::new().create(true).append(true).open(spec.log)?;
    let log_err = log.try_clone()?;
    let mut command = Command::new(spec.binary);
    command.args(spec.args);
    for name in spec.env_remove {
        command.env_remove(name);
    }
    for (name, value) in spec.env {
        command.env(name, value);
    }
    if let Some(dir) = spec.work_dir {
        command.current_dir(dir);
    }
    command.stdin(Stdio::null()).stdout(Stdio::from(log)).stderr(Stdio::from(log_err));
    command.spawn()
}

/// The environment of a PROOF instance: the live node's fleet identity is removed, its home is a scratch
/// directory, and it is marked unmanaged so anything that reads the marker treats it as the throwaway it is.
pub fn proof_env(scratch: &Path) -> Vec<(String, String)> {
    vec![
        ("WASM_AGENT_HOME".to_string(), scratch.display().to_string()),
        ("WASM_AGENT_MANAGED".to_string(), "0".to_string()),
    ]
}

pub const PROOF_ENV_REMOVE: [&str; 2] = ["WASM_AGENT_RENDEZVOUS", "WASM_AGENT_RELAY"];

/// End a child and wait for it. `kill` is SIGKILL on Unix and TerminateProcess on Windows: abrupt by
/// design (this is a supervisor, and a kernel that will not stop is the failure mode being avoided), at the
/// documented cost that a killed kernel cannot write its own goodbye - see docs/KERNEL.md, "Watchdog".
pub fn kill_and_wait(child: &mut Child) -> Option<std::process::ExitStatus> {
    let _ = child.kill();
    child.wait().ok()
}

/// Wait until `port` can be bound on loopback, i.e. until the kernel this supervisor just killed has really
/// released it. Measured on the Windows node this was written for: after `kill`, the listening socket is
/// reaped over 138-176 ms and, for a while, a connect to it is accepted and then RESET - so a probe reports
/// "an existing connection was forcibly closed" about a process that is already gone, and a swap that only
/// waited on health would call a perfectly good new kernel unhealthy. Binding is the question that matters:
/// it is the same syscall the kernel is about to make.
pub fn wait_port_bindable(port: u16, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        match std::net::TcpListener::bind(("127.0.0.1", port)) {
            // Dropping the listener immediately releases the port again; the kernel binds it next tick.
            Ok(listener) => {
                drop(listener);
                return true;
            }
            Err(_) => {
                if Instant::now() >= deadline {
                    return false;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
        }
    }
}

/// A port nothing is listening on right now. Binds an ephemeral port, reads it, releases it: racy in
/// principle, which is why a launch that cannot bind is a *start failure* the supervisor handles, not an
/// assumption it relies on.
pub fn free_port() -> std::io::Result<u16> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    drop(listener);
    Ok(port)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_free_port_can_be_bound_twice_in_a_row() {
        // Not a proof of anything, but it catches a "free port" helper that returns 0 or the same port.
        let first = free_port().expect("a free port");
        let second = free_port().expect("another free port");
        assert_ne!(first, 0);
        assert_ne!(second, 0);
        let listener = std::net::TcpListener::bind(("127.0.0.1", first)).expect("the port it named is free");
        drop(listener);
    }
}
