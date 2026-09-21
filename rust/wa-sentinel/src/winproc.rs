//! Windows process control, without a shell hop.
//!
//! Why this exists: stopping and starting the node through `taskkill` and `powershell
//! Start-Process` costs a process spawn each time (~138ms and ~204ms measured), and on the start
//! path that is the *entire* latency of bringing the node back - the node's own boot to `/health`
//! is ~49ms. Calling the Win32 API directly takes the spawn out of the path.
//!
//! The safety property this must not weaken. `SENTINEL.md` requires that the thing which can
//! restart the agent never acts by image name: another `wa` on the machine may be somebody's
//! session, and "kill every process called wa.exe" is how that session dies. That property does
//! **not** come from `taskkill` - both mechanisms are handed a pid - it comes from the caller,
//! which obtains the pid from the OS (`pid_on_port`) and passes that exact number here.
//! `TerminateProcess` cannot match by name even if somebody wanted it to: it takes a handle.
//!
//! Detachment. The child must outlive this process: the sentinel starts a node and then exits, and a
//! node that died with its starter would be worse than no supervisor at all. On Unix that is
//! `spawn` + null stdio (the child is reparented). On Windows the equivalent is `DETACHED_PROCESS`
//! with `bInheritHandles = FALSE`, which is what `Start-Process -WindowStyle Hidden` was standing in
//! for - a console-less process not tied to this one's lifetime or its window station.

#![cfg(windows)]

use anyhow::{bail, Result};
use std::ffi::{c_void, OsStr};
use std::os::windows::ffi::OsStrExt;
use std::path::{Path, PathBuf};

use windows_sys::Win32::Foundation::{CloseHandle, FALSE, FILETIME, HANDLE};
use windows_sys::Win32::System::Threading::{
    CreateProcessW, GetProcessTimes, QueryFullProcessImageNameW, TerminateProcess,
    WaitForSingleObject, CREATE_NEW_PROCESS_GROUP, CREATE_UNICODE_ENVIRONMENT, DETACHED_PROCESS,
    PROCESS_INFORMATION, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION, STARTUPINFOW,
};

/// A wide, NUL-terminated string for the `W` APIs. Every path here is built by us, and the APIs
/// require the terminator, so it is added in one place rather than at each call.
fn wide(value: &OsStr) -> Vec<u16> {
    value.encode_wide().chain(std::iter::once(0)).collect()
}

/// Kill a pid the caller obtained from the OS. There is deliberately no by-name function in this
/// module, and none should be added: the parameter is a pid or it is nothing.
pub fn kill_pid(pid: u32) -> Result<()> {
    // PROCESS_TERMINATE only. The sentinel has no business reading or writing the memory of the
    // process it is replacing, and asking for less is how that stays true if this is ever copied.
    const PROCESS_TERMINATE: u32 = 0x0001;
    let handle = unsafe { OpenProcess(PROCESS_TERMINATE, FALSE, pid) };
    if handle.is_null() {
        bail!("could not open pid {pid} to stop it (it may already be gone)");
    }
    let ok = unsafe { TerminateProcess(handle, 1) };
    // Waited on before the handle closes, so "killed" means the process is gone rather than merely
    // asked to go. A short bound, because a hung process must not hang the supervisor: the caller
    // verifies the port anyway, and that is the check that decides.
    if ok != 0 {
        unsafe { WaitForSingleObject(handle, 2000) };
    }
    unsafe { CloseHandle(handle) };
    if ok == 0 {
        bail!("TerminateProcess failed for pid {pid}");
    }
    Ok(())
}

/// Start the node detached, so it outlives the sentinel.
///
/// The command line is assembled the way Windows expects: `CreateProcessW` wants a single mutable
/// buffer holding `"program" arg1 arg2`, with the program quoted so a path containing a space is
/// still one token - `C:\Program Files\...` would otherwise become two.
pub fn start_detached(binary: &Path, args: &[String]) -> Result<u32> {
    start_detached_with_env(binary, args, None)
}

