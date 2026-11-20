//! Which certificate authorities wa trusts, and where that answer comes from.
//!
//! Every outbound `https` connection in this project goes through `ureq`, whose default anchor set
//! is its own compiled-in copy of Mozilla's roots (`ureq::tls::RootCerts::WebPki`). A machine whose
//! CA lives somewhere else - a cloud sandbox with its own bundle, an interception proxy, a lab with
//! a private CA - therefore cannot reach anything over TLS at all. Measured 19/11 in a cloud bench:
//! wa's provider and vault calls failed until a bridge was bolted on, while `pi` (which reads the
//! two variables below) worked. The anchors are the one TLS setting a machine must be able to
//! correct without rebuilding wa, so they are read here, once per environment value, and every
//! agent that speaks TLS is built from this crate's answer.
//!
//! The rule is OpenSSL's, because that is the rule operators already have in their fingers:
//!
//! * `SSL_CERT_FILE` names one PEM bundle; every certificate in it is trusted.
//! * `SSL_CERT_DIR` names directories, separated by `:` (`;` on Windows); every certificate in every
//!   file directly inside them is trusted.
//! * Both together are one anchor set (a union), not one replacing the other.
//! * They replace the compiled-in bundle, the way OpenSSL's two variables replace its own default
//!   file and directory. A sandbox bundle is the system bundle plus the sandbox's own CA, so nothing
//!   public is lost by naming it.
//! * Neither set - or set to an empty value - leaves the compiled-in bundle exactly as it is today.
//!   The anchors are then `RootCerts::WebPki`, which is what every agent got before this crate
//!   existed; a machine that names no bundle keeps the behaviour it was measured with.
//!
//! A source the operator named and wa cannot read, or that carries no certificate at all, is an
//! error naming that source, never a silent fall back to the compiled-in roots. A caller that cannot
//! tell what it trusts must not connect: "it worked anyway" is the failure mode that hides a
//! misconfigured bundle until the one call that matters.
//!
//! ```no_run
//! // At every agent: the anchors, or the reason there are none.
//! let tls = wa_tls::tls_config().expect("the CA bundle named by SSL_CERT_FILE / SSL_CERT_DIR");
//! let agent: ureq::Agent = ureq::Agent::config_builder().tls_config(tls).build().into();
//! ```

use std::fmt;
use std::sync::{Mutex, MutexGuard};

use ureq::tls::{Certificate, PemItem, RootCerts, TlsConfig};

/// The bundle file OpenSSL and everything that speaks its dialect read first.
pub const CERT_FILE: &str = "SSL_CERT_FILE";
/// The directory list OpenSSL and everything that speaks its dialect read second.
pub const CERT_DIR: &str = "SSL_CERT_DIR";

#[cfg(any(test, feature = "scratch"))]
pub mod scratch;

/// Why the anchors could not be built: always the variable, the source and the reason, in words the
/// operator can act on without reading this file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RootsError {
    message: String,
}

impl RootsError {
    fn new(message: String) -> Self {
        RootsError { message }
    }

    /// The message, without the `Display` wrapper: a caller that stores errors as strings keeps it.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for RootsError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for RootsError {}

/// The anchors for the environment this process runs in: `SSL_CERT_FILE` / `SSL_CERT_DIR` when either
/// names a source, the compiled-in Mozilla bundle otherwise.
///
/// One entry per environment value, process-wide: a bundle is a few hundred kilobytes and parsing it
/// per request would be work in the way of every provider call. A bundle replaced in place is picked
/// up on the next start, as it is with every other TLS stack.
pub fn tls_config() -> Result<TlsConfig, RootsError> {
    // A test that installed the anchors it means (wa_tls::scratch::Env): read those, not the
    // environment, and cache nothing, so two tests in one process cannot see each other's answer and
    // no test writes process-wide state another thread could observe.
    #[cfg(any(test, feature = "scratch"))]
    if let Some((file, dirs)) = scratch::installed_override() {
        return build(file.as_deref(), dirs.as_deref());
    }
    let file = env_text(CERT_FILE)?;
    let dirs = env_text(CERT_DIR)?;
    let mut cache = cache();
    if let Some(cached) = cache.as_ref() {
        if cached.file == file && cached.dirs == dirs {
            return cached.value.clone();
        }
    }
    let value = build(file.as_deref(), dirs.as_deref());
    *cache = Some(Cached {
        file,
        dirs,
        value: value.clone(),
    });
    value
}

/// The same answer for an environment named explicitly rather than read from the process: the same
/// rule, the same errors, and no process-wide state - what a caller that holds its own configuration
/// (and what wa_tls::scratch::Env) uses.
pub fn tls_config_at(file: Option<&str>, dirs: Option<&str>) -> Result<TlsConfig, RootsError> {
    build(file, dirs)
}

/// The same answer, for an environment handed in rather than read: the seam the tests use, so that a
/// test about a certificate file cannot pass because of a variable someone else's test left behind.
pub fn tls_config_from(
    lookup: &dyn Fn(&str) -> Result<Option<String>, String>,
) -> Result<TlsConfig, RootsError> {
    let file = lookup_text(lookup, CERT_FILE)?;
    let dirs = lookup_text(lookup, CERT_DIR)?;
    build(file.as_deref(), dirs.as_deref())
}

/// The certificates named by the environment, or `None` when it names none.
pub fn anchors() -> Result<Option<Vec<Certificate<'static>>>, RootsError> {
    #[cfg(any(test, feature = "scratch"))]
    if let Some((file, dirs)) = scratch::installed_override() {
        if file.is_none() && dirs.is_none() {
            return Ok(None);
        }
        return collect(file.as_deref(), dirs.as_deref()).map(Some);
    }
    let file = env_text(CERT_FILE)?;
    let dirs = env_text(CERT_DIR)?;
    if file.is_none() && dirs.is_none() {
        return Ok(None);
    }
    collect(file.as_deref(), dirs.as_deref()).map(Some)
}

