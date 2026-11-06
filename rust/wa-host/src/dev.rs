//! `wa dev <component-dir>`: build a component crate, and put the new build in front of the old one
//! without a node restart (`docs/SERVICE-COMPONENTS.md`, "Iterating on a component").
//!
//! The loop is: watch the crate, `cargo build --target wasm32-wasip2`, lay the artifact down as an
//! installed component in a dev-only component directory, then `wa_kernel_runtime::dev::swap` -
//! start the new instance beside the current one, wait for its `lifecycle.report(ready)`, and only
//! then stop the old one. A build that does not compile, or a candidate that exits or never reports
//! health, keeps the previous instance running: the loop reports it and waits for the next edit.
//!
//! # What "the local node" means here
//!
//! `wa dev` **is** the local node for the component it is told to watch. It runs the same runner a
//! node runs (`wa_kernel_runtime::services::spawn_instance`: grants, migration, limits, log,
//! supervision), in this process, from a component directory under the crate (`<dir>/.wa-dev/`).
//! It deliberately does not join a `wa serve` process's registry: doing that needs a node endpoint
//! for "start a second instance of this name and keep the old one", and the supervisor has no such
//! call yet (`docs/SERVICE-COMPONENTS.md` records it as the next step). What this buys today is a
//! swap that is proven end to end - the run below is the node's own code path, not a mock - and a
//! dev directory the operator can delete.
//!
//! # Timings
//!
//! Every cycle prints `build <ms> ms` (cargo's wall time) and `swap <ms> ms` (start + health + stop),
//! because the number that decides whether a loop is usable is the sum, and only one of the two terms
//! is under the component author's control.

use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const USAGE: &str = "\
usage: wa dev <component-dir> [options]

