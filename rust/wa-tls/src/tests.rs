//! What the anchors are, and what a client actually does with them.
//!
//! Two halves, on purpose. The first half is the rule: which sources are read, which are refused and
//! what the refusal says, checked through the injected environment so no test depends on another
//! test's variables. The second half is the wire: a real rustls server presenting a certificate from
//! a private CA, and ureq's real handshake against it - refused when nothing names the CA, accepted
//! when SSL_CERT_FILE or SSL_CERT_DIR does, and accepted for both CAs when the two variables are set
//! together.

use std::path::Path;

use ureq::tls::{RootCerts, TlsConfig};

use super::*;
use crate::scratch::{self, Env, Server, TempDir};

/// An environment handed in, so a test about a file cannot be answered by an ambient variable.
fn environment<'a>(
    pairs: &'a [(&'a str, String)],
) -> impl Fn(&str) -> Result<Option<String>, String> + 'a {
    move |name| {
        Ok(pairs
            .iter()
            .find(|(key, _)| *key == name)
            .map(|(_, value)| value.clone()))
    }
}

fn named<'a>(pairs: &'a [(&'a str, &'a Path)]) -> Vec<(&'a str, String)> {
    pairs
        .iter()
        .map(|(key, path)| (*key, path.display().to_string()))
        .collect()
}

/// How many certificates an agent would trust, or none for the compiled-in bundle.
fn anchored(config: &TlsConfig) -> Option<usize> {
    match config.root_certs() {
        RootCerts::Specific(certs) => Some(certs.len()),
        _ => None,
    }
}

fn agent() -> ureq::Agent {
    let tls = tls_config().expect("the anchors this environment names");
    ureq::Agent::config_builder()
        .http_status_as_error(false)
        .timeout_global(Some(std::time::Duration::from_secs(20)))
        .tls_config(tls)
        .build()
        .into()
}

// ------------------------------------------------------------------------------------ the rule

#[test]
fn a_machine_that_names_no_bundle_keeps_the_compiled_in_roots() {
    let config = tls_config_from(&environment(&[])).expect("no source named is not an error");
    assert_eq!(anchored(&config), None, "the compiled-in Mozilla bundle, as before this change");
    assert_eq!(
        anchored(&tls_config_from(&environment(&[(CERT_FILE, String::new()), (CERT_DIR, String::new())])).unwrap()),
        None,
        "an empty value names nothing, which is what OpenSSL does with it"
    );
}

#[test]
fn a_bundle_names_every_certificate_it_carries() {
    let dir = TempDir::new("bundle");
    let file = dir.copy_fixture("ca.pem", "bundle.pem");
    // A second certificate in the same file: a real bundle is many, and one must not shadow another.
    let mut bundle = std::fs::read(&file).unwrap();
    bundle.extend(std::fs::read(scratch::other_cert_file()).unwrap());
    std::fs::write(&file, &bundle).unwrap();
    let config = tls_config_from(&environment(&named(&[(CERT_FILE, &file)]))).expect("a readable bundle");
    assert_eq!(anchored(&config), Some(2));
}

#[test]
fn a_missing_bundle_is_a_named_error() {
    let missing = Path::new("/nonexistent/wa-tls/does-not-exist.pem");
    let error = tls_config_from(&environment(&named(&[(CERT_FILE, missing)]))).unwrap_err();
    let text = error.to_string();
    assert!(text.contains(CERT_FILE), "the message must name the variable: {text}");
    assert!(text.contains("does-not-exist.pem"), "and the source: {text}");
    assert!(text.contains("cannot be read"), "and what went wrong: {text}");
}

#[test]
fn a_bundle_without_a_certificate_is_a_named_error() {
    let dir = TempDir::new("empty-bundle");
    let file = dir.write("notes.pem", b"this file is not a certificate\n");
    let error = tls_config_from(&environment(&named(&[(CERT_FILE, &file)]))).unwrap_err();
    let text = error.to_string();
    assert!(text.contains(CERT_FILE), "{text}");
    assert!(text.contains("no certificate"), "{text}");
}

