//! The pure file questions the runner asks, out of the host so both processes answer them the same way.
//!
//! A vault approval is decided from a program's MAGIC and its DIGEST, and a launch from a name is resolved on
//! PATH: if the process that starts the child answered these differently from the one that admitted it, the
//! approval would be checking different bytes than the ones that run. They live here once
//! (ready-operations-slice-2.md).

use serde_json::{json, Value};

/// A bare name resolved through the PROCESS environment's PATH - the one a spawned child inherits, and
/// the one the kernel uses to start a program (operations.rs, the `program` branch of `start`).
///
/// host.executable_on_path below is the same answer from Lua, and it is not the same as
/// host.getenv("PATH"): that reads the host's config overrides first (resolved_env), so a node whose
/// config sets a PATH named one interpreter while the child ran another (round 7).
pub fn which_on_path(name: &str) -> Option<String> {
    let path = std::env::var("PATH").ok()?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join(name);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().to_string());
        }
    }
    None
}

pub fn file_magic_value(path: &str) -> serde_json::Value {
    use std::io::Read;
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) => return json!({"path": path, "magic": "missing",
            "error": format!("{:?}", error.kind())}),
    };
    if metadata.is_dir() { return json!({"path": path, "magic": "unreadable", "size": metadata.len()}); }
    if metadata.len() == 0 { return json!({"path": path, "magic": "empty", "size": 0}); }
    // Round 9: a bounded HEAD, not four bytes. A PE's magic is not at its start - it is at the offset
    // e_lfanew names - so four bytes cannot tell an MZ-only file from a real PE, and that difference is
    // exactly what the allow-list needs. Still never the whole file: a hundred-megabyte interpreter costs
    // these MAGIC_HEAD_BYTES and no more.
    let mut head = Vec::with_capacity(MAGIC_HEAD_BYTES.min(metadata.len() as usize));
    match std::fs::File::open(path) {
        Ok(file) => match file.take(MAGIC_HEAD_BYTES as u64).read_to_end(&mut head) {
            Ok(_) => {}
            Err(error) => return json!({"path": path, "magic": "unreadable",
                "error": format!("{:?}", error.kind())}),
        },
        Err(error) => return json!({"path": path, "magic": "unreadable",
            "error": format!("{:?}", error.kind())}),
    };
    let magic = classify_magic(&head);
    json!({"path": path, "magic": magic, "size": metadata.len()})
}

pub fn file_digest(path: &str) -> Result<String, String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).map_err(|error| format!("unreadable: {error}"))?;
    if let Ok(metadata) = file.metadata() {
        if metadata.len() > FILE_DIGEST_MAX_BYTES {
            return Err(format!("too_large: {} bytes", metadata.len()));
        }
    }
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buffer = vec![0u8; 256 * 1024];
    loop {
        match file.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => context.update(&buffer[..read]),
            Err(error) => return Err(format!("unreadable: {error}")),
        }
    }
    Ok(context.finish().as_ref().iter().map(|byte| format!("{byte:02x}")).collect())
}

/// How many leading bytes the kind is decided from: a bounded head, never the whole file. Large enough
/// for a PE's e_lfanew (typically 0x80-0x100) and for a universal binary's arch table.
pub const MAGIC_HEAD_BYTES: usize = 4096;

/// The host's own kind of each leading-byte shape: `elf`, `macho`, `pe` only for THIS host's format, and
/// `foreign` for another platform's executable. Also `script` (a shebang), `text`, `binary`, `empty`,
/// `missing` or `unreadable`.
pub fn classify_magic(head: &[u8]) -> &'static str {
    classify_magic_on(head, host_format())
}

/// A file's sha256, read in chunks; bounded by FILE_DIGEST_MAX_BYTES.
pub const FILE_DIGEST_MAX_BYTES: u64 = 512 * 1024 * 1024;

pub fn host_format() -> HostFormat {
    if cfg!(target_os = "linux") || cfg!(target_os = "android") { HostFormat::Elf }
    else if cfg!(target_os = "macos") || cfg!(target_os = "ios") { HostFormat::MachO }
    else if cfg!(target_os = "windows") { HostFormat::Pe }
    // A host this build was not written for: no format is native there (unknown is not yes).
    else { HostFormat::Unknown }
}

