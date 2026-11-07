//! The watchdog's configuration: a small `key = value` file, every knob with a default and a reason.
//!
//! Text, not TOML/JSON, for one reason: the file is written and read by shell scripts as well as by this
//! binary (`scripts/upgrade.sh` under `WA_WATCHDOG=1`), and a `grep '^port'` must be able to answer what
//! port the watchdog thinks it is on. Unknown keys are a refusal, not a shrug: a typo'd knob that is
//! silently ignored is a knob whose measurement nobody made.

use std::path::{Path, PathBuf};

/// Placeholders substituted at LAUNCH time, never at request time.
///
/// This is the one idea that makes a swap simple: a kernel's argument list is stored exactly as written
/// (`serve --port {port} --client-port {client_port}`), so the same list starts the service instance on the
/// service port and the proof instance on a spare port. A recorded list of *resolved* arguments could not:
/// it would name the service port for ever, and the proof instance would fight the running kernel for it.
pub const PLACEHOLDERS: [&str; 6] = ["{port}", "{client_port}", "{service_port}", "{service_client_port}", "{home}", "{db}"];

#[derive(Debug, Clone, PartialEq)]
pub struct Config {
    /// The kernel to start. `swap` replaces the *recorded* active kernel, not this value.
    pub kernel: Option<PathBuf>,
    /// The kernel's arguments, with [`PLACEHOLDERS`]. Default: `serve --port {port} --client-port {client_port}`.
    pub kernel_args: Vec<String>,
    /// The port the kernel serves `/health` on, and the port the service is reachable on.
    pub port: u16,
    /// The kernel's client bridge port (`{client_port}`).
    pub client_port: u16,
    /// `{home}` for the service instance (`WASM_AGENT_HOME` for a real kernel).
    pub runtime_home: Option<PathBuf>,
    /// `{db}` for the service instance.
    pub db: Option<PathBuf>,
    /// Working directory for the kernel.
    pub work_dir: Option<PathBuf>,
    /// How long a start may take before it counts as a failed start. 90s: `docs/SENTINEL.md` records a
    /// healthy node that answered at ~21s behind a dying predecessor, and 20s called it dead.
    pub start_timeout_ms: u64,
    /// The supervisor's loop cadence; also the poll interval while waiting for a start or a swap.
    pub tick_ms: u64,
    /// Exponential backoff on crash: base, factor, ceiling.
    pub backoff_base_ms: u64,
    pub backoff_factor: u32,
    pub backoff_max_ms: u64,
    /// How long a swapped-in kernel has to answer `/health` before the swap is rolled back.
    pub swap_health_window_ms: u64,
    /// How long `swap` (the CLI) waits for the supervisor's verdict before reporting that it is still
    /// pending. The request stays on disk: the supervisor answers it on its next pass.
    pub swap_wait_ms: u64,
    /// After a swap, how long the new kernel must stay up before the swap is considered settled. A kernel
    /// that dies inside this window is rolled back to the previous binary automatically.
    pub stability_ms: u64,
    /// Whether a kernel that answered health and then exited within [`Config::stability_ms`] of being
    /// swapped in is replaced by the previous binary (default: yes; it is the promise in docs/KERNEL.md).
    pub rollback_on_early_crash: bool,
    /// Consecutive failed probes before a *running* kernel is restarted. 0 (the default) means never: a
    /// busy node answers `/health` slowly and `ok:false` while a run is stalled, and killing it for that
    /// would interrupt the turn the node exists for. The sentinel and `upgrade.sh` wait for idle instead.
    pub health_miss_limit: u32,
    /// The port the copy of a new binary is proved on. 0 = pick a free one.
    pub spare_port: u16,
    /// Extra environment for the kernel (`NAME=value`), applied on top of the inherited environment.
    pub env: Vec<(String, String)>,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            kernel: None,
            kernel_args: vec!["serve".into(), "--port".into(), "{port}".into(), "--client-port".into(), "{client_port}".into()],
            port: 8799,
            client_port: 8800,
            runtime_home: None,
            db: None,
            work_dir: None,
            start_timeout_ms: 90_000,
            tick_ms: 200,
            backoff_base_ms: 500,
            backoff_factor: 2,
            backoff_max_ms: 60_000,
            swap_health_window_ms: 30_000,
            swap_wait_ms: 180_000,
            stability_ms: 60_000,
            rollback_on_early_crash: true,
            health_miss_limit: 0,
            spare_port: 0,
            env: Vec::new(),
        }
    }
}