#[test]
fn a_directory_names_every_certificate_it_holds() {
    let dir = TempDir::new("cert-dir");
    dir.copy_fixture("ca.pem", "ca.pem");
    dir.copy_fixture("otherca.pem", "otherca.pem");
    // A directory is not a bundle: it holds whatever the packager put there, and a file with no
    // certificate in it is not a reason to refuse the rest.
    dir.write("README", b"the operator's notes\n");
    let config = tls_config_from(&environment(&named(&[(CERT_DIR, dir.path())]))).expect("a readable directory");
    assert_eq!(anchored(&config), Some(2));
}

#[test]
fn the_directory_list_is_a_union() {
    let first = TempDir::new("cert-dir-one");
    first.copy_fixture("ca.pem", "ca.pem");
    let second = TempDir::new("cert-dir-two");
    second.copy_fixture("otherca.pem", "otherca.pem");
    let list = format!("{}:{}", first.path().display(), second.path().display());
    let config = tls_config_from(&environment(&[(CERT_DIR, list)])).expect("two directories");
    assert_eq!(anchored(&config), Some(2));
}

#[test]
fn a_missing_directory_is_a_named_error() {
    let missing = Path::new("/nonexistent/wa-tls/cert-dir");
    let error = tls_config_from(&environment(&named(&[(CERT_DIR, missing)]))).unwrap_err();
    let text = error.to_string();
    assert!(text.contains(CERT_DIR), "{text}");
    assert!(text.contains("cert-dir"), "{text}");
    assert!(text.contains("cannot be listed"), "{text}");
}

#[test]
fn a_directory_without_a_certificate_is_a_named_error() {
    let dir = TempDir::new("cert-dir-empty");
    dir.write("README", b"nothing to trust here\n");
    let error = tls_config_from(&environment(&named(&[(CERT_DIR, dir.path())]))).unwrap_err();
    assert!(error.to_string().contains("no certificate"), "{error}");
}

#[cfg(unix)]
#[test]
fn an_entry_that_cannot_be_read_is_a_named_error() {
    let dir = TempDir::new("cert-dir-broken");
    dir.copy_fixture("ca.pem", "ca.pem");
    std::os::unix::fs::symlink("/nonexistent/wa-tls/gone.pem", dir.path().join("gone.pem")).unwrap();
    let error = tls_config_from(&environment(&named(&[(CERT_DIR, dir.path())]))).unwrap_err();
    let text = error.to_string();
    assert!(text.contains("gone.pem"), "the message must name the entry: {text}");
    assert!(text.contains("cannot be read"), "{text}");
}

#[test]
fn file_and_directory_are_one_anchor_set() {
    let dir = TempDir::new("union");
    dir.copy_fixture("otherca.pem", "otherca.pem");
    let file = scratch::cert_file();
    let config = tls_config_from(&environment(&named(&[(CERT_FILE, &file), (CERT_DIR, dir.path())])))
        .expect("both sources");
    assert_eq!(anchored(&config), Some(2), "one replacing the other would answer 1");
}

#[test]
fn a_value_that_is_not_a_path_is_a_named_error() {
    let error = tls_config_from(&|name| {
        if name == CERT_FILE {
            Err(format!("{CERT_FILE}: not valid UTF-8"))
        } else {
            Ok(None)
        }
    })
    .unwrap_err();
    assert!(error.to_string().contains("not valid UTF-8"), "{error}");
}

#[test]
fn installing_anchors_for_a_test_writes_no_process_environment() {
    let before = (std::env::var_os(CERT_FILE), std::env::var_os(CERT_DIR));
    let env = Env::set(&[(CERT_FILE, &scratch::cert_file())]);
    assert_eq!(
        before,
        (std::env::var_os(CERT_FILE), std::env::var_os(CERT_DIR)),
        "set_var is unsound with threads: the seam must not touch the process environment"
    );
    // ...and it is really in force: the anchors the test installed, not the compiled-in bundle.
    let config = tls_config().expect("the anchors the test installed");
    assert_eq!(anchored(&config), Some(1));
    // Nothing asserted after the guard drops: another test may hold it a microsecond later, and
    // reading the answer then would be reading that test's. What this test owns is the two lines
    // above - the environment was not written, and the anchors it installed are the ones in force.
}

// ------------------------------------------------------------------------------------ the wire

