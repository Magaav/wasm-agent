//! Compatibility watcher handle backed by the process-wide root-isolated coordinator.
//! One OS event backend and one indexing worker; events are hints, never freshness proof.
use std::path::PathBuf;
pub struct WatchHandle { root:PathBuf }
impl WatchHandle {pub fn stop(&self){crate::coordinator::shared().stop_watch(&self.root);}}
impl Drop for WatchHandle {fn drop(&mut self){self.stop();}}
pub fn spawn(root:PathBuf,db:PathBuf)->std::io::Result<WatchHandle>{
 crate::coordinator::shared().notify(&root,&db).map_err(std::io::Error::other)?;
 Ok(WatchHandle{root})
}
/// Unsupported file events and our own DB/build writes cannot create a refresh loop.
pub(crate) fn ignored(event:&notify::Event)->bool{
 if matches!(event.kind,notify::EventKind::Access(_)){return true;}
 // Empty paths represent overflow/rescan hints and must reconcile every registered root.
 if event.paths.is_empty(){return false;}
 event.paths.iter().all(|path|{
  let text=path.to_string_lossy().replace('\\',"/");
  text.split('/').any(|part|matches!(part,".git"|"target"|".wa-graph"|"node_modules"|"releases"|".orca-worktree-trash")) ||
  (!path.is_dir() && crate::extract::language_for(&text).is_none() && !matches!(event.kind,notify::EventKind::Remove(notify::event::RemoveKind::Folder)|notify::EventKind::Modify(notify::event::ModifyKind::Name(_))|notify::EventKind::Create(notify::event::CreateKind::Folder)))
 })
}