/// Start detached, with an explicit environment when one is given.
///
/// `env = None` inherits this process's environment, which is what the default/master path wants
/// (and what every earlier version did). `env = Some(pairs)` replaces the child's environment
/// entirely: that is how a guest node is launched without inheriting the operator's provider keys
/// or any other secret from the supervisor's environment. The pairs become a Windows environment
/// block - `KEY=VALUE` NUL-terminated entries, then one more NUL.
pub fn start_detached_with_env(
    binary: &Path,
    args: &[String],
    env: Option<&[(String, String)]>,
) -> Result<u32> {
    let mut command_line = String::new();
    command_line.push('"');
    command_line.push_str(&binary.display().to_string());
    command_line.push('"');
    for arg in args {
        command_line.push(' ');
        // Quoted only when it needs it; quoting everything would be harmless but harder to read in
        // a process listing, which is where this gets debugged.
        if arg.contains(' ') {
            command_line.push('"');
            command_line.push_str(arg);
            command_line.push('"');
        } else {
            command_line.push_str(arg);
        }
    }
    let mut command_wide: Vec<u16> = wide(OsStr::new(&command_line));
    let application = wide(binary.as_os_str());
    let environment: Option<Vec<u16>> = env.map(|pairs| {
        // Windows requires an environment block to be sorted case-insensitively; an unsorted one
        // can be refused with ERROR_INVALID_PARAMETER, which is exactly how a guest start failed.
        let mut sorted: Vec<&(String, String)> = pairs.iter().collect();
        sorted.sort_by(|a, b| a.0.to_ascii_uppercase().cmp(&b.0.to_ascii_uppercase()));
        let mut block: Vec<u16> = Vec::new();
        for (key, value) in sorted {
            block.extend(OsStr::new(&format!("{key}={value}")).encode_wide());
            block.push(0);
        }
        block.push(0);
        block
    });
    let environment_pointer = environment
        .as_ref()
        .map(|block| block.as_ptr() as *const c_void)
        .unwrap_or(std::ptr::null());

    let mut startup: STARTUPINFOW = unsafe { std::mem::zeroed() };
    startup.cb = std::mem::size_of::<STARTUPINFOW>() as u32;
    let mut info: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };

    // DETACHED_PROCESS: no console, so it does not attach to (or die with) ours. The process group
    // flag keeps a Ctrl-C sent to us from reaching it. CREATE_UNICODE_ENVIRONMENT is required when
    // an explicit environment block is supplied: without it the block is read as ANSI and the call
    // fails with ERROR_INVALID_PARAMETER (the guest start bug this fixed).
    let flags = DETACHED_PROCESS
        | CREATE_NEW_PROCESS_GROUP
        | if environment.is_some() { CREATE_UNICODE_ENVIRONMENT } else { 0 };
    let created = unsafe {
        CreateProcessW(
            application.as_ptr(),
            command_wide.as_mut_ptr(),
            std::ptr::null(),
            std::ptr::null(),
            FALSE, // do not inherit handles: the node must not hold our pipes open
            flags,
            environment_pointer,
            std::ptr::null(),
            &startup,
            &mut info,
        )
    };
    if created == 0 {
        bail!(
            "CreateProcessW failed for {}: {}",
            binary.display(),
            std::io::Error::last_os_error()
        );
    }
    // Both handles are ours to close: the child holds its own copies. Leaking them would keep a
    // handle on every node the sentinel ever started.
    unsafe { CloseHandle(info.hThread) };
    unsafe { CloseHandle(info.hProcess) };
    Ok(info.dwProcessId)
}

/// When the process was created, as a Windows FILETIME. Opaque as a value; only equality against
/// the value recorded at start matters. That equality is what tells a live node from a recycled
/// pid: the OS may reuse a pid, but never the same creation time.
pub fn process_creation_time(pid: u32) -> Option<u64> {
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid) };
    if handle.is_null() {
        return None;
    }
    let mut creation = FILETIME::default();
    let mut exit = FILETIME::default();
    let mut kernel = FILETIME::default();
    let mut user = FILETIME::default();
    let ok = unsafe { GetProcessTimes(handle, &mut creation, &mut exit, &mut kernel, &mut user) };
    unsafe { CloseHandle(handle) };
    if ok == 0 {
        return None;
    }
    Some(((creation.dwHighDateTime as u64) << 32) | creation.dwLowDateTime as u64)
}

/// The executable image a pid is running. This is the process proof a port cannot give: the pid
/// on a port may be a foreign program, and stopping it because it happens to hold the port is the
/// failure this exists to prevent.
pub fn process_image_path(pid: u32) -> Option<PathBuf> {
    let handle = unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid) };
    if handle.is_null() {
        return None;
    }
    let mut buffer = vec![0u16; 32_768];
    let mut size = buffer.len() as u32;
    let ok = unsafe {
        QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, buffer.as_mut_ptr(), &mut size)
    };
    unsafe { CloseHandle(handle) };
    if ok == 0 {
        return None;
    }
    Some(PathBuf::from(String::from_utf16_lossy(&buffer[..size as usize])))
}

// Declared here rather than imported, because the `Win32_System_Threading` feature list in
// Cargo.toml is deliberately narrow: this is the one function from it that the feature does not
// re-export, and widening the feature set for one symbol would pull in far more than is used.
extern "system" {
    fn OpenProcess(access: u32, inherit: i32, pid: u32) -> HANDLE;
}
