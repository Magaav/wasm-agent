//! The swap protocol: verify a pin, stage the bytes, prove them on a spare port, ask the supervisor to
//! switch, and read the verdict.
//!
//! The order is the whole design (docs/KERNEL.md, "Transactional installs"):
//!
//! 1. **verify** - the bytes on disk must hash to the pin the caller named. Nothing else happens first.
//! 2. **stage** - copy into `<home>/bin/<sha12>/<name>` and verify the copy. The old binary is never
//!    overwritten, so a rollback is a path change, not a rebuild.
//! 3. **prove** - start the staged bytes on a spare port with a scratch home and wait for `/health`. The
//!    running kernel is untouched for the whole of this: `scripts/upgrade.sh` does the same thing with
//!    curl, and the reason is the same - a binary that cannot start must be found out while nothing has
//!    changed.
//! 4. **ask** - write a request file. The supervisor owns the switch (it is the only process that holds
//!    the kernel's pid), answers it, and writes a result file.
//! 5. **rollback** - if the switched-in kernel does not answer within the window, the supervisor puts the
//!    previous binary back and proves *that* before it reports. Both halves of the promise in KERNEL.md.

use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use crate::config::{Config, LaunchView};
use crate::hash;
use crate::health;
use crate::json;
use crate::paths::{Home, SwapRequest};
use crate::proc;

/// A pin is a lowercase hex SHA-256. Case, length and alphabet are checked here so that every later
/// comparison is a comparison of two canonical strings.
pub fn parse_pin(text: &str) -> Result<String, String> {
    let pin = text.trim().to_ascii_lowercase();
    if pin.len() != 64 || !pin.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return Err(format!("a sha256 pin is 64 hex characters, got {} characters", pin.len()));
    }
    Ok(pin)
}

/// `Ok(())` when the file hashes to the pin; otherwise the actual digest, so the refusal can name both.
pub fn verify_pin(path: &Path, pin: &str) -> Result<(), String> {
    if !path.is_file() {
        return Err(format!("{} is not a file", path.display()));
    }
    let actual = hash::sha256_file(path).map_err(|error| format!("cannot hash {}: {error}", path.display()))?;
    if actual == pin {
        Ok(())
    } else {
        Err(format!("sha256_mismatch: pin {pin}, bytes {actual}"))
    }
}

/// Copy the verified bytes into the staging area and verify the copy. Two verifications, because the copy is
/// what will run: a full disk, a partial copy or a truncated read must fail *here*, not at the switch.
pub fn stage(config: &Config, home: &Home, binary: &Path, pin: &str) -> Result<PathBuf, String> {
    let name = binary
        .file_name()
        .ok_or_else(|| format!("{} has no file name", binary.display()))?
        .to_string_lossy()
        .to_string();
    let directory = home.bin_dir().join(&pin[..12]);
    std::fs::create_dir_all(&directory).map_err(|error| format!("cannot create {}: {error}", directory.display()))?;
    let target = directory.join(&name);
    if target.is_file() && hash::sha256_file(&target).map(|actual| actual == pin).unwrap_or(false) {
        // The exact bytes are already staged (a retried swap, or a rollback target). Copying again would only
        // move the mtime, which nothing should read as a new kernel.
        return Ok(target);
    }
    let temporary = directory.join(format!("{name}.staging{}", std::process::id()));
    std::fs::copy(binary, &temporary).map_err(|error| format!("cannot copy to {}: {error}", temporary.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&temporary, std::fs::Permissions::from_mode(0o755));
    }
    verify_pin(&temporary, pin)?;
    if let Err(error) = std::fs::rename(&temporary, &target) {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("cannot move the staged copy into {}: {error}", target.display()));
    }
    let _ = config;
    Ok(target)
}

/// The verdict of proving bytes on a spare port.
pub struct Proof {
    pub ok: bool,
    pub port: u16,
    /// One line: "answered /health on :9101" or why it did not. No body text.
    pub detail: String,
    pub log: PathBuf,
}

