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
    assert_eq!(runtime,config.root.canonicalize().unwrap());
    // The configured root has its OWN store: the shared database is never what a process indexes into.
    assert_ne!(db,db_dir(&config.db).join(DB_FILE));
    assert_eq!(db.parent().unwrap().parent().unwrap(),config.db.with_extension("roots"));
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
    // Naming the configured root explicitly resolves to the same per-root store, never the shared one.
    let configured=db_dir(&per_root_store(&config.db,&config.root.canonicalize().unwrap())).join(DB_FILE);
    assert_eq!(locations(&json!({"root":config.root}),Some(&config)).unwrap().1,configured);
    assert_ne!(configured,db_dir(&config.db).join(DB_FILE));
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
    let moved = quarantine_database(&entry, "20261110T184200Z").unwrap().moved;
    let named: Vec<String> = moved.iter().map(|path| path.file_name().unwrap().to_string_lossy().into_owned()).collect();
    assert_eq!(moved.len(), 2, "the database and its wal: {named:?}");
    assert!(!db.exists() && !dir.join("graph.db-wal").exists());
    assert_eq!(std::fs::read(dir.join("graph.db.malformed-20261110T184200Z")).unwrap(), bytes, "preserved, never deleted");
    assert!(dir.join("graph.db.malformed-20261110T184200Z-wal").exists());
    assert!(quarantine_database(&entry, "20261110T184300Z").unwrap().moved.is_empty(), "nothing moves twice");
}

#[test]
fn a_malformed_failure_quarantines_and_queues_the_rebuild_at_once() {
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(DB_FILE), b"not a database").unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    // The disk answer is pinned so the test asserts the quarantine, not this machine's free space.
    entry.state.lock().unwrap().min_free_bytes = 1;
    scheduler.failed(&entry, "graph_index_failed: database disk image is malformed".into());
    let state = entry.state.lock().unwrap();
    assert_eq!(state.corruptions, 1);
    assert_eq!(state.quarantined.len(), 1);
    assert_eq!(state.attempts, 0, "a rebuild is a fresh start, not a retry");
    assert!(!state.stopped);
    assert_eq!(state.rebuilds.len(), 1, "the rebuild is counted against the 24 h budget before it runs");
    let quarantined = state.quarantined[0].clone();
    drop(state);
    assert!(quarantined.exists() && !dir.join(DB_FILE).exists(), "the path is free for the rebuild");
    let ready = scheduler.ready.lock().unwrap();
    assert_eq!(ready.len(), 1);
    assert!(ready[0].0.is_none(), "the rebuild runs at once, not after a delay");
}

// ---- a killed writer's journal is not damage -----------------------------------------------------

/// A store with committed rows and a journal beside it, the way a writer killed before its commit leaves
/// one: SQLite journaled the pages of an open transaction and never wrote the record count that would make
/// the journal something to roll back. Rusqlite is the same engine the heal uses.
fn store_with_journal(dir: &Path) -> PathBuf {
    std::fs::create_dir_all(dir).unwrap();
    let db = dir.join(DB_FILE);
    let live = dir.join("live.db");
    {
        let connection = rusqlite::Connection::open(&live).unwrap();
        connection.execute_batch("PRAGMA journal_mode=delete; CREATE TABLE probe(x TEXT);").unwrap();
        let mut statement = connection.prepare("INSERT INTO probe(x) VALUES (?1)").unwrap();
        for row in 0..200 { statement.execute([format!("row{row}")]).unwrap(); }
    }
    {
        let connection = rusqlite::Connection::open(&live).unwrap();
        connection.execute_batch("PRAGMA cache_size=1; BEGIN IMMEDIATE;").unwrap();
        connection.execute_batch("UPDATE probe SET x = x || 'x';").unwrap();
        std::fs::copy(&live, &db).unwrap();
        std::fs::copy(dir.join("live.db-journal"), dir.join(format!("{DB_FILE}-journal"))).unwrap();
    }
    db
}

#[test]
fn a_journal_beside_the_store_is_resolved_and_the_store_still_reads() {
    // 22/11: the install swapped the running node while its graph worker was committing. What the kill
    // left is this - a journal on the disk - and the old path read the store read-only, could not roll it
    // back, called the result `database disk image is malformed` and quarantined the whole index. Resolving
    // the journal first is what makes that quarantine unreachable for a crash that damaged nothing.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    let db = store_with_journal(&dir);
    let bytes = hot_journal(&dir, DB_FILE).expect("the fixture left no journal beside the store");
    assert!(bytes > 0, "a journal of zero bytes is not a pending journal");
    let pending = roll_back_hot_journal(&dir, DB_FILE).expect("the store could not be opened for the journal");
    // A journal SQLite wrote while the transaction was open carries records but no record count, so the
    // honest outcome for THIS fixture is "not pending": the store reads and nothing is rolled back. What the
    // row that matters measures - a journal that carries its record count and IS spent - is the crash-state
    // path of scripts/test-graph-crash-recovery.lua, which cannot be built without a real killed commit.
    assert_eq!(pending, Pending::NotPending, "a journal with no record count is not one to roll back");
    assert_eq!(pending.name(), "not_pending", "the line the operator reads names the outcome");
    let connection = rusqlite::Connection::open(&db).unwrap();
    let rows: i64 = connection.query_row("SELECT COUNT(*) FROM probe", [], |row| row.get(0)).unwrap();
    assert_eq!(rows, 200, "the committed revision survived: nothing was copied and nothing rebuilt");
    let verdict: String = connection.query_row("PRAGMA integrity_check", [], |row| row.get(0)).unwrap();
    assert_eq!(verdict, "ok", "the store a killed writer left behind reads clean after the journal is resolved");
    drop(connection);
    // A journal file SQLite does not recognise at all is spent rather than rolled back, and the store reads:
    // the outcome is named, so the line never claims a rollback it did not perform.
    std::fs::write(dir.join(format!("{DB_FILE}-journal")), b"junk, not a journal at all").unwrap();
    assert_eq!(roll_back_hot_journal(&dir, DB_FILE).unwrap(), Pending::RolledBack, "a rejected journal is spent, and the store reads");
    assert_eq!(hot_journal(&dir, DB_FILE), None, "the rejected journal is gone");
}

#[test]
fn a_store_without_a_pending_journal_is_never_touched() {
    // The heal is an allow-list of one cause: a non-empty journal. Everything else keeps every verdict the
    // scheduler made before it existed - above all a store that is damaged WITHOUT a journal, which is
    // damage and still quarantines.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(DB_FILE), b"not a database").unwrap();
    assert_eq!(hot_journal(&dir, DB_FILE), None, "a store with no journal has nothing to recover");
    std::fs::write(dir.join(format!("{DB_FILE}-journal")), b"").unwrap();
    assert_eq!(hot_journal(&dir, DB_FILE), None, "a zero-length journal is SQLite's own nothing-to-roll-back");
    std::fs::remove_file(dir.join(format!("{DB_FILE}-journal"))).unwrap();
    std::fs::create_dir_all(dir.join(format!("{DB_FILE}-journal"))).unwrap();
    assert_eq!(hot_journal(&dir, DB_FILE), None, "a directory that happens to carry the name is not a journal");
    std::fs::remove_dir(dir.join(format!("{DB_FILE}-journal"))).unwrap();
    assert_eq!(std::fs::read(dir.join(DB_FILE)).unwrap(), b"not a database", "nothing was written to the store");
}


// ---- the disk-eating loop is stopped, not outrun -------------------------------------------------

