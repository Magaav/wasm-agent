//! Portable literal search. Every omission is counted; no shell fallback or regex pretense.
use serde_json::{json, Value};
use std::{collections::BTreeMap, fs, path::PathBuf};
pub fn search(pattern: &str, path: &str, options: &Value) -> Value {
    let ignore_case=options["ignore_case"].as_bool().unwrap_or(true);
    let limit=options["limit"].as_u64().unwrap_or(100).clamp(1,500) as usize;
    let max_depth=options["max_depth"].as_u64().unwrap_or(12).min(64) as usize;
    let extensions: Vec<&str>=options["extensions"].as_array().map(|a|a.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
    let needle=if ignore_case {pattern.to_lowercase()} else {pattern.to_owned()};
    let mut matches=vec![];let mut stack=vec![(PathBuf::from(path),0)];
    let mut skipped:BTreeMap<&str,usize>=BTreeMap::new();let mut scanned=0usize;let mut visited=0usize;
    let mut stop=None;
    while let Some((file,depth))=stack.pop() {
        visited+=1;
        if visited>20000 {stop=Some("entry_budget");break;}
        let metadata=match fs::symlink_metadata(&file) {Ok(m)=>m,Err(_)=>{*skipped.entry("metadata_error").or_default()+=1;continue;}};
        if metadata.file_type().is_symlink() {*skipped.entry("symlink").or_default()+=1;continue;}
        if metadata.is_dir() {
            if depth>max_depth {*skipped.entry("depth_limit").or_default()+=1;continue;}
            let entries=match fs::read_dir(&file) {Ok(e)=>e,Err(_)=>{*skipped.entry("directory_error").or_default()+=1;continue;}};
            let mut children=vec![];
            for entry in entries {
                match entry {
                    Ok(e)=>{
                        if [".git","target","node_modules",".wasm-agent"].contains(&e.file_name().to_string_lossy().as_ref()) {
                            *skipped.entry("excluded_name").or_default()+=1;
                        } else {children.push(e.path());}
                    },
                    Err(_)=>{*skipped.entry("directory_entry_error").or_default()+=1;}
                }
                if children.len()>20000 {stop=Some("directory_budget");break;}
            }
            if stop.is_some(){break;}
            children.sort();
            stack.extend(children.into_iter().rev().map(|p|(p,depth+1)));
            continue;
        }
        if !metadata.is_file(){*skipped.entry("not_regular_file").or_default()+=1;continue;}
        if !extensions.is_empty() && !extensions.contains(&file.extension().and_then(|s|s.to_str()).unwrap_or("")) {
            *skipped.entry("extension_filter").or_default()+=1;continue;
        }
        if metadata.len()>4*1024*1024 {*skipped.entry("size_limit").or_default()+=1;continue;}
        // Take a bounded snapshot even if a file grows after metadata was read.
        use std::io::Read;
        let bytes=match fs::File::open(&file).and_then(|f|{let mut b=vec![];f.take(4*1024*1024+1).read_to_end(&mut b)?;Ok(b)}) {
            Ok(b)=>b,Err(_)=>{*skipped.entry("read_error").or_default()+=1;continue;}
        };
        if bytes.len()>4*1024*1024 {*skipped.entry("size_limit").or_default()+=1;continue;}
        let text=match String::from_utf8(bytes) {Ok(t)=>t,Err(_)=>{*skipped.entry("non_utf8").or_default()+=1;continue;}};
        scanned+=1;
        for (index,line) in text.lines().enumerate() {
            let haystack=if ignore_case{line.to_lowercase()}else{line.to_owned()};
            if haystack.contains(&needle) {
                if matches.len()==limit {stop=Some("result_limit");break;}
                let chars=line.chars().count();
                matches.push(json!({"file":file.to_string_lossy(),"line":index+1,
                    "text":line.chars().take(400).collect::<String>(),"text_truncated":chars>400,"line_chars":chars}));
            }
        }
        if stop.is_some(){break;}
    }
    let complete=stop.is_none() && skipped.is_empty();
    json!({"matches":matches,"count":matches.len(),"literal":true,"ignore_case":ignore_case,
        "complete":complete,"truncated":stop.is_some(),"stop_reason":stop,"skipped":skipped,
        "files_scanned":scanned,"max_depth":max_depth,"limit":limit,
        "note":"Paths use the supplied root. Line text may be clipped; use read for exact evidence. No filesystem-wide snapshot."})
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn literal_filters_and_completeness() {
        let root=std::env::temp_dir().join(format!("wa-grep-{}-{}",std::process::id(),std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        fs::create_dir_all(root.join("deep/more")).unwrap();
        fs::write(root.join("a.rs"),"Needle\nneedle.*\nneedle\n").unwrap();
        fs::write(root.join("b.lua"),"needle").unwrap();
        let p=root.to_str().unwrap();
        let r=search("needle.*",p,&json!({"ignore_case":false}));assert_eq!(r["count"],1);assert_eq!(r["complete"],true);
        let r=search("needle",p,&json!({"limit":1}));assert_eq!(r["count"],1);assert_eq!(r["stop_reason"],"result_limit");
        let r=search("Needle",p,&json!({"ignore_case":false,"extensions":["rs"]}));assert_eq!(r["count"],1);assert_eq!(r["skipped"]["extension_filter"],1);
        let r=search("needle",p,&json!({"max_depth":0}));assert_eq!(r["skipped"]["depth_limit"],1);assert_eq!(r["count"],4);
        fs::write(root.join("long"),"x".repeat(500)).unwrap();let r=search("xxx",root.join("long").to_str().unwrap(),&json!({}));assert_eq!(r["matches"][0]["text_truncated"],true);
        fs::remove_dir_all(root).unwrap();
    }
}
