//! Allocation-safety adjudication only. Never changes an original execution outcome.
//! Independent signed observations must bind stable OS identity, positive drain
//! and actual preserved effects. Missing provenance remains a blocker.
use crate::{error,validate_id};
use ring::{digest,signature};
use serde_json::{json,Value};
use std::{fs,io,path::Path};
pub(crate) fn hash(bytes:&[u8])->String {digest::digest(&digest::SHA256,bytes).as_ref().iter().map(|b|format!("{b:02x}")).collect()}
fn hex(value:&str)->io::Result<Vec<u8>> {if value.len()%2!=0 || value.len()>256 || !value.bytes().all(|b|b.is_ascii_hexdigit()){return Err(error("invalid_signature_hex"));} (0..value.len()).step_by(2).map(|i|u8::from_str_radix(&value[i..i+2],16).map_err(error)).collect()}
fn field<'a>(v:&'a Value,k:&str)->io::Result<&'a str>{v[k].as_str().filter(|s|!s.trim().is_empty()).ok_or_else(||error(format!("legacy_{k}_required")))}
pub(crate) fn creation(pid:u32)->io::Result<Option<String>> {
    #[cfg(windows)] {
        use windows_sys::Win32::{Foundation::{CloseHandle,GetLastError,FILETIME},System::Threading::{OpenProcess,GetProcessTimes,GetExitCodeProcess,PROCESS_QUERY_LIMITED_INFORMATION}};
        let handle=unsafe{OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,0,pid)};
        if handle.is_null(){let code=unsafe{GetLastError()};return if code==87 {Ok(None)}else{Err(io::Error::from_raw_os_error(code as i32))};}
        let mut c:FILETIME=unsafe{std::mem::zeroed()};let mut e=c;let mut k=c;let mut u=c;
        let ok=unsafe{GetProcessTimes(handle,&mut c,&mut e,&mut k,&mut u)};
        let mut exit=259;let exit_ok=unsafe{GetExitCodeProcess(handle,&mut exit)};
        let cause=io::Error::last_os_error();unsafe{CloseHandle(handle)};
        if ok==0 || exit_ok==0{return Err(cause);}if exit!=259{return Ok(None);}return Ok(Some(format!("windows-filetime:{}",((c.dwHighDateTime as u64)<<32)|c.dwLowDateTime as u64)));
    }
    #[cfg(target_os="linux")] {
        let stat=match fs::read_to_string(format!("/proc/{pid}/stat")){Ok(s)=>s,Err(e)if e.kind()==io::ErrorKind::NotFound=>return Ok(None),Err(e)=>return Err(e)};
        let ticks=stat.rsplit_once(')').and_then(|(_,rest)|rest.split_whitespace().nth(19)).ok_or_else(||error("process_creation_unverifiable"))?;
        let boot=fs::read_to_string("/proc/sys/kernel/random/boot_id")?;
        return Ok(Some(format!("linux:{}:{ticks}",boot.trim())));
    }
    #[cfg(not(any(windows,target_os="linux")))] {let _=pid;Err(error("stable_process_observation_unavailable"))}
}
fn observation(root:&Path,spec:&Value,role:&str,authority:&Value)->io::Result<(Value,Value)> {
    let path=field(spec,"path")?;let raw=fs::read(path)?;
    if hash(&raw)!=field(spec,"sha256")?{return Err(error("legacy_observation_moved"));}
    let signer=field(spec,"signer")?;
    let allowed=authority["keys"][signer]["roles"].as_array().is_some_and(|r|r.iter().any(|r|r==role));
    if !allowed{return Err(error("legacy_independent_observer_not_authorized"));}
    let public=hex(field(&authority["keys"][signer],"public_key")?)?;
    signature::UnparsedPublicKey::new(&signature::ED25519,public).verify(&raw,&hex(field(spec,"signature")?)?).map_err(|_|error("legacy_observation_signature_invalid"))?;
    // Observation files must live outside the operation directory they attest.
    if fs::canonicalize(path)?.starts_with(fs::canonicalize(root)?){return Err(error("legacy_observation_not_independently_preserved"));}
    Ok((serde_json::from_slice(&raw).map_err(error)?,json!({"path":path,"sha256":hash(&raw),"signer":signer})))
}
pub(crate) fn validate(root:&Path,args:&Value)->io::Result<Value> {
    let id=field(args,"id")?;validate_id(id)?;
    let directory=root.join(id);let raw=fs::read(directory.join("state.json"))?;
    let current:Value=serde_json::from_slice(&raw).map_err(error)?;
    if !current["owner_boot"].is_null(){return Err(error("legacy_bridge_only_for_missing_boot_identity"));}
    if hash(&raw)!=field(args,"state_sha256")? || current!=args["expected_state"]{return Err(error("legacy_original_state_moved"));}
    let originals=args["originals"].as_array().filter(|v|!v.is_empty()&&v.len()<=32).ok_or_else(||error("legacy_all_original_hashes_required"))?;
    let mut observed=Vec::new();
    for file in fs::read_dir(&directory)? {
        let file=file?;let name=file.file_name().to_string_lossy().to_string();
        if !name.starts_with("state.json.before-reconcile-"){continue;}
        let bytes=fs::read(file.path())?;
        if !originals.iter().any(|v|v["name"]==name&&v["sha256"]==hash(&bytes)){return Err(error("legacy_original_hash_mismatch_or_missing"));}
        observed.push(json!({"name":name,"sha256":hash(&bytes)}));
    }
    if observed.len()!=originals.len(){return Err(error("legacy_original_inventory_moved"));}
    observed.sort_by(|a,b|a["name"].as_str().cmp(&b["name"].as_str()));
    let originals_hash=hash(&serde_json::to_vec(&observed).map_err(error)?);
    let authority_raw=fs::read(root.join("legacy-authority.json"))?;
    let authority:Value=serde_json::from_slice(&authority_raw).map_err(error)?;
    if authority["schema"]!=1{return Err(error("legacy_authority_schema_unverifiable"));}
    let (identity,identity_fact)=observation(root,&args["identity"],"identity",&authority)?;
    let (drain,drain_fact)=observation(root,&args["drain"],"drain",&authority)?;
    let (effects,effects_fact)=observation(root,&args["effects"],"effects",&authority)?;
    let (review,review_fact)=observation(root,&args["review"],"review",&authority)?;
    if identity["kind"]!="os-process-and-containment-identity" || drain["kind"]!="os-process-exit-and-containment-drain" || effects["kind"]!="scoped-effect-preservation" || review["kind"]!="legacy-allocation-safety-review" {return Err(error("legacy_typed_observation_required"));}
    let canonical=fs::canonicalize(root)?.to_string_lossy().replace('\\',"/");
    let canonical=canonical.strip_prefix("//?/").unwrap_or(&canonical);
    let store=if cfg!(windows){canonical.to_lowercase()}else{canonical.to_string()};
    for v in [&identity,&drain,&effects,&review] {if v["operation_id"]!=id || v["state_sha256"]!=hash(&raw) || v["store_identity"]!=store || v["originals_sha256"]!=originals_hash {return Err(error("legacy_observation_operation_originals_or_store_binding_mismatch"));}}
    let pid=id.split('-').nth(2).and_then(|s|s.parse::<u32>().ok()).ok_or_else(||error("legacy_pid_not_attributable"))?;
    let stamp=field(&identity,"creation_stamp")?;
    if identity["process_id"]!=pid || drain["process_id"]!=pid || field(&drain,"creation_stamp")?!=stamp || field(&identity,"containment_identity")?!=field(&drain,"containment_identity")? || identity["binary_sha256"].as_str().is_none_or(|s|s.len()!=64) {return Err(error("legacy_stable_identity_mismatch"));}
    if hash(&fs::read(field(&identity,"binary_artifact")?)?)!=field(&identity,"binary_sha256")? {return Err(error("legacy_writer_binary_provenance_moved"));}
    if drain["wait_result"]!="signalled" || drain["contained_members_exited"]!=true || drain["handles_bound_to_creation_identity"]!=true {return Err(error("legacy_positive_containment_drain_required"));}
    if creation(pid)?.as_deref()==Some(stamp){return Err(error("legacy_owner_still_live"));}
    let scopes=effects["scopes"].as_array().filter(|v|!v.is_empty()&&v.len()<=64).ok_or_else(||error("legacy_scoped_effect_observations_required"))?;
    for scope in scopes {
        if scope["settled"]!=true || field(scope,"kind").is_err(){return Err(error("legacy_effect_scope_unresolved"));}
        let artifact=field(scope,"artifact")?;let bytes=fs::read(artifact)?;
        if hash(&bytes)!=field(scope,"sha256")?{return Err(error("legacy_effect_or_preservation_artifact_moved"));}
    }
    if effects["original_execution_outcome"]!="unknown" || effects["never_replay"]!=true || effects["quarantine_preserved"]!=true || review["verdict"]!="allocation_safe_original_unknown" || review["never_replay"]!=true {return Err(error("legacy_unknown_outcome_and_quarantine_required"));}
    let reviewer=field(&args["review"],"signer")?;
    let evidence_signers=[field(&args["identity"],"signer")?,field(&args["drain"],"signer")?,field(&args["effects"],"signer")?];
    if evidence_signers.contains(&reviewer){return Err(error("legacy_review_not_independent"));}
    // A label is not identity. Independent review needs a distinct authorized key:
    // otherwise one keypair can sign every fact under different aliases and appear
    // to be four independent observers. Reject the reviewer key matching any evidence key.
    let reviewer_key=hex(field(&authority["keys"][reviewer],"public_key")?)?;
    for signer in evidence_signers {if hex(field(&authority["keys"][signer],"public_key")?)?==reviewer_key{return Err(error("legacy_reviewer_key_not_distinct"));}}
    for (key,fact) in [("identity",&identity_fact),("drain",&drain_fact),("effects",&effects_fact)] {if review[format!("{key}_sha256")]!=fact["sha256"]{return Err(error("legacy_review_evidence_binding_mismatch"));}}
    if fs::read(directory.join("state.json"))?!=raw{return Err(error("legacy_state_moved_during_validation"));}
    Ok(json!({"schema":1,"operation_id":id,"expected":current,"state_sha256":hash(&raw),"originals":observed,"authority_sha256":hash(&authority_raw),"observations":[identity_fact,drain_fact,effects_fact,review_fact],"allocation_safe":true,"original_execution_outcome":"unknown","never_replay":true,"quarantine_preserved":true}))
}