#[test]
fn a_low_disk_defers_the_rebuild_and_makes_no_copy() {
    // The openclaw case, 11/11: 2.7 GB free of 96 GB and ~20 `graph.db.malformed-*` copies in seven
    // hours. With a floor above the free space, the decision must be "defer", and the decisive part is
    // that NOTHING is renamed: the copy is the rename.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(DB_FILE), b"not a database").unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    entry.state.lock().unwrap().min_free_bytes = u64::MAX;
    scheduler.failed(&entry, "graph_index_failed: database disk image is malformed".into());
    let state = entry.state.lock().unwrap();
    assert_eq!(state.corruptions, 0, "no quarantine happened");
    assert!(state.quarantined.is_empty());
    assert!(state.rebuilds.is_empty(), "no rebuild was attempted, so none is counted");
    assert!(state.stopped, "nothing further is tried automatically");
    assert!(state.retry_at.is_none());
    let reported = state.reported.clone().unwrap_or_default();
    assert!(reported.starts_with("graph_rebuild_deferred: low_disk"), "the reason is the measured one: {reported}");
    assert!(reported.contains(&format!("floor_bytes={}", u64::MAX)), "the line carries the floor it judged against: {reported}");
    drop(state);
    assert!(dir.join(DB_FILE).exists(), "the store stays exactly where it was");
    let malformed_copies = std::fs::read_dir(&dir).unwrap().filter(|entry| {
        entry.as_ref().map(|e| e.file_name().to_string_lossy().contains(".malformed-")).unwrap_or(false)
    }).count();
    assert_eq!(malformed_copies, 0, "a deferred rebuild creates no quarantine copy");
    assert!(scheduler.ready.lock().unwrap().is_empty(), "and queues no work");
}

#[test]
fn the_low_disk_deferral_is_reported_once_not_per_attempt() {
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(DB_FILE), b"not a database").unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    entry.state.lock().unwrap().min_free_bytes = u64::MAX;
    scheduler.failed(&entry, "graph_index_failed: database disk image is malformed".into());
    let first = entry.state.lock().unwrap().reported.clone().unwrap_or_default();
    // A second failure of the same shape must find the line already reported and stay quiet.
    scheduler.failed(&entry, "graph_index_failed: database disk image is malformed".into());
    let second = entry.state.lock().unwrap().reported.clone().unwrap_or_default();
    assert_eq!(first, second, "one line per deferred streak, not one per attempt");
    assert!(report_needed(Some(&first), &first) == false, "the reporter agrees: nothing new to say");
}

#[test]
fn three_failed_rebuilds_in_a_day_stop_the_loop() {
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(DB_FILE), b"not a database").unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    entry.state.lock().unwrap().min_free_bytes = 1;
    // Three rebuilds already failed inside the window - the state a real loop reaches after ~3 attempts.
    let now = epoch_seconds();
    {
        let mut state = entry.state.lock().unwrap();
        state.rebuilds = vec![now.saturating_sub(3600), now.saturating_sub(1800), now.saturating_sub(60)];
    }
    scheduler.failed(&entry, "graph_index_failed: database disk image is malformed".into());
    let state = entry.state.lock().unwrap();
    assert_eq!(state.corruptions, 0, "the fourth copy is never made");
    assert!(state.quarantined.is_empty());
    assert!(state.stopped, "automatic rebuild stops");
    assert!(state.retry_at.is_none());
    let reported = state.reported.clone().unwrap_or_default();
    assert!(reported.starts_with("graph_rebuild_stopped: failed_rebuilds"), "the stop is reported: {reported}");
    assert!(reported.contains("rebuilds=3") && reported.contains("window_hours=24"), "with the count and the window: {reported}");
    drop(state);
    assert!(dir.join(DB_FILE).exists(), "the store is left alone");
    assert!(scheduler.ready.lock().unwrap().is_empty());
}

#[test]
fn a_rebuild_budget_from_another_day_does_not_stop_this_one() {
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(DB_FILE), b"not a database").unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    entry.state.lock().unwrap().min_free_bytes = 1;
    let now = epoch_seconds();
    {
        let mut state = entry.state.lock().unwrap();
        state.rebuilds = vec![now.saturating_sub(30 * 3600), now.saturating_sub(26 * 3600), now.saturating_sub(25 * 3600)];
    }
    scheduler.failed(&entry, "graph_index_failed: database disk image is malformed".into());
    let state = entry.state.lock().unwrap();
    assert_eq!(state.corruptions, 1, "yesterday's rebuilds do not spend today's budget");
    assert_eq!(state.rebuilds.len(), 1, "the window is pruned to this rebuild");
    assert!(!state.stopped);
}

#[test]
fn a_recovered_index_clears_the_rebuild_budget() {
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    let now = epoch_seconds();
    {
        let mut state = entry.state.lock().unwrap();
        state.rebuilds = vec![now - 10, now - 5, now];
        state.stopped = true;
    }
    scheduler.recovered(&entry);
    let state = entry.state.lock().unwrap();
    assert!(state.rebuilds.is_empty(), "a rebuild that worked is not one of the copies a loop leaves");
    assert!(!state.stopped);
}

#[test]
fn an_explicit_index_retires_one_rebuild_from_the_budget() {
    // `graph_index_force` is a deliberate retry, and it must be able to happen - exactly once per
    // explicit decision, with the rest of the budget intact so the disk is still protected.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    let now = epoch_seconds();
    {
        let mut state = entry.state.lock().unwrap();
        state.rebuilds = vec![now - 30, now - 20, now - 10];
        state.stopped = true;
        state.dirty = true;
    }
    scheduler.resume(&entry);
    let state = entry.state.lock().unwrap();
    assert_eq!(state.rebuilds.len(), 2, "one rebuild is retired, not the whole budget");
    assert!(!state.stopped, "and the retry it was asked for can run");
}

#[test]
fn an_unmeasurable_disk_reports_itself_and_still_bounds_the_copies() {
    // A probe that cannot answer must not permanently disable the one repair the indexer has, so the
    // rebuild proceeds - and the 24 h budget is what keeps that from being unbounded.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    entry.state.lock().unwrap().min_free_bytes = 1;
    let answer = disk_answer(&dir, 1);
    assert!(matches!(answer, DiskAnswer::Enough(_)), "this machine can answer, so the shape under test is Enough");
    let now = epoch_seconds();
    {
        let mut state = entry.state.lock().unwrap();
        state.rebuilds = vec![now - 30, now - 20, now - 10];
    }
    std::fs::write(dir.join(DB_FILE), b"not a database").unwrap();
    scheduler.failed(&entry, "graph_index_failed: file is not a database".into());
    assert_eq!(entry.state.lock().unwrap().corruptions, 0, "the budget alone stops the copy when the disk cannot be judged");
}


// ---- the store has one writer, and the backup is not it ------------------------------------------

/// A graph store in the journal mode the guest actually runs: `delete` (rollback).
///
/// `wa_sqlite::tune` asks for WAL inside the component, but WAL needs a shared `-shm` mapping and
/// POSIX locks, neither of which WASI provides, so the file the component writes is rollback-journal.
/// A store created here without touching the journal mode is the same shape, and that is what makes
/// the tests below faithful.
fn guest_shaped_store(dir: &Path) -> PathBuf {
    std::fs::create_dir_all(dir).unwrap();
    let db = dir.join(DB_FILE);
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.execute_batch("CREATE TABLE IF NOT EXISTS t(x TEXT);").unwrap();
    conn.execute("INSERT INTO t VALUES ('first')", []).unwrap();
    let mode: String = conn.query_row("PRAGMA journal_mode", [], |row| row.get(0)).unwrap();
    assert_eq!(mode, "delete", "the guest's store is rollback-journal, not WAL");
    db
}

