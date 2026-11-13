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
fn one_quarantine_copy_per_store_not_one_per_detection() {
    // 77 copies in `graph.db.d/` on node `work`, 30 on `openclaw`: each detection left its own. The
    // newest is the evidence worth keeping, so the copy it replaces is removed - by name, and only
    // for this store's own siblings.
    let fixture = Fixture::new();
    let dir = db_dir(&fixture.0.join("graph.db"));
    std::fs::create_dir_all(&dir).unwrap();
    let entry = test_entry(&fixture.0, &dir.join(DB_FILE));
    for stamp in ["20261110T220000Z", "20261111T030000Z"] {
        std::fs::write(dir.join(DB_FILE), format!("broken {stamp}")).unwrap();
        let moved = quarantine_database(&entry, stamp).unwrap();
        assert_eq!(moved.len(), 1, "{stamp}: the store is moved aside");
        let copies: Vec<String> = std::fs::read_dir(&dir).unwrap().flatten()
            .map(|entry| entry.file_name().to_string_lossy().into_owned())
            .filter(|name| name.starts_with("graph.db.malformed-")).collect();
        assert_eq!(copies, vec![format!("graph.db.malformed-{stamp}")], "exactly one copy, the newest: {copies:?}");
        assert_eq!(std::fs::read_to_string(dir.join(format!("graph.db.malformed-{stamp}"))).unwrap(), format!("broken {stamp}"));
    }
    // A sibling of ANOTHER store is not this store's business.
    std::fs::write(dir.join("jobs.db.malformed-20261101T000000Z"), "other").unwrap();
    std::fs::write(dir.join(DB_FILE), "broken again").unwrap();
    quarantine_database(&entry, "20261111T040000Z").unwrap();
    assert!(dir.join("jobs.db.malformed-20261101T000000Z").exists(), "another store's quarantine is left alone");
}
