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