fn build(file: Option<&str>, dirs: Option<&str>) -> Result<TlsConfig, RootsError> {
    if file.is_none() && dirs.is_none() {
        // Today's behaviour, unchanged: the compiled-in Mozilla roots.
        return Ok(TlsConfig::builder().root_certs(RootCerts::WebPki).build());
    }
    let certs = collect(file, dirs)?;
    Ok(TlsConfig::builder()
        .root_certs(RootCerts::new_with_certs(&certs))
        .build())
}

fn collect(file: Option<&str>, dirs: Option<&str>) -> Result<Vec<Certificate<'static>>, RootsError> {
    let mut certs: Vec<Certificate<'static>> = Vec::new();
    if let Some(path) = file {
        let found = from_file(path)?;
        if found.is_empty() {
            return Err(RootsError::new(format!(
                "{CERT_FILE} {path}: no certificate in this file"
            )));
        }
        certs.extend(found);
    }
    if let Some(list) = dirs {
        let mut found: Vec<Certificate<'static>> = Vec::new();
        for dir in list.split(if cfg!(windows) { ';' } else { ':' }) {
            // An empty entry (a trailing separator, "a::b") names no directory.
            if dir.is_empty() {
                continue;
            }
            found.extend(from_dir(dir)?);
        }
        if found.is_empty() {
            return Err(RootsError::new(format!(
                "{CERT_DIR} {list}: no certificate in any file of this directory list"
            )));
        }
        certs.extend(found);
    }
    if certs.is_empty() {
        return Err(RootsError::new(format!(
            "{CERT_FILE} and {CERT_DIR} name no certificate"
        )));
    }
    Ok(certs)
}

fn from_file(source: &str) -> Result<Vec<Certificate<'static>>, RootsError> {
    let bytes = std::fs::read(source)
        .map_err(|error| RootsError::new(format!("{CERT_FILE} {source}: cannot be read: {error}")))?;
    parse(&bytes).map_err(|reason| RootsError::new(format!("{CERT_FILE} {source}: {reason}")))
}

fn from_dir(dir: &str) -> Result<Vec<Certificate<'static>>, RootsError> {
    let listing = std::fs::read_dir(dir)
        .map_err(|error| RootsError::new(format!("{CERT_DIR} {dir}: cannot be listed: {error}")))?;
    let mut files = Vec::new();
    for entry in listing {
        let entry = entry.map_err(|error| {
            RootsError::new(format!("{CERT_DIR} {dir}: cannot be listed: {error}"))
        })?;
        let kind = entry.file_type().map_err(|error| {
            RootsError::new(format!("{CERT_DIR} {dir}: cannot be listed: {error}"))
        })?;
        // One level, like OpenSSL's hashed directory: a directory inside it is not a source.
        if kind.is_dir() {
            continue;
        }
        files.push(entry.path());
    }
    // A stable order: two runs over the same directory build the same anchor set.
    files.sort();
    let mut certs: Vec<Certificate<'static>> = Vec::new();
    for path in files {
        let shown = path.display();
        let bytes = std::fs::read(&path).map_err(|error| {
            RootsError::new(format!("{CERT_DIR} {dir}: {shown}: cannot be read: {error}"))
        })?;
        // A directory holds whatever the operator's packager put in it: hashed links, a README, a
        // CRL, the CA files. A file that carries no certificate is not a source that lied, so it is
        // skipped; a file that cannot be read, or that is PEM and broken, is an error above.
        certs.extend(parse(&bytes).map_err(|reason| {
            RootsError::new(format!("{CERT_DIR} {dir}: {shown}: {reason}"))
        })?);
    }
    Ok(certs)
}

/// Every certificate in a PEM document, in the order it appears. Private keys and other sections in
/// the same file are not anchors and are ignored; a section that fails to parse is an error.
fn parse(pem: &[u8]) -> Result<Vec<Certificate<'static>>, String> {
    let mut certs = Vec::new();
    for item in ureq::tls::parse_pem(pem) {
        match item {
            Ok(PemItem::Certificate(cert)) => certs.push(cert),
            Ok(_) => {}
            Err(error) => return Err(format!("not readable as PEM: {error}")),
        }
    }
    Ok(certs)
}

fn env_text(name: &str) -> Result<Option<String>, RootsError> {
    match std::env::var(name) {
        Ok(value) => Ok(non_empty(value)),
        Err(std::env::VarError::NotPresent) => Ok(None),
        // A value that is not UTF-8 cannot be a path we read. Saying so is the only honest answer:
        // pretending it is unset would trust the compiled-in bundle while the operator believes
        // their own bundle is in force.
        Err(std::env::VarError::NotUnicode(value)) => Err(RootsError::new(format!(
            "{name} {value:?}: not valid UTF-8"
        ))),
    }
}

fn lookup_text(
    lookup: &dyn Fn(&str) -> Result<Option<String>, String>,
    name: &str,
) -> Result<Option<String>, RootsError> {
    Ok(lookup(name).map_err(RootsError::new)?.and_then(non_empty))
}

/// An empty value names nothing: OpenSSL and every client that reads these variables treat it so.
fn non_empty(value: String) -> Option<String> {
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

struct Cached {
    file: Option<String>,
    dirs: Option<String>,
    value: Result<TlsConfig, RootsError>,
}

static CACHE: Mutex<Option<Cached>> = Mutex::new(None);

fn cache() -> MutexGuard<'static, Option<Cached>> {
    // A poisoned cache is still a cache: one panicking test must not fail every later TLS call.
    CACHE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

#[cfg(test)]
mod tests;