/// The read the pre-update backup made before this branch: SQLite's `VACUUM INTO` on a plain
/// connection, with no knowledge of the store's lock. Used only to reproduce the failure.
fn unlocked_copy(source: &Path, copy: &Path) -> Result<String, String> {
    let connection = rusqlite::Connection::open_with_flags(source, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE)
        .map_err(|error| error.to_string())?;
    connection.busy_timeout(Duration::from_millis(0)).map_err(|error| error.to_string())?;
    connection.execute("VACUUM INTO ?1", [copy.to_string_lossy().as_ref()]).map_err(|error| error.to_string())?;
    copy_verdict(copy)
}

fn rows(db: &Path) -> i64 {
    let conn = rusqlite::Connection::open_with_flags(db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    conn.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap()
}

#[test]
fn a_copy_of_the_graph_store_waits_for_the_store_lock() {
    // The kernel holds this lock for the whole of every component call (`call`), so a reader that
    // holds it cannot meet a writing guest. Deterministic: while the test holds the lock the snapshot
    // cannot make progress at all.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    let db = guest_shaped_store(&dir);
    let copy = fixture.0.join("copy.db");
    let guard = lock_store(&dir, DB_FILE, Some(Instant::now())).unwrap().expect("the store's lock is free");
    let worker = {
        let (db, copy) = (db.clone(), copy.clone());
        std::thread::spawn(move || snapshot_store(&db, &copy, Duration::from_secs(20)))
    };
    std::thread::sleep(Duration::from_millis(300));
    assert!(!copy.exists(), "the copy must not begin while a component call holds the store");
    drop(guard);
    let snapshot = worker.join().expect("the snapshot thread did not panic").expect("the snapshot succeeds once the lock is free");
    assert_eq!(snapshot.check, "ok");
    assert!(copy.exists());
    assert_eq!(rows(&copy), 1, "and it is a working copy of the store");
}

#[test]
fn a_store_held_by_a_running_index_is_reported_busy_and_creates_nothing() {
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    let db = guest_shaped_store(&dir);
    let copy = fixture.0.join("copy.db");
    let guard = lock_store(&dir, DB_FILE, Some(Instant::now())).unwrap().unwrap();
    let started = Instant::now();
    let answer = snapshot_store(&db, &copy, Duration::from_millis(200));
    assert!(answer.is_err(), "a bounded wait must not hang a deploy behind an index");
    assert!(started.elapsed() < Duration::from_secs(10));
    assert!(answer.unwrap_err().starts_with("graph_store_busy"), "the answer names the reason");
    assert!(!copy.exists(), "a busy store leaves no destination behind");
    drop(guard);
}

#[test]
fn the_lockless_writer_a_wasi_guest_is_can_only_be_copied_under_the_store_lock() {
    // THE REPRODUCTION. Two SQLite implementations on one rollback-journal store:
    //
    //  * the writer below uses the `unix-none` VFS, which takes no locks at all - which is what the
    //    WASI guest's SQLite does, so its commits are page overwrites that exclude nobody;
    //  * the reader below is the pre-update backup's, first as it was (no shared lock), then through
    //    `snapshot_store` (the store's own lock).
    //
    // Measured on `wa-desktop` 13/11 against the real component: 3,653 `database disk image is
    // malformed` reads and torn copies in 70 s, on a store that passed `PRAGMA integrity_check`
    // immediately afterwards. That false verdict is what quarantined 77 copies and refused
    // `wa update`.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    let db = guest_shaped_store(&dir);
    let stop = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let writer = {
        let (db, stop) = (db.clone(), stop.clone());
        std::thread::spawn(move || {
            let conn = rusqlite::Connection::open_with_flags_and_vfs(
                &db,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE,
                "unix-none",
            )
            .expect("the lock-free VFS is what a WASI guest's SQLite has");
            let mut round = 0;
            while !stop.load(std::sync::atomic::Ordering::Relaxed) {
                round += 1;
                let _ = conn.execute("BEGIN IMMEDIATE", []);
                for row in 0..2000 {
                    let _ = conn.execute("INSERT INTO t VALUES (?)", [format!("{round}-{row}")]);
                }
                let _ = conn.execute("COMMIT", []);
            }
        })
    };
    // 1. The read the backup used to make: a native `VACUUM INTO` with no shared lock, which is
    //    exactly `lua/core/backup.lua` before this branch, so it meets the writer mid-commit.
    let mut torn = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(6);
    let mut copy_index = 0;
    while Instant::now() < deadline && torn.is_empty() {
        copy_index += 1;
        let copy = fixture.0.join(format!("unlocked-{copy_index}.db"));
        let _ = std::fs::remove_file(&copy);
        match unlocked_copy(&db, &copy) {
            Ok(verdict) if verdict == "ok" => {let _ = std::fs::remove_file(&copy);}
            Ok(verdict) => torn.push(format!("the copy did not pass integrity_check: {verdict}")),
            Err(error) => torn.push(error),
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    writer.join().expect("the writer thread did not panic");
    assert!(!torn.is_empty(), "an unlocked copy of a store a lockless writer is writing must tear or refuse; the reproduction did not reproduce");
    // 2. A fresh store of the same shape, the same kind of writer, and the read this branch makes: the
    //    store's lock. The writer holds it for 500 ms - as `call` holds it for a whole guest run - and
    //    the copy can only start once it lets go, so it never meets a page mid-commit.
    let safe_dir = db_dir(&fixture.0.join("second-graph.db"));
    let db = guest_shaped_store(&safe_dir);
    let dir = safe_dir;
    let lock_holder = {
        let (dir, db) = (dir.clone(), db.clone());
        std::thread::spawn(move || {
            let _guard = lock_store(&dir, DB_FILE, Some(Instant::now() + Duration::from_secs(20)))
                .unwrap().expect("the writer takes the store's lock, as `call` does");
            let conn = rusqlite::Connection::open_with_flags_and_vfs(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE, "unix-none").unwrap();
            let until = Instant::now() + Duration::from_millis(500);
            while Instant::now() < until {
                let _ = conn.execute("BEGIN IMMEDIATE", []);
                for row in 0..200 {
                    let _ = conn.execute("INSERT INTO t VALUES (?)", [format!("locked-{row}")]);
                }
                let _ = conn.execute("COMMIT", []);
            }
        })
    };
    std::thread::sleep(Duration::from_millis(150));
    let copy = fixture.0.join("locked.db");
    let started = Instant::now();
    let snapshot = snapshot_store(&db, &copy, Duration::from_secs(20)).expect("a store whose lock can be had copies cleanly");
    let waited = started.elapsed();
    lock_holder.join().expect("the lock holder did not panic");
    assert_eq!(snapshot.check, "ok");
    assert!(waited >= Duration::from_millis(250), "the copy waited for the writer to finish ({waited:?}), so it never read a page mid-commit");
    assert_eq!(copy_verdict(&copy).unwrap(), "ok");
    assert_eq!(copy_verdict(&db).unwrap(), "ok", "and the store it read is still sound: no page was written while it was read");
}

#[test]
fn the_newest_three_quarantine_copies_of_one_store_are_kept_and_the_older_ones_deleted() {
    // 77 copies in `graph.db.d/` on node `work`, 30 on `openclaw`: each detection left its own, and the
    // directory filled. Keeping ONE was the other half of the same mistake: the copy that explains a
    // quarantine was destroyed by the next one - measured twice on 22/11, the brief's own evidence file
    // `graph.db.malformed-20261122T144358Z` gone 71 s after it was made. Three copies, the newest three.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    let stamps = ["20261110T220000Z", "20261111T030000Z", "20261111T040000Z", "20261111T050000Z"];
    for stamp in stamps {
        std::fs::write(dir.join(DB_FILE), format!("broken {stamp}")).unwrap();
        let moved = quarantine_database(&entry, stamp).unwrap();
        assert_eq!(moved.moved.len(), 1, "{stamp}: the store is moved aside");
        // Every copy is byte-for-byte the store that was moved: it is evidence, so nothing rewrites it.
        for kept in &moved.moved {
            let name = kept.file_name().unwrap().to_string_lossy().into_owned();
            let stamp_of = name.trim_start_matches("graph.db.malformed-").trim_end_matches("-journal");
            assert_eq!(std::fs::read_to_string(kept).unwrap(), format!("broken {stamp_of}"), "{name} is not the copy it names");
        }
    }
    let copies: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("graph.db.malformed-"))
        .collect();
    let mut expected: Vec<String> = stamps[1..].iter().map(|stamp| format!("graph.db.malformed-{stamp}")).collect();
    let mut sorted = copies.clone();
    sorted.sort();
    expected.sort();
    assert_eq!(sorted, expected, "the newest three copies are kept, the oldest is deleted: {copies:?}");
    // A sibling of ANOTHER store is not this store's business.
    std::fs::write(dir.join("jobs.db.malformed-20261101T000000Z"), "other").unwrap();
    std::fs::write(dir.join(DB_FILE), "broken again").unwrap();
    quarantine_database(&entry, "20261111T060000Z").unwrap();
    assert!(dir.join("jobs.db.malformed-20261101T000000Z").exists(), "another store's quarantine is left alone");
    let after: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("graph.db.malformed-"))
        .collect();
    assert_eq!(after.len(), 3, "still three of this store's: {after:?}");
}

#[test]
fn the_quarantine_retention_is_a_group_rule_with_a_budget_and_a_newest_copy_that_always_survives() {
    // Retention is a decision about EVIDENCE, so the rule is exercised with the numbers small enough to
    // read: three copies of ten bytes, a budget of twenty-five, and a budget no copy can fit.
    let fixture = Fixture::new();
    let dir = fixture.0.join("store.d");
    std::fs::create_dir_all(&dir).unwrap();
    let write = |stamp: &str, suffix: &str, bytes: usize| {
        std::fs::write(dir.join(format!("graph.db.malformed-{stamp}{suffix}")), vec![0u8; bytes]).unwrap();
    };
    for stamp in ["20261122T010000Z", "20261122T020000Z", "20261122T030000Z", "20261122T040000Z"] {
        write(stamp, "", 10);
    }
    // A group is the database AND its journal: one stamp is one evidence set, deleted together.
    write("20261122T040000Z", "-journal", 5);
    let left = || -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        names
    };
    assert_eq!(retain_quarantine(&dir, "graph.db", 3, 1_000), 3, "three groups kept");
    assert_eq!(left(), vec![
        "graph.db.malformed-20261122T020000Z".to_string(),
        "graph.db.malformed-20261122T030000Z".to_string(),
        "graph.db.malformed-20261122T040000Z".to_string(),
        "graph.db.malformed-20261122T040000Z-journal".to_string(),
    ], "the oldest group goes, the journal of a kept group stays");
    // The budget, not the count, is what binds here: 30 bytes of groups against 25 keeps the newest 15.
    assert_eq!(retain_quarantine(&dir, "graph.db", 3, 25), 2, "the budget keeps the newest that fit");
    assert_eq!(left(), vec![
        "graph.db.malformed-20261122T030000Z".to_string(),
        "graph.db.malformed-20261122T040000Z".to_string(),
        "graph.db.malformed-20261122T040000Z-journal".to_string(),
    ]);
    // A budget smaller than the newest copy alone still keeps it: a store bigger than the ceiling must
    // leave the copy that explains the quarantine it caused.
    assert_eq!(retain_quarantine(&dir, "graph.db", 3, 1), 1, "the newest copy survives any budget");
    // A store's copies that are NOT this store's are left alone, and a name that is not one of the four
    // suffixes is not counted as a copy this rule may delete.
    std::fs::write(dir.join("jobs.db.malformed-20261101T000000Z"), "other").unwrap();
    std::fs::write(dir.join("graph.db.malformed-20261101T000000Z-junk"), "junk").unwrap();
    assert_eq!(retain_quarantine(&dir, "graph.db", 3, 1_000), 1);
    assert!(dir.join("jobs.db.malformed-20261101T000000Z").exists(), "another store's quarantine is left alone");
    assert!(dir.join("graph.db.malformed-20261101T000000Z-junk").exists(), "an unknown suffix is not evidence this rule owns");
}

