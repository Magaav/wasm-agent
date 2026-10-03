//! Durable acknowledgement is not an installation result. Legacy requests retain legacy behavior.
use super::*;

pub(crate) fn reserved(id: &str) -> bool {
    !id.is_empty() && id.bytes().all(|b|b.is_ascii_alphanumeric() || b==b'-') && sentinel_dir().join("deploy-protocol").join(id).join("intent.json").exists()
}
pub(crate) fn fence(request: &Value,id: &str) -> Result<()> {
    if reserved(id) {
        let original:Value=serde_json::from_slice(&std::fs::read(sentinel_dir().join("deploy-protocol").join(id).join("intent.json"))?)?;
        if original != *request { bail!("immutable_intent_mismatch"); }
    }
    Ok(())
}
pub(crate) fn validate(request: &Value, id: &str) -> Result<()> {
    fence(request,id)?;
    if request.get("expected_sha").is_none() { return Ok(()); }
    let sha = request["expected_sha"].as_str().unwrap_or("");
    if request["verb"] != "deploy" || sha.len() != 40 || !sha.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("expected_sha requires deploy and a full 40-character source SHA");
    }
    if request["id"].as_str() != Some(id) { bail!("request id does not match durable filename"); }
    if request["queued_at"].as_u64().filter(|n| *n > 0).is_none() { bail!("missing queued_at"); }
    if request["queued_at"].as_u64().unwrap_or(0) > now_epoch() { bail!("future_queued_at"); }
    if request["session"].as_str().unwrap_or("").is_empty() { bail!("protocol deploy requires parent session"); }
    if request.get("owner").is_some() && request["owner"].as_str().filter(|s|!s.is_empty()).is_none() { bail!("invalid_owner_scope"); }
    for field in ["prompt","reason"] { if request.get(field).is_some() && !request[field].is_string() { bail!("invalid_text_field:{field}"); } }
    let object=request.as_object().context("request_not_object")?;
    if object.keys().any(|k| !["verb","id","expected_sha","queued_at","session","owner","prompt","reason"].contains(&k.as_str())) { bail!("unknown_intent_field"); }
    if id.is_empty() || !id.bytes().all(|b|b.is_ascii_alphanumeric() || b==b'-') { bail!("unsafe_request_id"); }
    Ok(())
}

pub(crate) fn record(request: &Value, id: &str, phase: &str, detail: &str) -> Result<()> {
    if request.get("expected_sha").is_none() { return Ok(()); }
    if id.is_empty() || !id.bytes().all(|b|b.is_ascii_alphanumeric() || b == b'-') { bail!("unsafe request filename identity"); }
    let dir = sentinel_dir().join("deploy-protocol").join(id);
    std::fs::create_dir_all(&dir)?;
    let lock=std::fs::OpenOptions::new().create(true).truncate(false).read(true).write(true).open(dir.join("intake.lock"))?;
    lock.lock()?;
    // First observation remains immutable, including across watcher replacement.
    let intent = dir.join("intent.json");
    if intent.exists() {
        let original:Value=serde_json::from_slice(&std::fs::read(&intent)?)?;
        if original != *request { bail!("immutable_intent_mismatch"); }
    } else { wa_operation::atomic_json(&intent, request)?; }
    let ack = dir.join("ack.json");
    if !ack.exists() {
        wa_operation::atomic_json(&ack, &json!({"schema":1,"id":id,"expected_sha":request["expected_sha"],
            "session":request["session"],"queued_at":request["queued_at"],"phase":phase,
            "detail":detail,"at":now_epoch()}))?;
    }
    wa_operation::atomic_json(&dir.join("state.json"), &json!({"schema":1,"id":id,
        "expected_sha":request["expected_sha"],"session":request["session"],
        "queued_at":request["queued_at"],"phase":phase,"detail":detail,"at":now_epoch()}))?;
    Ok(())
}

/// Cheap durable observation. No health, source lookup or effect admission.
pub(crate) fn intake(request: &Value, id: &str) -> Result<()> {
    if request.get("expected_sha").is_none() && !reserved(id) { return Ok(()); }
    let result=validate(request,id).and_then(|_|record(request,id,"held","parent_owner_not_ready; deploy_effect_quarantined"));
    if let Err(error)=result {
        let safe=id.bytes().map(|b|format!("{b:02x}")).collect::<String>();
        let dir=sentinel_dir().join("intake-problems").join(safe);
        std::fs::create_dir_all(&dir)?;
        let evidence=json!({"id":id,"observed":request,"phase":"problem","detail":error.to_string(),"at":now_epoch()});
        let name=format!("{}-{}.json",now_epoch(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)?.as_nanos());
        wa_operation::atomic_json(&dir.join(name),&evidence)?;
        // Preserve original ack/intent. Latest problem is separately discoverable.
        wa_operation::atomic_json(&dir.join("latest.json"),&evidence)?;
        bail!("{error}");
    }
    Ok(())
}

fn git(root: &Path, args: &[&str]) -> Result<String> {
    let output = std::process::Command::new("git").arg("-C").arg(root).args(args).output()?;
    if !output.status.success() { bail!("canonical source git check failed: {}", String::from_utf8_lossy(&output.stderr)); }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Select only the configured runtime repository's PRIMARY checkout. No request-supplied path.
/// Revalidate at dispatch; deploy.sh revalidates the source SHA before building and before swapping.
pub(crate) fn canonical_script(expected: &str) -> Result<PathBuf> {
    let record = installed_binary().parent().context("install parent")?.join("runtime-worktree.txt");
    let runtime = PathBuf::from(std::fs::read_to_string(&record).context("configured runtime-worktree missing")?.trim());
    let common = PathBuf::from(git(&runtime, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?);
    let canonical = common.parent().context("canonical git parent")?;
    if canonical.join(".git").is_dir() == false { bail!("runtime shared Git has no canonical primary checkout"); }
    let canonical_common = PathBuf::from(git(canonical, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?);
    if std::fs::canonicalize(&common)? != std::fs::canonicalize(canonical_common)? { bail!("runtime root identity changed"); }
    if git(canonical, &["symbolic-ref", "--short", "HEAD"])? != "main" { bail!("canonical checkout is not main"); }
    if !git(canonical, &["status", "--porcelain"])?.is_empty() { bail!("canonical checkout is dirty"); }
    if git(canonical, &["rev-parse", "HEAD"])? != expected || git(canonical, &["rev-parse", "origin/main"])? != expected {
        bail!("canonical source is not exact expected pushed origin/main SHA");
    }
    // A local tracking ref alone is not proof that this SHA is still published.
    let published = git(canonical, &["ls-remote", "origin", "refs/heads/main"])?;
    if published.split_whitespace().next() != Some(expected) { bail!("remote main does not name expected SHA"); }
    let script = canonical.join("scripts").join("deploy.sh");
    if !script.is_file() { bail!("canonical deploy.sh missing"); }
    Ok(script)
}
