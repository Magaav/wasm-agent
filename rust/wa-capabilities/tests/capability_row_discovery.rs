//! A row file is DISCOVERED: the scan `build.rs` runs finds it with no other file edited.
//!
//! `wa_capabilities::registry_scan` is the very source the build script compiles, and these rows run that
//! function on a directory they make themselves. That is the only way this repository can prove discovery
//! without adding a capability to the shipped registry, which would change `capabilities::digest()` - the
//! value `/health` publishes and an installed Lua tree pins.
use std::path::Path;

const ROWS: &str = "pub const ROWS: &[crate::capabilities::Capability] = &[];\n";

fn write(directory: &Path, name: &str, body: &str) {
    std::fs::write(directory.join(name), body).expect("write a row file");
}

#[test]
fn a_row_file_added_on_its_own_is_collected() {
    let directory = tempfile::tempdir().expect("a scratch directory");
    write(directory.path(), "probe.rs", ROWS);
    write(directory.path(), "zzz_second.rs", ROWS);
    let aggregate = wa_capabilities::registry_scan::generate(directory.path()).expect("the scan answers");
    assert!(
        aggregate.contains("pub mod probe;") && aggregate.contains("probe::ROWS,"),
        "a row file added on its own is a module the aggregate collects:\n{aggregate}"
    );
    assert!(
        aggregate.contains("pub mod zzz_second;") && aggregate.contains("zzz_second::ROWS,"),
        "and so is the next one, with no other file edited:\n{aggregate}"
    );

    // The aggregate the build actually wrote comes from the same scan over the real directory, so every
    // row file in the tree is in it - a file the build script did not see would be missing here.
    let real = Path::new(env!("CARGO_MANIFEST_DIR")).join(wa_capabilities::registry_scan::DIRECTORY);
    let generated = wa_capabilities::registry_scan::generate(&real).expect("the real registry scans");
    for file in wa_capabilities::registry_scan::row_files(&real).expect("the real row files") {
        let name = wa_capabilities::registry_scan::module_name(&file).expect("a module name");
        assert!(
            generated.contains(&format!("{name}::ROWS,")),
            "{name} is not in the aggregate the build writes"
        );
    }
    assert_eq!(
        generated.matches("::ROWS,").count(),
        wa_capabilities::registry_scan::row_files(&real).expect("the real row files").len(),
        "the aggregate collects exactly the row files, one row block each"
    );
}

#[test]
fn a_directory_with_no_rows_is_refused_by_name() {
    let directory = tempfile::tempdir().expect("a scratch directory");
    let error = wa_capabilities::registry_scan::generate(directory.path())
        .expect_err("an empty directory is not a registry");
    assert!(
        error.contains("holds no row files"),
        "the refusal says what is wrong instead of building an empty registry: {error}"
    );
}

#[test]
fn a_file_that_declares_no_rows_is_refused_by_name() {
    let directory = tempfile::tempdir().expect("a scratch directory");
    write(directory.path(), "hollow.rs", "// nothing here\n");
    let error = wa_capabilities::registry_scan::generate(directory.path())
        .expect_err("a row file that declares no rows is refused");
    assert!(
        error.contains("hollow.rs") && error.contains("pub const ROWS"),
        "the refusal names the file and the reason: {error}"
    );
}

