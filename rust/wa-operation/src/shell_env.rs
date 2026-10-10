//! Direct Git Bash needs its bundled utilities on PATH; never source user/login profiles.
use std::{ffi::{OsStr, OsString}, io, path::Path};

/// Scope PATH repair to an absolute Git bash/sh layout. Other shells and non-Windows stay unchanged.
pub fn git_shell_path(program: &OsStr, inherited: Option<&OsStr>) -> io::Result<Option<OsString>> {
    if !cfg!(windows) { return Ok(None); }
    let program=Path::new(program);
    if !program.is_absolute() { return Ok(None); }
    let name=program.file_name().and_then(OsStr::to_str).unwrap_or("").to_ascii_lowercase();
    if !matches!(name.as_str(),"bash.exe"|"sh.exe") { return Ok(None); }
    let Some(parent)=program.parent() else { return Ok(None); };
    let root=if parent.ends_with("usr/bin") { parent.parent().and_then(Path::parent) }
        else if parent.ends_with("bin") {parent.parent()} else {None};
    let Some(root)=root else {return Ok(None);};
    let utilities=root.join("usr/bin");
    if !utilities.join("bash.exe").is_file() {return Ok(None);}
    let git=root.join("cmd/git.exe");
    if !git.is_file() {return Ok(None);} // Not a verified Git installation layout.
    for name in ["dirname","date","mkdir","sed","tr","wc","uname"] {
        if !utilities.join(format!("{name}.exe")).is_file() {
            return Err(io::Error::other(format!("git_shell_environment_missing:{name}")));
        }
    }
    let mut dirs=vec![utilities,root.join("cmd")];
    for arch in ["mingw64/bin","mingw32/bin"] {let dir=root.join(arch);if dir.is_dir(){dirs.push(dir);}}
    dirs.extend(inherited.map(std::env::split_paths).into_iter().flatten());
    std::env::join_paths(dirs).map(Some).map_err(io::Error::other)
}

pub fn configure_command(command: &mut std::process::Command) -> io::Result<()> {
    let inherited=command.get_envs().find(|(k,_)|k.eq_ignore_ascii_case("PATH"))
        .and_then(|(_,v)|v.map(OsStr::to_os_string)).or_else(||std::env::var_os("PATH"));
    if let Some(path)=git_shell_path(command.get_program(),inherited.as_deref())? {command.env("PATH",path);}
    Ok(())
}

pub(crate) fn configure_spec(spec: &mut crate::Spec) -> io::Result<()> {
    let inherited=spec.env.iter().rev().find(|(k,_)|k.eq_ignore_ascii_case("PATH"))
        .map(|(_,v)|OsString::from(v)).or_else(||std::env::var_os("PATH"));
    if let Some(path)=git_shell_path(OsStr::new(&spec.program),inherited.as_deref())? {
        spec.env.retain(|(k,_)|!k.eq_ignore_ascii_case("PATH"));
        spec.env.push(("PATH".into(),path.to_string_lossy().into_owned()));
    }
    Ok(())
}

#[cfg(all(test,windows))]
mod tests {
    use super::*;
    use std::path::PathBuf;
    #[test]
    fn real_git_utilities_work_with_plain_windows_path_and_old_launch_fails() {
        let bash=PathBuf::from(r"C:\Program Files\Git\usr\bin\bash.exe");
        assert!(bash.is_file());
        let system=std::env::var_os("SystemRoot").unwrap();
        let path=std::env::join_paths([PathBuf::from(system).join("System32")]).unwrap();
        let script="for x in dirname date mkdir sed tr wc uname git; do command -v \"$x\" >/dev/null || exit 9; done; printf ready";
        let old=std::process::Command::new(&bash).args(["--noprofile","--norc","-c",script]).env("PATH",&path).output().unwrap();
        assert!(!old.status.success(),"negative control did not reproduce missing PATH");
        let mut command=std::process::Command::new(&bash);
        command.args(["--noprofile","--norc","-c",script]).env("PATH",&path);
        configure_command(&mut command).unwrap();
        let output=command.output().unwrap();assert!(output.status.success(),"{}",String::from_utf8_lossy(&output.stderr));
        assert_eq!(output.stdout,b"ready");
        let mut spec=crate::Spec::command(bash.display().to_string(),vec![]);
        spec.env.push(("Path".into(),path.to_string_lossy().into_owned()));configure_spec(&mut spec).unwrap();
        assert_eq!(spec.env.iter().filter(|(k,_)|k.eq_ignore_ascii_case("PATH")).count(),1);
        assert!(spec.env[0].1.replace('\\',"/").contains("usr/bin"));
        assert!(git_shell_path(OsStr::new("cmd.exe"),Some(&path)).unwrap().is_none());
        assert!(git_shell_path(OsStr::new("bash.exe"),Some(&path)).unwrap().is_none());
    }
}
