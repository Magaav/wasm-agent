//! Captured content revisions and atomic affected-file/relationship publication.
use crate::store::{Store,Result,IndexReport,sha256,collect_files_progress,relative,EXTRACT_VERSION};
use crate::extract;
use rusqlite::{params,OptionalExtension};
use std::collections::{BTreeMap,BTreeSet};
use std::path::{Path,PathBuf};
#[derive(Clone)]
pub struct Manifest {pub root:PathBuf,pub files:BTreeMap<String,Vec<u8>>,pub fingerprint:String,pub skipped_non_utf8:Vec<String>}
impl Manifest {
 pub fn capture(root:&Path,progress:&mut impl FnMut(&str,usize))->Result<Self>{Self::capture_until(root,None,progress)}
 pub fn capture_until(root:&Path,deadline:Option<std::time::Instant>,progress:&mut impl FnMut(&str,usize))->Result<Self>{
  let root=root.canonicalize()?;let mut files=BTreeMap::new();let mut skipped_non_utf8=Vec::new();
  for (n,path) in collect_files_progress(&root,deadline,progress)?.iter().enumerate(){
   if deadline.map_or(false,|end|std::time::Instant::now()>=end){return Err("graph_capture_timeout".into());}
   let bytes=std::fs::read(path)?;let name=relative(&root,path);if std::str::from_utf8(&bytes).is_ok(){files.insert(name,bytes);}else{skipped_non_utf8.push(name);}progress("hashing",n+1);
  }
  let mut identity=Vec::new();identity.extend_from_slice(root.to_string_lossy().as_bytes());identity.push(0);identity.extend_from_slice(EXTRACT_VERSION.as_bytes());
  for (name,bytes) in &files{identity.extend_from_slice(name.as_bytes());identity.push(0);identity.extend_from_slice(sha256(bytes).as_bytes());identity.push(b'\n');}
  identity.extend_from_slice(&serde_json::to_vec(&skipped_non_utf8)?);
  Ok(Self{root,files,fingerprint:sha256(&identity),skipped_non_utf8})
 }
}
impl Store {
 pub fn matches_manifest(&self,manifest:&Manifest)->Result<bool>{
  let root:Option<String>=self.conn.query_row("SELECT value FROM graph_meta WHERE key='root'",[],|r|r.get(0)).optional()?;
  if root.as_deref()!=Some(manifest.root.to_string_lossy().as_ref()){return Ok(false);}
  let mut sources=BTreeMap::new();let mut stmt=self.conn.prepare("SELECT path,source FROM graph_sources")?;
  for row in stmt.query_map([],|r|Ok((r.get::<_,String>(0)?,r.get::<_,Vec<u8>>(1)?)))?{let (path,bytes)=row?;sources.insert(path,bytes);}
  Ok(sources==manifest.files)
 }
 pub fn committed_revision(&self)->Result<u64>{
  let exists:i64=self.conn.query_row("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='graph_meta'",[],|r|r.get(0))?;if exists==0{return Ok(0);}
  let value:Option<String>=self.conn.query_row("SELECT value FROM graph_meta WHERE key='committed_revision'",[],|r|r.get(0)).optional()?;
  match value{None=>Ok(0),Some(value)=>value.parse().map_err(|_|"graph_committed_revision_invalid".into())}
 }
 pub fn manifest_fingerprint(&self)->Result<Option<String>>{
  let exists:i64=self.conn.query_row("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='graph_meta'",[],|r|r.get(0))?;if exists==0{return Ok(None);}
  Ok(self.conn.query_row("SELECT value FROM graph_meta WHERE key='manifest'",[],|r|r.get(0)).optional()?)}
 pub fn index_manifest(&mut self,manifest:&Manifest,force:bool,revision:u64,progress:&mut impl FnMut(&str,usize))->Result<IndexReport>{
  let base=(self.generation()?,self.manifest_fingerprint()?,self.committed_revision()?);let mut prepared=Vec::new();let mut report=IndexReport::default();
  if revision<=base.2{return Err("graph_index_revision_conflict".into());}
  for (path,bytes) in &manifest.files{
   let hash=format!("{EXTRACT_VERSION}:{}",sha256(bytes));
   let same=self.file_stamp(path)?.map(|old|old.0==hash&&old.3==*bytes).unwrap_or(false);
   if !force&&same{report.unchanged+=1;continue;}
   let lang=extract::language_for(path).ok_or("unsupported_graph_source")?;
   let source=std::str::from_utf8(bytes)?;prepared.push((path.clone(),lang.to_string(),extract::extract_progress(path,lang,source,progress).map_err(|e|format!("{e}"))?,hash,bytes));progress("parsing",prepared.len());
  }
  let removed:Vec<_>=self.all_file_paths()?.into_iter().filter(|p|!manifest.files.contains_key(p)).collect();
  self.conn.execute_batch("BEGIN IMMEDIATE")?;
  let outcome=(||->Result<IndexReport>{
   if (self.generation()?,self.manifest_fingerprint()?,self.committed_revision()?)!=base{return Err("graph_index_commit_conflict".into());}
   self.conn.execute_batch("CREATE TEMP TABLE IF NOT EXISTS affected_edges(id INTEGER PRIMARY KEY);DELETE FROM affected_edges;")?;
   let mut names=BTreeSet::new();let mut aliases=BTreeSet::new();
   for path in prepared.iter().map(|p|&p.0).chain(removed.iter()){
    // Import resolution also depends on the existence of the target file, even
    // when its public definition names did not change.
    let mut stmt=self.conn.prepare("SELECT e.id FROM edges e JOIN imports i ON i.path=e.path AND i.alias=e.receiver WHERE i.module=?1 OR i.module=?2 OR i.module LIKE ?3")?;
    let stem=std::path::Path::new(path).file_stem().unwrap_or_default().to_string_lossy();
    let ids=stmt.query_map(params![path,stem.as_ref(),format!("%/{path}")],|r|r.get::<_,i64>(0))?.collect::<std::result::Result<Vec<_>,_>>()?;
    for id in ids{self.conn.execute("INSERT OR IGNORE INTO affected_edges VALUES(?1)",params![id])?;}
    names.insert(stem.into_owned());
    let mut stmt=self.conn.prepare("SELECT name FROM nodes WHERE path=?1")?;
    for value in stmt.query_map(params![path],|r|r.get::<_,String>(0))?{names.insert(extract::simple_name(&value?).to_string());}
    let mut stmt=self.conn.prepare("SELECT alias FROM imports WHERE path=?1")?;
    for value in stmt.query_map(params![path],|r|r.get::<_,String>(0))?{aliases.insert(value?);}
    self.conn.execute("INSERT OR IGNORE INTO affected_edges SELECT id FROM edges WHERE path=?1 OR dst IN(SELECT id FROM nodes WHERE path=?1)",params![path])?;
   }
   for path in &removed{self.remove_file(path)?;report.removed+=1;}
   for (path,lang,ex,hash,bytes) in &prepared{
    self.remove_file(path)?;self.insert_extract(path,lang,ex,hash.clone(),0,bytes.len() as i64,bytes)?;
    for node in &ex.nodes{names.insert(extract::simple_name(&node.name).to_string());}
    for import in &ex.imports{aliases.insert(import.alias.clone());}
    self.conn.execute("INSERT OR IGNORE INTO affected_edges SELECT id FROM edges WHERE path=?1",params![path])?;
    report.indexed+=1;report.nodes+=ex.nodes.len();report.edges+=ex.edges.len();progress("staging",report.indexed);
   }
   // Names affect both previously resolved and unresolved callers: adding an
   // alternative definition can make a unique fallback ambiguous.
   for name in &names{
    self.conn.execute("INSERT INTO edges(src,kind,target,path,line,col,dst,resolution,confidence,lookup_name,receiver) SELECT src,'mentions',target,path,line,col,NULL,'unresolved',0,lookup_name,'' FROM latent_mentions WHERE lookup_name=?1",params![name])?;
    self.conn.execute("DELETE FROM latent_mentions WHERE lookup_name=?1",params![name])?;
    self.conn.execute("INSERT OR IGNORE INTO affected_edges SELECT id FROM edges WHERE lookup_name=?1",params![name])?;
   }
   for alias in &aliases{self.conn.execute("INSERT OR IGNORE INTO affected_edges SELECT id FROM edges WHERE receiver=?1",params![alias])?;}
   if prepared.iter().any(|p|p.1=="go_module") || removed.iter().any(|p|p.ends_with("go.mod")) {
    self.conn.execute("INSERT OR IGNORE INTO affected_edges SELECT id FROM edges WHERE path LIKE '%.go'",[])?;
   }
   self.conn.execute_batch("UPDATE edges SET dst=NULL,resolution='unresolved',confidence=0 WHERE id IN(SELECT id FROM affected_edges)")?;
   let (resolved,unresolved,examined)=self.resolve_affected(progress)?;report.resolved=resolved;report.unresolved=unresolved;report.re_resolved=examined;
   let generation=self.compute_generation()?;
   for (key,value) in [("root",manifest.root.to_string_lossy().into_owned()),("generation",generation),("manifest",manifest.fingerprint.clone()),("skipped_non_utf8",serde_json::to_string(&manifest.skipped_non_utf8)?),("committed_revision",revision.max(self.committed_revision()?).to_string())]{self.conn.execute("INSERT OR REPLACE INTO graph_meta(key,value) VALUES(?1,?2)",params![key,value])?;}
   Ok(report)
  })();
  match outcome{Ok(report)=>{self.conn.execute_batch("COMMIT")?;progress("committed",report.indexed+report.removed);Ok(report)},Err(error)=>{let _=self.conn.execute_batch("ROLLBACK");Err(error)}}
 }
}
