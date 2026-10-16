//! One retained pre-Cargo failure. Not a generic "nothing installed" escape.
use super::*;
pub(super) const SOURCE:&str="acde06f016d27e4a29c644c5bea897ae53febf8c";
pub(super) const TREE:&str="336031129a33b7201d0392a3a1dd6bebdd707b3c";
pub(super) const SCRIPT:&str="c09035567018e7c92483abaaa23acb72a2d0a850eaf9b1d801e205205607033a";
pub(super) const HELPER:&str="c02c6ac9a288ab5b76b66cc86bb80ead23388cc1b5afd4e23d6cba29cad163ec";
const FAILURE:&str="native code-mode shipping build/readiness failed; nothing installed";
const ERROR:&str="Error: codemode_build:ripgrep_unavailable:prepare_offline_before_build";

pub(super) fn source(root:&Path,intent:&Value,effect:&Value)->Result<Vec<u8>> {
    if intent["expected_sha"]!=SOURCE || effect["tree"]!=TREE || effect["script_sha256"]!=SCRIPT
        || git(root,&["rev-parse",&format!("{SOURCE}^{{tree}}")])?!=TREE {bail!("preinstall_codemode_source_contract_unrecognized");}
    let raw=quiet_command("git").arg("-C").arg(root).args(["show",&format!("{SOURCE}:scripts/codemode-build.mjs")]).output()?;
    if !raw.status.success() || hex_digest(&raw.stdout)!=HELPER {bail!("preinstall_codemode_helper_identity_mismatch");}
    Ok(raw.stdout)
}

pub(super) fn generation(intent:&Value,effect:&Value,active:&Value,binding:&Value,state:&Value,node:&Value,target:u32,created:Option<u64>,binary_hash:&str)->Result<()> {
    if intent["owner"].as_str().is_none_or(|s|s.is_empty()) || intent["session"].as_str().is_none_or(|s|s.is_empty())
        || !same_effect(active,effect) || active["phase"]!="admitted" || effect["phase"]!="admitted"
        || effect["id"]!=intent["id"] || effect["expected_sha"]!=intent["expected_sha"]
        || effect["owner"]!=intent["owner"] || effect["parent"]!=intent["session"]
        || binding["owner"]!=intent["owner"] || binding["parent"]!=intent["session"]
        || state["schema"]!=1 || state["id"]!=intent["id"] || state["expected_sha"]!=intent["expected_sha"]
        || state["session"]!=intent["session"] || state["queued_at"]!=intent["queued_at"]
        || !["spawned","failed"].contains(&state["phase"].as_str().unwrap_or(""))
        || effect["at"].as_u64().zip(intent["queued_at"].as_u64()).is_none_or(|(at,queued)|at<queued)
        || effect["watcher_pid"].as_u64().is_none_or(|p|p==0)
        || created.is_none_or(|v|v==0) || effect["target_created"].as_u64()!=created
        || effect["target_pid"].as_u64()!=Some(target as u64) || node["pid"].as_u64()!=Some(target as u64)
        || node["process_start"].as_u64()!=created || node["binary_sha256"].as_str()!=Some(binary_hash)
        || binary_hash.len()!=64 || !binary_hash.bytes().all(|b|b.is_ascii_hexdigit()) {
        bail!("preinstall_codemode_generation_mismatch");
    }
    Ok(())
}

pub(super) fn capture<'a>(intent:&Value,effect:&Value,state:&Value,text:&'a str,result:&Value,exit:&Value,helper_hash:&str)->Result<&'a str> {
    if intent["expected_sha"]!=SOURCE || effect["expected_sha"]!=SOURCE || effect["tree"]!=TREE
        || effect["script_sha256"]!=SCRIPT || helper_hash!=HELPER
        || effect["owner"]!=intent["owner"] || effect["parent"]!=intent["session"] {
        bail!("preinstall_codemode_contract_unrecognized");
    }
    if result["ok"]!=false || result["request_id"]!=intent["id"] || result["expected_sha"]!=SOURCE
        || result["detail"]!=FAILURE || result["reason"]!=intent["reason"]
        || result["commit"]!=&SOURCE[..8] || result["branch"]!="main"
        || result["node_sha256"]!="" || result["sentinel_sha256"]!="" || result["watcher_pid"]!="" {
        bail!("preinstall_codemode_result_unproven");
    }
    let pid=state["detail"].as_str().and_then(|s|s.strip_prefix("pid ")).and_then(|s|s.split(',').next()).and_then(|s|s.parse::<u64>().ok()).filter(|p|*p>0).context("preinstall_codemode_pid_missing")?;
    let elapsed=exit["elapsed_ms"].as_u64().context("preinstall_codemode_elapsed_missing")?;
    if exit["schema"]!=1 || exit["id"]!=intent["id"] || exit["expected_sha"]!=SOURCE
        || !same_effect(&exit["effect"],effect) || exit["pid"].as_u64()!=Some(pid)
        || exit["exit"]["wait_ok"]!=true || exit["exit"]["success"]!=false || exit["exit"]["code"]!=1
        || exit["exit"]["status"]!="exit code: 1" || exit["effect_replayed"]!=false || exit["installation_verified"]!=false
        || exit["at"].as_u64().zip(effect["at"].as_u64()).is_none_or(|(end,start)|end<start.saturating_add(elapsed/1000)) {
        bail!("preinstall_codemode_native_exit_unproven");
    }
    let stanza=owned_preinstall_stanza(intent,effect,state,text)?;
    let header=deploy_capture_header(Path::new(effect["script"].as_str().context("preinstall_script_missing")?),intent["reason"].as_str().unwrap_or(""),"detached",effect["at"].as_u64().context("preinstall_at_missing")?);
    let start=text.find(&header).context("preinstall_codemode_header_missing")?+header.len();
    let after=&text[start+stanza.len()..];
    if !after.is_empty() && !after.starts_with("--- deploy detached at ") {bail!("preinstall_codemode_trailing_capture_unproven");}
    let ending=format!("--- deploy pid {pid} exited with exit code: 1 after {:.1}s\n",elapsed as f32/1000.0);
    let failure=format!("deploy: building\n{ERROR}\ndeploy: {FAILURE}\n{ending}");
    if !stanza.ends_with(&failure) || stanza.matches("deploy: building\n").count()!=1 || stanza.matches(ERROR).count()!=1
        || ["installing through upgrade.sh","upgrade:","deploy: the new binary answers on a scratch port","deploy: installing node","node installed,","deploy: sentinel pid","source_provenance=clean-built-by-deploy"].iter().any(|s|stanza.contains(s)) {
        bail!("preinstall_codemode_boundary_unproven");
    }
    Ok(stanza)
}

// Preserve public per-request JSON originals, including notification unknowns and
// cursors. Nothing here submits a wake, resets a cursor or repairs a journal.
pub(super) fn archive_json(dir:&Path,destination:&Path)->Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry=entry?;let name=entry.file_name();let path=entry.path();
        if path.extension().is_some_and(|e|e=="json") {
            if !entry.file_type()?.is_file() {bail!("preinstall_evidence_not_regular");}
            std::fs::copy(path,destination.join(name))?;
        }else if name=="returns" {
            if !entry.file_type()?.is_dir() {bail!("preinstall_returns_not_directory");}
            let target=destination.join("returns");std::fs::create_dir(&target)?;
            archive_json(&path,&target)?;
        }
    }
    Ok(())
}
