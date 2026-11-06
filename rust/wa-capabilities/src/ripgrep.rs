//! Provision the small search dependency once, independently of any model turn.
use anyhow::{bail, Context, Result};
use std::{fs, path::Path, process::Command, time::{Duration, SystemTime, UNIX_EPOCH}};

const VERSION: &str = "15.2.0";

fn asset(os: &str, arch: &str) -> Result<(&'static str, &'static str)> {
    Ok(match (os, arch) {
        ("windows", "x86_64") => ("x86_64-pc-windows-msvc.zip", "71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5"),
        ("windows", "aarch64") => ("aarch64-pc-windows-msvc.zip", "e4abca10c3a64ebea742667dd7009449d49403db5460dd6873e389fa2945360f"),
        ("linux", "x86_64") => ("x86_64-unknown-linux-musl.tar.gz", "33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c"),
        ("linux", "aarch64") => ("aarch64-unknown-linux-musl.tar.gz", "800b1e7206afe799dfb5a6901f23147cfaabe0e52210538100f61e86e1740915"),
        ("macos", "x86_64") => ("x86_64-apple-darwin.tar.gz", "af7825fcc69a2afc7a7aea55fc9af90e26421d8f20fe59df32e233c0b8a231c1"),
        ("macos", "aarch64") => ("aarch64-apple-darwin.tar.gz", "3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4"),
        _ => bail!("no bundled ripgrep for {os}/{arch}; install rg on PATH"),
    })
}

fn command(program: impl AsRef<std::ffi::OsStr>) -> Command {
    let mut cmd = Command::new(program);
    #[cfg(windows)] {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x08000000); // CREATE_NO_WINDOW
    }
    cmd
}

fn works(program: impl AsRef<std::ffi::OsStr>) -> bool {
    command(program).arg("--version").output().is_ok_and(|out|
        out.status.success() && out.stdout.starts_with(b"ripgrep "))
}

pub fn ensure(home: &Path) -> Result<()> {
    let bin = home.join(".wasm-agent/bin");
    let executable = if cfg!(windows) { "rg.exe" } else { "rg" };
    let local = bin.join(executable);
    if !works(&local) {
        if works(executable) { return Ok(()); }
        let (suffix, expected) = asset(std::env::consts::OS, std::env::consts::ARCH)?;
        eprintln!("ripgrep missing; installing {VERSION} into {}", bin.display());
        fs::create_dir_all(&bin)?;
        let stage = bin.join(format!(".rg-{}-{}", std::process::id(),
            SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()));
        fs::create_dir(&stage)?;
        let result = (|| -> Result<()> {
            let name = format!("ripgrep-{VERSION}-{suffix}");
            let url = format!("https://github.com/BurntSushi/ripgrep/releases/download/{VERSION}/{name}");
            let agent: ureq::Agent = ureq::Agent::config_builder()
                .timeout_global(Some(Duration::from_secs(120))).build().into();
            let bytes = agent.get(&url).call()?.body_mut().read_to_vec()?;
            let actual = ring::digest::digest(&ring::digest::SHA256, &bytes).as_ref()
                .iter().map(|byte| format!("{byte:02x}")).collect::<String>();
            if actual != expected { bail!("ripgrep archive checksum mismatch"); }
            let archive = stage.join(&name);
            fs::write(&archive, bytes)?;
            let extracted = stage.join("extracted");
            fs::create_dir(&extracted)?;
            let status = if cfg!(windows) {
                // Pass native paths as environment values, never interpolate them into shell code.
                let powershell = std::env::var_os("SystemRoot").context("SystemRoot missing")?;
                command(Path::new(&powershell).join("System32/WindowsPowerShell/v1.0/powershell.exe"))
                    .args(["-NoProfile", "-NonInteractive", "-Command",
                        "$ErrorActionPreference='Stop'; Expand-Archive -LiteralPath $env:WA_RG_ARCHIVE -DestinationPath $env:WA_RG_EXTRACT"])
                    .env("WA_RG_ARCHIVE", &archive).env("WA_RG_EXTRACT", &extracted).status()?
            } else {
                command("tar").arg("-xzf").arg(&archive).arg("-C").arg(&extracted).status()?
            };
            if !status.success() { bail!("ripgrep archive extraction failed: {status}"); }
            let directory = name.trim_end_matches(".zip").trim_end_matches(".tar.gz");
            let ready = extracted.join(directory).join(executable);
            #[cfg(unix)] {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&ready, fs::Permissions::from_mode(0o755))?;
            }
            if !works(&ready) { bail!("downloaded ripgrep cannot run"); }
            // Publish the verified executable on the same filesystem. Another startup may
            // have already installed it; never replace a working, possibly running copy.
            if !works(&local) {
                if local.exists() { fs::remove_file(&local)?; }
                if let Err(error) = fs::rename(&ready, &local) {
                    if !works(&local) { return Err(error.into()); }
                }
            }
            Ok(())
        })();
        let _ = fs::remove_dir_all(&stage);
        result?;
    }
    let mut paths = vec![bin];
    if let Some(path) = std::env::var_os("PATH") { paths.extend(std::env::split_paths(&path)); }
    std::env::set_var("PATH", std::env::join_paths(paths)?);
    Ok(())
}