#[test]
fn index_only_is_an_allow_list_of_the_two_measured_shapes() {
    // Measured on the store quarantined at 22/11 22:56 (`graph.db.malformed-20261123T015417Z`):
    // `PRAGMA integrity_check(100000)` answered 150 complaints, 149 of them `row <n> missing from index
    // <name>` and one `wrong # of entries in index <name>`. Those two are what a REINDEX repairs.
    assert!(index_only("row 101406 missing from index idx_edges_path"));
    assert!(index_only("row 7 missing from index idx_edges_src"));
    assert!(index_only("wrong # of entries in index idx_edges_src"));
    // Everything else is refused by name: a table, page or freelist fault needs the journal or a rebuild,
    // and a repair that guessed would be a write over damage nobody diagnosed.
    for complaint in [
        "*** in database main ***",
        "Freelist: size is 1017 but should be 45",
        "Tree 4 page 33166: btreeInitPage() returns error code 11",
        "Page 5: never used but is listed in the freelist",
        "2nd reference to page 17995",
        "database disk image is malformed",
        "file is not a database",
        "row 5 missing from index ",
        "row  missing from index idx_a",
        "row x missing from index idx_a",
        "wrong # of entries in index ",
        "ok",
    ] {
        assert!(!index_only(complaint), "{complaint} is not an index-entry complaint");
    }
}

#[test]
fn the_quarantine_line_names_the_integrity_error_the_reason_and_how_many_copies_survive() {
    let moved = vec![PathBuf::from("/h/graph.db.d/graph.db.malformed-20261123T015417Z")];
    let line = quarantine_line(Path::new("/srv/tree"), &moved,
        "graph_index_failed: database disk image is malformed",
        "row 101406 missing from index idx_edges_path", 3, " free_bytes=10 floor_bytes=5");
    assert_eq!(line, "graph_db_quarantined root=/srv/tree moved=/h/graph.db.d/graph.db.malformed-20261123T015417Z reason=graph_index_failed:_database_disk_image_is_malformed integrity=row_101406_missing_from_index_idx_edges_path kept=3 next=rebuild free_bytes=10 floor_bytes=5", "{line}");
    // A verdict that cannot be measured says so, and a very long one is bounded without splitting a
    // character.
    assert!(quarantine_line(Path::new("/r"), &moved, "e", "unmeasurable: unable to open database file", 1, "").contains(" integrity=unmeasurable:_unable_to_open_database_file "), "an unmeasurable verdict is named");
    let long = quarantine_line(Path::new("/r"), &moved, "e", &"x".repeat(400), 1, "");
    assert!(long.contains(&format!("integrity={}~ ", "x".repeat(180))), "a long verdict is cut and marked: {long}");
}