Builds a component crate for wasm32-wasip2 whenever its sources change and hot-swaps the running
instance: the new one starts beside the old one, is waited on for `lifecycle.report(ready)`, and
only then stops the old one.

  --config <json>        the config object `service.run(config)` receives
  --net <host:port>       grant one net address (repeatable; default: the manifest's `net` list)
  --release              build with --release (default: debug)
  --once                 one build and one swap, then exit (what the smoke test uses)
  --interval <ms>        how often to look for changes in watch mode (default 500)
  --ready-timeout <s>    how long a new instance may take to report ready (default 20)
  --restart              stop the old instance before starting the new one (a component whose two
                         instances cannot coexist: a fixed port, a device)
  --no-build             lay down and swap the artifact already built (no cargo)
  --no-swap              build and install, do not run anything
  --json                 print one machine-readable line per cycle
";

struct Options {
    dir: PathBuf,
    config: Option<Value>,
    net: Vec<String>,
    release: bool,
    once: bool,
    interval: Duration,
    ready: Duration,
    restart: bool,
    build: bool,
    swap: bool,
    json: bool,
}

/// The artifact of one build: where it is, how long cargo took, how big it is.
struct Built {
    wasm: PathBuf,
    millis: u64,
    bytes: u64,
}

pub fn run(args: &[String]) -> i32 {
    let options = match parse(args) {
        Ok(options) => options,
        Err(message) => {
            eprintln!("{message}\n\n{USAGE}");
            return 2;
        }
    };
    let manifest = match read_manifest(&options.dir) {
        Ok(manifest) => manifest,
        Err(error) => {
            eprintln!("dev: {error}");
            return 2;
        }
    };
    let name = manifest["name"].as_str().map(str::to_string).unwrap_or_else(|| package_name(&options.dir));
    if !valid_name(&name) {
        eprintln!("dev: invalid component name {name:?} (lowercase letters, digits and '-')");
        return 2;
    }
    // The dev component directory: everything `wa dev` lays down lives under the crate it watches,
    // so a node's own component directory is never touched by a development build.
    let components = options.dir.join(".wa-dev").join("components");
    if let Err(error) = std::fs::create_dir_all(&components) {
        eprintln!("dev: cannot create {}: {error}", components.display());
        return 2;
    }
    std::env::set_var("WA_COMPONENTS_DIR", &components);
    let request = request_for(&name, &manifest, &options);
    let mut instance: Option<wa_kernel_runtime::dev::DevInstance> = None;
    println!(
        "dev: {name} from {} (components in {})",
        options.dir.display(),
        components.display()
    );
    let mut fingerprint = snapshot(&options.dir);
    if options.once {
        let ok = cycle(&options, &name, &components, &request, &mut instance);
        stop(&mut instance);
        return if ok { 0 } else { 1 };
    }
    cycle(&options, &name, &components, &request, &mut instance);
    loop {
        std::thread::sleep(options.interval);
        let now = snapshot(&options.dir);
        if now == fingerprint {
            continue;
        }
        fingerprint = now;
        println!("dev: change detected, rebuilding");
        if !cycle(&options, &name, &components, &request, &mut instance) {
            eprintln!("dev: the previous instance is still running; waiting for the next edit");
        }
    }
}

/// One build, one install, one swap. `true` when the component is running the build that was just
/// made (a stopped or kept-previous cycle is a failure the loop reports and survives).
fn cycle(options: &Options, name: &str, components: &Path, request: &Value, instance: &mut Option<wa_kernel_runtime::dev::DevInstance>) -> bool {
    let mut built: Option<Built> = None;
    if options.build {
        match build(&options.dir, options.release) {
            Ok(built_now) => {
                println!("dev: build {} ms ({} bytes)", built_now.millis, built_now.bytes);
                built = Some(built_now);
            }
            Err(error) => {
                println!("dev: build_failed {error}");
                return false;
            }
        }
    }
    let wasm = match &built {
        Some(built) => built.wasm.clone(),
        None => match existing_artifact(&options.dir, options.release) {
            Ok(path) => path,
            Err(error) => {
                println!("dev: {error}");
                return false;
            }
        },
    };
    if let Err(error) = install(&wasm, name, components, &options.dir) {
        println!("dev: install_failed {error}");
        return false;
    }
    if !options.swap {
        println!("dev: installed {} (not run: --no-swap)", wasm.display());
        return true;
    }
    let began = Instant::now();
    let answer = wa_kernel_runtime::dev::swap(instance, request, options.ready, options.restart);
    let swap_ms = began.elapsed().as_millis() as u64;
    let ok = answer["ok"].as_bool().unwrap_or(false);
    let mode = answer["mode"].as_str().unwrap_or("unknown");
    let sha = answer["sha256"].as_str().unwrap_or_default();
    let short: String = sha.chars().take(12).collect();
    if ok {
        println!(
            "dev: swap {swap_ms} ms mode={mode} sha256={short} health={} start={}ms ready={}ms stop={}ms",
            answer["health"].as_str().unwrap_or("-"),
            answer["start_ms"].as_u64().unwrap_or(0),
            answer["ready_ms"].as_u64().unwrap_or(0),
            answer["stop_ms"].as_u64().unwrap_or(0),
        );
    } else {
        println!("dev: swap {swap_ms} ms mode={mode} kept the running instance; reason={}", answer["error"].as_str().unwrap_or("-"));
    }
    if options.json {
        println!(
            "dev-json: {}",
            json!({
                "ok": ok,
                "mode": mode,
                "sha256": sha,
                "health": answer["health"],
                "build_ms": built.as_ref().map(|built| built.millis).unwrap_or(0),
                "bytes": built.as_ref().map(|built| built.bytes).unwrap_or(0),
                "swap_ms": swap_ms,
                "start_ms": answer["start_ms"],
                "ready_ms": answer["ready_ms"],
                "stop_ms": answer["stop_ms"],
                "error": answer["error"],
            })
        );
    }
    ok
}

fn stop(instance: &mut Option<wa_kernel_runtime::dev::DevInstance>) {
    if let Some(mut running) = instance.take() {
        let began = Instant::now();
        let exit = running.stop();
        println!("dev: stopped {exit} in {} ms", began.elapsed().as_millis());
    }
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut options = Options {
        dir: PathBuf::new(),
        config: None,
        net: Vec::new(),
        release: false,
        once: false,
        interval: Duration::from_millis(500),
        ready: Duration::from_secs(20),
        restart: false,
        build: true,
        swap: true,
        json: false,
    };
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].as_str();
        let value = |index: &mut usize| -> Result<String, String> {
            *index += 1;
            args.get(*index).cloned().ok_or_else(|| format!("{arg} needs a value"))
        };
        match arg {
            "--config" => {
                let text = value(&mut index)?;
                options.config = Some(serde_json::from_str(&text).map_err(|error| format!("--config is not JSON: {error}"))?);
            }
            "--net" => options.net.push(value(&mut index)?),
            "--release" => options.release = true,
            "--once" => options.once = true,
            "--restart" => options.restart = true,
            "--no-build" => options.build = false,
            "--no-swap" => options.swap = false,
            "--json" => options.json = true,
            "--interval" => {
                let text = value(&mut index)?;
                options.interval = Duration::from_millis(text.parse().map_err(|_| "--interval needs milliseconds".to_string())?)
            }
            "--ready-timeout" => {
                let text = value(&mut index)?;
                options.ready = Duration::from_secs(text.parse().map_err(|_| "--ready-timeout needs seconds".to_string())?)
            }
            "--help" | "-h" => return Err("help".into()),
            other if other.starts_with("--") => return Err(format!("unknown option {other}")),
            other => options.dir = PathBuf::from(other),
        }
        index += 1;
    }
    if options.dir.as_os_str().is_empty() {
        return Err("dev needs a component directory".into());
    }
    if !options.dir.is_dir() {
        return Err(format!("not a directory: {}", options.dir.display()));
    }
    if options.interval < Duration::from_millis(50) {
        return Err("--interval is at least 50 ms".into());
    }
    Ok(options)
}

