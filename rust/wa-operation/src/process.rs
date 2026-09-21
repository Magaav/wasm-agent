//! Nonblocking output and process containment. No reader threads, read_to_end, or unbounded wait.
use crate::Spec;
use std::io;
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
    pub fn containment() -> &'static str {
        "posix_process_group"
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
