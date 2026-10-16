//! Focused repair regressions: static evidence, never dynamic coverage proof.
use crate::{extract, Store};
use serde_json::{json, Value};
use std::path::PathBuf;
struct Fixture(PathBuf);
impl Fixture {
    fn new(tag: &str) -> Self {
        let p = std::env::temp_dir().join(format!(
            "graph-repair-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        Self(p)
    }
    fn write(&self, p: &str, s: &str) {
        let p = self.0.join(p);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, s).unwrap();
    }
    fn store(&self) -> Store {
        let mut s = Store::open(self.0.join("graph.db")).unwrap();
        s.index(&self.0, false).unwrap();
        s
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
#[test]
fn go_exact_unicode_receiver_types_declarations_and_imports() {
    let source="package demo\nimport alias \"example.test/demo/lib\"\ntype Store struct { Value int }\ntype Reader interface { Read() int }\ntype Alias = int\nconst Label = \"é🙂\"\nvar Global int\nfunc 自由() string { return \"é🙂\" }\nfunc (s *Store) 方法() int { return alias.Public() }\n";
    let ex = extract::extract("main.go", "go", source);
    for (name, kind) in [
        ("Store", "struct"),
        ("Reader", "interface"),
        ("Alias", "type"),
        ("Label", "const"),
        ("Global", "var"),
        ("自由", "fn"),
        ("Store.方法", "method"),
    ] {
        let n = ex
            .nodes
            .iter()
            .find(|n| n.name == name)
            .unwrap_or_else(|| panic!("missing {name}: {:?}", ex.nodes));
        assert_eq!(n.kind, kind);
        assert!(source.is_char_boundary(n.start_byte) && source.is_char_boundary(n.end_byte));
    }
    assert_eq!(ex.imports[0].alias, "alias");
    assert_eq!(ex.imports[0].module, "example.test/demo/lib");
    let f = Fixture::new("unicode");
    f.write("main.go", source);
    let s = f.store();
    let hit = s.search_symbols_json("自由", 4).unwrap();
    let h = &hit[0];
    let exact = s
        .symbol_source_json(
            "main.go",
            "自由",
            h["line"].as_i64().unwrap(),
            Some("fn"),
            0,
            20000,
        )
        .unwrap();
    assert_eq!(exact["source"], "func 自由() string { return \"é🙂\" }");
    assert_eq!(
        exact["source_version"],
        crate::store::sha256(source.as_bytes())
    );
    assert_eq!(exact["source_version"], h["source_version"]);
    let overview = s.architecture_json(&["languages".into()], 8).unwrap();
    assert!(overview.to_string().contains("go"));
    let audit = s
        .audit_json(
            &f.0,
            &json!({"changes":[{"path":"main.go","lines":[3,4,5,6,7,8,9]}]}),
        )
        .unwrap();
    assert_eq!(audit["mapped_lines"], 7, "{audit}");
}
#[test]
fn go_local_calls_resolve_but_interfaces_external_and_shadowed_stay_unresolved() {
    let f = Fixture::new("calls");
    f.write("go.mod", "module example.test/demo\n\ngo 1.23\n");
    f.write("main.go","package demo\nimport alias \"example.test/demo/lib\"\nimport \"fmt\"\ntype Reader interface { Read() int }\nfunc Known() {}\nfunc Use(r Reader, f func()) { Known(); alias.Public(); fmt.Printf(\"x\"); r.Read(); f() }\nfunc Shadow() { Known := func() {}; Known() }\n");
    f.write("lib/lib.go", "package lib\nfunc Public() {}\n");
    f.write(
        "other/no.go",
        "package other\nfunc Printf() {}\nfunc Read() {}\nfunc f() {}\n",
    );
    let mut s = f.store();
    let edges = s.explain("Use").unwrap().remove(0).1;
    let known = edges.iter().find(|e| e.target == "Known").unwrap();
    assert_eq!(known.resolution, "go_package_unique");
    assert_eq!(known.dst_path.as_deref(), Some("main.go"));
    let imported = edges.iter().find(|e| e.target == "alias.Public").unwrap();
    assert_eq!(imported.resolution, "go_local_import_unique");
    assert_eq!(imported.dst_path.as_deref(), Some("lib/lib.go"));
    for target in ["fmt.Printf", "dynamic::r.Read", "dynamic::f"] {
        let e = edges.iter().find(|e| e.target == target).unwrap();
        assert!(e.dst.is_none(), "{e:?}");
        assert_eq!(e.confidence, 0);
    }
    assert!(s
        .explain("Shadow")
        .unwrap()
        .remove(0)
        .1
        .iter()
        .all(|e| e.dst.is_none()));
    f.write("go.mod", "module changed.test/module\n");
    s.index(&f.0, false).unwrap();
    assert!(
        s.explain("Use")
            .unwrap()
            .remove(0)
            .1
            .iter()
            .find(|e| e.target == "alias.Public")
            .unwrap()
            .dst
            .is_none(),
        "module migration left stale import edge"
    );
}
#[test]
fn go_migration_freshness_and_exclusion_are_content_bound() {
    let f = Fixture::new("migration");
    f.write("main.go", "package demo\nfunc First() {}\n");
    f.write("pkg/active.go", "package active\nfunc Active() {}\n");
    f.write("vendor/private.go", "package private\nfunc Secret() {}\n");
    f.write(
        ".cache/private.go",
        "package private\nfunc CacheSecret() {}\n",
    );
    let mut s = f.store();
    assert_eq!(s.stats().unwrap().files, 2);
    s.conn
        .execute("UPDATE files SET hash='9:old-extractor'", [])
        .unwrap();
    assert_eq!(s.index(&f.0, false).unwrap().indexed, 2);
    assert_eq!(s.index(&f.0, false).unwrap().unchanged, 2);
    let old = s.search_symbols_json("First", 2).unwrap()[0]["source_version"].clone();
    f.write("main.go", "package demo\nfunc Later() {}\n");
    s.index(&f.0, false).unwrap();
    assert!(s.query("First", 2).unwrap().is_empty());
    assert_ne!(
        old,
        s.search_symbols_json("Later", 2).unwrap()[0]["source_version"]
    );
}
#[test]
fn source_domains_prioritize_active_without_hiding_history_or_active_tests() {
    let f = Fixture::new("domains");
    f.write("src/live.lua", "function resolve_route() return 1 end\n");
    f.write(
        "reviews/evidence/src/live.lua",
        "function resolve_route() return 2 end\nfunction historical_only() end\n",
    );
    f.write("docs/history/old.lua", "function archive_only() end\n");
    f.write(
        "tests/current.lua",
        "function resolve_route_test() resolve_route() end\n",
    );
    f.write(
        "tests/history/current.lua",
        "function active_fixture() end\n",
    );
    f.write(
        "src/archive/compress.lua",
        "function active_archive_feature() end\n",
    );
    f.write("src/caller.lua", "function caller() resolve_route() end\n");
    f.write("src/imports.lua","local live = require('src.live')\nlocal old = dofile('reviews/evidence/src/live.lua')\nfunction import_live() live.resolve_route() end\nfunction import_old() old.resolve_route() end\n");
    let s = f.store();
    let hits = s.search_symbols_json("resolve_route", 10).unwrap();
    assert_eq!(hits[0]["path"], "src/live.lua");
    assert_eq!(hits[0]["source_domain"], "active");
    let historic = hits
        .as_array()
        .unwrap()
        .iter()
        .find(|h| h["source_domain"] == "evidence")
        .unwrap();
    assert_eq!(historic["score_breakdown"]["source_domain"], -400);
    let exact = s
        .symbol_source_json(
            historic["path"].as_str().unwrap(),
            "resolve_route",
            1,
            Some("fn"),
            0,
            20000,
        )
        .unwrap();
    assert!(exact["source"].as_str().unwrap().contains("return 2"));
    assert_eq!(exact["symbol"]["source_domain"], "evidence");
    assert_eq!(
        s.search_symbols_json("historical_only", 2).unwrap()[0]["source_domain"],
        "evidence"
    );
    assert_eq!(
        s.search_symbols_json("archive_only", 2).unwrap()[0]["source_domain"],
        "historical"
    );
    assert_eq!(
        s.search_symbols_json("resolve_route_test", 2).unwrap()[0]["source_role"],
        "test"
    );
    assert_eq!(
        s.search_symbols_json("active_fixture", 2).unwrap()[0]["source_domain"],
        "active"
    );
    assert_eq!(
        s.search_symbols_json("active_archive_feature", 2).unwrap()[0]["source_domain"],
        "active"
    );
    assert_eq!(
        s.explain("caller").unwrap().remove(0).1[0]
            .dst_path
            .as_deref(),
        Some("src/live.lua")
    );
    assert_eq!(
        s.explain("import_live").unwrap().remove(0).1[0]
            .dst_path
            .as_deref(),
        Some("src/live.lua")
    );
    let historical = s.explain("import_old").unwrap().remove(0).1.remove(0);
    assert_eq!(
        historical.dst_path.as_deref(),
        Some("reviews/evidence/src/live.lua")
    );
    assert_eq!(historical.to_json()["dst_source_domain"], "evidence");
}
#[test]
fn unsupported_deleted_and_index_version_gaps_keep_patch_facts_and_counts() {
    let f = Fixture::new("facts");
    f.write("code.lua", "function current() end\n");
    f.write("data.txt", "unsupported\n");
    let s = f.store();
    let changes = json!([{ "path":"code.lua","stage":"index","lines":[1],"changed_line_count":1,"gap":"index_source_differs_from_worktree","index_source_version":"old"},{"path":"data.txt","stage":"worktree","lines":[1,2],"changed_line_count":2},{"path":"deleted.go","stage":"index","changed_line_count":12,"gap":"deleted_file"}]);
    let audit = s.audit_json(&f.0, &json!({"changes":changes})).unwrap();
    assert_eq!(audit["changed_lines"], 15);
    assert_eq!(audit["mapped_lines"], 0);
    assert_eq!(audit["gap_count"], 3);
    assert_eq!(audit["verdict"], "incomplete");
    assert_eq!(audit["patch_facts"]["rows"][0]["stage"], "index");
}
#[test]
fn impact_pages_all_patch_facts_including_104_unsupported_files() {
    let f = Fixture::new("paging");
    let mut changes = Vec::new();
    for i in 0..104 {
        let name = format!("data/{i}.txt");
        f.write(&name, "unsupported\n");
        changes.push(json!({"path":name,"stage":"index","lines":[1],"changed_line_count":1}));
    }
    let s = f.store();
    let mut req = json!({"changes":changes,"max_bytes":2048,"limit":8});
    let mut facts = Vec::<Value>::new();
    let mut gaps = 0;
    let mut pages = 0;
    loop {
        let r = s.impact_json(&f.0, &req).unwrap();
        assert!(serde_json::to_vec(&r).unwrap().len() <= 2048);
        assert_eq!(r["coverage"]["changed_lines"], 104);
        facts.extend(r["patch_facts"]["rows"].as_array().unwrap().clone());
        gaps += r["coverage"]["gaps"].as_array().unwrap().len();
        pages += 1;
        assert!(pages < 300);
        if r["next_cursor"].is_null() {
            break;
        }
        req["cursor"] = r["next_cursor"].clone();
    }
    assert_eq!(facts.len(), 104);
    assert_eq!(gaps, 104);
    let unique: std::collections::BTreeSet<_> =
        facts.iter().map(|r| r["path"].as_str().unwrap()).collect();
    assert_eq!(unique.len(), 104);
}

#[test]
fn go_module_tabs_crlf_and_nested_boundaries_remain_exact() {
    let module = "// é🙂\r\nmodule\texample.test/demo\r\ngo 1.23\r\n";
    let ex = extract::extract("go.mod", "go_module", module);
    let node = ex.nodes.iter().find(|n| n.kind == "module").unwrap();
    assert_eq!(node.line, 2);
    assert_eq!(
        &module[node.start_byte..node.end_byte],
        "module\texample.test/demo"
    );
    let f = Fixture::new("nested-module");
    f.write("go.mod", module);
    f.write("main.go","package main\nimport nested \"example.test/demo/nested\"\nfunc RootUse() { nested.Inner() }\n");
    f.write("nested/go.mod", "module other.test/nested\n");
    f.write(
        "nested/main.go",
        "package nested\nimport local \"other.test/nested/lib\"\nfunc Inner() { local.Local() }\n",
    );
    f.write("nested/lib/code.go", "package lib\nfunc Local() {}\n");
    let s = f.store();
    let root = s.explain("RootUse").unwrap().remove(0).1;
    assert!(
        root[0].dst.is_none(),
        "must not cross nested module boundary"
    );
    let inner = s.explain("Inner").unwrap().remove(0).1;
    assert_eq!(inner[0].dst_path.as_deref(), Some("nested/lib/code.go"));
}

#[test]
fn go_extension_case_does_not_escape_go_resolution_limits() {
    let f = Fixture::new("go-case");
    f.write("caller.GO", "package demo\nfunc Call() { External() }\n");
    f.write("other/external.go", "package other\nfunc External() {}\n");
    let s = f.store();
    let edges = s.explain("Call").unwrap().remove(0).1;
    assert!(edges[0].dst.is_none());
    assert_eq!(edges[0].resolution, "go_unresolved_selector_or_external");
}

#[test]
fn go_unknown_selector_cannot_guess_a_local_type_for_an_external_default_alias() {
    let f = Fixture::new("selector");
    f.write(
        "caller.go",
        "package demo\nimport \"external.test/pkg/v2\"\nfunc Caller() { pkg.Method() }\n",
    );
    f.write(
        "types.go",
        "package demo\ntype pkg struct {}\nfunc (p pkg) Method() {}\n",
    );
    let s = f.store();
    let edge = s.explain("Caller").unwrap().remove(0).1.remove(0);
    assert!(
        edge.dst.is_none(),
        "unknown package selector must not become a typed method edge"
    );
    assert_eq!(edge.resolution, "go_unresolved_selector_or_external");
}