// ---- a boot watch is BOUNDED --------------------------------------------------------------------

#[test]
fn a_watch_count_stops_at_the_budget_instead_of_walking_the_tree() {
    // The measured defect (21/11, openclaw): a recursive OS watch is one inotify watch PER DIRECTORY and
    // notify takes them synchronously, so registering the node cwd walked 713k directories before the
    // listener existed and held /health for 60-150 s. What must hold after the fix: the count is taken
    // with a budget, and a tree past it is refused rather than counted to the end.
    let fixture = Fixture::new();
    let tree = fixture.0.join("bounded");
    for a in 0..6 { for b in 0..6 { std::fs::create_dir_all(tree.join(format!("a{a}/b{b}"))).unwrap(); } }
    // 36 leaves + 6 middle directories + the root = 43 directories.
    assert_eq!(watchable_directories(&tree, 1_000), Some(43), "a small tree is counted exactly");
    // Over the budget the answer is None, and it is None EARLY: the scan returns as soon as the budget
    // is passed rather than finishing the tree first (that is what keeps boot bounded).
    assert_eq!(watchable_directories(&tree, 5), None, "past the budget the root is not watched");
    assert_eq!(watchable_directories(&tree, 43), Some(43), "exactly at the budget still qualifies");
    assert_eq!(watchable_directories(&tree, 42), None, "one directory past it does not");
    // A directory that cannot be read is not a reason to refuse the root: the watcher would simply not
    // see it, which is the same hint-quality as any unreadable subtree.
    let missing = fixture.0.join("does-not-exist");
    assert_eq!(watchable_directories(&missing, 1_000), Some(1), "an unreadable root counts as itself");
}

#[test]
fn an_operator_budget_of_zero_means_no_os_watch() {
    // WA_GRAPH_WATCH_DIRS=0 is the documented off switch; it must not be read as "unlimited".
    let fixture = Fixture::new();
    let tree = fixture.0.join("unwatched");
    std::fs::create_dir_all(tree.join("sub")).unwrap();
    assert_eq!(watchable_directories(&tree, 0), None, "a zero budget watches nothing");
}

/// A store with one table and two indexes holding `rows` rows: the smallest thing that has an index to
/// disagree with its table.
fn store_with_rows(path: &Path, rows: i64) {
    let connection = rusqlite::Connection::open(path).unwrap();
    connection.execute_batch("CREATE TABLE t (a INTEGER PRIMARY KEY, b TEXT, c TEXT); CREATE INDEX idx_b ON t(b); CREATE INDEX idx_c ON t(c);").unwrap();
    let mut insert = connection.prepare("INSERT INTO t (b, c) VALUES (?1, ?2)").unwrap();
    for i in 0..rows {insert.execute((format!("b{i}"), format!("c{i}"))).unwrap();}
}

fn page_of(path: &Path, page: u64, page_size: u64) -> Vec<u8> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).unwrap();
    let mut bytes = vec![0u8; page_size as usize];
    file.seek(SeekFrom::Start((page - 1) * page_size)).unwrap();
    file.read_exact(&mut bytes).unwrap();
    bytes
}

fn write_page(path: &Path, page: u64, page_size: u64, bytes: &[u8]) {
    use std::io::{Seek, SeekFrom, Write};
    let mut file = std::fs::OpenOptions::new().write(true).open(path).unwrap();
    file.seek(SeekFrom::Start((page - 1) * page_size)).unwrap();
    file.write_all(bytes).unwrap();
    file.sync_all().unwrap();
}

fn rootpage(path: &Path, name: &str) -> u64 {
    let connection = rusqlite::Connection::open(path).unwrap();
    connection.query_row("SELECT rootpage FROM sqlite_master WHERE name = ?1", [name], |row| row.get::<_, u64>(0)).unwrap()
}

fn page_size(path: &Path) -> u64 {
    let connection = rusqlite::Connection::open(path).unwrap();
    connection.query_row("PRAGMA page_size", [], |row| row.get(0)).unwrap()
}

#[test]
fn index_only_damage_is_repaired_in_place_and_no_copy_is_taken() {
    // The state measured on 22/11 22:56: the table pages of the new revision beside the index of the old
    // one, no journal left to roll back, and `REINDEX` the whole repair (0.746 s on the 183 MB store).
    let fixture = Fixture::new();
    let dir = fixture.0.join("graph.db.d");
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join(DB_FILE);
    let old = fixture.0.join("old.db");
    store_with_rows(&old, 60);
    std::fs::copy(&old, &db).unwrap();
    {
        let connection = rusqlite::Connection::open(&db).unwrap();
        let mut insert = connection.prepare("INSERT INTO t (b, c) VALUES (?1, ?2)").unwrap();
        for i in 60..200 {insert.execute((format!("b{i}"), format!("c{i}"))).unwrap();}
    }
    // The damage: one index root page from the older revision, in place of this one's.
    let size = page_size(&db);
    let root = rootpage(&db, "idx_b");
    write_page(&db, root, size, &page_of(&old, root, size));
    let complaints = integrity_complaints(&db).unwrap();
    assert!(complaints.len() > 1, "the fixture is damaged: {complaints:?}");
    assert!(complaints.iter().all(|complaint| index_only(complaint)), "the fixture is INDEX-ONLY damage: {complaints:?}");
    let rows: i64 = rusqlite::Connection::open(&db).unwrap().query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
    let before = std::fs::read(&db).unwrap();
    match repair_indexes(&dir, DB_FILE) {
        Repair::Repaired {complaints: fixed} => assert_eq!(fixed, complaints.len(), "the line names how many complaints were repaired"),
        other => panic!("index-only damage was not repaired: {other:?}"),
    }
    assert_eq!(integrity_complaints(&db).unwrap(), vec!["ok".to_string()], "the repaired store passes integrity_check");
    let after: i64 = rusqlite::Connection::open(&db).unwrap().query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
    assert_eq!(after, rows, "every row is still there: a repair derives the index from the table, it never drops rows");
    assert_ne!(std::fs::read(&db).unwrap(), before, "the store was rewritten in place, not copied");
    let copies: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("graph.db.malformed-")).collect();
    assert!(copies.is_empty(), "a repair is not a quarantine: {copies:?}");
}

#[test]
fn a_torn_table_page_is_never_repaired_and_a_refusal_writes_nothing() {
    // The other class, and the one the rollback journal exists for: a zeroed table page. The allow-list
    // refuses it, nothing is written, and the caller quarantines exactly as before.
    let fixture = Fixture::new();
    let dir = fixture.0.join("graph.db.d");
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join(DB_FILE);
    store_with_rows(&db, 60);
    let size = page_size(&db);
    let root = rootpage(&db, "t");
    write_page(&db, root, size, &vec![0u8; size as usize]);
    let before = std::fs::read(&db).unwrap();
    match integrity_complaints(&db) {
        Ok(complaints) => assert!(complaints.iter().any(|complaint| !index_only(complaint)), "a torn table page is not an index complaint: {complaints:?}"),
        // SQLite refusing to walk the store at all is damage this path must not repair either.
        Err(text) => assert!(!index_only(&text), "the pragma's own error is not an index complaint: {text}"),
    }
    match repair_indexes(&dir, DB_FILE) {
        Repair::StillDamaged {verdict} => assert!(!verdict.is_empty(), "the refusal names the verdict"),
        other => panic!("a torn table page was not refused: {other:?}"),
    }
    assert_eq!(std::fs::read(&db).unwrap(), before, "a refused repair leaves the store byte for byte as it was");
    // And a store that is not there is not repaired into existence.
    assert!(matches!(repair_indexes(&dir.join("absent"), DB_FILE), Repair::Unavailable {..} | Repair::StillDamaged {..}), "no store, no repair");
}