/// Start `binary` on a spare port with a scratch home and wait for `/health`. The instance is always killed
/// before returning, whatever the verdict.
pub fn prove(config: &Config, home: &Home, binary: &Path, id: &str) -> Proof {
    let port = if config.spare_port != 0 {
        config.spare_port
    } else {
        match proc::free_port() {
            Ok(port) => port,
            Err(error) => {
                return Proof {
                    ok: false,
                    port: 0,
                    detail: format!("no spare port could be found: {error}"),
                    log: PathBuf::new(),
                }
            }
        }
    };
    let scratch = home.work_dir().join(format!("proof-{id}"));
    let _ = std::fs::remove_dir_all(&scratch);
    if let Err(error) = std::fs::create_dir_all(&scratch) {
        return Proof {
            ok: false,
            port,
            detail: format!("cannot create the proof home {}: {error}", scratch.display()),
            log: PathBuf::new(),
        };
    }
    let log = home.log_path(&format!("proof-{id}"));
    let view = LaunchView::proof(&scratch, port);
    let args = match config.resolve_args(&view) {
        Ok(args) => args,
        Err(error) => return Proof { ok: false, port, detail: error, log },
    };
    let mut env = proc::proof_env(&scratch);
    env.extend(config.env.iter().cloned());
    // `WASM_AGENT_HOME` must win over the config's own `env`: the proof instance may not read the live home.
    env.retain(|(name, _)| name != "WASM_AGENT_HOME");
    env.push(("WASM_AGENT_HOME".to_string(), scratch.display().to_string()));
    let mut child = match proc::spawn(&proc::Spawn {
        binary,
        args: &args,
        log: &log,
        env: &env,
        env_remove: &proc::PROOF_ENV_REMOVE,
        work_dir: config.work_dir.as_deref(),
    }) {
        Ok(child) => child,
        Err(error) => {
            return Proof { ok: false, port, detail: format!("cannot start the candidate: {error}"), log };
        }
    };
    let deadline = Instant::now() + Duration::from_millis(config.start_timeout_ms);
    let interval = Duration::from_millis(config.tick_ms.clamp(20, 200));
    let mut last = health::Probe::default();
    let mut exited = None;
    let mut ok = false;
    loop {
        if let Ok(Some(status)) = child.try_wait() {
            exited = Some(status);
            break;
        }
        last = health::probe(port, Duration::from_millis(2_000));
        if last.ready() {
            ok = true;
            break;
        }
        if Instant::now() >= deadline {
            break;
        }
        std::thread::sleep(interval);
    }
    proc::kill_and_wait(&mut child);
    let detail = match (&exited, ok) {
        (_, true) => format!("answered /health on :{port}"),
        (Some(status), false) => format!(
            "exited ({status}) before answering /health on :{port}; the last probe said: {}",
            last.why_not()
        ),
        (None, false) => format!("did not answer /health on :{port} within {}ms ({})", config.start_timeout_ms, last.why_not()),
    };
    let _ = std::fs::remove_dir_all(&scratch);
    Proof { ok, port, detail, log }
}

/// The verdict a supervisor leaves for the caller.
#[derive(Debug, Clone, PartialEq)]
pub struct SwapResult {
    pub id: String,
    pub ok: bool,
    pub rolled_back: bool,
    pub previous: PathBuf,
    pub active: PathBuf,
    pub detail: String,
    pub at_ms: u64,
}

impl SwapResult {
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

    pub fn from_json(text: &str) -> Option<SwapResult> {
        Some(SwapResult {
            id: json::field_str(text, "id")?,
            ok: json::field_bool(text, "ok")?,
            rolled_back: json::field_bool(text, "rolled_back").unwrap_or(false),
            previous: PathBuf::from(json::field_str(text, "previous")?),
            active: PathBuf::from(json::field_str(text, "active")?),
            detail: json::field_str(text, "detail").unwrap_or_default(),
            at_ms: json::field_u64(text, "at_ms").unwrap_or(0),
        })
    }
}

pub fn write_result(home: &Home, result: &SwapResult) -> std::io::Result<()> {
    home.write_atomic(&home.results_dir().join(format!("{}.json", result.id)), &(result.to_json() + "\n"))
}

