//! Native SCM host. Service lifetime is independent of console/node lifetime.
//! Config is privileged installer-owned local state, not a request-selected executable.
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::{collections::BTreeMap, path::{Path, PathBuf}, sync::{atomic::{AtomicBool, AtomicUsize, Ordering}, OnceLock}, time::{Duration, Instant}};
use windows_sys::Win32::System::Services::*;

static STOP: AtomicBool = AtomicBool::new(false);
static ACTIVE: AtomicBool = AtomicBool::new(false);
static SHUTDOWN: AtomicBool = AtomicBool::new(false);
static STATUS: AtomicUsize = AtomicUsize::new(0);
static CONFIG: OnceLock<Config> = OnceLock::new();
static STATUS_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[derive(Clone, Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Config {
    pub schema: u32,
    pub name: String,
    pub home: PathBuf,
    pub install: PathBuf,
    pub cwd: PathBuf,
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
}

pub(crate) fn valid_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= 80 && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}
impl Config {
    pub(crate) fn validate(&self) -> Result<()> {
        if self.schema != 1 || !valid_name(&self.name) {bail!("invalid_windows_service_identity");}
        for path in [&self.home, &self.install, &self.cwd] {
            if !path.is_absolute() || !path.is_dir() {bail!("service_path_not_absolute_directory: {}", path.display());}
        }
        if self.environment.len() > 16 {bail!("service_environment_too_large");}
        for (key, value) in &self.environment {
            if !matches!(key.as_str(), "PATH" | "WA_SENTINEL_SCRIPTS" | "WA_SENTINEL_NODE" | "WA_SENTINEL_WAKE_BUDGET"
                | "WA_SENTINEL_JOB_WAKE_BUDGET" | "WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY" | "WASM_AGENT_PORT"
                | "WASM_AGENT_CLIENT_PORT" | "WA_DEPLOY_ROOT" | "CARGO_BUILD_JOBS" | "WA_GATE_JOBS")
                || value.len() > 4096 || value.contains(['\0', '\r', '\n']) {bail!("service_environment_refused: {key}");}
        }
        Ok(())
    }
}
fn load(name: &str, file: &Path) -> Result<Config> {
    if !file.is_absolute() {bail!("service_config_must_be_absolute");}
    use std::io::Read;
    let mut bytes=Vec::new();
    std::fs::File::open(file).context("open service config")?.take(16385).read_to_end(&mut bytes).context("read service config")?;
    if bytes.len() > 16384 {bail!("service_config_exceeds_16KiB");}
    let config: Config = serde_json::from_slice(&bytes).context("decode service config")?;
    config.validate()?;
    if config.name != name {bail!("service_config_name_mismatch");}
    let expected = std::fs::canonicalize(config.install.join("wa-sentinel.exe"))?;
    if std::fs::canonicalize(std::env::current_exe()?)? != expected {bail!("service_binary_install_mismatch");}
    Ok(config)
}
pub(crate) fn stopping() -> bool {STOP.load(Ordering::Acquire)}
pub(crate) fn active() -> bool {ACTIVE.load(Ordering::Acquire)}
fn wide(text: &str) -> Vec<u16> {text.encode_utf16().chain(Some(0)).collect()}
fn require_limited_identity() -> Result<()> {
    use windows_sys::Win32::{Foundation::CloseHandle, Security::{GetTokenInformation, TokenElevation, TOKEN_ELEVATION, TOKEN_QUERY},
        System::Threading::{GetCurrentProcess, OpenProcessToken}};
    let mut token=std::ptr::null_mut();
    if unsafe {OpenProcessToken(GetCurrentProcess(),TOKEN_QUERY,&mut token)}==0 {
        return Err(std::io::Error::last_os_error()).context("prove service token identity");
    }
    let mut value:TOKEN_ELEVATION=unsafe {std::mem::zeroed()};let mut needed=0;
    let observed=unsafe {GetTokenInformation(token,TokenElevation,&mut value as *mut _ as *mut _,
        std::mem::size_of_val(&value) as u32,&mut needed)};
    let failure=if observed==0 {Some(std::io::Error::last_os_error())}else{None};
    unsafe {CloseHandle(token);}
    if let Some(error)=failure {return Err(error).context("query service token elevation");}
    if needed as usize!=std::mem::size_of_val(&value) || value.TokenIsElevated!=0 {
        bail!("service_requires_non_elevated_account: refusing LocalSystem/elevated administrator runtime");
    }
    Ok(())
}
fn status(state: u32, exit: u32) -> Result<()> {
    let _guard=STATUS_LOCK.lock().map_err(|_|anyhow::anyhow!("service_status_lock_poisoned"))?;
    let state=if state==SERVICE_RUNNING && stopping() {SERVICE_STOP_PENDING}else{state};
    let handle = STATUS.load(Ordering::Acquire) as SERVICE_STATUS_HANDLE;
    if handle.is_null() {bail!("service_status_handle_unavailable");}
    let value = SERVICE_STATUS {
        dwServiceType: SERVICE_WIN32_OWN_PROCESS, dwCurrentState: state,
        dwControlsAccepted: if state == SERVICE_RUNNING {SERVICE_ACCEPT_STOP | SERVICE_ACCEPT_SHUTDOWN} else {0},
        dwWin32ExitCode: if exit == 0 {0} else {1066}, dwServiceSpecificExitCode: exit,
        dwCheckPoint: if state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING {1} else {0},
        dwWaitHint: if state == SERVICE_START_PENDING || state == SERVICE_STOP_PENDING {10000} else {0},
    };
    if unsafe {SetServiceStatus(handle, &value)} == 0 {return Err(std::io::Error::last_os_error()).context("SetServiceStatus");}
    Ok(())
}
unsafe extern "system" fn control(code: u32, _: u32, _: *mut core::ffi::c_void, _: *mut core::ffi::c_void) -> u32 {
    if matches!(code, SERVICE_CONTROL_STOP | SERVICE_CONTROL_SHUTDOWN) {
        SHUTDOWN.store(code == SERVICE_CONTROL_SHUTDOWN, Ordering::Release);
        STOP.store(true, Ordering::Release);
        let _ = status(SERVICE_STOP_PENDING, 0);
        if code==SERVICE_CONTROL_STOP {
            // Persist intent when control is observed, not only at orderly exit:
            // a crash while stopping must not authorize failure recovery intake.
            if let Some(config)=CONFIG.get() {
                if let Err(error)=std::fs::write(config.home.join(".wasm-agent/sentinel/stop"),format!("SCM stop {}\n",super::now_epoch())) {
                    super::audit("service-stop-marker-failed",&config.name,&error.to_string());
                }
            }
        }
        return 0;
    }
    if code == SERVICE_CONTROL_INTERROGATE {return 0;}
    120
}
unsafe extern "system" fn service_main(_: u32, _: *mut *mut u16) {
    let Some(config) = CONFIG.get() else {return;};
    let name = wide(&config.name);
    let handle = RegisterServiceCtrlHandlerExW(name.as_ptr(), Some(control), std::ptr::null_mut());
    if handle.is_null() {
        super::audit("service-handler-failed",&config.name,&std::io::Error::last_os_error().to_string());
        return;
    }
    STATUS.store(handle as usize, Ordering::Release);
    let result = std::panic::catch_unwind(|| -> Result<()> {
        status(SERVICE_START_PENDING, 0)?;
        // Service manager environment is not the interactive operator envelope.
        // Keep OS/account defaults, but never inherit a provider key, run marker,
        // script/Lua override or another instance binding from machine variables.
        for (key,_) in std::env::vars() {
            let upper=key.to_ascii_uppercase();
            if ["WA_","WASM_AGENT_","OPENAI_","OPENCODE_","ANTHROPIC_","PI_"].iter().any(|prefix|upper.starts_with(prefix)) {
                std::env::remove_var(key);
            }
        }
        std::env::set_var("WASM_AGENT_HOME", &config.home);
        std::env::set_var("WA_INSTALL_DIR", &config.install);
        std::env::set_var("WA_SENTINEL_SUPERVISOR", format!("windows:{}", config.name));
        std::env::set_var("WA_INSTANCE_BASE_HOME", &config.home);
        std::env::set_var("WA_INSTANCE_OPERATOR_INSTALL", &config.install);
        for (key, value) in &config.environment {std::env::set_var(key, value);}
        std::env::set_current_dir(&config.cwd)?;
        ACTIVE.store(true, Ordering::Release);
        require_limited_identity()?;
        // Readiness must not hide missing diagnostic write permissions.
        for name in ["sentinel.log","service.log"] {
            std::fs::OpenOptions::new().create(true).append(true).open(super::sentinel_dir().join(name))
                .with_context(||format!("service diagnostic path not writable: {name}"))?;
        }
        if super::stop_path().exists() {
            super::audit("service-stopped", &config.name, "intentional stop marker preserved; no queue consumed");
            return Ok(());
        }
        super::audit("service-start", &config.name, "SCM entry; no console or node-owned parent");
        super::watch()
    });
    let mut exit = match result {
        Ok(Ok(())) => 0,
        Ok(Err(error)) => {super::audit("service-failed", &config.name, &format!("{error:#}"));1},
        Err(_) => {super::audit("service-failed", &config.name, "watcher panicked; effects remain unresolved");2},
    };
    if stopping() && !SHUTDOWN.load(Ordering::Acquire) {
        // Manual SCM stop persists intent across boot/recovery. Shutdown does not.
        // Explicit CLI start/restart removes it only after exact SCM identity proof.
        if let Err(error)=std::fs::write(super::stop_path(),format!("SCM stop {}\n",super::now_epoch())) {
            super::audit("service-stop-marker-failed",&config.name,&error.to_string());
            exit=3; // Do not certify a durable intentional stop that was not written.
        }
    }
    super::audit("service-exit", &config.name, &format!("code={exit}, stop_control={}, shutdown={}", stopping(), SHUTDOWN.load(Ordering::Acquire)));
    if let Err(error)=status(SERVICE_STOPPED, exit) {
        super::audit("service-status-failed",&config.name,&error.to_string());
    }
    // Other request threads must not outlive the service. Unknown operations remain
    // unknown; this is lifecycle exit, never permission to replay them after recovery.
    std::process::exit(if exit == 0 {0} else {1});
}
pub(crate) fn ready() -> Result<()> {if active() && !stopping() {status(SERVICE_RUNNING, 0)?;} Ok(())}
pub(crate) fn log(message: &str) {
    if !active() {return;}
    use std::io::Write;
    let path = super::sentinel_dir().join("service.log");
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
        let _ = writeln!(file, "{}\t{message}", super::now_epoch());
    }
}
pub(crate) fn check(args: &[String]) -> Result<()> {
    if args.len()!=4 || args[0]!="--name" || args[2]!="--config" {bail!("service-config-check requires --name NAME --config ABSOLUTE_JSON");}
    let config=load(&args[1],Path::new(&args[3]))?;
    println!("{}",serde_json::json!({"ok":true,"schema":1,"service":config.name,"configuration_valid":true,
        "scm_started":false,"effects":"none"}));
    Ok(())
}
pub(crate) fn run(args: &[String]) -> Result<()> {
    if args.len() != 4 || args[0] != "--name" || args[2] != "--config" {bail!("service requires --name NAME --config ABSOLUTE_JSON");}
    let config = load(&args[1], Path::new(&args[3]))?;
    CONFIG.set(config).map_err(|_| anyhow::anyhow!("service_dispatch_already_initialized"))?;
    // Validation is read-only, but dispatcher failures must still leave a durable
    // reason at this selected service's state root (SCM also records its exit).
    std::env::set_var("WASM_AGENT_HOME", &CONFIG.get().unwrap().home);
    let mut name = wide(&args[1]);
    let table = [SERVICE_TABLE_ENTRYW {lpServiceName: name.as_mut_ptr(), lpServiceProc: Some(service_main)},
        SERVICE_TABLE_ENTRYW {lpServiceName: std::ptr::null_mut(), lpServiceProc: None}];
    if unsafe {StartServiceCtrlDispatcherW(table.as_ptr())} == 0 {
        let error=std::io::Error::last_os_error();
        super::audit("service-dispatch-failed",&args[1],&error.to_string());
        return Err(error).context("SCM dispatcher; service mode must be started by Windows, never as a console fallback");
    }
    Ok(())
}

