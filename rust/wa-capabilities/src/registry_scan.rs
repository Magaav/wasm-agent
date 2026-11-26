//! The build-time scan behind the capability registry: which files declare capability rows.
//!
//! A capability's registration is data - one `pub const ROWS` in a file under `src/capability_rows/`,
//! beside the module that implements the handlers it names - and this module is the one place that
//! lists those files. `build.rs` runs [`generate`] over the directory and writes the aggregate
//! `capabilities.rs` includes, so a new row file is collected without an edit to `capabilities.rs` or
//! to `host.rs` (mission capability-registration-is-data, item 4).
//!
//! The same source is compiled twice on purpose: by `build.rs`, which writes the aggregate, and into
//! this crate, so `tests/capability_row_discovery.rs` exercises the function the build actually ran,
//! on a directory it makes itself. A scan nothing tests is a scan that can silently collect nothing.
use std::path::{Path, PathBuf};

/// The directory, relative to the crate root, where the row files live: one file per capability area.
pub const DIRECTORY: &str = "src/capability_rows";

/// The row files, in name order.
///
/// A directory that is missing or empty is an error and never an empty registry: a node whose rows
/// could not be found can do nothing, and it has to say so at build time instead of starting and
/// refusing every capability at run time.
pub fn row_files(directory: &Path) -> Result<Vec<PathBuf>, String> {
    let entries = std::fs::read_dir(directory)
        .map_err(|error| format!("no capability-row directory at {}: {error}", directory.display()))?;
    let mut files = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| format!("{}: {error}", directory.display()))?;
        let path = entry.path();
        if path.extension().and_then(|extension| extension.to_str()) != Some("rs") || !path.is_file() {
            continue;
        }
        files.push(path);
    }
    files.sort();
    if files.is_empty() {
        return Err(format!(
            "{} holds no row files: a registry with no rows is a node that can do nothing",
            directory.display()
        ));
    }
    Ok(files)
}

/// One row file's module name: its file stem, which has to be a Rust identifier because it becomes one.
pub fn module_name(file: &Path) -> Result<String, String> {
    let stem = file.file_stem().and_then(|stem| stem.to_str()).unwrap_or_default();
    let mut characters = stem.chars();
    let starts = matches!(characters.next(), Some(first) if first.is_ascii_alphabetic() || first == '_');
    if !starts || !characters.all(|character| character.is_ascii_alphanumeric() || character == '_') {
        return Err(format!(
            "{} is not a Rust module name: a row file is a module, so its name has to be one",
            file.display()
        ));
    }
    Ok(stem.to_string())
}

/// The aggregate: one `mod` per row file, and the list `capabilities::registry()` is built from.
pub fn generate(directory: &Path) -> Result<String, String> {
    let mut modules = Vec::new();
    let mut text = String::from(
        "// Written by wa-capabilities/build.rs from the files in src/capability_rows/ (registry_scan).\n\
         // Do not edit: a row file declares its own area's capabilities, and this list is discovered.\n",
    );
    for file in row_files(directory)? {
        let name = module_name(&file)?;
        let source = std::fs::read_to_string(&file)
            .map_err(|error| format!("{}: {error}", file.display()))?;
        if !source.lines().any(|line| line.trim_start().starts_with("pub const ROWS:")) {
            return Err(format!(
                "{} declares no `pub const ROWS:`, so it would register nothing",
                file.display()
            ));
        }
        let absolute = file.canonicalize().map_err(|error| format!("{}: {error}", file.display()))?;
        text.push_str(&format!("#[path = {:?}] pub mod {name};\n", absolute.display().to_string()));
        modules.push(name);
    }
    text.push_str("\npub static SECTIONS: &[&[crate::capabilities::Capability]] = &[\n");
    for name in &modules {
        text.push_str(&format!("    {name}::ROWS,\n"));
    }
    text.push_str("];\n");
    Ok(text)
}

