use super::*;

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
    assert_eq!(runtime,config.root.canonicalize().unwrap());assert_eq!(db,config.db);
    let options=json!({"root":fixture.0.join("owned")});
    let (owned,cache)=locations(&options,Some(&config)).unwrap();
    assert_ne!(owned,runtime);assert_ne!(cache,db);
    assert_eq!(cache.parent().unwrap(),config.db.with_extension("roots"));
    let alias=json!({"root":fixture.0.join("owned").join(".")});
    assert_eq!(locations(&alias,Some(&config)).unwrap(),(owned,cache));
    assert!(!db.exists()); // Resolution itself has no index/write effect.
}

#[test]
fn explicit_database_override_is_preserved_with_verified_root() {
    let fixture=Fixture::new();let config=fixture.config();let db=fixture.0.join("private.db");
    let options=json!({"root":fixture.0.join("owned"),"db":db});
    assert_eq!(locations(&options,Some(&config)).unwrap().1,db);
    assert_eq!(locations(&options,None).unwrap().1,db);
    assert_eq!(locations(&json!({"root":config.root}),Some(&config)).unwrap().1,config.db);
}

#[test]
fn missing_or_file_root_never_falls_back_to_runtime() {
    let fixture=Fixture::new();let config=fixture.config();
    assert!(locations(&json!({"root":fixture.0.join("missing")}),Some(&config)).unwrap_err().contains("graph_root_unavailable"));
    let file=fixture.0.join("not-directory");std::fs::write(&file,b"fixture").unwrap();
    assert_eq!(locations(&json!({"root":file}),Some(&config)).unwrap_err(),"graph_root_not_directory");
    assert_eq!(locations(&json!({}),None).unwrap_err(),"graph_not_configured");
}