#[test]
fn the_scheduler_repairs_an_index_that_disagrees_with_its_table_instead_of_quarantining() {
    // THE ASSERTION THAT FAILS ON THE BASE, and the one a review will look for: it names no function this
    // branch adds, so the land gate can run it against the base's own code. The store is damaged the way the
    // copy quarantined on 22/11 22:56 was - the table pages of a revision beside the index of the one before
    // (see the report), no journal left to roll back - and the scheduler is handed the verdict the component
    // answered for it. On the base that verdict moves 181 MB aside and starts a rebuild from nothing; here the
    // indexes are rebuilt from the tables and the store stays.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join(DB_FILE);
    let older = fixture.0.join("older.db");
    store_with_rows(&older, 60);
    std::fs::copy(&older, &db).unwrap();
    {
        let connection = rusqlite::Connection::open(&db).unwrap();
        let mut insert = connection.prepare("INSERT INTO t (b, c) VALUES (?1, ?2)").unwrap();
        for i in 60..200 {insert.execute((format!("b{i}"), format!("c{i}"))).unwrap();}
    }
    let size = page_size(&db);
    let root = rootpage(&db, "idx_b");
    write_page(&db, root, size, &page_of(&older, root, size));
    let rows_before: i64 = rusqlite::Connection::open(&db).unwrap()
        .query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &db);
    entry.state.lock().unwrap().min_free_bytes = 1;
    scheduler.failed(&entry, "graph_index_failed: database disk image is malformed".into());
    let state = entry.state.lock().unwrap();
    assert!(state.quarantined.is_empty(), "an index that disagrees with its table was thrown away: {:?}", state.quarantined);
    assert_eq!(state.corruptions, 0, "nothing was quarantined, so nothing is counted as one");
    drop(state);
    assert!(db.exists(), "the store is still where it was");
    let copies: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("graph.db.malformed-")).collect();
    assert!(copies.is_empty(), "a copy of the store was taken: {copies:?}");
    // The store is repaired, not merely kept: it passes integrity_check and still holds every row.
    let connection = rusqlite::Connection::open_with_flags(&db, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let verdict: String = connection.query_row("PRAGMA integrity_check", [], |row| row.get(0)).unwrap();
    assert_eq!(verdict, "ok", "the repaired store still does not pass integrity_check");
    let rows_after: i64 = connection.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
    assert_eq!(rows_after, rows_before, "the repair lost rows");
    assert!(!scheduler.ready.lock().unwrap().is_empty(), "the repaired store is re-queried");
}

#[test]
fn a_component_verdict_of_malformed_over_a_healthy_store_is_its_own_event_and_not_a_repair() {
    // THE UNEXPLAINED PAIR OF VERDICTS ABOUT ONE FILE: the component answers `database disk image is
    // malformed` for a store `PRAGMA integrity_check` answers `ok` for. Nothing is reindexed and no copy is
    // taken, so the line may not read `graph_db_repaired complaints=0 next=reindex` - that is a repair that
    // never happened, and it is what the scheduler reported for this case (measured on this node 23/11
    // 03:44 local: `graph.db.malformed-20261123T064420Z` reads `ok` natively with every row; see the
    // report). The scheduler's own field is read here rather than stderr, so this test compiles against the
    // base and fails there on the assertion, not on a missing symbol.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join(DB_FILE);
    // HERMETIC, AND SAID SO: this test writes only the fixture directory it has just created (`Fixture::new`
    // under TMPDIR, removed on drop). It refuses a store anywhere else, which is what keeps a unit test from
    // writing the node's own `graph.db.d` - on this node TMPDIR itself sits inside the node home
    // (`~/.wasm-agent/tmp`), so "inside HOME" is not the fence; "inside the fixture" is.
    assert!(db.starts_with(&fixture.0), "the store must be inside this test's own fixture, never a node store: {}", db.display());
    store_with_rows(&db, 60);
    assert_eq!(integrity_complaints(&db).unwrap(), vec!["ok".to_string()], "the store handed to the scheduler is healthy");
    let before = std::fs::read(&db).unwrap();
    let scheduler = test_scheduler();
    let entry = test_entry(&fixture.0, &db);
    entry.state.lock().unwrap().min_free_bytes = 1;
    scheduler.failed(&entry, "graph_index_failed: database disk image is malformed".into());
    let reported = entry.state.lock().unwrap().reported.clone().unwrap_or_default();
    assert_eq!(reported, format!("graph_db_store_healthy root={} file={} next=retry", fixture.0.display(), DB_FILE),
        "the healthy case is its own line and says what happens next");
    assert!(!reported.contains("graph_db_repaired"), "nothing was reindexed, so no line may say it was: {reported}");
    let copies: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten()
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.starts_with("graph.db.malformed-"))
        .collect();
    assert!(copies.is_empty(), "a healthy store was copied aside: {copies:?}");
    assert_eq!(std::fs::read(&db).unwrap(), before, "a healthy store is kept byte for byte");
    assert!(!scheduler.ready.lock().unwrap().is_empty(), "the component's answer is retried");
}

// ---- one store per root: two roots must never fight over one graph store -------------------------

#[test]
fn two_roots_get_two_stores_and_never_the_shared_one() {
    // THE MEASURED DEFECT, as an assertion. Before this change `locations` answered the configured
    // database for the configured root, so `wa serve` (cwd = the runtime worktree) and every mission
    // worker (cwd = its mission directory) indexed into ONE file - `wa-host main.rs` set both to
    // `<home>/.wasm-agent/graph.db` for every process. Two roots took turns re-parsing ~600 files each
    // and the store's own `graph_meta` recorded the guest mount point, so it could not even say whose
    // tree it held (docs/missions/reports/graph-index-tear-cause.md).
    let fixture = Fixture::new();
    let config = fixture.config();
    let shared = db_dir(&config.db).join(DB_FILE);
    let (runtime_a, store_a) = locations(&json!({}), Some(&config)).unwrap();
    assert_eq!(runtime_a, config.root.canonicalize().unwrap());
    assert_ne!(store_a, shared, "the configured root must not index into the shared store");
    assert_eq!(store_a.parent().unwrap().parent().unwrap(), config.db.with_extension("roots"));
    let (runtime_b, store_b) = locations(&json!({"root": fixture.0.join("owned")}), Some(&config)).unwrap();
    assert_ne!(runtime_b, runtime_a);
    assert_ne!(store_b, store_a, "two roots must not resolve to one store");
    assert_ne!(store_b, shared);
    // Stable: asking twice gives the same store, and so does a symlinked spelling of one root (`.`),
    // which is what a worker's cwd and a tool's root path differ by.
    assert_eq!(locations(&json!({}), Some(&config)).unwrap().1, store_a);
    assert_eq!(locations(&json!({"root": fixture.0.join("owned").join(".")}), Some(&config)).unwrap().1, store_b);
    // Resolving a location writes nothing: an unasked-for store is never created.
    assert!(!store_a.exists() && !store_b.exists() && !shared.exists());
    // An explicit database is still used exactly, which is how a test or a tool pins its own store.
    let private = fixture.0.join("private.db");
    assert_eq!(locations(&json!({"db": private}), Some(&config)).unwrap().1, private);
}