fn read_manifest(dir: &Path) -> Result<Value, String> {
    let path = dir.join("manifest.json");
    let text = std::fs::read_to_string(&path).map_err(|error| format!("no manifest at {}: {error}", path.display()))?;
    serde_json::from_str(&text).map_err(|error| format!("{} is not JSON: {error}", path.display()))
}

/// The request `services::start` takes: name, grants and config. The grants come from the CLI, or -
/// when it names none - from the manifest's own declaration, which for a dev loop is what the
/// component says it needs.
fn request_for(name: &str, manifest: &Value, options: &Options) -> Value {
    let net: Vec<String> = if options.net.is_empty() {
        manifest["capabilities"]["net"].as_array().into_iter().flatten().filter_map(|address| address.as_str().map(str::to_string)).collect()
    } else {
        options.net.clone()
    };
    let mut request = json!({"name": name, "net": net});
    if let Some(config) = &options.config {
        request["config"] = config.clone();
    }
    request
}

/// Lay the artifact down as an installed component, in the same three files a deploy writes: the
/// `.wasm`, its pin (last, so a reader never sees a wasm whose pin is missing or old) and the
/// manifest. `wa-kernel-runtime`'s `load` verifies the pin before anything runs, so a half-written
/// install is refused by name instead of started.
fn install(wasm: &Path, name: &str, components: &Path, dir: &Path) -> Result<(), String> {
    let bytes = std::fs::read(wasm).map_err(|error| format!("{}: {error}", wasm.display()))?;
    if bytes.len() < 8 || &bytes[..4] != b"\0asm" {
        return Err(format!("{} is not a wasm module", wasm.display()));
    }
    let pin = sha256(&bytes);
    let staged = components.join(format!("{name}.wasm.tmp"));
    std::fs::write(&staged, &bytes).map_err(|error| format!("{}: {error}", staged.display()))?;
    std::fs::rename(&staged, components.join(format!("{name}.wasm"))).map_err(|error| format!("rename: {error}"))?;
    let manifest = std::fs::read(dir.join("manifest.json")).map_err(|error| format!("manifest: {error}"))?;
    std::fs::write(components.join(format!("{name}.json")), manifest).map_err(|error| format!("manifest: {error}"))?;
    let pinned = format!("{pin}  {name}.wasm\n");
    let staged = components.join(format!("{name}.wasm.sha256.tmp"));
    std::fs::write(&staged, pinned.as_bytes()).map_err(|error| format!("pin: {error}"))?;
    std::fs::rename(&staged, components.join(format!("{name}.wasm.sha256"))).map_err(|error| format!("pin: {error}"))?;
    Ok(())
}

fn existing_artifact(dir: &Path, release: bool) -> Result<PathBuf, String> {
    let path = artifact_path(dir, release)?;
    if !path.is_file() {
        return Err(format!("no artifact at {} (build it, or drop --no-build)", path.display()));
    }
    Ok(path)
}

/// Where cargo puts a component's `.wasm`, asked rather than guessed: `cargo metadata --no-deps`
/// names the cdylib target (whose file name has `-` replaced by `_`) and this run's target directory
/// (`CARGO_TARGET_DIR`, a workspace, or the crate's own `target/`).
fn artifact_path(dir: &Path, release: bool) -> Result<PathBuf, String> {
    let metadata = cargo(dir, &["metadata", "--no-deps", "--format-version", "1"])?;
    let parsed: Value = serde_json::from_slice(&metadata).map_err(|error| format!("cargo metadata: {error}"))?;
    let target_directory = parsed["target_directory"].as_str().ok_or("cargo metadata: no target_directory")?;
    let package = parsed["packages"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|package| {
            package["manifest_path"].as_str().and_then(|path| Path::new(path).parent()).is_some_and(|parent| same_dir(parent, dir))
        })
        .ok_or_else(|| format!("cargo metadata: no package at {}", dir.display()))?;
    let target = package["targets"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|target| target["crate_types"].as_array().into_iter().flatten().any(|kind| kind == "cdylib"))
        .ok_or("no cdylib target: a component needs crate-type = [\"cdylib\"]")?;
    let stem = target["name"].as_str().ok_or("cargo metadata: target without name")?.replace('-', "_");
    let profile = if release { "release" } else { "debug" };
    Ok(PathBuf::from(target_directory).join("wasm32-wasip2").join(profile).join(format!("{stem}.wasm")))
}


