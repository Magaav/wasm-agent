//! The reserved meta keys, and the component identity that owns a namespace.
//!
//! Everything under `__wa/` is host-owned. The values are stored as decimal/`String` text on
//! purpose: `sqlite3` on the host's kv file and `strings` on a snapshot are the operator's debugger,
//! and a version that reads as `7` beats one that reads as a four-byte integer in a hex dump.
//!
//! The schema version is a **monotone integer** (v1, v2, ...), not the component's semver. The two
//! answer different questions: the semver says which build is installed, the integer says which
//! migration steps have been applied. Tying them together would make every version bump a migration
//! and every migration a version bump; `docs/STATE.md` has the rule that connects them.

use crate::kv::Kv;
use crate::{Error, Result};

/// Anything under this prefix belongs to this crate and the host, never to the component.
pub const RESERVED_PREFIX: &[u8] = b"__wa/";

pub fn is_reserved(key: &[u8]) -> bool {
    key.starts_with(RESERVED_PREFIX)
}

/// The reserved keys, as constants because a typo in one of them would read as "not migrated yet".
pub mod key {
    /// Monotone schema version of this namespace, decimal text.
    pub const SCHEMA_VERSION: &[u8] = b"__wa/meta/schema";
    /// Component id that owns the namespace (`wa-whatsapp`, `agent-core`, ...).
    pub const COMPONENT: &[u8] = b"__wa/meta/component";
    /// Semver of the component build installed when this namespace was last opened.
    pub const COMPONENT_VERSION: &[u8] = b"__wa/meta/component-version";
    /// sha256 of the component that last completed a migration (or created the namespace).
    pub const LAST_MIGRATED_BY: &[u8] = b"__wa/meta/last-migrated-by";
    pub const LAST_MIGRATED_AT: &[u8] = b"__wa/meta/last-migrated-at";
    pub const CREATED_AT: &[u8] = b"__wa/meta/created-at";
    pub const UPDATED_AT: &[u8] = b"__wa/meta/updated-at";
    /// The in-flight migration, JSON ([`crate::Journal`]). Present only while one is unfinished.
    pub const JOURNAL: &[u8] = b"__wa/meta/migration/journal";
    /// The changes the in-flight step is applying, binary ([`crate::Change`] encoding).
    pub const PENDING: &[u8] = b"__wa/meta/migration/pending";
}

/// Who is asking. The id is the namespace owner; the pin is what `last_migrated_by` records, so an
/// operator can answer "which build moved this data?" from the state alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ComponentInfo {
    pub id: String,
    pub version: String,
    pub sha256: String,
}

impl ComponentInfo {
    pub fn new(
        id: impl Into<String>,
        version: impl Into<String>,
        sha256: impl Into<String>,
    ) -> Result<Self> {
        let info = ComponentInfo {
            id: id.into(),
            version: version.into(),
            sha256: sha256.into(),
        };
        info.validate()?;
        Ok(info)
    }

    /// Refuse a malformed identity here rather than writing it into state: the id decides who may
    /// open the namespace, and the pin is what an import compares against.
    pub fn validate(&self) -> Result<()> {
        if !ident(&self.id) {
            return Err(Error::Corrupt(format!(
                "component id {:?} is not a plain name",
                self.id
            )));
        }
        if !is_semver(&self.version) {
            return Err(Error::Corrupt(format!(
                "component version {:?} is not semver",
                self.version
            )));
        }
        if !is_sha256(&self.sha256) {
            return Err(Error::Corrupt(
                "component pin is not a lowercase sha256 hex digest".into(),
            ));
        }
        Ok(())
    }
}

fn ident(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 100
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.')
}

