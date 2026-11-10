use super::*;

#[test]
fn component_mounts_and_answers_map_back_to_host_paths() {
    // The component writes only inside P.d/, never next to the ledger.
    assert_eq!(db_dir(Path::new("/h/.wasm-agent/graph.db")), PathBuf::from("/h/.wasm-agent/graph.db.d"));
    assert_eq!(db_dir(Path::new("/h/.wasm-agent/graph.roots/ab.db")), PathBuf::from("/h/.wasm-agent/graph.roots/ab.db.d"));
    let mut answer = json!({"root":"/graph/root","db":"/graph/db/graph.db","items":[{"path":"a.lua","detail":"/graph/rootless"}]});
    host_paths(&mut answer, "/srv/tree", "/h/g.db.d");
    assert_eq!(answer["root"], "/srv/tree");
    assert_eq!(answer["db"], format!("/h/g.db.d{}graph.db", std::path::MAIN_SEPARATOR));
    assert_eq!(answer["items"][0]["path"], "a.lua", "relative selectors are untouched");
    assert_eq!(answer["items"][0]["detail"], "/graph/rootless", "only whole path prefixes map");
    assert!(indexable("x/a.lua") && indexable("go.mod") && indexable("A.TS") && !indexable("marker.txt") && !indexable("a.db-journal"));
    assert_eq!(mountable(r"\\?\C:\Users\x"), r"C:\Users\x");
    assert_eq!(mountable("/srv/tree"), "/srv/tree");
    assert!(excluded(Path::new("rust/target/x.rs")) && !excluded(Path::new("rust/src/x.rs")));
}

#[test]
fn the_databases_own_files_are_never_mistaken_for_source() {
    // The guest's SQLite writes these beside the database. With `db` inside the root they land in
    // the watched tree, and treating them as edits made one refresh schedule the next forever.
    for name in ["graph.db", "graph.db-wal", "graph.db-shm", "graph.db-journal", "graph.db.lock", ".graph.db.lock"] {
        assert!(database_artifact(name, "graph.db"), "{name} is the database's own");
    }
    for name in ["graph.db.d", "graph.dbs", "a.rs", "graph.db.lock2", "notes.txt"] {
        assert!(!database_artifact(name, "graph.db"), "{name} is not");
    }
}

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let id=std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let root=std::env::temp_dir().join(format!("wa-graph-locations-{}-{id}",std::process::id()));
        std::fs::create_dir_all(root.join("runtime")).unwrap();
        std::fs::create_dir_all(root.join("owned")).unwrap();
        Self(root)
    }
    fn config(&self) -> Config {Config {root:self.0.join("runtime"),db:self.0.join("graph.db")}}
}
impl Drop for Fixture {fn drop(&mut self) {let _=std::fs::remove_dir_all(&self.0);}}

#[test]
fn explicit_workspace_has_stable_separate_cache_without_touching_runtime_index() {
    let fixture=Fixture::new();let config=fixture.config();
    let (runtime,db)=locations(&json!({}),Some(&config)).unwrap();
    assert_eq!(runtime,config.root.canonicalize().unwrap());assert_eq!(db,db_dir(&config.db).join(DB_FILE));
    let options=json!({"root":fixture.0.join("owned")});
    let (owned,cache)=locations(&options,Some(&config)).unwrap();
    assert_ne!(owned,runtime);assert_ne!(cache,db);
    assert_eq!(cache.parent().unwrap().parent().unwrap(),config.db.with_extension("roots"));
    let alias=json!({"root":fixture.0.join("owned").join(".")});
    assert_eq!(locations(&alias,Some(&config)).unwrap(),(owned,cache));
    assert!(!db.exists() && !db.parent().unwrap().exists()); // Resolution itself has no index/write effect.
}

#[test]
fn explicit_database_override_is_preserved_with_verified_root() {
    let fixture=Fixture::new();let config=fixture.config();let db=fixture.0.join("private.db");
    let options=json!({"root":fixture.0.join("owned"),"db":db});
    assert_eq!(locations(&options,Some(&config)).unwrap().1,db);
    assert_eq!(locations(&options,None).unwrap().1,db);
    assert_eq!(locations(&json!({"root":config.root}),Some(&config)).unwrap().1,db_dir(&config.db).join(DB_FILE));
}