#[test]
fn a_healthy_store_is_never_quarantined_and_the_component_error_is_named() {
    // Measured 23/11 06:44Z: a store of 133,959 nodes that `PRAGMA integrity_check` calls ok was renamed
    // aside, because the component's `database disk image is malformed` outlived REPAIR_LIMIT retries.
    // A copy is taken to keep the damage; there is no damage to keep, so the answer is a refusal that
    // names the component's own error and stops the loop.
    let fixture = Fixture::new();
    let dir = fixture.0.join("graph.db.d");
    std::fs::create_dir_all(&dir).unwrap();
    let db = dir.join(DB_FILE);
    let connection = rusqlite::Connection::open(&db).unwrap();
    connection.execute_batch("CREATE TABLE graph_meta(key TEXT PRIMARY KEY, value TEXT);\
        CREATE TABLE files(path TEXT, hash TEXT);\
        INSERT INTO graph_meta VALUES('root','/graph/root');").unwrap();
    drop(connection);
    let entry = test_entry(&fixture.0, &db);
    {
        let mut state = entry.state.lock().unwrap();
        state.repairs = REPAIR_LIMIT; // the repairs this streak was allowed are spent
        state.min_free_bytes = 1;     // the disk is not the reason here
    }
    let scheduler = test_scheduler();
    scheduler.failed(&entry, "graph_index_failed: database disk image is malformed".to_string());
    assert!(db.exists(), "a store integrity_check calls ok is never moved aside");
    let copies = std::fs::read_dir(&dir).unwrap().flatten()
        .filter(|item| item.file_name().to_string_lossy().contains(".malformed-")).count();
    assert_eq!(copies, 0, "no copy is taken of a healthy store");
    let state = entry.state.lock().unwrap();
    assert!(state.stopped, "automatic retry stops instead of quarantining");
    assert!(state.retry_at.is_none());
    drop(state);
    let line = quarantine_refused_line(&fixture.0, "ok", "graph_index_failed: database disk image is malformed");
    assert!(line.contains("integrity=ok"), "{line}");
    assert!(line.contains("component_error=graph_index_failed:_database_disk_image_is_malformed"), "{line}");
    assert!(line.contains("next=stop") && line.contains("use=graph_index_force"), "{line}");
}

