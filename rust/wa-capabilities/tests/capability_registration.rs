//! The registry is DATA: every capability row lives in its own area's file under `src/capability_rows/`,
//! and the shared module declares none.
//!
//! This is the row that fails when registration goes back to being an edit to a shared file. It reads the
//! sources on disk, so it judges the SHAPE of the registration rather than the behaviour of one call, and it
//! reads them with its own parser instead of the build script's scan on purpose: two independent readers
//! have to agree, the same rule the `docs/HOST.md` drift test in `capabilities` follows.
use std::collections::BTreeMap;
use std::path::PathBuf;

fn crate_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// The rows a source file declares, as written: `plain!("name", EffectClass, handler, "description")`.
/// Only the name and the effect class are read here; the handler is a path the compiler resolves.
fn declared_rows(text: &str) -> Vec<(String, String)> {
    let mut rows = Vec::new();
    for line in text.lines() {
        let trimmed = line.trim_start();
        let rest = trimmed
            .strip_prefix("plain!(")
            .or_else(|| trimmed.strip_prefix("upvalue!("));
        let Some(rest) = rest else { continue };
        let mut fields = rest.split(',');
        let name = fields
            .next()
            .expect("a row names its capability")
            .trim()
            .trim_matches('"')
            .to_string();
        let effect = fields.next().expect("a row names its effect class").trim().to_string();
        assert!(!name.is_empty(), "a row declares an empty name: {line}");
        rows.push((name, effect));
    }
    rows
}

/// The wire spelling `Effect::as_str` writes, read back here so this checker shares no code with the
/// registry it checks. An unknown class is a failure, never a pass.
fn effect_class(identifier: &str) -> &'static str {
    match identifier {
        "ReadOnly" => "read-only",
        "WritesFiles" => "writes files",
        "RunsProcess" => "runs a process",
        "Network" => "network",
        "Device" => "device",
        other => panic!("a row declares an effect class the inventory does not promise: {other}"),
    }
}

#[test]
fn every_capability_is_a_row_in_its_own_file() {
    // 1. The shared module declares no row itself. A capability added here is a capability whose
    //    registration is an edit to the file every other capability also edits.
    let shared = std::fs::read_to_string(crate_root().join("src/capabilities.rs"))
        .expect("capabilities.rs is readable");
    let shared_rows = declared_rows(&shared);
    assert!(
        shared_rows.is_empty(),
        "capabilities.rs declares {} capability row(s) itself ({}...): a row belongs in its own area's \
         file under src/capability_rows/, so that adding or moving a capability never edits a shared file",
        shared_rows.len(),
        shared_rows
            .iter()
            .take(5)
            .map(|(name, _)| name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );

    // 2. The row files exist, and every one of them registers something.
    let rows_dir = crate_root().join("src/capability_rows");
    assert!(
        rows_dir.is_dir(),
        "{} is not a directory: the row files under it are what the build script collects",
        rows_dir.display()
    );
    let mut files: Vec<PathBuf> = std::fs::read_dir(&rows_dir)
        .expect("the row directory is readable")
        .map(|entry| entry.expect("a readable directory entry").path())
        .filter(|path| path.extension().and_then(|extension| extension.to_str()) == Some("rs"))
        .collect();
    files.sort();
    assert!(!files.is_empty(), "no row files under {}", rows_dir.display());

    let mut declared: BTreeMap<String, (String, String)> = BTreeMap::new();
    for file in &files {
        let label = file
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("?")
            .to_string();
        let text = std::fs::read_to_string(file).expect("a row file is readable");
        let rows = declared_rows(&text);
        assert!(!rows.is_empty(), "{label} declares no rows: a row file that lists nothing registers nothing");
        for (name, effect) in rows {
            if let Some((_, first)) = declared.insert(name.clone(), (effect, label.clone())) {
                panic!("`{name}` is declared twice: in {first} and in {label}");
            }
        }
    }

    // 3. The live registry is exactly what those files declare - both directions, same effect class - so a
    //    row added to a file IS a capability, and nothing is registered from anywhere else.
    // Through `inventory()`, the surface `wa capabilities --json` answers with, and not through the
    // function this change added: the row has to FAIL on the code before it with an assertion that names
    // what is wrong, rather than die on a symbol that code did not have yet.
    let live: BTreeMap<String, String> = wa_capabilities::capabilities::inventory()
        .iter()
        .map(|capability| (capability.name.to_string(), capability.effect.as_str().to_string()))
        .collect();
    let unaccounted: Vec<&String> = live.keys().filter(|name| !declared.contains_key(*name)).collect();
    assert!(
        unaccounted.is_empty(),
        "registered but no row file declares it (a second registration path): {unaccounted:?}"
    );
    let missing: Vec<&String> = declared.keys().filter(|name| !live.contains_key(*name)).collect();
    assert!(
        missing.is_empty(),
        "declared in a row file but not in the live registry: {missing:?}"
    );
    for (name, (effect, file)) in &declared {
        assert_eq!(
            live.get(name).map(String::as_str),
            Some(effect_class(effect)),
            "the row for `{name}` in {file} and the registry disagree about its effect class"
        );
    }
}