/// `major.minor.patch` with an optional `-prerelease`/`+build` suffix. Small on purpose: the host
/// does the real version resolution, this only refuses something that is obviously not a version.
pub fn is_semver(s: &str) -> bool {
    let (core, suffix) = match s.find(['-', '+']) {
        Some(at) => (&s[..at], Some(&s[at + 1..])),
        None => (s, None),
    };
    let numbers: Vec<&str> = core.split('.').collect();
    if numbers.len() != 3
        || !numbers
            .iter()
            .all(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
    {
        return false;
    }
    match suffix {
        None => true,
        Some(suffix) => {
            !suffix.is_empty()
                && suffix
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
        }
    }
}

fn is_sha256(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// The metadata of one namespace: what it is, at which schema version, touched by whom.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Meta {
    pub schema_version: u32,
    pub component: String,
    pub component_version: String,
    pub last_migrated_by: String,
    pub created_at_ms: u64,
    pub last_migrated_at_ms: u64,
}

impl Meta {
    /// Read the metadata, or `None` if the namespace has never been initialised. A **partial** set
    /// of meta keys is corruption, not "almost initialised": guessing the missing half is how a
    /// namespace silently restarts at v1 and skips its migrations.
    pub fn read(kv: &mut dyn Kv) -> Result<Option<Meta>> {
        let schema = kv.get(key::SCHEMA_VERSION)?;
        if schema.is_none() {
            if kv.get(key::COMPONENT)?.is_some() {
                return Err(Error::Corrupt(
                    "meta has a component but no schema version".into(),
                ));
            }
            return Ok(None);
        }
        let text = |kv: &mut dyn Kv, key: &[u8]| -> Result<String> {
            match kv.get(key)? {
                Some(bytes) => String::from_utf8(bytes)
                    .map_err(|_| Error::Corrupt(format!("meta {} is not utf-8", text_key(key)))),
                None => Err(Error::Corrupt(format!(
                    "meta {} is missing",
                    text_key(key)
                ))),
            }
        };
        let number = |kv: &mut dyn Kv, key: &[u8]| -> Result<u64> {
            let raw = text(kv, key)?;
            raw.parse::<u64>()
                .map_err(|_| Error::Corrupt(format!("meta {} is not a number", text_key(key))))
        };
        let meta = Meta {
            schema_version: number(kv, key::SCHEMA_VERSION)?
                .try_into()
                .map_err(|_| Error::Corrupt("schema version does not fit u32".into()))?,
            component: text(kv, key::COMPONENT)?,
            component_version: text(kv, key::COMPONENT_VERSION)?,
            last_migrated_by: text(kv, key::LAST_MIGRATED_BY)?,
            created_at_ms: number(kv, key::CREATED_AT)?,
            last_migrated_at_ms: number(kv, key::LAST_MIGRATED_AT)?,
        };
        if !ident(&meta.component) || !is_sha256(&meta.last_migrated_by) {
            return Err(Error::Corrupt("meta component or pin is malformed".into()));
        }
        if !is_semver(&meta.component_version) {
            return Err(Error::Corrupt(
                "meta component version is not semver".into(),
            ));
        }
        Ok(Some(meta))
    }

    /// Write all meta keys. Ordering: the schema version goes first, so a crash in the middle leaves
    /// a namespace whose version is right and whose timestamps are stale - never the reverse, which
    /// would let the next run migrate data that is already migrated.
    pub fn write(&self, kv: &mut dyn Kv, now_ms: u64) -> Result<()> {
        kv.put(
            key::SCHEMA_VERSION,
            self.schema_version.to_string().as_bytes(),
        )?;
        kv.put(key::COMPONENT, self.component.as_bytes())?;
        kv.put(key::COMPONENT_VERSION, self.component_version.as_bytes())?;
        kv.put(key::LAST_MIGRATED_BY, self.last_migrated_by.as_bytes())?;
        kv.put(key::LAST_MIGRATED_AT, self.last_migrated_at_ms.to_string().as_bytes())?;
        kv.put(key::CREATED_AT, self.created_at_ms.to_string().as_bytes())?;
        kv.put(key::UPDATED_AT, now_ms.to_string().as_bytes())?;
        Ok(())
    }

    /// One atomic put: the point at which a step becomes "done". Nothing else in the run is allowed
    /// to be the commit marker, because this is the only write the store guarantees is whole.
    pub fn set_schema_version(&self, kv: &mut dyn Kv, version: u32, now_ms: u64) -> Result<()> {
        kv.put(key::SCHEMA_VERSION, version.to_string().as_bytes())?;
        kv.put(key::UPDATED_AT, now_ms.to_string().as_bytes())?;
        Ok(())
    }
}

fn text_key(key: &[u8]) -> &'static str {
    if key == key::SCHEMA_VERSION {
        "schema"
    } else if key == key::COMPONENT {
        "component"
    } else if key == key::COMPONENT_VERSION {
        "component-version"
    } else if key == key::LAST_MIGRATED_BY {
        "last-migrated-by"
    } else if key == key::LAST_MIGRATED_AT {
        "last-migrated-at"
    } else if key == key::CREATED_AT {
        "created-at"
    } else if key == key::UPDATED_AT {
        "updated-at"
    } else {
        "key"
    }
}

/// Open (creating if the namespace is empty) and check ownership.
///
/// A namespace that holds keys but no meta is refused rather than adopted: it is either a namespace
/// written by software that predates this crate or one whose meta was deleted, and starting over at
/// `initial_version` would be a silent data loss. The operator imports a snapshot instead.
///
/// `initial_version` is the schema version an empty namespace starts at - the version the current
/// component writes natively, not v1.
pub fn open(
    kv: &mut dyn Kv,
    info: &ComponentInfo,
    initial_version: u32,
    now_ms: u64,
) -> Result<Meta> {
    info.validate()?;
    if initial_version == 0 {
        return Err(Error::Corrupt(
            "schema versions start at 1; 0 is not a version".into(),
        ));
    }
    match Meta::read(kv)? {
        Some(mut meta) => {
            if meta.component != info.id {
                return Err(Error::OwnerMismatch {
                    expected: info.id.clone(),
                    found: meta.component,
                });
            }
            // Record the build that is running now, but do not touch `last_migrated_by`: opening a
            // namespace is not migrating it, and that key answers "which build moved the data?".
            if meta.component_version != info.version {
                meta.component_version = info.version.clone();
                kv.put(key::COMPONENT_VERSION, meta.component_version.as_bytes())?;
                kv.put(key::UPDATED_AT, now_ms.to_string().as_bytes())?;
            }
            Ok(meta)
        }
        None => {
            let keys = user_keys(kv)?.len();
            if keys > 0 {
                return Err(Error::Uninitialised { keys });
            }
            let meta = Meta {
                schema_version: initial_version,
                component: info.id.clone(),
                component_version: info.version.clone(),
                last_migrated_by: info.sha256.clone(),
                created_at_ms: now_ms,
                last_migrated_at_ms: now_ms,
            };
            meta.write(kv, now_ms)?;
            Ok(meta)
        }
    }
}

/// Every key the component owns, in one pass. Used to bound an import and to copy a batch; not used
/// by a migration's own writes, which go through the journal.
pub fn user_keys(kv: &mut dyn Kv) -> Result<Vec<Vec<u8>>> {
    Ok(kv
        .scan_prefix(b"")?
        .into_iter()
        .map(|(key, _)| key)
        .filter(|key| !is_reserved(key))
        .collect())
}
