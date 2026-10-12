//! Causal regressions for affected-only resolution, frozen snapshots and failure visibility.
use super::*;
use crate::incremental::Manifest;
use std::time::SystemTime;
struct Fixture{root:PathBuf,db:PathBuf}
impl Fixture{
 fn new(label:&str)->Self{let id=SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap().as_nanos();let base=std::env::temp_dir().join(format!("graph-managed-{label}-{}-{id}",std::process::id()));let root=base.join("source");std::fs::create_dir_all(&root).unwrap();Self{db:base.join("graph.db"),root}}
 fn write(&self,path:&str,text:&str){let path=self.root.join(path);std::fs::create_dir_all(path.parent().unwrap()).unwrap();std::fs::write(path,text).unwrap();}
 fn entry(&self)->Arc<Entry>{shared().entry(&self.root,&self.db).unwrap()}
 fn admit(&self,entry:&Arc<Entry>)->u64{shared().admit(entry,false,&mut |_,_|{}).unwrap()}
 fn snapshot(&self,entry:&Arc<Entry>,revision:u64)->(Store,Value){entry.snapshot(revision,Instant::now()+Duration::from_secs(10),&mut |_|{}).unwrap()}
}
impl Drop for Fixture{fn drop(&mut self){shared().stop_watch(&self.root);let _=std::fs::remove_dir_all(self.root.parent().unwrap());}}
fn canonical(store:&Store)->Vec<String>{
 let mut stmt=store.conn.prepare("SELECT s.name,s.path,s.line,e.kind,e.target,e.path,e.line,COALESCE(d.name,''),COALESCE(d.path,''),COALESCE(d.line,0),e.resolution,e.confidence FROM edges e JOIN nodes s ON e.src=s.id LEFT JOIN nodes d ON e.dst=d.id ORDER BY s.path,s.line,e.kind,e.target,e.path,e.line,d.path,d.line").unwrap();
 stmt.query_map([],|row|Ok(format!("{:?}",(row.get::<_,String>(0)?,row.get::<_,String>(1)?,row.get::<_,i64>(2)?,row.get::<_,String>(3)?,row.get::<_,String>(4)?,row.get::<_,String>(5)?,row.get::<_,i64>(6)?,row.get::<_,String>(7)?,row.get::<_,String>(8)?,row.get::<_,i64>(9)?,row.get::<_,String>(10)?,row.get::<_,i64>(11)?)))).unwrap().collect::<Result<Vec<_>,_>>().unwrap()
}
fn parity(f:&Fixture,incremental:&Store){let mut full=Store::open(f.db.with_extension("full.db")).unwrap();full.index(&f.root,true).unwrap();assert_eq!(canonical(incremental),canonical(&full),"incremental must match a full rebuild");}
#[test]
fn affected_edges_include_unchanged_callers_ambiguity_aliases_and_latent_docs(){
 let f=Fixture::new("resolution");f.write("consumer/caller.lua","function caller() target() end\n");f.write("consumer/import.lua","local P=require('provider')\nfunction imported() P.perform() end\n");f.write("readme.md","`target` and `M.perform`\n");
 let mut store=Store::open(&f.db).unwrap();store.index(&f.root,false).unwrap();assert!(store.path("caller","target").unwrap().is_none());
 f.write("lib/target.lua","function target() return 1 end\n");let r=store.index(&f.root,false).unwrap();assert_eq!(r.indexed,1);assert!(r.re_resolved>0);assert!(store.path("caller","target").unwrap().is_some());parity(&f,&store);
 f.write("other/target.lua","function target() return 2 end\n");store.index(&f.root,false).unwrap();assert!(store.path("caller","target").unwrap().is_none(),"new ambiguity must invalidate an unedited caller");parity(&f,&store);
 std::fs::remove_file(f.root.join("other/target.lua")).unwrap();store.index(&f.root,false).unwrap();assert!(store.path("caller","target").unwrap().is_some());parity(&f,&store);
 f.write("provider.lua","local M={}\nfunction M.perform() return 1 end\nreturn M\n");store.index(&f.root,false).unwrap();assert!(store.path("imported","M.perform").unwrap().is_some());parity(&f,&store);
 f.write("consumer/import.lua","local P=require('replacement')\nfunction imported() P.perform() end\n");f.write("replacement.lua","local M={}\nfunction M.perform() return 2 end\nreturn M\n");store.index(&f.root,false).unwrap();let path=store.path("imported","M.perform").unwrap().unwrap();assert_eq!(path.last().unwrap().0.path,"replacement.lua");parity(&f,&store);
 std::fs::rename(f.root.join("replacement.lua"),f.root.join("renamed.lua")).unwrap();store.index(&f.root,false).unwrap();parity(&f,&store);
 let warm=store.index(&f.root,false).unwrap();assert_eq!((warm.indexed,warm.re_resolved),(0,0));
}
#[test]
fn body_only_edit_resolves_a_subset_not_the_whole_graph(){
 let f=Fixture::new("subset");for n in 0..24{f.write(&format!("part{n}.lua"),&format!("function own{n}() return 1 end\nfunction use{n}() own{n}() end\n"));}
 let mut store=Store::open(&f.db).unwrap();store.index(&f.root,false).unwrap();let all=store.stats().unwrap().edges;
 f.write("part0.lua","function own0() return 2 end\nfunction use0() own0() end\n");let r=store.index(&f.root,false).unwrap();assert_eq!(r.indexed,1);assert!(r.re_resolved>0 && (r.re_resolved as i64)<all);parity(&f,&store);
}
#[test]
fn restored_timestamp_and_event_loss_are_reconciled_from_bytes(){
 let f=Fixture::new("event-loss");f.write("a.lua","function before() return 1 end\n");let entry=f.entry();let first=f.admit(&entry);let (old,_)=f.snapshot(&entry,first);old.end_read().unwrap();shared().stop_watch(&f.root);
 let file=f.root.join("a.lua");let time=std::fs::metadata(&file).unwrap().modified().unwrap();std::fs::write(&file,"function afterx() return 2 end\n").unwrap();std::fs::OpenOptions::new().read(true).write(true).open(&file).unwrap().set_modified(time).unwrap();assert_eq!(std::fs::metadata(&file).unwrap().modified().unwrap(),time);
 let revision=f.admit(&entry);assert!(revision>first);let (new,meta)=f.snapshot(&entry,revision);assert!(new.query("afterx",10).unwrap().iter().any(|n|n.name=="afterx"));assert_eq!(meta["required_revision"],revision);new.end_read().unwrap();
 f.write("added.js","function added() {}\n");std::fs::write(f.root.join("non-utf8.lua"),[255,254,0,0]).unwrap();std::fs::remove_file(file).unwrap();let revision=f.admit(&entry);let (new,meta)=f.snapshot(&entry,revision);assert_eq!(meta["capture_domain"],"supported_utf8_sources");assert_eq!(meta["skipped_non_utf8"][0],"non-utf8.lua");assert!(new.query("before",10).unwrap().is_empty());assert!(!new.query("added",10).unwrap().is_empty());new.end_read().unwrap();
}
#[test]
fn an_expired_waiter_does_not_cancel_work_or_fake_progress(){
 let f=Fixture::new("timeout");f.write("a.lua","function pending() return 1 end\n");let entry=f.entry();shared().stop_watch(&f.root);
 let publication=entry.publication.lock().unwrap();let revision=f.admit(&entry);let mut beats=0;
 let error=match entry.snapshot(revision,Instant::now()+Duration::from_millis(10),&mut |_|beats+=1){Err(error)=>error,Ok(_)=>panic!("read escaped blocked publication")};
 assert_eq!(error["error"],"graph_wait_timeout");assert_eq!(error["required_revision"],revision);assert_eq!(beats,0,"a quiet queue/blocked worker is not progress");assert_eq!(entry.status()["committed_revision"],0);
 // Change the live source without any hint after admission: the required revision stays frozen.
 f.write("a.lua","function laterxx() return 2 end\n");drop(publication);
 let (snapshot,meta)=f.snapshot(&entry,revision);assert_eq!(meta["required_revision"],revision);assert!(snapshot.query("pending",10).unwrap().iter().any(|n|n.name=="pending"));snapshot.end_read().unwrap();
 let next=f.admit(&entry);assert!(next>revision);let (snapshot,_)=f.snapshot(&entry,next);assert!(!snapshot.query("laterxx",10).unwrap().is_empty());snapshot.end_read().unwrap();
}
#[test]
fn worker_failure_is_explicit_and_force_retry_recovers(){
 let mut f=Fixture::new("failure");f.write("a.lua","function safe() end\n");let blocker=f.root.parent().unwrap().join("not-directory");std::fs::write(&blocker,"blocker").unwrap();f.db=blocker.join("graph.db");let entry=f.entry();shared().stop_watch(&f.root);let revision=f.admit(&entry);
 let error=match entry.snapshot(revision,Instant::now()+Duration::from_secs(10),&mut |_|{}){Err(error)=>error,Ok(_)=>panic!("failed worker returned source")};assert!(error["error"].as_str().unwrap().starts_with("graph_index_failed"),"{error}");assert_eq!(error["committed_revision"],0);assert!(error["next"].as_str().unwrap().contains("read/grep"));
 std::fs::remove_file(&blocker).unwrap();std::fs::create_dir(&blocker).unwrap();let retry=shared().admit(&entry,true,&mut |_,_|{}).unwrap();assert!(retry>revision);let (snapshot,_)=f.snapshot(&entry,retry);assert!(!snapshot.query("safe",10).unwrap().is_empty());snapshot.end_read().unwrap();
}
#[test]
fn roots_and_committed_read_transactions_remain_isolated(){
 let a=Fixture::new("root-a");let b=Fixture::new("root-b");a.write("a.lua","function first() end\n");b.write("b.lua","function foreign() end\n");let ea=a.entry();let eb=b.entry();shared().stop_watch(&a.root);shared().stop_watch(&b.root);
 let ra=a.admit(&ea);let rb=b.admit(&eb);let (old,_)=a.snapshot(&ea,ra);let (other,_)=b.snapshot(&eb,rb);assert!(old.query("foreign",10).unwrap().is_empty());assert!(other.query("first",10).unwrap().is_empty());other.end_read().unwrap();
 a.write("a.lua","function newer() end\n");let next=a.admit(&ea);let (new,_)=a.snapshot(&ea,next);assert!(!new.query("newer",10).unwrap().is_empty());assert!(!old.query("first",10).unwrap().is_empty());assert!(old.query("newer",10).unwrap().is_empty(),"old reader sees no partial/new commit");old.end_read().unwrap();new.end_read().unwrap();assert_eq!(eb.status()["workspace_revision"],rb);
}
#[test]
fn hints_coalesce_and_a_captured_manifest_is_published_atomically(){
 let f=Fixture::new("coalesce");f.write("a.lua","function initial() end\n");let entry=f.entry();shared().stop_watch(&f.root);
 let capture=entry.capture.lock().unwrap();for n in 0..30{f.write("a.lua",&format!("function final{n}() end\n"));shared().notify(&f.root,&f.db).unwrap();}drop(capture);
 let required=f.admit(&entry);let (snapshot,meta)=f.snapshot(&entry,required);assert!(!snapshot.query("final29",10).unwrap().is_empty());assert_eq!(meta["work"]["parsed"],1);snapshot.end_read().unwrap();
 let manifest=Manifest::capture(&f.root,&mut |_,_|{}).unwrap();assert!(Store::open_readonly(&f.db).unwrap().matches_manifest(&manifest).unwrap());
}
#[test]
fn dependency_lookup_names_are_literal_and_repeated_callers_keep_provenance(){
 let f=Fixture::new("literal-lookup");f.write("provider.lua","local M={}\nfunction M.sendXtool() return 1 end\nreturn M\n");f.write("caller.lua","local P=require('provider')\nfunction caller() P.send_tool(); P.send_tool() end\n");
 let mut store=Store::open(&f.db).unwrap();store.index(&f.root,false).unwrap();assert!(store.path("caller","M.sendXtool").unwrap().is_none(),"underscore is not a wildcard dependency key");
 f.write("provider.lua","local M={}\nfunction M.send_tool() return 2 end\nreturn M\n");let report=store.index(&f.root,false).unwrap();assert!(report.re_resolved>=2);let rows=store.explain("M.send_tool").unwrap();assert_eq!(rows[0].2.iter().filter(|edge|edge.kind=="calls"&&edge.resolution=="import_exact").count(),2,"memoization retains both distinct call sites");parity(&f,&store);
}
#[test]
fn deep_unicode_cache_paths_preserve_sqlite_locking_and_read_only_snapshots(){
 let f=Fixture::new("long-cache");f.write("a.lua","function exact() end\n");
 let mut dir=f.root.parent().unwrap().join("long-cache");for _ in 0..4{dir=dir.join("segment-".repeat(12));}
 let db=dir.join("graph-λ.db");assert!(db.to_string_lossy().len()>400);
 let mut writer=Store::open(&db).unwrap();writer.index(&f.root,false).unwrap();
 let reader=Store::open_readonly(&db).unwrap();reader.begin_read().unwrap();assert!(!reader.query("exact",10).unwrap().is_empty());
 assert!(reader.conn.execute("DELETE FROM nodes",[]).is_err(),"long-path support must not grant write flags");
 f.write("a.lua","function newer() end\n");writer.index(&f.root,false).unwrap();assert!(!reader.query("exact",10).unwrap().is_empty());assert!(reader.query("newer",10).unwrap().is_empty());reader.end_read().unwrap();
}