impl Config {
    /// Parse the text form. Every key is required to be known; every number is required to be one.
    pub fn parse(text: &str) -> Result<Config, String> {
        let mut config = Config::default();
        let mut seen: Vec<String> = Vec::new();
        for (number, raw) in text.lines().enumerate() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
                continue;
            }
            let (key, value) = line
                .split_once('=')
                .ok_or_else(|| format!("line {}: expected `key = value`, found {line:?}", number + 1))?;
            let key = key.trim().to_string();
            let value = value.trim().to_string();
            // Every key is set once - except `env`, which is a *list* (`render` writes one line per
            // variable) and is therefore the only key that may repeat. Refusing the rest means a typo
            // cannot be silently overridden by a later line.
            if key != "env" {
                if seen.iter().any(|existing| existing == &key) {
                    return Err(format!("line {}: `{key}` is set twice; the first value would be silently replaced", number + 1));
                }
                seen.push(key.clone());
            }
            let number_of = |value: &str| -> Result<u64, String> {
                value
                    .parse::<u64>()
                    .map_err(|_| format!("line {}: `{key}` expects a whole number, found {value:?}", number + 1))
            };
            let text_of = |value: String| -> String {
                // Quotes are optional and stripped, so a path with spaces can be written either way.
                let trimmed = value.trim();
                match trimmed.strip_prefix('"').and_then(|inner| inner.strip_suffix('"')) {
                    Some(inner) => inner.to_string(),
                    None => trimmed.to_string(),
                }
            };
            match key.as_str() {
                "kernel" => config.kernel = Some(PathBuf::from(text_of(value))),
                // NOT `text_of`: an argument list is split with quote grouping of its own, so an outer
                // pair of quotes would be eaten twice and a one-argument list with a space in it would
                // come back as two.
                "kernel_args" => config.kernel_args = split_args(&value)?,
                "port" => config.port = port_of(&key, number_of(&value)?)?,
                "client_port" => config.client_port = port_of(&key, number_of(&value)?)?,
                "spare_port" => config.spare_port = port_of(&key, number_of(&value)?)?,
                "runtime_home" => config.runtime_home = Some(PathBuf::from(text_of(value))),
                "db" => config.db = Some(PathBuf::from(text_of(value))),
                "work_dir" => config.work_dir = Some(PathBuf::from(text_of(value))),
                "start_timeout_ms" => config.start_timeout_ms = number_of(&value)?,
                "tick_ms" => config.tick_ms = number_of(&value)?,
                "backoff_base_ms" => config.backoff_base_ms = number_of(&value)?,
                "backoff_factor" => config.backoff_factor = number_of(&value)? as u32,
                "backoff_max_ms" => config.backoff_max_ms = number_of(&value)?,
                "swap_health_window_ms" => config.swap_health_window_ms = number_of(&value)?,
                "swap_wait_ms" => config.swap_wait_ms = number_of(&value)?,
                "stability_ms" => config.stability_ms = number_of(&value)?,
                "rollback_on_early_crash" => {
                    config.rollback_on_early_crash = match value.as_str() {
                        "1" | "true" | "yes" => true,
                        "0" | "false" | "no" => false,
                        _ => return Err(format!("line {}: `rollback_on_early_crash` expects true or false, found {value:?}", number + 1)),
                    }
                }
                "health_miss_limit" => config.health_miss_limit = number_of(&value)? as u32,
                "env" => {
                    let assignment = text_of(value);
                    let (name, value) = assignment
                        .split_once('=')
                        .ok_or_else(|| format!("line {}: `env` expects NAME=value, found {assignment:?}", number + 1))?;
                    config.env.push((name.trim().to_string(), value.to_string()));
                }
                other => {
                    return Err(format!(
                        "line {}: unknown key `{other}` (known: kernel, kernel_args, port, client_port, runtime_home, db, work_dir, start_timeout_ms, tick_ms, backoff_base_ms, backoff_factor, backoff_max_ms, swap_health_window_ms, swap_wait_ms, stability_ms, rollback_on_early_crash, health_miss_limit, spare_port, env)",
                        number + 1
                    ))
                }
            }
        }
        if config.tick_ms == 0 {
            return Err("tick_ms must be at least 1".to_string());
        }
        if config.backoff_factor < 1 {
            return Err("backoff_factor must be at least 1".to_string());
        }
        if config.port == 0 || config.client_port == 0 {
            return Err("port and client_port must be non-zero".to_string());
        }
        Ok(config)
    }

    pub fn load(path: &Path) -> Result<Config, String> {
        let text = std::fs::read_to_string(path).map_err(|error| format!("cannot read {}: {error}", path.display()))?;
        Config::parse(&text).map_err(|error| format!("{}: {error}", path.display()))
    }

    /// The same text form `parse` reads, so `init` and `parse` cannot drift.
    pub fn render(&self) -> String {
        let mut out = String::new();
        out.push_str("# wa-watchdog configuration. Written by `wa-watchdog init`; edit by hand, restart to apply.\n");
        if let Some(kernel) = &self.kernel {
            out.push_str(&format!("kernel = {}\n", kernel.display()));
        }
        let args: Vec<String> = self
            .kernel_args
            .iter()
            .map(|arg| if arg.chars().any(char::is_whitespace) { format!("\"{arg}\"") } else { arg.clone() })
            .collect();
        out.push_str(&format!("kernel_args = {}\n", args.join(" ")));
        out.push_str(&format!("port = {}\n", self.port));
        out.push_str(&format!("client_port = {}\n", self.client_port));
        if let Some(home) = &self.runtime_home {
            out.push_str(&format!("runtime_home = {}\n", home.display()));
        }
        if let Some(db) = &self.db {
            out.push_str(&format!("db = {}\n", db.display()));
        }
        if let Some(dir) = &self.work_dir {
            out.push_str(&format!("work_dir = {}\n", dir.display()));
        }
        out.push_str(&format!("start_timeout_ms = {}\n", self.start_timeout_ms));
        out.push_str(&format!("tick_ms = {}\n", self.tick_ms));
        out.push_str(&format!("backoff_base_ms = {}\n", self.backoff_base_ms));
        out.push_str(&format!("backoff_factor = {}\n", self.backoff_factor));
        out.push_str(&format!("backoff_max_ms = {}\n", self.backoff_max_ms));
        out.push_str(&format!("swap_health_window_ms = {}\n", self.swap_health_window_ms));
        out.push_str(&format!("swap_wait_ms = {}\n", self.swap_wait_ms));
        out.push_str(&format!("stability_ms = {}\n", self.stability_ms));
        out.push_str(&format!("rollback_on_early_crash = {}\n", self.rollback_on_early_crash));
        out.push_str(&format!("health_miss_limit = {}\n", self.health_miss_limit));
        out.push_str(&format!("spare_port = {}\n", self.spare_port));
        for (name, value) in &self.env {
            out.push_str(&format!("env = {name}={value}\n"));
        }
        out
    }

    /// Resolve [`PLACEHOLDERS`] for one launch. Refuses a list that still names a placeholder it was not
    /// given a value for: a kernel started with a literal `{db}` argument fails in a way nobody can read.
    pub fn resolve_args(&self, view: &LaunchView) -> Result<Vec<String>, String> {
        let mut out = Vec::with_capacity(self.kernel_args.len());
        for arg in &self.kernel_args {
            let mut resolved = arg.clone();
            if resolved.contains("{port}") {
                resolved = resolved.replace("{port}", &view.port.to_string());
            }
            if resolved.contains("{client_port}") {
                resolved = resolved.replace("{client_port}", &view.client_port.to_string());
            }
            if resolved.contains("{service_port}") {
                resolved = resolved.replace("{service_port}", &self.port.to_string());
            }
            if resolved.contains("{service_client_port}") {
                resolved = resolved.replace("{service_client_port}", &self.client_port.to_string());
            }
            if resolved.contains("{home}") {
                let home = view
                    .home
                    .as_ref()
                    .ok_or_else(|| "`{home}` is used in kernel_args but `runtime_home` is not configured".to_string())?;
                resolved = resolved.replace("{home}", &home.display().to_string());
            }
            if resolved.contains("{db}") {
                let db = view.db.as_ref().ok_or_else(|| "`{db}` is used in kernel_args but `db` is not configured".to_string())?;
                resolved = resolved.replace("{db}", &db.display().to_string());
            }
            out.push(resolved);
        }
        Ok(out)
    }
}