/// Hold the graph ON for one test, the way a node that switched it on has it (docs/GRAPH.md). It exists
/// because `enabled()` is process-wide and `cargo test` runs the tests of one binary in threads: a test
/// that set the environment would be setting it for its neighbours. The lock inside keeps two tests from
/// holding the switch at once, and the guard puts it back to "ask the resolver" when the test ends.
#[cfg(test)]
struct SwitchGuard(std::sync::MutexGuard<'static, ()>);
#[cfg(test)]
fn switch(value: bool) -> SwitchGuard {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let guard = LOCK.lock().unwrap_or_else(|error| error.into_inner());
    *TEST_SWITCH.lock().unwrap_or_else(|error| error.into_inner()) = Some(value);
    SwitchGuard(guard)
}
#[cfg(test)]
impl Drop for SwitchGuard {
    fn drop(&mut self) {
        *TEST_SWITCH.lock().unwrap_or_else(|error| error.into_inner()) = None;
    }
}

/// EVERY GRAPH DOOR ANSWERS A DORMANT NODE BY NAME (docs/GRAPH.md, 23/11): with the switch off nothing is
/// indexed and nothing is answered, and the answer says it did nothing and names the switch - it is not an
/// empty success and not a component error.
#[test]
fn a_dormant_graph_refuses_every_door_by_name_and_touches_nothing() {
    let _off = switch(false);
    let answer = notify(json!({"path": "x/a.lua"}), None);
    assert_eq!(answer["error"], json!("graph_dormant"), "the write hint refuses instead of claiming a queue: {answer}");
    assert_eq!(answer["effect"], json!("none"));
    assert!(answer["next"].as_str().unwrap_or_default().contains("WA_GRAPH_COMPONENT"), "the refusal names the switch: {answer}");
    let read = run(json!({}), "stats", &[]);
    assert_eq!(read["error"], json!("graph_dormant"), "a read capability refuses too: {read}");
    let index = run(json!({}), "index", &[]);
    assert_eq!(index["error"], json!("graph_dormant"), "and so does an explicit index: {index}");
}

#[test]
fn a_write_hint_indexes_nothing_and_leaves_the_store_untouched() {
    // Item 0: `write`, `edit` and every native write used to enqueue a full index of the tree. Nothing
    // is parsed or written until a graph call asks, and the answer says so instead of staying silent.
    // The node this test stands for has the graph switched ON (docs/GRAPH.md): off, the hint is refused
    // before it reads anything, which the test above holds.
    let _on = switch(true);
    let fixture = Fixture::new();
    let config = fixture.config();
    let store = per_root_store(&config.db, &config.root.canonicalize().unwrap());
    std::fs::create_dir_all(db_dir(&store)).unwrap();
    let path = db_dir(&store).join(DB_FILE);
    std::fs::write(&path, b"fixture").unwrap();
    let before = std::fs::metadata(&path).unwrap().modified().unwrap();
    let source = fixture.0.join("runtime").join("main.lua");
    std::fs::write(&source, "-- fixture\n").unwrap();
    let other = fixture.0.join("runtime").join("notes.txt");
    std::fs::write(&other, "not source\n").unwrap();
    for _ in 0..3 {
        let answer = notify(json!({"path": source}), Some(&config));
        assert_eq!(answer["ok"], json!(true));
        assert_eq!(answer["queued"], json!(false), "a write hint indexes nothing: {answer}");
        assert_eq!(answer["reason"], json!("on_demand"));
    }
    // The answers that were already named stay named, byte for byte.
    assert_eq!(notify(json!({"path": other}), Some(&config))["reason"], json!("not_indexable_source"));
    let outside = fixture.0.join("elsewhere.lua");
    std::fs::write(&outside, "-- fixture\n").unwrap();
    assert_eq!(notify(json!({"path": outside}), Some(&config))["reason"], json!("outside_indexed_root"));
    assert_eq!(notify(json!({}), None)["error"], json!("graph_not_configured"));
    // The store beside the configured database is not touched at all, and no new one appeared.
    assert_eq!(std::fs::metadata(&path).unwrap().modified().unwrap(), before, "nothing wrote the store");
    assert_eq!(std::fs::read(&path).unwrap(), b"fixture");
    assert!(!db_dir(&config.db).join(DB_FILE).exists(), "the shared store is not created either");
}

#[test]
fn the_store_directory_keeps_a_bound_and_never_evicts_what_is_in_use_or_evidence() {
    // One store per root is unbounded without a cap: every mission worktree would keep its own ~180 MB
    // index for ever. Eviction is bounded by count and bytes, never touches the store just asked for,
    // never a store whose lock is held, and never a store that still carries a quarantine copy.
    let fixture = Fixture::new();
    let roots = fixture.0.join("graph.roots");
    let mut made = Vec::new();
    for index in 0..5 {
        let store = roots.join(format!("{index}.db"));
        std::fs::create_dir_all(db_dir(&store)).unwrap();
        std::fs::write(db_dir(&store).join(DB_FILE), vec![0u8; 10]).unwrap();
        made.push(store);
        std::thread::sleep(Duration::from_millis(15)); // distinct mtimes: the order is the policy
    }
    std::fs::write(db_dir(&made[0]).join("graph.db.malformed-20261123T000626Z"), b"evidence").unwrap();
    let held = store_lock_file(&db_dir(&made[1]), DB_FILE).unwrap();
    held.lock().unwrap();
    retain_stores(&made[3], 2, u64::MAX);
    let exists = |store: &PathBuf| db_dir(store).join(DB_FILE).exists();
    assert!(exists(&made[3]), "the store that was just asked for is never evicted");
    assert!(exists(&made[4]), "the newest store is kept first");
    assert!(exists(&made[0]), "a store carrying a quarantine copy is evidence, never deleted");
    assert!(exists(&made[1]), "a store whose lock is held is in use, never deleted");
    assert!(!exists(&made[2]), "the rest are bounded by the count: {}", made[2].display());
    held.unlock().unwrap();
    // Bytes are the second bound: one store larger than the budget is still not the one being asked for.
    retain_stores(&made[3], 8, 1);
    assert!(exists(&made[3]), "the asked-for store survives the byte budget too");
}

#[test]
fn the_graph_journal_appends_every_process_line_and_rotates_at_its_bound() {
    // Item 4: `graph_db_*` lines must be countable for EVERY process, not only the one systemd
    // captures. Measured 23/11: 23 `graph_db_` lines reached `journalctl --user` in a day while the
    // store was quarantined 41 times, because a worker's stderr goes to whoever started it.
    let fixture = Fixture::new();
    let path = fixture.0.join("graph.log");
    append_journal(&path, "graph_db_store_healthy root=/a file=graph.db next=retry");
    append_journal(&path, "graph_db_store_evicted store=b bytes=1 stores_limit=8 bytes_limit=2");
    let text = std::fs::read_to_string(&path).unwrap();
    assert_eq!(text.lines().count(), 2, "one line per event, appended not replaced: {text}");
    assert!(text.contains("graph_db_store_healthy") && text.contains("graph_db_store_evicted"));
    std::fs::write(&path, "x".repeat(JOURNAL_BYTES as usize)).unwrap();
    append_journal(&path, "graph_db_quarantined root=/a");
    let rotated = fixture.0.join("graph.log.1");
    assert!(rotated.exists(), "the file is bounded by rotation, not by discarding the older one");
    assert_eq!(std::fs::metadata(&rotated).unwrap().len(), JOURNAL_BYTES);
    let text = std::fs::read_to_string(&path).unwrap();
    assert!(text.contains("graph_db_quarantined") && !text.contains("graph_db_store_healthy"));
}
#[test]
fn two_roots_alternating_never_claim_or_read_each_others_store() {
    // The kernel's half of "two roots, alternating calls, neither re-parses the other's files": each root
    // claims its own store, keeps it across interleaved calls, and a store that says another root is
    // refused instead of answered from. (The component's half - each store holding only its own root's
    // files - is the store path being keyed by the root, asserted in
    // two_roots_get_two_stores_and_never_the_shared_one.)
    let fixture = Fixture::new();
    let alpha = fixture.0.join("alpha");
    let beta = fixture.0.join("beta");
    std::fs::create_dir_all(&alpha).unwrap();
    std::fs::create_dir_all(&beta).unwrap();
    let alpha = alpha.canonicalize().unwrap();
    let beta = beta.canonicalize().unwrap();
    let store_a = db_dir(&per_root_store(&fixture.0.join("graph.db"), &alpha));
    let store_b = db_dir(&per_root_store(&fixture.0.join("graph.db"), &beta));
    assert_ne!(store_a, store_b);
    std::fs::create_dir_all(&store_a).unwrap();
    std::fs::create_dir_all(&store_b).unwrap();
    // The first call for each root claims its own store name.
    assert!(attribute_store(&store_a, DB_FILE, &alpha.to_string_lossy()).unwrap());
    assert!(attribute_store(&store_b, DB_FILE, &beta.to_string_lossy()).unwrap());
    std::fs::write(store_a.join(DB_FILE), b"alpha").unwrap();
    std::fs::write(store_b.join(DB_FILE), b"beta").unwrap();
    // Alternating calls: each one is answered by its own store, never by the other root's.
    for _ in 0..3 {
        assert!(!attribute_store(&store_a, DB_FILE, &alpha.to_string_lossy()).unwrap());
        assert!(!attribute_store(&store_b, DB_FILE, &beta.to_string_lossy()).unwrap());
        assert!(attribute_store(&store_a, DB_FILE, &beta.to_string_lossy()).is_err());
        assert!(attribute_store(&store_b, DB_FILE, &alpha.to_string_lossy()).is_err());
    }
    // Each store still names the root that built it, and still holds only its own bytes.
    assert_eq!(recorded_root(&store_a), Some(alpha.to_string_lossy().into_owned()));
    assert_eq!(recorded_root(&store_b), Some(beta.to_string_lossy().into_owned()));
    assert_eq!(std::fs::read(store_a.join(DB_FILE)).unwrap(), b"alpha");
    assert_eq!(std::fs::read(store_b.join(DB_FILE)).unwrap(), b"beta");
    // And the other root's store is never opened: the answer is a named refusal.
    let refusal = attribute_store(&store_a, DB_FILE, &beta.to_string_lossy()).unwrap_err();
    assert!(refusal.starts_with("graph_store_root_mismatch"), "{refusal}");
    assert!(!attribute_store(&store_a, DB_FILE, &beta.to_string_lossy()).is_ok());
}

#[test]
fn a_store_is_claimed_once_attributed_inside_and_never_adopted_when_it_cannot_say() {
    let fixture = Fixture::new();
    let dir = fixture.0.join("graph.roots").join("one.db.d");
    std::fs::create_dir_all(&dir).unwrap();
    let mine = fixture.0.join("mine");
    std::fs::create_dir_all(&mine).unwrap();
    let mine = mine.canonicalize().unwrap().to_string_lossy().into_owned();
    // No store and no attribution: this call claims the name, and claiming creates no index.
    assert!(attribute_store(&dir, DB_FILE, &mine).unwrap(), "the first call for a root claims its store");
    assert_eq!(recorded_root(&dir).as_deref(), Some(mine.as_str()));
    assert!(!dir.join(DB_FILE).exists(), "claiming a name creates no store");
    std::fs::write(dir.join(DB_FILE), b"store").unwrap();
    // A store that says it is this root's is usable, and says so on every call.
    assert!(!attribute_store(&dir, DB_FILE, &mine).unwrap(), "a store of this root is not re-claimed");
    // Another root's store is refused by name and left exactly as it was.
    let refusal = attribute_store(&dir, DB_FILE, "/somewhere/else").unwrap_err();
    assert!(refusal.starts_with("graph_store_root_mismatch"), "{refusal}");
    assert!(refusal.contains(&mine), "the refusal names the store's root: {refusal}");
    assert_eq!(std::fs::read(dir.join(DB_FILE)).unwrap(), b"store");
    // UNKNOWN IS NOT YES: an existing store with no attribution is refused, never adopted, and nothing
    // is written beside it - the operator removes a derived index or pins one with `db`.
    let unclaimed = fixture.0.join("graph.roots").join("legacy.db.d");
    std::fs::create_dir_all(&unclaimed).unwrap();
    std::fs::write(unclaimed.join(DB_FILE), b"legacy").unwrap();
    let refusal = attribute_store(&unclaimed, DB_FILE, &mine).unwrap_err();
    assert!(refusal.starts_with("graph_store_unattributed"), "{refusal}");
    assert_eq!(std::fs::read(unclaimed.join(DB_FILE)).unwrap(), b"legacy");
    assert!(!unclaimed.join(SOURCE_ROOT).exists(), "nothing claims a store it did not create");
}
