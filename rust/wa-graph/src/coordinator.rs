//! One deterministic worker per process, bounded root-isolated queues; no polling or inference.
//! Notifications are hints. Admission always captures content, then freezes a revision.
use notify::Watcher;
use crate::{incremental::Manifest, IndexReport, Store};
use serde_json::{json, Value};
use std::{collections::{BTreeMap, VecDeque}, path::{Path, PathBuf}, sync::{Arc, Condvar, Mutex, OnceLock}, time::{Duration, Instant}};

#[cfg(test)]
#[path="coordinator_tests.rs"]
mod tests;
const ROOT_LIMIT: usize = 32;
#[derive(Clone, Default)]
pub struct Progress { pub serial: u64, pub phase: String, pub completed: usize }
#[derive(Default)]
struct State {
    workspace: u64, committed: u64, latest: Option<Arc<Manifest>>,
    pending: Option<(u64, Arc<Manifest>, bool)>, published: Option<Arc<Manifest>>, dirty: bool, queued: bool, active: bool,
    failure: Option<(u64, String)>, progress: Progress, capture_progress:Progress, report: IndexReport, watched:bool, watch_error:Option<String>,
}
pub struct Entry {
    pub root: PathBuf, pub db: PathBuf,
    capture: Mutex<()>, publication: Mutex<()>, state: Mutex<State>, changed: Condvar,
}
struct Queue { roots: BTreeMap<(PathBuf, PathBuf), Arc<Entry>>, ready: VecDeque<Arc<Entry>> }
pub struct Coordinator { queue: Mutex<Queue>, wake: Condvar, worker_error:Mutex<Option<String>>, watcher:Mutex<Option<notify::RecommendedWatcher>> }
static INSTANCE: OnceLock<Arc<Coordinator>> = OnceLock::new();
pub fn notify_known_path(path:&Path){if let Some(manager)=INSTANCE.get(){manager.notify_path(path);}}
pub fn shared() -> &'static Arc<Coordinator> {
    INSTANCE.get_or_init(|| {
        let manager = Arc::new(Coordinator { queue: Mutex::new(Queue { roots:BTreeMap::new(), ready:VecDeque::new() }), wake:Condvar::new(), worker_error:Mutex::new(None), watcher:Mutex::new(None) });
        if std::env::var("WA_GRAPH_WATCH").map_or(true,|value|value!="0"){
            let weak=Arc::downgrade(&manager);
            match notify::recommended_watcher(move |event:notify::Result<notify::Event>|{if let Some(manager)=weak.upgrade(){manager.event(event);}}){
                Ok(watcher)=>*manager.watcher.lock().unwrap()=Some(watcher),
                Err(error)=>eprintln!("graph_watch_create_failed: {error}; content admission remains authoritative")
            }
        }
        let worker = manager.clone();
        if let Err(error)=std::thread::Builder::new().name("wa-graph-index".into()).spawn(move || {
            if std::panic::catch_unwind(std::panic::AssertUnwindSafe(||worker.run())).is_err(){
                *worker.worker_error.lock().unwrap()=Some("graph_worker_panicked_outside_task; use supported node recovery".into());
                let entries:Vec<_>={worker.queue.lock().unwrap_or_else(|e|e.into_inner()).roots.values().cloned().collect()};
                for entry in entries{let mut state=entry.state.lock().unwrap_or_else(|e|e.into_inner());state.failure=Some((state.workspace,"graph_worker_unavailable".into()));entry.changed.notify_all();}
            }
        }){*manager.worker_error.lock().unwrap()=Some(format!("graph_worker_spawn_failed:{error}"));}
        manager
    })
}
impl Coordinator {
    pub fn entry(&self, root:&Path, db:&Path) -> Result<Arc<Entry>, String> {
        let root=root.canonicalize().map_err(|e|format!("graph_root_unavailable: {e}"))?;
        let db=if db.is_absolute(){db.to_path_buf()}else{std::env::current_dir().map_err(|e|e.to_string())?.join(db)};
        let key=(root.clone(),db.clone());
        let mut retired=None;
        let mut queue=self.queue.lock().map_err(|_|"graph_queue_poisoned")?;
        if let Some(entry)=queue.roots.get(&key){return Ok(entry.clone());}
        if queue.roots.len()>=ROOT_LIMIT {
            let idle=queue.roots.iter().find_map(|(key,entry)| {
                let state=entry.state.try_lock().ok()?;
                (Arc::strong_count(entry)==1 && !state.queued && !state.active).then(||key.clone())
            });
            if let Some(key)=idle{let old=queue.roots.remove(&key).unwrap();let shared=queue.roots.values().any(|other|other.root==old.root);if !shared{retired=Some(old.root.clone());}}else{return Err("graph_root_capacity: 32 active roots; finish existing work before admitting another".into());}
        }
        let committed=if db.exists(){Store::open_readonly(&db).and_then(|store|store.committed_revision()).map_err(|e|e.to_string())?}else{0};
        let entry=Arc::new(Entry {root,db,capture:Mutex::new(()),publication:Mutex::new(()),state:Mutex::new(State{workspace:committed,committed,..State::default()}),changed:Condvar::new()});
        queue.roots.insert(key,entry.clone());drop(queue);
        if let Some(watcher)=self.watcher.lock().unwrap().as_mut(){
            if let Some(root)=retired{let _=watcher.unwatch(&root);}
            let result=watcher.watch(&entry.root,notify::RecursiveMode::Recursive);
            let mut state=entry.state.lock().unwrap();state.watched=result.is_ok();state.watch_error=result.err().map(|error|error.to_string());
            if let Some(error)=&state.watch_error{eprintln!("graph_watch_register_failed root={} error={error}; content admission remains authoritative",entry.root.display());}
        }
        Ok(entry)
    }
    fn event(&self,event:notify::Result<notify::Event>){
        if event.as_ref().map_or(false,|event|crate::watch::ignored(event)){return;}
        let normalize=|path:&Path|{let text=path.to_string_lossy().replace('\\',"/").trim_start_matches("//?/").to_string();if cfg!(windows){text.to_lowercase()}else{text}};
        let entries:Vec<_>={self.queue.lock().unwrap().roots.values().filter(|entry|{
            event.as_ref().map_or(true,|event|event.paths.is_empty() || event.paths.iter().any(|path|{let root=normalize(&entry.root);let path=normalize(path);path==root || path.starts_with(&(root+"/"))}))
        }).cloned().collect()};
        if let Err(error)=event{eprintln!("graph_watch_event_failed: {error}; reconcile registered roots");}
        for entry in entries{entry.state.lock().unwrap().dirty=true;self.enqueue(&entry);}
    }
    pub fn stop_watch(&self,root:&Path){
        let Ok(root)=root.canonicalize()else{return;};
        if let Some(watcher)=self.watcher.lock().unwrap().as_mut(){let _=watcher.unwatch(&root);}
        let entries:Vec<_>={self.queue.lock().unwrap().roots.values().filter(|entry|entry.root==root).cloned().collect()};
        for entry in entries{entry.state.lock().unwrap().watched=false;}
    }
    fn enqueue(&self, entry:&Arc<Entry>) {
        let mut state=entry.state.lock().unwrap();
        if state.queued || state.active{return;}state.queued=true;
        let mut queue=self.queue.lock().unwrap();queue.ready.push_back(entry.clone());self.wake.notify_one();
    }
    /// Cheap, nonblocking hint after successful native writes or watcher events.
    pub fn notify(&self, root:&Path, db:&Path)->Result<(),String>{
        if let Some(error)=self.worker_error.lock().map_err(|_|"graph_worker_state_poisoned")?.as_ref(){return Err(error.clone());}
        let entry=self.entry(root,db)?;entry.state.lock().unwrap().dirty=true;self.enqueue(&entry);Ok(())
    }
    pub fn notify_path(&self,path:&Path){
        if crate::extract::language_for(&path.to_string_lossy()).is_none(){return;}
        let Ok(path)=path.canonicalize()else{return;};
        let entries:Vec<_>={self.queue.lock().unwrap().roots.values().filter(|entry|path.strip_prefix(&entry.root).map_or(false,|relative|!relative.components().any(|part|matches!(part.as_os_str().to_str(),Some(".git"|"target"|"node_modules"|".wa-graph"|"releases"|".orca-worktree-trash"))))).cloned().collect()};
        for entry in entries{entry.state.lock().unwrap().dirty=true;self.enqueue(&entry);}
    }
    pub fn admit(&self, entry:&Arc<Entry>, force:bool, progress:&mut impl FnMut(&str,usize))->Result<u64,String>{self.admit_until(entry,force,None,progress)}
    pub fn admit_until(&self, entry:&Arc<Entry>, force:bool, deadline:Option<Instant>, progress:&mut impl FnMut(&str,usize))->Result<u64,String>{
        if let Some(error)=self.worker_error.lock().map_err(|_|"graph_worker_state_poisoned")?.as_ref(){return Err(error.clone());}
        let _capture=loop {
            match entry.capture.try_lock(){Ok(guard)=>break guard,Err(std::sync::TryLockError::Poisoned(_))=>return Err("graph_capture_poisoned".into()),Err(std::sync::TryLockError::WouldBlock)=>{}}
            if deadline.map_or(false,|end|Instant::now()>=end){return Err("graph_capture_wait_timeout".into());}
            std::thread::sleep(Duration::from_millis(10));
        };
        let manifest=Arc::new(Manifest::capture_until(&entry.root,deadline,&mut |phase,count|{entry.capture_progress(phase,count);progress(phase,count)}).map_err(|e|format!("graph_capture_failed: {e}"))?);
        let mut state=entry.state.lock().unwrap();
        if state.latest.is_none() && !force && entry.db.exists(){
            let cache=Store::open_readonly(&entry.db).map_err(|e|e.to_string())?;
            cache.begin_read().map_err(|e|e.to_string())?;
            let fresh=cache.manifest_fingerprint().map_err(|e|e.to_string())?.as_deref()==Some(manifest.fingerprint.as_str()) && cache.matches_manifest(&manifest).map_err(|e|e.to_string())?;
            if fresh{let revision=cache.committed_revision().map_err(|e|e.to_string())?;state.workspace=revision;state.committed=revision;state.latest=Some(manifest.clone());state.published=Some(manifest.clone());}
            cache.end_read().map_err(|e|e.to_string())?;
        }
        let changed=state.latest.as_ref().map_or(true,|old|old.root!=manifest.root || old.files!=manifest.files || old.skipped_non_utf8!=manifest.skipped_non_utf8);
        if changed || force {
            state.workspace=state.workspace.checked_add(1).ok_or("graph_revision_exhausted")?;
            let revision=state.workspace;state.latest=Some(manifest.clone());
            let force=force || state.pending.as_ref().map_or(false,|p|p.2);
            state.pending=Some((revision,manifest,force));state.failure=None;
        }
        let required=state.workspace;let pending=state.pending.is_some();drop(state);
        if pending{self.enqueue(entry);}Ok(required)
    }
    fn run(&self) {
        loop {
            let entry={let mut queue=self.queue.lock().unwrap();while queue.ready.is_empty(){queue=self.wake.wait(queue).unwrap();}queue.ready.pop_front().unwrap()};
            eprintln!("graph_index_dequeued root={}",entry.root.display());
            // A bounded quiet window coalesces bursts without waiting forever for a busy writer.
            std::thread::sleep(Duration::from_millis(75));
            let dirty={let mut state=entry.state.lock().unwrap();state.queued=false;state.active=true;std::mem::take(&mut state.dirty)};
            let mut failed_revision=entry.state.lock().unwrap().workspace;
            let outcome=std::panic::catch_unwind(std::panic::AssertUnwindSafe(||->Result<(),String>{
                if dirty {
                    // Admission queues too; duplicate queue keys are harmless, and never duplicate a parse.
                    self.admit_until(&entry,false,Some(Instant::now()+Duration::from_secs(120)),&mut |phase,count|entry.progress(phase,count))?;
                }
                let pending=entry.state.lock().unwrap().pending.take();
                if let Some((revision,manifest,force))=pending {
                    failed_revision=revision;
                    eprintln!("graph_index_waiting_publication root={} revision={revision}",entry.root.display());
                    let _publication=entry.publication.lock().map_err(|_|"graph_publication_poisoned")?;
                    let mut store=Store::open(&entry.db).map_err(|e|e.to_string())?;
                    let report=store.index_manifest(&manifest,force,revision,&mut |phase,count|entry.progress(phase,count)).map_err(|e|e.to_string())?;
                    let mut state=entry.state.lock().unwrap();state.committed=revision;state.published=Some(manifest);state.report=report;state.failure=None;entry.changed.notify_all();
                }
                Ok(())
            }));
            let error=match outcome {Ok(Ok(()))=>None,Ok(Err(error))=>Some(error),Err(_)=>Some("graph_worker_panicked".into())};
            let mut state=entry.state.lock().unwrap();state.active=false;
            if let Some(error)=error {state.failure=Some((failed_revision,error.clone()));eprintln!("graph_index_failed root={} revision={} error={error}",entry.root.display(),state.workspace);}
            let more=state.pending.is_some() || state.dirty;entry.changed.notify_all();drop(state);
            if more{self.enqueue(&entry);}
        }
    }
}
impl Entry {
    fn capture_progress(&self,phase:&str,count:usize){let mut state=self.state.lock().unwrap();state.capture_progress.serial+=1;state.capture_progress.phase=phase.into();state.capture_progress.completed=count;}
    fn progress(&self,phase:&str,count:usize){let mut state=self.state.lock().unwrap();if state.progress.phase!=phase || count%256==0{eprintln!("graph_index_progress root={} workspace_revision={} phase={phase} completed={count}",self.root.display(),state.workspace);}state.progress.serial+=1;state.progress.phase=phase.into();state.progress.completed=count;self.changed.notify_all();}
    pub fn status(&self)->Value{let state=self.state.lock().unwrap();self.status_locked(&state)}
    fn status_locked(&self,state:&State)->Value{json!({"root":self.root,"db":self.db,"workspace_revision":state.workspace,"committed_revision":state.committed,
        "queued":state.queued,"active":state.active,"dirty_hint":state.dirty,"watch_registered":state.watched,"watch_error":state.watch_error,"progress":{"serial":state.progress.serial,"phase":state.progress.phase,"completed":state.progress.completed},
        "capture_progress":{"serial":state.capture_progress.serial,"phase":state.capture_progress.phase,"completed":state.capture_progress.completed},
        "capture_domain":"supported_utf8_sources","skipped_non_utf8":state.published.as_ref().map(|manifest|&manifest.skipped_non_utf8),
        "work":{"revision":state.committed,"parsed":state.report.indexed,"unchanged":state.report.unchanged,"removed":state.report.removed,"re_resolved":state.report.re_resolved,"nodes":state.report.nodes,"edges":state.report.edges,"resolved":state.report.resolved,"unresolved":state.report.unresolved},"failure":state.failure})}
    fn error(&self, required:u64, error:&str)->Value{let mut status=self.status();status["error"]=json!(error);status["required_revision"]=json!(required);
        status["next"]=json!(if error.contains("poisoned") || error.contains("panicked") || error.contains("worker_unavailable") {
            "Use bounded read/grep now. The worker/publication boundary is unavailable; use supported idle-safe node recovery, not automatic replay or repeated force indexing. No stale answer was returned."
        }else{
            "Use bounded read/grep now. Inspect failure/progress and repair its cause; graph action=index force=true deliberately retries a failed derived index. No stale answer was returned."
        });status}
    /// Only observed work advances a waiter's scoped heartbeat. A timeout does not cancel shared work.
    pub fn snapshot(&self, required:u64, deadline:Instant, progress:&mut impl FnMut(&Progress))->Result<(Store,Value),Value>{
        let started=Instant::now();let initial=self.state.lock().unwrap();let mut seen=initial.progress.serial;let reused=initial.committed>=required;drop(initial);
        loop {
            let mut state=self.state.lock().unwrap();
            if state.progress.serial>seen{seen=state.progress.serial;let update=state.progress.clone();drop(state);progress(&update);state=self.state.lock().unwrap();}
            if state.failure.as_ref().map_or(false,|(revision,_)|*revision>=required){let error=state.failure.as_ref().unwrap().1.clone();drop(state);return Err(self.error(required,&format!("graph_index_failed: {error}")));}
            if state.committed>=required && state.latest.is_some(){drop(state);break;}
            let Some(remaining)=deadline.checked_duration_since(Instant::now())else{drop(state);return Err(self.error(required,"graph_wait_timeout"));};
            state=self.changed.wait_timeout(state,remaining.min(Duration::from_millis(200))).unwrap().0;drop(state);
        }
        if Instant::now()>=deadline{return Err(self.error(required,"graph_wait_timeout"));}
        let _publication=loop {
            match self.publication.try_lock() {
                Ok(guard)=>break guard,
                Err(std::sync::TryLockError::Poisoned(_))=>return Err(self.error(required,"graph_publication_poisoned")),
                Err(std::sync::TryLockError::WouldBlock)=>{}
            }
            let Some(remaining)=deadline.checked_duration_since(Instant::now())else{return Err(self.error(required,"graph_wait_timeout"));};
            let state=self.state.lock().unwrap();
            if state.progress.serial>seen{seen=state.progress.serial;let update=state.progress.clone();drop(state);progress(&update);}else{drop(self.changed.wait_timeout(state,remaining.min(Duration::from_millis(100))).unwrap());}
        };
        let store=Store::open_readonly(&self.db).map_err(|e|self.error(required,&format!("graph_snapshot_open_failed: {e}")))?;
        store.begin_read().map_err(|e|self.error(required,&e.to_string()))?;
        let committed=store.committed_revision().map_err(|e|self.error(required,&e.to_string()))?;
        if committed<required{return Err(self.error(required,"graph_snapshot_revision_mismatch"));}
        let published={self.state.lock().unwrap().published.clone()}.ok_or_else(||self.error(required,"graph_snapshot_unpublished"))?;
        if !store.matches_manifest(&published).map_err(|e|self.error(required,&e.to_string()))?{return Err(self.error(required,"graph_snapshot_content_mismatch"));}
        let mut meta=self.status();meta["required_revision"]=json!(required);meta["committed_revision"]=json!(committed);meta["reused_committed_snapshot"]=json!(reused);meta["wait_ms"]=json!(started.elapsed().as_millis());
        Ok((store,meta))
    }
}