#[test]
fn missing_or_file_root_never_falls_back_to_runtime() {
    let fixture=Fixture::new();let config=fixture.config();
    assert!(locations(&json!({"root":fixture.0.join("missing")}),Some(&config)).unwrap_err().contains("graph_root_unavailable"));
    let file=fixture.0.join("not-directory");std::fs::write(&file,b"fixture").unwrap();
    assert_eq!(locations(&json!({"root":file}),Some(&config)).unwrap_err(),"graph_root_not_directory");
    assert_eq!(locations(&json!({}),None).unwrap_err(),"graph_not_configured");
}

// ---- a failing index is bounded ------------------------------------------------------------------

fn test_scheduler() -> Arc<Scheduler> {
    Arc::new(Scheduler { entries: Mutex::new(BTreeMap::new()), ready: Mutex::new(VecDeque::new()), wake: Condvar::new(), watcher: Mutex::new(None) })
}

fn test_entry(root: &Path, db: &Path) -> Arc<Entry> {
    Arc::new(Entry { root: root.to_path_buf(), db: db.to_path_buf(), calls: Mutex::new(()), state: Mutex::new(State::default()) })
}

#[test]
fn the_measured_failure_texts_are_classified() {
    // Exactly what node `work` logged on 10/11: the guest's SQLite message, and a trapping guest.
    assert!(malformed("graph_index_failed: database disk image is malformed"));
    assert!(malformed("graph_db_malformed: file is not a database"));
    assert!(!malformed("graph_component_unavailable: component_trap"));
    assert!(!malformed("graph_index_revision_conflict"));
    assert!(report_needed(None, "graph_component_unavailable: component_trap"));
    assert!(!report_needed(Some("trapped"), "trapped"), "one line per streak, not per attempt");
    assert!(report_needed(Some("trapped"), "malformed"), "a new cause is worth a line");
}

#[test]
fn a_failing_index_backs_off_with_a_growing_bounded_delay() {
    assert_eq!(retry_delay(1), Duration::from_secs(2));
    assert_eq!(retry_delay(2), Duration::from_secs(4));
    assert!(retry_delay(7) > retry_delay(6), "the delay grows");
    for attempts in 1..=64 {assert!(retry_delay(attempts) <= RETRY_MAX, "bounded at {attempts}");}
    assert_eq!(retry_delay(9), RETRY_MAX, "the delay saturates at attempt 9");
    assert_eq!(retry_delay(64), RETRY_MAX);
    assert!(retry_allowed(1) && retry_allowed(RETRY_LIMIT - 1));
    assert!(!retry_allowed(RETRY_LIMIT), "the streak ends: a doomed root cannot retry forever");
}

#[test]
fn timestamps_are_readable_utc() {
    assert_eq!(utc_stamp(0), "19700101T000000Z");
    assert_eq!(utc_stamp(86_400), "19700102T000000Z");
    assert_eq!(utc_stamp(1_000_000_000), "20010909T014640Z");
}