/// One launch's values for the placeholders: the service instance and the proof instance differ only here.
#[derive(Debug, Clone)]
pub struct LaunchView {
    pub port: u16,
    pub client_port: u16,
    pub home: Option<PathBuf>,
    pub db: Option<PathBuf>,
}

impl LaunchView {
    /// The instance that serves the node.
    pub fn service(config: &Config) -> LaunchView {
        LaunchView {
            port: config.port,
            client_port: config.client_port,
            home: config.runtime_home.clone(),
            db: config.db.clone(),
        }
    }

    /// The throwaway instance used to prove new bytes on a spare port. Its own home and db, so it cannot
    /// read or write the live node's state (`scripts/upgrade.sh` learned this the hard way).
    pub fn proof(scratch: &Path, port: u16) -> LaunchView {
        LaunchView {
            port,
            client_port: port.saturating_add(1),
            home: Some(scratch.to_path_buf()),
            db: Some(scratch.join("proof.db")),
        }
    }
}

fn port_of(key: &str, value: u64) -> Result<u16, String> {
    if value > u16::MAX as u64 {
        return Err(format!("`{key}` must be a port (0-65535), found {value}"));
    }
    Ok(value as u16)
}

/// Split an argument list, honouring double quotes so a path with spaces is one argument.
pub fn split_args(text: &str) -> Result<Vec<String>, String> {
    let mut out = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut started = false;
    for ch in text.chars() {
        match ch {
            '"' => {
                quoted = !quoted;
                started = true;
            }
            ch if ch.is_whitespace() && !quoted => {
                if started {
                    out.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            ch => {
                current.push(ch);
                started = true;
            }
        }
    }
    if quoted {
        return Err("kernel_args: unbalanced double quote".to_string());
    }
    if started {
        out.push(current);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_the_documented_ones() {
        let config = Config::default();
        assert_eq!(config.port, 8799);
        assert_eq!(config.client_port, 8800);
        assert_eq!(config.start_timeout_ms, 90_000);
        assert!(!config.rollback_on_early_crash || config.stability_ms > 0);
        assert_eq!(config.health_miss_limit, 0, "a live kernel is never killed for health by default");
        assert_eq!(config.resolve_args(&LaunchView::service(&config)).unwrap(), ["serve", "--port", "8799", "--client-port", "8800"]);
    }

    #[test]
    fn a_typo_is_refused_not_ignored() {
        let error = Config::parse("prot = 8799\n").unwrap_err();
        assert!(error.contains("unknown key `prot`"), "{error}");
        let error = Config::parse("port = 8799\nport = 8800\n").unwrap_err();
        assert!(error.contains("set twice"), "{error}");
        let error = Config::parse("tick_ms = fast\n").unwrap_err();
        assert!(error.contains("whole number"), "{error}");
        let error = Config::parse("backoff_factor = 0\n").unwrap_err();
        assert!(error.contains("at least 1"), "{error}");
    }

    /// `env` is the one list-valued key (`render` writes one line per variable), so the duplicate-key
    /// refusal - which exists so a second line cannot silently override the first - must not apply to it.
    /// Found by a real config: `wa-watchdog init` plus six `env = ...` lines, refused with "`env` is set
    /// twice", which made every hand-written supervisor config with an environment unusable.
    #[test]
    fn env_may_repeat_and_every_other_key_may_not() {
        let text = "kernel = /k
port = 9100
env = A=1
env = B=two words
env = C=
";
        let config = Config::parse(text).expect("a config with three env lines");
        assert_eq!(
            config.env,
            vec![
                ("A".to_string(), "1".to_string()),
                ("B".to_string(), "two words".to_string()),
                ("C".to_string(), String::new()),
            ]
        );
        // Round-tripping keeps every line: render -> parse is the same list.
        let again = Config::parse(&config.render()).expect("render/parse agreement with env");
        assert_eq!(again.env, config.env);
        // A scalar key is still refused, and the refusal names it.
        let twice = Config::parse("port = 9100
port = 9101
").unwrap_err();
        assert!(twice.contains("`port` is set twice"), "{twice}");
    }

    #[test]
    fn render_and_parse_agree() {
        let mut config = Config {
            kernel: Some(PathBuf::from("/opt/wa with space/wa")),
            kernel_args: vec!["serve".into(), "--ui".into(), "/opt/ui dir".into(), "--port".into(), "{port}".into()],
            runtime_home: Some(PathBuf::from("/home/wa/.wasm-agent")),
            spare_port: 9100,
            stability_ms: 0,
            ..Config::default()
        };
        config.env.push(("WA_CLIENT_PORT".into(), "8800".into()));
        let text = config.render();
        let parsed = Config::parse(&text).expect("render must parse");
        // A path with a space must survive the round trip: render quotes it, `split_args` un-quotes it.
        assert_eq!(parsed.port, config.port);
        assert_eq!(parsed.env, config.env);
        assert_eq!(parsed.spare_port, 9100);
        assert_eq!(parsed.stability_ms, 0);
        assert_eq!(parsed.kernel, config.kernel);
        assert_eq!(parsed.kernel_args, config.kernel_args, "kernel_args must survive render -> parse");
    }

    #[test]
    fn placeholders_are_resolved_per_launch_and_left_alone_otherwise() {
        let mut config = Config {
            kernel_args: vec!["serve".into(), "--port".into(), "{port}".into(), "--db".into(), "{db}".into()],
            ..Config::default()
        };
        let error = config.resolve_args(&LaunchView::service(&config)).unwrap_err();
        assert!(error.contains("`{db}`"), "{error}");
        config.db = Some(PathBuf::from("/var/wa/kernel.db"));
        let service = config.resolve_args(&LaunchView::service(&config)).unwrap();
        assert_eq!(service[2], "8799");
        assert_eq!(service[4], "/var/wa/kernel.db");
        config.spare_port = 0;
        config.kernel_args = vec!["--port".into(), "{port}".into(), "--service".into(), "{service_port}".into()];
        let proof = config.resolve_args(&LaunchView::proof(Path::new("/tmp/proof"), 9101)).unwrap();
        assert_eq!(proof[1], "9101", "the proof instance takes the spare port");
        assert_eq!(proof[3], "8799", "`{{service_port}}` still names the service port");
    }

    #[test]
    fn an_argument_list_keeps_quoted_paths_whole() {
        let args = split_args("serve --ui \"/opt/ui dir\" --port 8799").unwrap();
        assert_eq!(args, ["serve", "--ui", "/opt/ui dir", "--port", "8799"]);
        assert!(split_args("serve --ui \"unterminated").is_err());
        assert_eq!(split_args("   ").unwrap(), Vec::<String>::new());
    }
}