/// The classifier with the HOST named, so every case is testable on any machine: an ELF is `elf` on
/// Linux and `foreign` on macOS or Windows, and the same holds for the other two.
pub fn classify_magic_on(head: &[u8], host: HostFormat) -> &'static str {
    if head.starts_with(b"\x7fELF") { return native_if(host == HostFormat::Elf, "elf"); }
    if head.len() >= 4 {
        let magic = u32::from_be_bytes([head[0], head[1], head[2], head[3]]);
        match magic {
            // The thin Mach-O headers: 32/64-bit, each in both byte orders.
            0xfeed_face | 0xfeed_facf | 0xcefa_edfe | 0xcffa_edfe => {
                return native_if(host == HostFormat::MachO, "macho");
            }
            // The universal (fat) header, big-endian and its byte-swapped twin. Its count is what tells it
            // apart from a Java class, which starts with the same four bytes.
            0xcafe_babe => {
                return match fat_arch_count(head, false) {
                    Some(_) => native_if(host == HostFormat::MachO, "macho"),
                    None => "binary",
                };
            }
            0xbeba_feca => {
                return match fat_arch_count(head, true) {
                    Some(_) => native_if(host == HostFormat::MachO, "macho"),
                    None => "binary",
                };
            }
            _ => {}
        }
    }
    // PE: "MZ" alone is not an executable - the COFF header starts at e_lfanew (offset 0x3c) and begins
    // with "PE\0\0". A file whose e_lfanew is out of range, or does not point at "PE\0\0", is a DOS stub
    // or a decoy, never a native binary.
    if head.starts_with(b"MZ") {
        return if pe_header_at(head).is_some() { native_if(host == HostFormat::Pe, "pe") } else { "binary" };
    }
    if head.starts_with(b"#!") { return "script"; }
    if head.iter().all(|byte| *byte == 0x09 || *byte == 0x0a || *byte == 0x0d || (0x20..0x7f).contains(byte)) {
        return "text";
    }
    "binary"
}

/// This HOST's own executable format: the only one a "native binary" may be. An ELF on macOS is a foreign
/// binary, and foreign is not native - the allow-list admits what this node can actually run.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostFormat { Elf, MachO, Pe, Unknown }


fn native_if(is_host: bool, family: &'static str) -> &'static str {
    if is_host { family } else { "foreign" }
}

/// The architecture count of a universal header, or None when the header is not one: a count of 0 or more
/// than FAT_MAX_ARCH, or a table that does not fit in the bytes read, is not a fat binary (and a Java
/// class, whose next four bytes are a version, is never read as one).
pub fn fat_arch_count(head: &[u8], little_endian: bool) -> Option<u32> {
    if head.len() < 8 { return None; }
    let raw = [head[4], head[5], head[6], head[7]];
    let count = if little_endian { u32::from_le_bytes(raw) } else { u32::from_be_bytes(raw) };
    if count == 0 || count > FAT_MAX_ARCH { return None; }
    // Each entry is 20 bytes: a header whose table is not even present is not a universal binary.
    if head.len() < 8 + 20 * count as usize { return None; }
    Some(count)
}

/// The offset a PE's COFF header is at, when these bytes really hold one.
pub fn pe_header_at(head: &[u8]) -> Option<usize> {
    if head.len() < 0x40 { return None; }
    let offset = u32::from_le_bytes([head[0x3c], head[0x3d], head[0x3e], head[0x3f]]) as usize;
    if offset < 0x40 || offset + 4 > head.len() { return None; }
    if &head[offset..offset + 4] != b"PE\0\0" { return None; }
    Some(offset)
}

/// The most architectures a universal (fat) Mach-O header may name. It is also what separates 0xcafebabe
/// the FAT BINARY from 0xcafebabe the JAVA CLASS: a class file follows it with minor+MAJOR version, and no
/// Java class has a major below 45, while a fat header names one to a few architectures.
pub const FAT_MAX_ARCH: u32 = 15;
