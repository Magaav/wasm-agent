//! Files: the text and image reads, the writes that fsync, the atomic rename and the removal, and
//! the path and byte facts a decision must not make from a name (docs/VAULT.md). The handlers are
//! in crate::host.
//!
//! One file per area, and this file is the whole registration of its capabilities: build.rs scans
//! this directory (src/registry_scan.rs) and capabilities::registry() is built from what it finds,
//! so adding or moving a capability edits this file and nothing else. docs/HOST.md keeps one
//! documented row per capability, which the drift test in capabilities checks against these rows.

use crate::capabilities::plain;

pub const ROWS: &[crate::capabilities::Capability] = &[
    plain!("read_file", ReadOnly, crate::host::read_file, "Read a UTF-8 text file; nil plus a named reason when missing, not text, or over the read limit"),
    plain!("read_image_base64", ReadOnly, crate::host::read_image_base64, "Read a bounded PNG/JPEG/WebP/GIF as base64 with its MIME type"),
    plain!("write_file", WritesFiles, crate::host::write_file, "Create or overwrite a text file"),
    plain!("append_file", WritesFiles, crate::host::append_file, "Append text to a file, created owner-only, and fsync it before answering"),
    plain!("rename_file", WritesFiles, crate::host::rename_file, "Rename a file atomically; refuses an existing target, so two writers cannot take the same spool"),
    plain!("remove_file", WritesFiles, crate::host::remove_file, "Remove a file (no reach beyond write_file with empty text); a directory is refused"),
    plain!("path_kind", ReadOnly, crate::host::path_kind, "Classify a path as file/dir/missing/other without reading it"),
    // What a path IS, for the one decision that must not be made from a name: whether a program is the
    // platform's (root-owned, not group/other-writable) or the connector's own code. and the sha256 of a
    // file read in chunks, so an approval can name a binary's bytes without loading them into Lua
    // (docs/VAULT.md, the vault approval).
    plain!("path_facts", ReadOnly, crate::host::path_facts, "A path's realpath, kind, size and (on unix) owner and mode bits, as JSON"),
    plain!("file_sha256", ReadOnly, crate::host::file_sha256, "SHA-256 of a file's bytes, read in chunks; nil plus a named reason when it cannot be read"),
    // What a file IS, from its leading bytes: the vault approval (round 8) allows node or a POSIX shell
    // by REALPATH and by this answer, so a copy of python called `node`, or a shell script named `bash`,
    // is refused whatever its name says.
    plain!("file_magic", ReadOnly, crate::host::file_magic, "A file's kind from its leading bytes: elf, macho or pe only for THIS host's own format, foreign for another platform's executable, plus script, text, binary, empty, missing, as JSON"),
    plain!("list_dir", ReadOnly, crate::host::list_dir, "List one directory's entries"),
    plain!("grep", ReadOnly, crate::host::grep, "Literal substring search over a directory or file with bounded, counted results"),
];
