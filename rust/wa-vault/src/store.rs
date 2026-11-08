//! Where the document and the audit log live.
//!
//! Two implementations, and they are the same two places the design names: 0600 files (the CLI, and a
//! node that runs the vault in-process) and bytes in memory (the tests, and the shape a component
//! fills from its own kv namespace). There is no path here that reads a value: the store sees the
//! document - ciphertext and metadata - and the audit lines.
//!
//! `FileStore::save` is a temp-file-and-rename so a crash mid-write leaves the previous document
//! whole. `append` is an append: the log is the one file that only ever grows, and a rewrite of it
//! would destroy the evidence the chain exists to protect.
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// The document file, under the store directory.
pub const DOC_FILE: &str = "vault.json";
/// The audit log file, under the store directory.
pub const AUDIT_FILE: &str = "audit.log";

pub trait Store: Send + Sync {
    /// The document, or `None` for a vault that has never been written.
    fn load(&self) -> Result<Option<Vec<u8>>, String>;
    fn save(&self, bytes: &[u8]) -> Result<(), String>;
    /// Append one audit line (a newline is added by the store).
    fn append(&self, line: &str) -> Result<(), String>;
    /// The whole audit log, as text.
    fn audit(&self) -> Result<String, String>;
}

pub struct FileStore {
    dir: PathBuf,
}

impl FileStore {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        FileStore { dir: dir.into() }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    fn doc_path(&self) -> PathBuf {
        self.dir.join(DOC_FILE)
    }
}

impl Store for FileStore {
    fn load(&self) -> Result<Option<Vec<u8>>, String> {
        match std::fs::read(self.doc_path()) {
            Ok(bytes) => Ok(Some(bytes)),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(format!("vault_read:{error}")),
        }
    }

    fn save(&self, bytes: &[u8]) -> Result<(), String> {
        std::fs::create_dir_all(&self.dir).map_err(|error| format!("vault_dir:{error}"))?;
        let temporary = self.dir.join(format!(".{DOC_FILE}.{}.tmp", std::process::id()));
        {
            let mut file = std::fs::File::create(&temporary).map_err(|error| format!("vault_write:{error}"))?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let _ = file.set_permissions(std::fs::Permissions::from_mode(0o600));
            }
            file.write_all(bytes).map_err(|error| format!("vault_write:{error}"))?;
            file.sync_all().map_err(|error| format!("vault_write:{error}"))?;
        }
        std::fs::rename(&temporary, self.doc_path()).map_err(|error| format!("vault_rename:{error}"))
    }

    fn append(&self, line: &str) -> Result<(), String> {
        std::fs::create_dir_all(&self.dir).map_err(|error| format!("vault_dir:{error}"))?;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join(AUDIT_FILE))
            .map_err(|error| format!("vault_audit_open:{error}"))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = file.set_permissions(std::fs::Permissions::from_mode(0o600));
        }
        writeln!(file, "{line}").map_err(|error| format!("vault_audit_write:{error}"))
    }

    fn audit(&self) -> Result<String, String> {
        match std::fs::read_to_string(self.dir.join(AUDIT_FILE)) {
            Ok(text) => Ok(text),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
            Err(error) => Err(format!("vault_audit_read:{error}")),
        }
    }
}

/// Bytes in memory. Two mutexes rather than one so a test can read the audit log while the document
/// is being written; the engine never takes both at once in a way that could deadlock.
#[derive(Default)]
pub struct MemoryStore {
    doc: Mutex<Option<Vec<u8>>>,
    audit: Mutex<String>,
}

impl MemoryStore {
    pub fn new() -> Self {
        MemoryStore::default()
    }

    /// The document as the engine left it, for a test that wants to look at the *file* rather than the
    /// value.
    pub fn document(&self) -> Option<Vec<u8>> {
        self.doc.lock().expect("doc lock").clone()
    }
}

impl Store for MemoryStore {
    fn load(&self) -> Result<Option<Vec<u8>>, String> {
        Ok(self.doc.lock().expect("doc lock").clone())
    }

    fn save(&self, bytes: &[u8]) -> Result<(), String> {
        *self.doc.lock().expect("doc lock") = Some(bytes.to_vec());
        Ok(())
    }

    fn append(&self, line: &str) -> Result<(), String> {
        let mut log = self.audit.lock().expect("audit lock");
        log.push_str(line);
        log.push('\n');
        Ok(())
    }

    fn audit(&self) -> Result<String, String> {
        Ok(self.audit.lock().expect("audit lock").clone())
    }
}