#[test]
fn a_trapping_component_is_retried_on_the_backoff_clock_not_in_a_tight_loop() {
    let fixture = Fixture::new();
    let tree = fixture.0.join("tree");
    std::fs::create_dir_all(&tree).unwrap();
    let started = Arc::new(Mutex::new(Vec::new()));
    let recorded = started.clone();
    *TEST_CALL.lock().unwrap() = Some(Box::new(move |_, tool| {
        assert_eq!(tool, "index");
        recorded.lock().unwrap().push(Instant::now());
        json!({"error": "graph_component_unavailable: component_trap"})
    }));
    let scheduler = test_scheduler();
    let entry = scheduler.entry(&tree, &fixture.0.join("graph.db")).unwrap();
    let worker = scheduler.clone();
    std::thread::spawn(move || worker.run());
    scheduler.enqueue(&entry);
    std::thread::sleep(Duration::from_millis(2_900));
    let attempts = started.lock().unwrap().clone();
    // Before the fix the scheduler re-enqueued the moment the attempt returned: one attempt per
    // 75 ms quiet window, ~38 in this window, which is the measured spin on node `work`.
    assert!(attempts.len() <= 2, "a trap must not be retried in a tight loop: {} attempts in 2.9 s", attempts.len());
    assert!(!attempts.is_empty(), "the index was attempted");
    for pair in attempts.windows(2) {
        let gap = pair[1].saturating_duration_since(pair[0]);
        assert!(gap >= Duration::from_millis(1_800), "attempts {:?} apart, expected the backoff delay", gap);
    }
    let state = entry.state.lock().unwrap();
    assert_eq!(state.attempts, attempts.len() as u32);
    assert!(state.retry_at.is_some() || state.stopped);
    assert_eq!(state.failure.as_deref(), Some("graph_component_unavailable: component_trap"));
    drop(state);
    *TEST_CALL.lock().unwrap() = None;
    entry.state.lock().unwrap().stopped = true;
    let _ = started;
}

#[test]
fn a_failure_streak_stops_and_needs_an_explicit_index() {
    let fixture = Fixture::new();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &fixture.0.join("graph.db.d").join(DB_FILE));
    entry.state.lock().unwrap().attempts = RETRY_LIMIT - 1;
    scheduler.failed(&entry, "graph_component_unavailable: component_trap".into());
    let state = entry.state.lock().unwrap();
    assert_eq!(state.attempts, RETRY_LIMIT);
    assert!(state.stopped, "no automatic retry after the limit");
    assert!(state.retry_at.is_none());
    drop(state);
    assert!(scheduler.ready.lock().unwrap().is_empty(), "a stopped streak queues nothing");
    scheduler.enqueue(&entry);
    assert!(scheduler.ready.lock().unwrap().is_empty(), "an edit hint cannot resurrect it");
    scheduler.resume(&entry);
    let state = entry.state.lock().unwrap();
    assert_eq!(state.attempts, 0);
    assert!(!state.stopped, "an explicit index resumes the policy");
    drop(state);
    assert_eq!(scheduler.ready.lock().unwrap().len(), 1, "the resume queues the work it was told to do");
}

#[test]
fn a_malformed_database_is_moved_aside_with_a_timestamp_and_never_deleted() {
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join(DB_FILE);
    let bytes = b"this is not a sqlite database".to_vec();
    std::fs::write(&db, &bytes).unwrap();
    std::fs::write(dir.join("graph.db-wal"), b"wal").unwrap();
    let entry = test_entry(&fixture.0, &db);
    let moved = quarantine_database(&entry, "20261110T184200Z").unwrap();
    assert_eq!(moved.len(), 2, "the database and its wal");
    assert!(!db.exists() && !dir.join("graph.db-wal").exists());
    assert_eq!(std::fs::read(dir.join("graph.db.malformed-20261110T184200Z")).unwrap(), bytes, "preserved, never deleted");
    assert!(dir.join("graph.db.malformed-20261110T184200Z-wal").exists());
    assert!(quarantine_database(&entry, "20261110T184300Z").unwrap().is_empty(), "nothing moves twice");
}

#[test]
fn a_malformed_failure_quarantines_and_queues_the_rebuild_at_once() {
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(DB_FILE), b"not a database").unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    scheduler.failed(&entry, "graph_index_failed: database disk image is malformed".into());
    let state = entry.state.lock().unwrap();
    assert_eq!(state.corruptions, 1);
    assert_eq!(state.quarantined.len(), 1);
    assert_eq!(state.attempts, 0, "a rebuild is a fresh start, not a retry");
    assert!(!state.stopped);
    let quarantined = state.quarantined[0].clone();
    drop(state);
    assert!(quarantined.exists() && !dir.join(DB_FILE).exists(), "the path is free for the rebuild");
    let ready = scheduler.ready.lock().unwrap();
    assert_eq!(ready.len(), 1);
    assert!(ready[0].0.is_none(), "the rebuild runs at once, not after a delay");
}
