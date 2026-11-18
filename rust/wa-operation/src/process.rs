//! Nonblocking output and process containment. No reader threads, read_to_end, or unbounded wait.
use crate::Spec;
use std::io;
/// The niceness an operation's command runs at (18/11, item 1.6): one step below the node's own, so a
/// long build, a test suite or a promoted background call cannot starve the session that is waiting on
/// it. It is a niceness, so raising it never needs privilege and an idle node still runs the command at
/// full speed - the command only yields when something else wants the CPU. WASM_AGENT_OPERATION_NICE
/// overrides it; 0 keeps the inherited priority.
#[cfg(unix)]
pub fn operation_nice() -> i32 {
    std::env::var("WASM_AGENT_OPERATION_NICE")
        .ok()
        .and_then(|value| value.trim().parse::<i32>().ok())
        .map(|nice| nice.clamp(0, 19))
        .unwrap_or(10)
}
#[cfg(windows)]
#[path = "windows.rs"]
mod platform;
#[cfg(windows)]
pub use platform::Process;

#[cfg(unix)]
pub struct Process {
    child: std::process::Child,
    pub stdout: Option<std::process::ChildStdout>,
    pub stderr: Option<std::process::ChildStderr>,
    group: i32,
    terminated: bool,
}
#[cfg(unix)]
impl Process {
    pub fn owned_id(&self)->Option<u32>{Some(self.child.id())}
    pub fn spawn(spec: &Spec) -> io::Result<Self> {
        use std::os::unix::{io::AsRawFd, process::CommandExt};
        use std::process::{Command, Stdio};
        let mut command = Command::new(&spec.program);
        command
            .args(&spec.args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .process_group(0);
        if !spec.cwd.is_empty() {
            command.current_dir(&spec.cwd);
        }
        for (k, v) in &spec.env {
            command.env(k, v);
        }
        // Low CPU priority for the command (see operation_nice), and ONLY for a backgrounded one
        // (18/11 round 2, finding 9): a call the caller is actively awaiting keeps the node's own
        // priority, so a foreground build runs as fast as the node can run it. Best effort on purpose:
        // an environment that refuses the call leaves the command at the node's own priority.
        let nice = if spec.background { operation_nice() } else { 0 };
        if nice > 0 {
            unsafe {
                command.pre_exec(move || {
                    libc::setpriority(libc::PRIO_PROCESS, 0, nice);
                    Ok(())
                });
            }
        }
        let mut child = command.spawn()?;
        let stdout = child.stdout.take();
        let stderr = child.stderr.take();
        let result = Self {
            group: child.id() as i32,
            terminated: false,
            child,
            stdout,
            stderr,
        };
        for fd in [
            result.stdout.as_ref().unwrap().as_raw_fd(),
            result.stderr.as_ref().unwrap().as_raw_fd(),
        ] {
            let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
            if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(result)
    }
    pub fn code(&mut self) -> io::Result<Option<i32>> {
        Ok(self.child.try_wait()?.map(|s| s.code().unwrap_or(-1)))
    }
    pub fn terminate(&mut self) -> io::Result<()> {
        // Do not signal a numeric PGID again after successful cleanup: after reaping,
        // that number may be recycled while evidence is being persisted.
        if self.terminated {
            return Ok(());
        }
        if unsafe { libc::kill(-self.group, libc::SIGKILL) } < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() != Some(libc::ESRCH) {
                return Err(error);
            }
        }
        self.terminated = true;
        Ok(())
    }
    pub fn descendants(&self) -> io::Result<bool> {
        let rc = unsafe { libc::kill(-self.group, 0) };
        if rc == 0 {
            return Ok(true);
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ESRCH) {
            Ok(false)
        } else {
            Err(error)
        }
    }
    pub fn cleanup_auxiliaries(&mut self) -> io::Result<()> { Ok(()) }
    pub fn auxiliary_cleanup(&self) -> &[String] { &[] }
    pub fn containment() -> &'static str {
        "posix_process_group"
    }
    /// Lower a RUNNING operation's CPU priority, after the fact (18/11 round 3, item 5).
    ///
    /// A call that has gone pending is work nobody is waiting for any more, and that is the only fact
    /// that should put it one step below the node. The command is its own process group (spawn sets
    /// process_group(0)), so ONE PRIO_PGRP call covers the shell and everything it started. Best
    /// effort in the sense that matters: a group that has already exited is not an error about the
    /// work, and a node that refuses the call keeps the priority it had - the caller records that.
    pub fn demote(pid: u32) -> io::Result<()> {
        let nice = operation_nice();
        if nice <= 0 {
            return Ok(());
        }
        if unsafe { libc::setpriority(libc::PRIO_PGRP, pid, nice) } < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return Ok(());
            }
            return Err(error);
        }
        // The leader itself, in case it is already a session of its own.
        unsafe {
            libc::setpriority(libc::PRIO_PROCESS, pid, nice);
        }
        Ok(())
    }
    /// The priority name the record carries after a demote (see priority()).
    pub fn demoted_priority() -> String {
        Self::priority(true)
    }
    /// What the operation's own record says about the CPU priority it runs at: the node's own for a
    /// call somebody waits for, one step lower for a backgrounded one.
    pub fn priority(background: bool) -> String {
        match if background { operation_nice() } else { 0 } {
            0 => "default".to_string(),
            nice => format!("nice+{nice}"),
        }
    }
    pub fn read(&mut self, stderr: bool, buffer: &mut [u8]) -> io::Result<Option<usize>> {
        use std::io::Read;
        let result = if stderr {
            match self.stderr.as_mut() {
                Some(p) => p.read(buffer),
                None => return Ok(Some(0)),
            }
        } else {
            match self.stdout.as_mut() {
                Some(p) => p.read(buffer),
                None => return Ok(Some(0)),
            }
        };
        match result {
            Err(e) if e.kind() == io::ErrorKind::WouldBlock => Ok(None),
            Err(e) if e.kind() == io::ErrorKind::Interrupted => Ok(None),
            other => other.map(Some),
        }
    }
}
#[cfg(unix)]
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.terminate();
        // Never block the supervisor on reaping. Normally code() already reaped it.
        let _ = self.child.try_wait();
    }
}
