use super::*;
use std::{
    ffi::OsStr,
    os::windows::ffi::OsStrExt,
    ptr::{null, null_mut},
};
use windows_sys::Win32::{
    Foundation::*,
    Security::SECURITY_ATTRIBUTES,
    Storage::FileSystem::*,
    System::{JobObjects::*, Pipes::*, Threading::*},
};

struct Handle(HANDLE);
unsafe impl Send for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() && self.0 != INVALID_HANDLE_VALUE {
            unsafe {
                CloseHandle(self.0);
            }
        }
    }
}
fn wide(s: &str) -> Vec<u16> {
    OsStr::new(s).encode_wide().chain(Some(0)).collect()
}
fn check(ok: i32) -> io::Result<()> {
    if ok == 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(())
    }
}
fn quote(arg: &str) -> String {
    let mut out = String::from("\"");
    let mut slashes = 0;
    for c in arg.chars() {
        if c == '\\' {
            slashes += 1;
            continue;
        }
        if c == '"' {
            out.push_str(&"\\".repeat(slashes * 2 + 1));
            out.push(c)
        } else {
            out.push_str(&"\\".repeat(slashes));
            out.push(c)
        }
        slashes = 0;
    }
    out.push_str(&"\\".repeat(slashes * 2));
    out.push('"');
    out
}
fn pipe() -> io::Result<(Handle, Handle)> {
    let mut r = null_mut();
    let mut w = null_mut();
    let sa = SECURITY_ATTRIBUTES {
        nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: null_mut(),
        bInheritHandle: 1,
    };
    check(unsafe { CreatePipe(&mut r, &mut w, &sa, 0) })?;
    let pair = (Handle(r), Handle(w));
    check(unsafe { SetHandleInformation(pair.0 .0, HANDLE_FLAG_INHERIT, 0) })?;
    Ok(pair)
}
pub struct Process {
    process: Handle,
    job: Handle,
    stdout: Handle,
    stderr: Handle,
    auxiliary_cleanup: Vec<String>,
}
impl Process {
    pub fn spawn(spec: &Spec) -> io::Result<Self> {
        if spec.program.contains('\0')
            || spec.args.iter().any(|a| a.contains('\0'))
            || spec.cwd.contains('\0')
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "NUL in process argument",
            ));
        }
        let job = Handle(unsafe { CreateJobObjectW(null(), null()) });
        if job.0.is_null() {
            return Err(io::Error::last_os_error());
        }
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = unsafe { std::mem::zeroed() };
        limits.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
        limits.BasicLimitInformation.ActiveProcessLimit = 64;
        check(unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as _,
                std::mem::size_of_val(&limits) as u32,
            )
        })?;
        let (out_read, out_write) = pipe()?;
        let (err_read, err_write) = pipe()?;
        let sa = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: null_mut(),
            bInheritHandle: 1,
        };
        let input = Handle(unsafe {
            CreateFileW(
                wide("NUL").as_ptr(),
                GENERIC_READ,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                &sa,
                OPEN_EXISTING,
                0,
                null_mut(),
            )
        });
        if input.0 == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // Restrict inheritance to this operation's stdio. Parallel launches must not retain each other's pipes.
        let mut size = 0;
        unsafe {
            InitializeProcThreadAttributeList(null_mut(), 1, 0, &mut size);
        }
        let mut storage =
            vec![0usize; (size + std::mem::size_of::<usize>() - 1) / std::mem::size_of::<usize>()];
        let attrs = storage.as_mut_ptr() as LPPROC_THREAD_ATTRIBUTE_LIST;
        check(unsafe { InitializeProcThreadAttributeList(attrs, 1, 0, &mut size) })?;
        struct Attrs(LPPROC_THREAD_ATTRIBUTE_LIST);
        impl Drop for Attrs {
            fn drop(&mut self) {
                unsafe { DeleteProcThreadAttributeList(self.0) }
            }
        }
        let _attrs = Attrs(attrs);
        let handles = [input.0, out_write.0, err_write.0];
        check(unsafe {
            UpdateProcThreadAttribute(
                attrs,
                0,
                PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
                handles.as_ptr() as _,
                std::mem::size_of_val(&handles),
                null_mut(),
                null(),
            )
        })?;
        let mut startup: STARTUPINFOEXW = unsafe { std::mem::zeroed() };
        startup.StartupInfo.cb = std::mem::size_of::<STARTUPINFOEXW>() as u32;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
        startup.StartupInfo.hStdInput = input.0;
        startup.StartupInfo.hStdOutput = out_write.0;
        startup.StartupInfo.hStdError = err_write.0;
        startup.lpAttributeList = attrs;
        let program = spec.program.replace('/', "\\");
        let application = wide(&program);
        let executable = program.rsplit('\\').next().unwrap_or("");
        let line = if (executable.eq_ignore_ascii_case("cmd.exe")
            || executable.eq_ignore_ascii_case("cmd"))
            && spec.args.len() == 2
            && spec.args[0].eq_ignore_ascii_case("/C")
        {
            // cmd parses shell syntax, not C argv backslash-escaped quotes.
            format!("{} /D /S /C \"{}\"", quote(&program), spec.args[1])
        } else {
            std::iter::once(program.as_str())
                .chain(spec.args.iter().map(String::as_str))
                .map(quote)
                .collect::<Vec<_>>()
                .join(" ")
        };
        let mut command = wide(&line);
        let cwd = wide(&spec.cwd);
        let mut env: std::collections::BTreeMap<String, (String, String)> = std::env::vars()
            .map(|(k, v)| (k.to_uppercase(), (k, v)))
            .collect();
        for (k, v) in &spec.env {
            env.insert(k.to_uppercase(), (k.clone(), v.clone()));
        }
        let mut env_wide: Vec<u16> = env
            .values()
            .flat_map(|(k, v)| wide(&format!("{k}={v}")))
            .collect();
        env_wide.push(0);
        let mut info: PROCESS_INFORMATION = unsafe { std::mem::zeroed() };
        check(unsafe {
            CreateProcessW(
                application.as_ptr(),
                command.as_mut_ptr(),
                null(),
                null(),
                1,
                CREATE_SUSPENDED
                    | CREATE_NO_WINDOW
                    | CREATE_UNICODE_ENVIRONMENT
                    | EXTENDED_STARTUPINFO_PRESENT,
                env_wide.as_ptr() as _,
                if spec.cwd.is_empty() {
                    null()
                } else {
                    cwd.as_ptr()
                },
                &startup.StartupInfo,
                &mut info,
            )
        })?;
        let process = Handle(info.hProcess);
        let thread = Handle(info.hThread);
        // The child cannot spawn anything before containment is installed. Failure never resumes it.
        if let Err(e) = check(unsafe { AssignProcessToJobObject(job.0, process.0) }) {
            unsafe {
                TerminateProcess(process.0, 1);
            }
            return Err(e);
        }
        let result = Self {
            process,
            job,
            stdout: out_read,
            stderr: err_read,
            auxiliary_cleanup: Vec::new(),
        };
        if unsafe { ResumeThread(thread.0) } == u32::MAX {
            return Err(io::Error::last_os_error());
        }
        Ok(result)
    }
    pub fn code(&mut self) -> io::Result<Option<i32>> {
        match unsafe { WaitForSingleObject(self.process.0, 0) } {
            WAIT_TIMEOUT => Ok(None),
            WAIT_OBJECT_0 => {
                let mut code = 0;
                check(unsafe { GetExitCodeProcess(self.process.0, &mut code) })?;
                Ok(Some(code as i32))
            }
            _ => Err(io::Error::last_os_error()),
        }
    }
    pub fn terminate(&mut self) -> io::Result<()> {
        check(unsafe { TerminateJobObject(self.job.0, 1) })
    }
    pub fn descendants(&self) -> io::Result<bool> {
        match self.live_descendants() {
            Ok(live) => Ok(!live.is_empty()),
            // Windows can deny opening/querying a process while it is exiting.
            // Keep supervising until the job snapshot removes it; do not invent
            // either successful cleanup or an execution failure from that race.
            Err(error) if process_query_exiting(&error) => Ok(true),
            Err(error) => Err(error),
        }
    }
    fn live_descendants(&self) -> io::Result<Vec<Handle>> {
        // Accounting can briefly include an already-signalled root; do not misreport that as an orphan.
        let mut storage = [0usize; 66];
        check(unsafe {
            QueryInformationJobObject(
                self.job.0,
                JobObjectBasicProcessIdList,
                storage.as_mut_ptr() as _,
                std::mem::size_of_val(&storage) as u32,
                null_mut(),
            )
        })?;
        let list = unsafe { &*(storage.as_ptr() as *const JOBOBJECT_BASIC_PROCESS_ID_LIST) };
        let ids = unsafe {
            std::slice::from_raw_parts(
                list.ProcessIdList.as_ptr(),
                list.NumberOfProcessIdsInList as usize,
            )
        };
        let root = unsafe { GetProcessId(self.process.0) };
        let mut live = Vec::new();
        for &id in ids {
            if id as u32 == root {
                continue;
            }
            let handle = Handle(unsafe {
                OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, 0, id as u32)
            });
            if handle.0.is_null() {
                let error = io::Error::last_os_error();
                if error.raw_os_error() == Some(ERROR_INVALID_PARAMETER as i32) { continue; }
                return Err(error);
            }
            // A PID from the job snapshot may have been recycled before OpenProcess.
            // Check membership on the opened handle, never terminate a process by name.
            let mut owned = 0;
            if unsafe { WaitForSingleObject(handle.0, 0) } != WAIT_TIMEOUT { continue; }
            check(unsafe { IsProcessInJob(handle.0, self.job.0, &mut owned) })?;
            if owned != 0 {
                live.push(handle);
            }
        }
        Ok(live)
    }
    pub fn cleanup_auxiliaries(&mut self) -> io::Result<()> {
        let live = match self.live_descendants() {
            Ok(live) => live,
            Err(error) if process_query_exiting(&error) => return Ok(()),
            Err(error) => return Err(error),
        };
        if live.is_empty() { return Ok(()); }
        let mut images = Vec::new();
        let mut compiler_helper = false;
        for handle in &live {
            let mut image = vec![0u16; 32768];
            let mut size = image.len() as u32;
            if let Err(error) = check(unsafe {
                QueryFullProcessImageNameW(handle.0, 0, image.as_mut_ptr(), &mut size)
            }) {
                if process_query_exiting(&error) || unsafe { WaitForSingleObject(handle.0, 0) }==WAIT_OBJECT_0 {
                    return Ok(());
                }
                return Err(error);
            }
            let image = String::from_utf16_lossy(&image[..size as usize]);
            let helper = compiler_auxiliary(&image);
            if !helper && !console_host(&image) { return Ok(()); }
            compiler_helper |= helper;
            images.push(image);
        }
        if !compiler_helper { return Ok(()); }
        // Risk: explicitly reap MSVC's resident telemetry uploader, but only after
        // the launcher exited AND every remaining owned process is that helper
        // or its system console host. A console host alone is never sufficient.
        // An active shell/compiler/background task prevents this cleanup entirely.
        // Terminate the verified job, not reopened numeric PIDs (which can recycle).
        check(unsafe { TerminateJobObject(self.job.0, 0) })?;
        self.auxiliary_cleanup.extend(images);
        Ok(())
    }
    pub fn auxiliary_cleanup(&self) -> &[String] {
        &self.auxiliary_cleanup
    }
    pub fn containment() -> &'static str {
        "windows_job_object"
    }
    pub fn read(&mut self, stderr: bool, buffer: &mut [u8]) -> io::Result<Option<usize>> {
        let pipe = if stderr { self.stderr.0 } else { self.stdout.0 };
        let mut available = 0;
        if unsafe { PeekNamedPipe(pipe, null_mut(), 0, null_mut(), &mut available, null_mut()) }
            == 0
        {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(ERROR_BROKEN_PIPE as i32) {
                return Ok(Some(0));
            }
            return Err(error);
        }
        if available == 0 {
            return Ok(None);
        }
        let mut read = 0;
        check(unsafe {
            ReadFile(
                pipe,
                buffer.as_mut_ptr(),
                available.min(buffer.len() as u32),
                &mut read,
                null_mut(),
            )
        })?;
        Ok(Some(read as usize))
    }
}
fn compiler_auxiliary(image: &str) -> bool {
    let image = image.replace('\\', "/").to_ascii_lowercase();
    image.contains("/microsoft visual studio/")
        && image.contains("/vc/tools/msvc/")
        && image.ends_with("/vctip.exe")
}
fn process_query_exiting(error: &io::Error) -> bool {
    // Querying a process as Windows tears it down can return ACCESS_DENIED or
    // GEN_FAILURE before its handle signals. Retry via the next job snapshot.
    matches!(error.raw_os_error(), Some(code) if code==ERROR_ACCESS_DENIED as i32 || code==ERROR_GEN_FAILURE as i32)
}
fn console_host(image: &str) -> bool {
    let Some(system) = std::env::var_os("SystemRoot") else { return false; };
    std::path::PathBuf::from(system).join("System32/conhost.exe")
        .to_string_lossy().replace('\\', "/").eq_ignore_ascii_case(&image.replace('\\', "/"))
}
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.terminate();
    }
}
