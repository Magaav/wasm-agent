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
    inherit_ca_bundle(&mut spec.env, &|name| std::env::var(name).ok());
    Ok(())
}

/// Hand a Node child the machine's CA bundle under the name Node actually reads.
///
/// Node ignores SSL_CERT_FILE and SSL_CERT_DIR - measured 20/11 on node 26: fetch against a
/// certificate from a private CA fails with SSL_CERT_FILE set, and succeeds when the same file is in
/// NODE_EXTRA_CA_CERTS. The MCP connector is such a child (lua/core/mcp.lua starts
/// scripts/mcp-client.mjs), so on a host whose CA lives only in that bundle every MCP call over https
/// failed while the rest of wa worked.
///
/// Node's variable is additive - it adds to Node's own bundle rather than replacing it - so a machine
/// that names its own bundle keeps the public roots too. SSL_CERT_DIR has no Node equivalent (Node has
/// no directory form), so it is deliberately not forwarded: guessing at a flag that older Node builds
/// reject would break the connector on exactly the machines that set it.
///
/// A caller that already named NODE_EXTRA_CA_CERTS keeps its value; nothing here overrides an
/// explicit decision.
fn inherit_ca_bundle(env: &mut Vec<(String, String)>, lookup: &dyn Fn(&str) -> Option<String>) {
    const NODE: &str = "NODE_EXTRA_CA_CERTS";
    const FILE: &str = "SSL_CERT_FILE";
    if env.iter().any(|(name, _)| name.eq_ignore_ascii_case(NODE)) {
        return;
    }
    if lookup(NODE).is_some_and(|value| !value.is_empty()) {
        return;
    }
    if let Some(bundle) = lookup(FILE).filter(|value| !value.is_empty()) {
        env.push((NODE.to_string(), bundle));
    }
}

#[cfg(test)]
mod ca_bundle_tests {
    use super::*;

    fn lookup<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |name| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| value.to_string())
        }
    }

    #[test]
    fn ssl_cert_file_becomes_the_childs_node_bundle() {
        let mut env = Vec::new();
        inherit_ca_bundle(&mut env, &lookup(&[("SSL_CERT_FILE", "/etc/sandbox/ca.pem")]));
        assert_eq!(env, vec![("NODE_EXTRA_CA_CERTS".to_string(), "/etc/sandbox/ca.pem".to_string())]);
    }

    #[test]
    fn a_caller_that_named_the_node_bundle_keeps_it() {
        let mut env = vec![("NODE_EXTRA_CA_CERTS".to_string(), "/caller/ca.pem".to_string())];
        inherit_ca_bundle(&mut env, &lookup(&[("SSL_CERT_FILE", "/machine/ca.pem")]));
        assert_eq!(env.len(), 1, "an explicit decision is not overridden: {env:?}");
        assert_eq!(env[0].1, "/caller/ca.pem");

        let mut env = Vec::new();
        inherit_ca_bundle(
            &mut env,
            &lookup(&[("SSL_CERT_FILE", "/machine/ca.pem"), ("NODE_EXTRA_CA_CERTS", "/process/ca.pem")]),
        );
        assert!(env.is_empty(), "nor is a value the process already carries: {env:?}");
    }

    #[test]
    fn nothing_named_nothing_added() {
        let mut env = Vec::new();
        inherit_ca_bundle(&mut env, &lookup(&[]));
        assert!(env.is_empty());
        inherit_ca_bundle(&mut env, &lookup(&[("SSL_CERT_FILE", "")]));
        assert!(env.is_empty(), "an empty value names nothing");
        inherit_ca_bundle(&mut env, &lookup(&[("SSL_CERT_DIR", "/etc/ssl/certs")]));
        assert!(env.is_empty(), "Node has no directory form, so a directory is not forwarded");
    }

    /// The property end to end, with the child a real one: node 26 refuses the scratch server's
    /// certificate with no bundle and reaches it with the variable this function produces.
    #[test]
    fn a_node_child_reaches_a_private_ca_only_with_the_forwarded_bundle() {
        let server = wa_tls::scratch::Server::start();
        let ready = std::process::Command::new("node").arg("--version").output();
        assert!(
            ready.map(|output| output.status.success()).unwrap_or(false),
            "this test needs node on PATH, as every component build in this repository does"
        );
        let script = "fetch(process.argv[1]).then(r=>r.text()).then(t=>console.log('OK '+t)).catch(e=>console.log('ERR '+e.message))";
        let mut env = Vec::new();
        inherit_ca_bundle(&mut env, &lookup(&[("SSL_CERT_FILE", &wa_tls::scratch::cert_file().display().to_string())]));
        assert_eq!(env.len(), 1, "the bundle was not forwarded: {env:?}");

        let with = std::process::Command::new("node")
            .args(["-e", script, &server.url("/")])
            .envs(env.iter().map(|(name, value)| (name.as_str(), value.as_str())))
            .output()
            .expect("a node child");
        let text = String::from_utf8_lossy(&with.stdout);
        assert!(text.starts_with("OK"), "the child given the bundle reaches a private CA: {text} {}", String::from_utf8_lossy(&with.stderr));

        let without = std::process::Command::new("node")
            .args(["-e", script, &server.url("/")])
            .output()
            .expect("a node child");
        let text = String::from_utf8_lossy(&without.stdout);
        assert!(text.starts_with("ERR"), "the same child without it does not: {text}");
    }
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