#[test]
fn a_private_ca_is_refused_when_no_bundle_is_named() {
    let _env = Env::clear();
    let server = Server::start();
    let error = agent()
        .get(&server.url("/"))
        .call()
        .expect_err("a private CA is not in the compiled-in bundle");
    // Pin where the refusal comes from. Measured on ureq 3.4: an unknown issuer is an io error of
    // kind InvalidData carrying rustls's InvalidCertificate(UnknownIssuer), so a test that only
    // looked for the word "tls" would pass on a timeout and prove nothing about anchors.
    match &error {
        ureq::Error::Io(io) => {
            assert_eq!(io.kind(), std::io::ErrorKind::InvalidData, "not a silent read failure");
            assert!(
                format!("{io:?}").contains("InvalidCertificate"),
                "the refusal must be the certificate step: {io:?}"
            );
        }
        other => panic!("a refused handshake is ureq's io error carrying the TLS refusal, got {other:?}"),
    }
    eprintln!("refused without SSL_CERT_FILE: {error}");
}

#[test]
fn ssl_cert_file_makes_a_private_ca_trusted() {
    let _env = Env::set(&[(CERT_FILE, &scratch::cert_file())]);
    let server = Server::start();
    let mut response = agent().get(&server.url("/")).call().expect("the CA named by SSL_CERT_FILE");
    assert_eq!(response.status().as_u16(), 200);
    assert_eq!(response.body_mut().read_to_string().unwrap(), "ok");
}

#[test]
fn ssl_cert_dir_makes_a_private_ca_trusted() {
    let dir = TempDir::new("cert-dir-wire");
    dir.copy_fixture("ca.pem", "ca.pem");
    let _env = Env::set(&[(CERT_DIR, dir.path())]);
    let server = Server::start();
    let mut response = agent().get(&server.url("/")).call().expect("the CA in the directory SSL_CERT_DIR names");
    assert_eq!(response.status().as_u16(), 200);
    assert_eq!(response.body_mut().read_to_string().unwrap(), "ok");
}

#[test]
fn file_and_directory_together_trust_both_private_cas() {
    let dir = TempDir::new("union-wire");
    dir.copy_fixture("otherca.pem", "otherca.pem");
    let _env = Env::set(&[(CERT_FILE, &scratch::cert_file()), (CERT_DIR, dir.path())]);
    let first = Server::start();
    let second = Server::start_other();
    for server in [&first, &second] {
        let mut response = agent()
            .get(&server.url("/"))
            .call()
            .unwrap_or_else(|error| panic!("{} should be trusted: {error}", server.base()));
        assert_eq!(response.status().as_u16(), 200);
        assert_eq!(response.body_mut().read_to_string().unwrap(), "ok");
    }
}

#[test]
fn a_broken_bundle_refuses_the_agent_instead_of_falling_back() {
    let _env = Env::set_text(CERT_FILE, "/nonexistent/wa-tls/typo.pem");
    let server = Server::start();
    let broken = tls_config().expect_err("a named source that cannot be read is not a fall back");
    assert!(broken.to_string().contains("typo.pem"), "{broken}");
    // And there is no agent to make the request with: trust has no answer, so the call has none.
    assert!(std::panic::catch_unwind(|| {
        let _ = tls_config().expect("...");
    })
    .is_err());
    let _ = server;
}

/// The scheme is the gate: a plain URL consults no anchor, so a bundle the machine cannot read is not
/// its problem - and a TLS URL still refuses with that bundle named (review r1, item 7).
#[test]
fn a_plain_url_is_answered_without_reading_the_bundle() {
    let _env = Env::set_text(CERT_FILE, "/nonexistent/wa-tls/typo.pem");
    assert!(tls_config_for("https://example.invalid/").is_err(), "a TLS url still refuses");
    let plain = tls_config_for("http://127.0.0.1:1/health").expect("a plain url consults no anchor");
    assert_eq!(anchored(&plain), None, "and it asks for nothing: the compiled-in bundle");
    assert!(is_tls("wss://relay.example/ws"));
    assert!(is_tls("https://api.example/v1"));
    assert!(!is_tls("ws://relay.example/ws"));
    assert!(!is_tls("http://127.0.0.1:8799/health"));
    assert!(!is_tls("not a url"));
}