/// Two paths name the same directory: `cargo metadata` answers with canonical paths, and the caller
/// has whatever the command line gave it (`../wa-fake-kernel/fixture`, a symlink, a `/c/...` path
/// from Git Bash). Compared canonically so the lookup cannot miss for spelling.
fn same_dir(a: &Path, b: &Path) -> bool {
    let canonical = |path: &Path| std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    canonical(a) == canonical(b)
}

fn build(dir: &Path, release: bool) -> Result<Built, String> {
    let path = artifact_path(dir, release)?;
    let mut args = vec!["build", "--target", "wasm32-wasip2"];
    if release {
        args.push("--release");
    }
    let began = Instant::now();
    cargo(dir, &args)?;
    let millis = began.elapsed().as_millis() as u64;
    let bytes = std::fs::metadata(&path).map_err(|error| format!("artifact_missing:{}:{error}", path.display()))?.len();
    Ok(Built { wasm: path, millis, bytes })
}

fn cargo(dir: &Path, args: &[&str]) -> Result<Vec<u8>, String> {
    let cargo = std::env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    let output = std::process::Command::new(&cargo).args(args).current_dir(dir).output().map_err(|error| format!("cargo_unavailable:{cargo}:{error}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let tail: Vec<&str> = stderr.lines().rev().take(6).collect();
        let tail: Vec<&str> = tail.into_iter().rev().collect();
        return Err(format!("{}: {}", output.status, tail.join(" | ")));
    }
    Ok(output.stdout)
}

/// The crate's inputs and their stamps: `Cargo.toml`, `Cargo.lock`, the manifest, and every file
/// under `src/`. A change in any of them rebuilds; nothing else is watched, because nothing else can
/// change the artifact.
fn snapshot(dir: &Path) -> BTreeMap<PathBuf, (u64, u64)> {
    let mut stamps = BTreeMap::new();
    for file in ["Cargo.toml", "Cargo.lock", "manifest.json"] {
        stamp(&dir.join(file), &mut stamps);
    }
    collect(&dir.join("src"), &mut stamps);
    stamps
}

fn collect(dir: &Path, stamps: &mut BTreeMap<PathBuf, (u64, u64)>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        match entry.file_type() {
            Ok(kind) if kind.is_dir() => collect(&path, stamps),
            _ => stamp(&path, stamps),
        }
    }
}

fn stamp(path: &Path, stamps: &mut BTreeMap<PathBuf, (u64, u64)>) {
    let Ok(metadata) = std::fs::metadata(path) else { return };
    let modified = metadata.modified().ok().and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok()).map(|since| since.as_millis() as u64).unwrap_or(0);
    stamps.insert(path.to_path_buf(), (modified, metadata.len()));
}

fn package_name(dir: &Path) -> String {
    std::fs::read_to_string(dir.join("Cargo.toml"))
        .ok()
        .and_then(|text| text.lines().find_map(|line| line.trim().strip_prefix("name = ").map(|value| value.trim().trim_matches('"').to_string())))
        .unwrap_or_else(|| "component".into())
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 40
        && name.bytes().next().is_some_and(|byte| byte.is_ascii_lowercase())
        && name.bytes().all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

fn sha256(bytes: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, bytes).as_ref().iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The artifact is where cargo says it is: a crate whose package name and lib name differ
    /// (`fake-kernel-fixture` builds `fake_kernel_fixture.wasm`) is the case a guess gets wrong.
    #[test]
    fn the_artifact_is_read_from_cargo_metadata() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../wa-fake-kernel/fixture");
        if !dir.join("Cargo.toml").is_file() {
            return;
        }
        let path = artifact_path(&dir, false).expect("the fixture's layout");
        assert!(path.to_string_lossy().contains("wasm32-wasip2"), "{}", path.display());
        assert!(path.to_string_lossy().ends_with("fake_kernel_fixture.wasm"), "{}", path.display());
    }

    /// A cancel-free snapshot: touching a source file changes it, so the loop cannot miss an edit.
    #[test]
    fn the_snapshot_sees_a_source_change() {
        let dir = std::env::temp_dir().join(format!("wa-dev-snapshot-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("src")).unwrap();
        std::fs::write(dir.join("Cargo.toml"), "[package]\n").unwrap();
        std::fs::write(dir.join("src/lib.rs"), "fn one() {}\n").unwrap();
        let before = snapshot(&dir);
        std::thread::sleep(Duration::from_millis(20));
        std::fs::write(dir.join("src/lib.rs"), "fn one() {} // edited\n").unwrap();
        let after = snapshot(&dir);
        assert_ne!(before, after, "an edited source file must change the snapshot");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A component name that the runtime would refuse is refused here, before anything is written.
    #[test]
    fn a_name_the_runtime_would_refuse_is_refused() {
        assert!(valid_name("fake-kernel-fixture"));
        assert!(!valid_name("Fake"));
        assert!(!valid_name("with space"));
        assert!(!valid_name(""));
    }
}