/// Wait for the supervisor's verdict on `id`. `None` means it has not answered yet: the request is still on
/// disk and will be answered on a later pass, so "pending" is not "lost".
pub fn wait_result(home: &Home, id: &str, timeout: Duration) -> Option<SwapResult> {
    let path = home.results_dir().join(format!("{id}.json"));
    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(text) = std::fs::read_to_string(&path) {
            if let Some(result) = SwapResult::from_json(&text) {
                return Some(result);
            }
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Write a request and make it durable before the caller is told it exists.
pub fn write_request(home: &Home, request: &SwapRequest) -> std::io::Result<PathBuf> {
    let path = home.requests_dir().join(format!("{}.json", request.id));
    home.write_atomic(&path, &(request.to_json() + "\n"))?;
    Ok(path)
}

/// The requests the supervisor has not claimed or answered, oldest first.
pub fn pending_requests(home: &Home) -> Vec<(PathBuf, SwapRequest)> {
    let mut found = Vec::new();
    let entries = match std::fs::read_dir(home.requests_dir()) {
        Ok(entries) => entries,
        Err(_) => return found,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = path.file_name().map(|name| name.to_string_lossy().to_string()).unwrap_or_default();
        if !name.ends_with(".json") {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        if let Some(request) = SwapRequest::from_json(&text) {
            found.push((path, request));
        }
    }
    found.sort_by(|a, b| a.1.id.cmp(&b.1.id));
    found
}

/// Claim a request by renaming it, so that two supervisors (or a restart of one) can never answer it twice.
pub fn claim(path: &Path) -> Option<PathBuf> {
    let claimed = path.with_extension("claimed");
    std::fs::rename(path, &claimed).ok().map(|_| claimed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> Home {
        let root = std::env::temp_dir().join(format!("wa-watchdog-swap-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let home = Home::resolve(Some(root)).expect("home");
        home.ensure().expect("dirs");
        home
    }

    #[test]
    fn a_pin_must_be_a_sha256() {
        assert!(parse_pin(&"ab".repeat(32)).is_ok());
        assert!(parse_pin(&"AB".repeat(32)).is_ok(), "upper case is normalised, not refused");
        assert!(parse_pin("abc").is_err());
        assert!(parse_pin(&"zz".repeat(32)).is_err());
        assert!(parse_pin(&"ab".repeat(32)).unwrap().chars().all(|ch| ch.is_ascii_lowercase() || ch.is_ascii_digit()));
    }

    #[test]
    fn verify_names_both_digests_when_the_pin_is_wrong() {
        let home = scratch("pin");
        let file = home.root().join("candidate");
        std::fs::write(&file, b"not a kernel").expect("write candidate");
        let pin = hash::sha256_file(&file).expect("hash");
        assert!(verify_pin(&file, &pin).is_ok());
        let error = verify_pin(&file, &"00".repeat(32)).unwrap_err();
        assert!(error.contains("sha256_mismatch"), "{error}");
        assert!(error.contains(&pin), "the refusal names the real digest: {error}");
        assert!(verify_pin(&home.root().join("absent"), &pin).is_err());
        let _ = std::fs::remove_dir_all(home.root());
    }

    #[test]
    fn staging_never_touches_the_source_and_is_idempotent() {
        let home = scratch("stage");
        let config = Config::default();
        let source = home.root().join("build").join("wa");
        std::fs::create_dir_all(source.parent().expect("parent")).expect("build dir");
        std::fs::write(&source, b"kernel bytes").expect("write source");
        let pin = hash::sha256_file(&source).expect("hash");
        let staged = stage(&config, &home, &source, &pin).expect("stage");
        assert!(staged.is_file());
        assert_eq!(hash::sha256_file(&staged).expect("hash staged"), pin);
        assert_eq!(staged.parent().expect("parent").file_name().unwrap().to_string_lossy(), &pin[..12]);
        assert_eq!(std::fs::read(&source).expect("source is still there"), b"kernel bytes");
        // A second swap of the same bytes reuses the staged file instead of copying it again.
        let again = stage(&config, &home, &source, &pin).expect("stage twice");
        assert_eq!(again, staged);
        let _ = std::fs::remove_dir_all(home.root());
    }

    #[test]
    fn a_request_and_a_result_round_trip_through_disk() {
        let home = scratch("request");
        let request = SwapRequest {
            id: "swap-1".into(),
            binary: PathBuf::from("/staged/wa"),
            sha256: "ab".repeat(32),
            args: vec!["serve".into(), "--port".into(), "{port}".into()],
            at_ms: 5,
        };
        let path = write_request(&home, &request).expect("write request");
        let pending = pending_requests(&home);
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].1, request);
        let claimed = claim(&path).expect("claim");
        assert!(!path.exists(), "a claimed request is no longer pending");
        assert!(pending_requests(&home).is_empty());
        assert!(claimed.exists());
        let result = SwapResult {
            id: request.id.clone(),
            ok: false,
            rolled_back: true,
            previous: PathBuf::from("/old/wa"),
            active: PathBuf::from("/staged/wa"),
            detail: "did not answer".into(),
            at_ms: 9,
        };
        write_result(&home, &result).expect("write result");
        assert_eq!(wait_result(&home, &request.id, Duration::from_millis(10)), Some(result));
        assert_eq!(wait_result(&home, "swap-none", Duration::from_millis(10)), None);
        let _ = std::fs::remove_dir_all(home.root());
    }
}