// CLI lifecycle uses SCM directly and verifies exact binary/name configuration;
// never fall back to a detached watcher after access-denied or unknown identity.
struct Handle(SC_HANDLE);
impl Drop for Handle {fn drop(&mut self) {unsafe {CloseServiceHandle(self.0);}}}
pub(crate) fn lifecycle(name: &str, verb: &str) -> Result<()> {
    if !valid_name(name) || !matches!(verb, "start" | "stop" | "restart") {bail!("invalid_service_lifecycle");}
    let manager = Handle(unsafe {OpenSCManagerW(std::ptr::null(), std::ptr::null(), SC_MANAGER_CONNECT)});
    if manager.0.is_null() {return Err(std::io::Error::last_os_error()).context("open SCM");}
    let name_w = wide(name);
    let service = Handle(unsafe {OpenServiceW(manager.0, name_w.as_ptr(), SERVICE_QUERY_CONFIG | SERVICE_QUERY_STATUS | SERVICE_START | SERVICE_STOP)});
    if service.0.is_null() {return Err(std::io::Error::last_os_error()).context("open exact sentinel service; no fallback");}
    let mut needed = 0;
    unsafe {QueryServiceConfigW(service.0, std::ptr::null_mut(), 0, &mut needed);}
    if needed == 0 || needed > 65536 {bail!("service_config_size_invalid");}
    let mut storage = vec![0usize; (needed as usize + std::mem::size_of::<usize>() - 1) / std::mem::size_of::<usize>()];
    let config = storage.as_mut_ptr() as *mut QUERY_SERVICE_CONFIGW;
    if unsafe {QueryServiceConfigW(service.0, config, needed, &mut needed)} == 0 {return Err(std::io::Error::last_os_error()).context("query sentinel service identity");}
    let command = unsafe {read_wide((*config).lpBinaryPathName,storage.as_ptr() as usize,storage.len()*std::mem::size_of::<usize>())}?;
    let (exe,file)=parse_service_command(&command,name)?;
    if std::fs::canonicalize(exe)? != std::fs::canonicalize(std::env::current_exe()?)? {
        bail!("SCM_service_binary_or_name_mismatch");
    }
    let bound=load(name, Path::new(file))?;
    if std::fs::canonicalize(&bound.home)? != std::fs::canonicalize(super::home())? {
        bail!("SCM_service_home_mismatch: refusing cross-instance lifecycle");
    }
    if verb == "stop" || verb == "restart" {
        let mut value: SERVICE_STATUS = unsafe {std::mem::zeroed()};
        if unsafe {ControlService(service.0, SERVICE_CONTROL_STOP, &mut value)} == 0 {
            let e = std::io::Error::last_os_error();
            if e.raw_os_error() != Some(1062) {return Err(e).context("SCM stop sentinel");}
        }
        wait_state(service.0, SERVICE_STOPPED)?;
        // Even an already-stopped service must preserve a fresh explicit stop.
        std::fs::write(super::stop_path(),format!("SCM stop {}\n",super::now_epoch()))
            .context("persist intentional SCM stop")?;
    }
    if verb == "start" || verb == "restart" {
        if super::stop_path().exists() {std::fs::remove_file(super::stop_path())?;}
        if unsafe {StartServiceW(service.0, 0, std::ptr::null())} == 0 {
            let e = std::io::Error::last_os_error();
            if e.raw_os_error() != Some(1056) {return Err(e).context("SCM start sentinel");}
        }
        wait_state(service.0, SERVICE_RUNNING)?;
    }
    Ok(())
}
fn parse_service_command<'a>(command:&'a str,name:&str)->Result<(&'a str,&'a str)> {
    let text=command.strip_prefix('"').context("SCM service executable must be quoted")?;
    let (exe,rest)=text.split_once('"').context("SCM service executable quote missing")?;
    let prefix=format!(" service --name {name} --config \"");
    let file=rest.strip_prefix(&prefix).and_then(|v|v.strip_suffix('"'))
        .context("SCM_service_binary_or_name_mismatch")?;
    if exe.is_empty() || file.is_empty() || file.contains('"') || command.contains(['\r','\n','\0']) {
        bail!("SCM_service_command_invalid");
    }
    Ok((exe,file))
}
unsafe fn read_wide(pointer: *const u16,base:usize,bytes:usize) -> Result<String> {
    let address=pointer as usize;
    let end=base.checked_add(bytes).context("service config range overflow")?;
    if pointer.is_null() || address<base || address>=end || address%2!=0 {bail!("service_command_outside_config");}
    for len in 0..((end-address)/2).min(32768) {
        if *pointer.add(len) == 0 {return String::from_utf16(std::slice::from_raw_parts(pointer, len)).context("service command UTF16");}
    }
    bail!("service_command_exceeds_bound")
}
fn wait_state(service: SC_HANDLE, expected: u32) -> Result<()> {
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let mut value: SERVICE_STATUS_PROCESS = unsafe {std::mem::zeroed()};let mut needed = 0;
        if unsafe {QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO, &mut value as *mut _ as *mut u8,
            std::mem::size_of_val(&value) as u32, &mut needed)} == 0 {return Err(std::io::Error::last_os_error()).context("SCM status");}
        if value.dwCurrentState == expected {return Ok(());}
        if Instant::now() >= until {bail!("service_state_wait_timeout: actual={} expected={expected}", value.dwCurrentState);}
        std::thread::sleep(Duration::from_millis(100));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wide_command_read_never_leaves_its_scm_buffer() {
        let text=wide("fixture command");
        let base=text.as_ptr() as usize;let bytes=text.len()*2;
        assert_eq!(unsafe {read_wide(text.as_ptr(),base,bytes)}.unwrap(),"fixture command");
        assert!(unsafe {read_wide(text.as_ptr(),base+2,bytes-2)}.is_err());
        assert!(unsafe {read_wide(text.as_ptr(),base,2)}.is_err());
        assert!(unsafe {read_wide(std::ptr::null(),base,bytes)}.is_err());
    }
    #[test]
    fn service_command_requires_exact_scoped_native_invocation() {
        let command=r#""C:\Program Files\wa\wa-sentinel.exe" service --name fixture --config "C:\state\service.json""#;
        let (exe,file)=parse_service_command(command,"fixture").unwrap();
        assert_eq!(exe,r"C:\Program Files\wa\wa-sentinel.exe");
        assert_eq!(file,r"C:\state\service.json");
        for value in [r#"C:\wa.exe service --name fixture --config "C:\state.json""#,
            r#""C:\wa.exe" watch"#,r#""C:\wa.exe" service --name other --config "C:\state.json""#,
            r#""C:\wa.exe" service --name fixture --config "C:\state.json" --extra"#] {
            assert!(parse_service_command(value,"fixture").is_err());
        }
    }
    #[test]
    fn service_identity_and_environment_are_bounded() {
        assert!(valid_name("wasm-agent-sentinel"));
        for name in ["", "../other", "sentinel service", "x\nstop"] {assert!(!valid_name(name));}
        let root = std::env::temp_dir();
        let mut config = Config {schema:1,name:"fixture".into(),home:root.clone(),install:root.clone(),cwd:root,environment:BTreeMap::new()};
        assert!(config.validate().is_ok());
        config.environment.insert("OPENAI_API_KEY".into(), "secret".into());assert!(config.validate().is_err());
        config.environment.clear();config.environment.insert("PATH".into(),"C:\\tools\nother".into());assert!(config.validate().is_err());
        config.environment.clear();config.environment.insert("WASM_AGENT_LUA_ROOT".into(),"C:\\source".into());assert!(config.validate().is_err());
        config.environment.clear();config.environment.insert("WA_SENTINEL_NODE".into(),"C:\\node.exe".into());assert!(config.validate().is_ok());
        config.home=PathBuf::from("relative");assert!(config.validate().is_err());
    }
}
