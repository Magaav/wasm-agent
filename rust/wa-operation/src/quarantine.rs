//! Operator risk acceptance for exact archived obsolete ownership, never execution settlement.
//! Trusted local authorization is explicit, item-pinned and revalidated. No age/default bypass.
use crate::error;
use ring::digest;
use serde_json::{json,Value};
use std::{fs,io,path::{Path,Component}};
pub fn hash(bytes:&[u8])->String{digest::digest(&digest::SHA256,bytes).as_ref().iter().map(|b|format!("{b:02x}")).collect()}
fn field<'a>(v:&'a Value,k:&str)->io::Result<&'a str>{v[k].as_str().filter(|s|!s.trim().is_empty()).ok_or_else(||error(format!("quarantine_{k}_required")))}
pub fn file(path:&Path)->io::Result<Vec<u8>>{
    if !fs::symlink_metadata(path)?.file_type().is_file(){return Err(error("quarantine_regular_file_required"));}
    fs::read(path)
}
pub fn validate(root:&Path,args:&Value,kind:&str,id:&str,expected:&Value)->io::Result<Value>{
    let auth_path=root.join("quarantined-retirement.json");
    let bytes=file(&auth_path)?;
    if hash(&bytes)!=field(args,"authorization_sha256")?{return Err(error("quarantine_authorization_moved"));}
    let auth:Value=serde_json::from_slice(&bytes).map_err(error)?;
    if auth["schema"]!=1 || auth["kind"]!="operator-quarantined-retirement" || auth["original_outcome"]!="unknown" ||
       auth["never_replay"]!=true || auth["risk_accepted"]!=true || auth["drain_proven"]!=false ||
       auth["effect_settlement_proven"]!=false {return Err(error("quarantine_explicit_risk_acceptance_required"));}
    field(&auth,"operator")?;field(&auth,"reason")?;
    let canonical=fs::canonicalize(root)?;
    if fs::canonicalize(field(&auth,"data_root")?)?!=canonical{return Err(error("quarantine_store_mismatch"));}
    let approval=&auth["approval"];
    if hash(&file(Path::new(field(approval,"path")?))?)!=field(approval,"sha256")?{return Err(error("quarantine_approval_evidence_moved"));}
    let items=auth["items"].as_array().filter(|v|!v.is_empty()&&v.len()<=256).ok_or_else(||error("quarantine_bounded_exact_items_required"))?;
    let matched=items.iter().filter(|v|v["kind"]==kind && v["id"]==id).collect::<Vec<_>>();
    if matched.len()!=1{return Err(error("quarantine_item_unknown_or_duplicate"));}let item=matched[0];
    if item["expected"]!=*expected{return Err(error("quarantine_expected_identity_moved"));}
    let manifest_path=Path::new(field(item,"archive_manifest")?);
    let raw=file(manifest_path)?;
    if hash(&raw)!=field(item,"archive_sha256")?{return Err(error("quarantine_archive_manifest_moved"));}
    let archive:Value=serde_json::from_slice(&raw).map_err(error)?;
    if archive["schema"]!=1 || archive["kind"]!=kind || archive["id"]!=id || archive["expected"]!=*expected{return Err(error("quarantine_archive_identity_mismatch"));}
    let parent=fs::canonicalize(manifest_path.parent().ok_or_else(||error("quarantine_archive_parent_required"))?)?;
    let files=archive["files"].as_array().filter(|v|!v.is_empty()&&v.len()<=512).ok_or_else(||error("quarantine_archive_files_required"))?;
    let mut names=std::collections::HashSet::new();
    for f in files{
        let name=field(f,"name")?;if !names.insert(name){return Err(error("quarantine_duplicate_archive_file"));}let relative=Path::new(name);
        if !relative.components().all(|p|matches!(p,Component::Normal(_))) || name.contains('\\') || name.contains(':'){return Err(error("quarantine_archive_path_unsafe"));}
        let path=parent.join(relative);
        if !fs::canonicalize(&path)?.starts_with(&parent) || hash(&file(&path)?)!=field(f,"sha256")?{return Err(error("quarantine_preserved_bytes_moved"));}
    }
    if kind=="workspace" {
        let start:Value=serde_json::from_str(field(expected,"start_state_json")?).map_err(error)?;
        if let Some(pid)=start["executor"]["process_id"].as_u64(){
            let current=crate::legacy::creation(u32::try_from(pid).map_err(error)?)?;
            if current.is_some() && (start["executor"]["creation_stamp"].as_str().is_none() || current.as_deref()==start["executor"]["creation_stamp"].as_str()){return Err(error("quarantine_workspace_original_executor_present"));}
        }
    }
    Ok(json!({"schema":1,"kind":kind,"id":id,"expected":expected,"authorization_sha256":hash(&bytes),
        "archive_manifest":manifest_path,"archive_sha256":hash(&raw),"operator":auth["operator"],
        "original_outcome":"unknown","never_replay":true,"risk_accepted":true,"drain_proven":false,"effect_settlement_proven":false,
        "files":files,"item":item}))
}
pub fn check_owner(operations:&Path,state:&Value,id:&str)->io::Result<Option<rusqlite::Connection>>{
    let pid=state["owner_process_id"].as_u64().or_else(||id.split('-').nth(2)?.parse().ok()).ok_or_else(||error("quarantine_original_pid_missing"))?;
    let pid=u32::try_from(pid).map_err(error)?;
    if let Some(stamp)=crate::legacy::creation(pid)?{
        let recorded=state["creation_stamp"].as_str();
        let distinct=recorded.is_some_and(|old|old!=stamp);
        // A positive newer OS creation time proves PID reuse, not original drain.
        #[cfg(windows)] let newer=id.split('-').nth(1).and_then(|s|s.parse::<u64>().ok())
            .and_then(|us|us.checked_mul(10)?.checked_add(116444736000000000))
            .zip(stamp.strip_prefix("windows-filetime:").and_then(|s|s.parse::<u64>().ok())).is_some_and(|(admitted,born)|born>admitted);
        #[cfg(not(windows))] let newer=false;
        if !distinct && !newer{return Err(error("quarantine_owner_pid_present_inspect_generation"));}
    }
    if let Some(boot)=state["owner_boot"].as_str(){
        if !boot.starts_with("boot-") || boot.len()>100 || !boot.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'-'){return Err(error("quarantine_owner_boot_invalid"));}
        let path=operations.join(format!("{boot}.lease.sqlite"));
        let lease=rusqlite::Connection::open_with_flags(path,rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE).map_err(error)?;
        lease.busy_timeout(std::time::Duration::ZERO).map_err(error)?;
        lease.execute_batch("BEGIN EXCLUSIVE").map_err(|_|error("quarantine_owner_live_or_unavailable"))?;
        Ok(Some(lease))
    }else{Ok(None)}
}
#[cfg(test)]mod tests{
 use super::*;
 #[test]fn exact_archives_and_explicit_risk_are_required(){
  let root=std::env::temp_dir().join(format!("wa-quarantine-{}-{}",std::process::id(),crate::SEQUENCE.fetch_add(1,std::sync::atomic::Ordering::Relaxed)));fs::create_dir_all(root.join("archive")).unwrap();
  fs::write(root.join("approval"),"operator approved exact risk disposition").unwrap();fs::write(root.join("archive/original"),"unknown original").unwrap();let expected=json!({"owner":"old"});
  let manifest=json!({"schema":1,"kind":"test","id":"old","expected":expected,"files":[{"name":"original","sha256":hash(b"unknown original")}]});let raw=manifest.to_string();fs::write(root.join("archive/manifest.json"),&raw).unwrap();
  let mut auth=json!({"schema":1,"kind":"operator-quarantined-retirement","data_root":root,"operator":"human","reason":"retire obsolete ownership","approval":{"path":root.join("approval"),"sha256":hash(b"operator approved exact risk disposition")},"risk_accepted":true,"original_outcome":"unknown","never_replay":true,"drain_proven":false,"effect_settlement_proven":false,"items":[{"kind":"test","id":"old","expected":expected,"archive_manifest":root.join("archive/manifest.json"),"archive_sha256":hash(raw.as_bytes())}]});
  fs::write(root.join("quarantined-retirement.json"),auth.to_string()).unwrap();let args=json!({"authorization_sha256":hash(auth.to_string().as_bytes())});
  assert!(check_owner(&root,&json!({"owner_process_id":std::process::id()}),"op-fixture-999999999-0").is_err());
  assert!(validate(&root,&args,"test","old",&expected).is_ok());assert!(validate(&root,&args,"test","other",&expected).is_err());assert!(validate(&root,&args,"test","old",&json!({"owner":"changed"})).is_err());
  fs::write(root.join("archive/original"),"moved").unwrap();assert!(validate(&root,&args,"test","old",&expected).is_err());fs::write(root.join("archive/original"),"unknown original").unwrap();
  auth["risk_accepted"]=json!(false);fs::write(root.join("quarantined-retirement.json"),auth.to_string()).unwrap();let args=json!({"authorization_sha256":hash(auth.to_string().as_bytes())});assert!(validate(&root,&args,"test","old",&expected).is_err());
  fs::remove_dir_all(root).unwrap();
 }
}
