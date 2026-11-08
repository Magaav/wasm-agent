//! Which WASI interfaces a WASI 0.3 (`wa:kernel@0.2`) component gets, and with what scope.
//!
//! `docs/WASI-INTERFACES.md` is this file in prose: a table of every interface the runtime can serve,
//! its tier, and the grant key that turns it on. The table below and that document are kept in step
//! by a test ([`tests::the_document_lists_every_interface_the_code_knows`]), so the answer to "may a
//! component use `wasi:sockets`?" cannot be one thing in the code and another in the docs.
//!
//! Three tiers, and the first one is the whole design:
//!
//! * **A - always on, no capability.** Clocks, randomness, exit, stdout/stderr and the terminal
//!   queries. A component cannot reach anything outside itself through them, so gating them would
//!   only produce components that fail for no security gain. This is `wasmtime`'s default set and
//!   the reason `docs/GRANT-POLICY.md` step 4 says log and lifecycle are never policy-checked.
//! * **B - granted with a scope.** Filesystem (named preopens, read-only or read-write), sockets
//!   (an address allowlist, never a whole network), environment (named variables, never the whole
//!   environment), stdin, the key/value and config shapes. Everything here reaches outside the
//!   component, so it needs a manifest capability *and* a policy rule, and every decision is audited.
//! * **C - never linked.** Node policy writing, credential values, deploy/upgrade, mesh calls upward,
//!   the machine-control actions of the `client`, shell/operation, TLS. There is no grant key: a
//!   component that imports one of these is refused before it runs, with the interface named.
//!
//! Two layers, in this order (`docs/GRANT-POLICY.md`): the **manifest grant** (may this component
//! ever, per the artifact's own declaration) then the **node policy** (may this node, right now, with
//! a record). The policy can only narrow: a rule naming an address the manifest never granted does
//! nothing. The reverse - a manifest capability with no policy rule on a node that has a
//! `policy.json` - is a refusal with `no_policy`, because every tier B decision is sensitive.
//!
//! What each interface does *at call time* stays in its own host implementation: the filesystem's
//! `../` is refused by the preopen's confinement, a socket connect is checked by the address check
//! installed here (`net.dial`), a kv key by the kv host (`kv.read`/`kv.write`). This module decides
//! *which interfaces exist at all* and audits that decision; it never re-implements an interface.
use crate::components::{Grant, Installed};
use std::net::SocketAddr;
use std::sync::Arc;
use wa_grant_policy::Decision;
use wasmtime_wasi::sockets::SocketAddrUse;
use wasmtime_wasi::WasiCtxBuilder;

/// How an interface is granted (docs/WASI-INTERFACES.md).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tier {
    /// Always linked: nothing outside the component is reachable through it.
    Always,
    /// Linked only when the manifest declares its grant and the node policy allows the scope.
    Granted,
    /// Never linked, to any component, whatever the manifest says.
    Never,
}

impl Tier {
    pub fn as_str(&self) -> &'static str {
        match self {
            Tier::Always => "A",
            Tier::Granted => "B",
            Tier::Never => "C",
        }
    }
}

/// One row of the table: an interface, its tier, the manifest key that grants it, and the policy
/// capability every decision about it is recorded under.
pub struct Spec {
    /// The interface name as an import spells it, without the version.
    pub interface: &'static str,
    /// The WASI versions this node serves for it (`["0.2.0", "0.3.0"]` where both exist).
    pub versions: &'static [&'static str],
    pub tier: Tier,
    /// The manifest `capabilities` key that has to be declared (`""` for tier A, `"-"` for tier C).
    pub manifest_key: &'static str,
    /// The policy capability the decision is audited under (`""` when nothing is asked).
    pub capability: &'static str,
    /// Whether this runner can link it at all on wasmtime 50 (a `false` here is a documented gap,
    /// refused with `wasi_interface_unavailable` rather than silently not linked).
    pub served: bool,
    /// The tier a **preview-2** (`@0.2.x`) import of this interface gets instead, when it differs.
    ///
    /// Only `wasi:cli/environment` and `wasi:cli/stdin` have one, and the reason is a fact about the
    /// toolchain: a component built with Rust's `std` (every wasip2 build) imports the whole preview-2
    /// cli surface - `environment`, `stdin`, `stdout`, `exit` and the terminals - whether or not the
    /// program ever uses it. Refusing `wasi:cli/environment@0.2.x` would therefore refuse a component
    /// for an import it never calls. So the preview-2 spellings are linked for every component and
    /// carry **no capability**: with no grant the environment list is empty and stdin is an empty
    /// pipe (EOF). The 0.3 spellings stay tier B: a native-async component names them in its world on
    /// purpose.
    pub tier_p2: Option<Tier>,
    /// One line, the same words the document's note column carries: why this tier.
    pub note: &'static str,
}

const fn spec(
    interface: &'static str,
    versions: &'static [&'static str],
    tier: Tier,
    manifest_key: &'static str,
    capability: &'static str,
    served: bool,
    note: &'static str,
) -> Spec {
    Spec { interface, versions, tier, manifest_key, capability, served, tier_p2: None, note }
}

/// `spec` for a row whose preview-2 spelling has its own tier (see [`Spec::tier_p2`]).
const fn spec_v2(
    interface: &'static str,
    versions: &'static [&'static str],
    tier: Tier,
    manifest_key: &'static str,
    capability: &'static str,
    served: bool,
    note: &'static str,
) -> Spec {
    Spec { interface, versions, tier, manifest_key, capability, served, tier_p2: Some(Tier::Always), note }
}

/// The table. `docs/WASI-INTERFACES.md` lists these rows in the same order with the same words; the
/// test at the bottom of this file fails when they disagree.
pub const TABLE: &[Spec] = &[
    // ---- tier A ------------------------------------------------------------------------------
    spec("wasi:clocks/monotonic-clock", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "elapsed time and timers; a component's only clock"),
    spec("wasi:clocks/system-clock", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "wall clock; the 0.2 spelling is `wall-clock`"),
    spec("wasi:clocks/wall-clock", &["0.2.0"], Tier::Always, "", "", true, "the preview-2 spelling of the wall clock (0.3 renamed it `system-clock`)"),
    spec("wasi:clocks/types", &["0.3.0"], Tier::Always, "", "", true, "duration/instant records the other clocks and sockets use"),
    spec("wasi:random/random", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "the OS CSPRNG"),
    spec("wasi:random/insecure", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "the non-cryptographic PRNG"),
    spec("wasi:random/insecure-seed", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "a seed for the above; never a secret"),
    spec("wasi:cli/exit", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "a component's own exit; the supervisor decides whether it restarts"),
    spec("wasi:cli/stdout", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "the component's service log, never the node's console"),
    spec("wasi:cli/stderr", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "as stdout: the same log file"),
    spec("wasi:cli/terminal-input", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "a capability query; the host answers `false`"),
    spec("wasi:cli/terminal-output", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "a capability query; the host answers `false`"),
    spec("wasi:cli/terminal-stdin", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "a capability query over stdin; graded with terminal-input"),
    spec("wasi:cli/terminal-stdout", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "a capability query over stdout; graded with terminal-output"),
    spec("wasi:cli/terminal-stderr", &["0.2.0", "0.3.0"], Tier::Always, "", "", true, "a capability query over stderr; graded with terminal-output"),
    spec("wasi:cli/types", &["0.3.0"], Tier::Always, "", "", true, "the `error-code` record the 0.3 cli streams report"),
    spec("wasi:io/error", &["0.2.0"], Tier::Always, "", "", true, "a resource handle for an error another interface produced"),
    spec("wasi:io/poll", &["0.2.0"], Tier::Always, "", "", true, "preview 2 polling; only reachable through a resource another interface made"),
    spec("wasi:io/streams", &["0.2.0"], Tier::Always, "", "", true, "preview 2 streams; only reachable through a resource another interface made"),
    // ---- tier B: filesystem ----------------------------------------------------------------
    spec("wasi:filesystem/types", &["0.2.0", "0.3.0"], Tier::Granted, "dirs", "wasi.filesystem", true, "named preopens only, read-only unless the preopen is granted write"),
    spec("wasi:filesystem/preopens", &["0.2.0", "0.3.0"], Tier::Granted, "dirs", "wasi.filesystem", true, "the list is exactly the granted preopens; never `/` and never the node home"),
    // ---- tier B: sockets -------------------------------------------------------------------
    spec("wasi:sockets/types", &["0.2.0", "0.3.0"], Tier::Granted, "net", "wasi.sockets", true, "outbound host:port allowlist; inbound only on 127.0.0.1 unless `net_bind` names the address"),
    spec("wasi:sockets/ip-name-lookup", &["0.2.0", "0.3.0"], Tier::Granted, "dns", "wasi.sockets", true, "a name lookup is an outbound request; its own `dns` grant"),
    spec("wasi:sockets/network", &["0.2.0"], Tier::Granted, "net", "wasi.sockets", true, "preview 2's network handle, under the same address check"),
    spec("wasi:sockets/instance-network", &["0.2.0"], Tier::Granted, "net", "wasi.sockets", true, "preview 2's default network, under the same address check"),
    spec("wasi:sockets/tcp", &["0.2.0"], Tier::Granted, "net", "wasi.sockets", true, "preview 2 TCP, under the same address check"),
    spec("wasi:sockets/tcp-create-socket", &["0.2.0"], Tier::Granted, "net", "wasi.sockets", true, "preview 2 socket creation, under the same address check"),
    spec("wasi:sockets/udp", &["0.2.0"], Tier::Granted, "net", "wasi.sockets", true, "preview 2 UDP, under the same address check"),
    spec("wasi:sockets/udp-create-socket", &["0.2.0"], Tier::Granted, "net", "wasi.sockets", true, "preview 2 socket creation, under the same address check"),
    // ---- tier B: cli -----------------------------------------------------------------------
    spec_v2(
        "wasi:cli/environment",
        &["0.2.0", "0.3.0"],
        Tier::Granted,
        "env",
        "wasi.env",
        true,
        "only the variable names the grant lists; never the node's environment - and the 0.2.x spelling is linked for every component (std imports it) with an empty list when nothing is granted",
    ),
    spec_v2(
        "wasi:cli/stdin",
        &["0.2.0", "0.3.0"],
        Tier::Granted,
        "stdin",
        "wasi.stdin",
        true,
        "an empty pipe, never the node's own stdin - and the 0.2.x spelling is linked for every component (std imports it) as an empty pipe",
    ),
    // ---- tier B: the keyvalue and config shapes --------------------------------------------
    spec("wa:kernel/keyvalue", &["0.2.0"], Tier::Granted, "storage", "wasi.keyvalue", true, "wa's `wasi:keyvalue` shape over this component's own kv namespace"),
    spec("wa:kernel/config", &["0.2.0"], Tier::Granted, "config", "wasi.config", true, "wa's `wasi:config` shape over the non-secret config this component was granted"),
    // ---- tier B: the keystore (`docs/VAULT.md`) ----------------------------------------------
    spec("wa:kernel/keystore", &["0.2.0"], Tier::Granted, "keystore", "wasi.keystore", false, "seal/open under the kernel's root key, bound to the importing component's own namespace; the host function lands with the WASI 0.3 component runner (`docs/VAULT.md`, \"What integration needs\")"),
    // ---- tier B in the document, not linkable on wasmtime 50 --------------------------------
    spec("wasi:http/types", &["0.2.0", "0.3.0"], Tier::Granted, "http", "http.request", false, "no wasi:http crate ships with wasmtime 50; outgoing HTTP is `wa:kernel/http`, gated per host:port"),
    spec("wasi:http/outgoing-handler", &["0.2.0", "0.3.0"], Tier::Granted, "http", "http.request", false, "as wasi:http/types: use `wa:kernel/http`"),
    spec("wasi:keyvalue/store", &["0.2.0"], Tier::Granted, "storage", "wasi.keyvalue", false, "the proposal itself is not shipped by wasmtime 50; `wa:kernel/keyvalue` is the served shape"),
    spec("wasi:config/store", &["0.2.0"], Tier::Granted, "config", "wasi.config", false, "the proposal itself is not shipped by wasmtime 50; `wa:kernel/config` is the served shape"),
    spec("wasi:nn/inference", &["0.2.0", "0.3.0"], Tier::Granted, "nn", "nn.run", false, "wasmtime-wasi-nn has no 50 release: not linkable, so a component importing it waits"),
    // ---- tier C ----------------------------------------------------------------------------
    spec("wasi:tls/*", &[], Tier::Never, "-", "", false, "TLS terminates in the kernel; a component never holds a key or makes a trust decision"),
    spec("wasi:vault/*", &[], Tier::Never, "-", "", false, "credential values reach a component only through `wa:kernel/credentials.get`, one named secret per grant"),
    // ---- tier C: the vault component's own exports (`wit/vault/vault.wit`) -------------------
    spec("wa:vault/vault", &[], Tier::Never, "-", "", false, "the vault component's own interface: only the kernel links it, so a guest importing it is refused"),
    spec("wa:vault/reveal", &[], Tier::Never, "-", "", false, "the reveal door: a component that imports it is refused at link time, whatever its manifest grants"),
    spec("wa:vault/audit", &[], Tier::Never, "-", "", false, "the audit chain is read by the kernel and the operator, never by a guest"),
    spec("wasi:secrets/*", &[], Tier::Never, "-", "", false, "as wasi:vault"),
    spec("wasi:logging/logging", &["0.1.0"], Tier::Never, "-", "", false, "`wa:kernel/log` is the one log a component may write, into its own bounded file"),
    spec("wa:host/policy", &[], Tier::Never, "-", "", false, "node policy is the operator's: `host.policy_*` is not reachable from a component"),
    spec("wa:host/deploy", &[], Tier::Never, "-", "", false, "deploy/upgrade belongs to Sentinel and to the operator's session"),
    spec("wa:host/mesh", &[], Tier::Never, "-", "", false, "a mesh call upward is the node's, never a component's"),
    spec("wa:host/client", &[], Tier::Never, "-", "", false, "machine control (the `client` machine actions) is the operator's"),
    spec("wa:host/exec", &[], Tier::Never, "-", "", false, "shell and operation are the operator's session, not a component's"),
];

/// The row for an import name (`wasi:cli/stdout@0.3.0` -> the `wasi:cli/stdout` row), and the
/// version the import asked for. A resource import (`wa:kernel/websocket.socket@0.1.0`) is not an
/// interface and answers `None`, exactly as `imports::kernel_serves` treats it.
pub fn spec_of(import: &str) -> Option<(&'static Spec, &str)> {
    let (interface, version) = split(import)?;
    let row = TABLE.iter().find(|row| row.interface == interface || wildcard(row.interface, interface))?;
    Some((row, version))
}

/// `wasi:tls/*` is a whole package: a row without an interface part covers every interface in it.
fn wildcard(row: &str, interface: &str) -> bool {
    match row.strip_suffix("/*") {
        Some(package) => interface.rsplit_once('/').is_some_and(|(p, _)| p == package),
        None => false,
    }
}

fn split(import: &str) -> Option<(&str, &str)> {
    let (rest, version) = import.rsplit_once('@')?;
    let interface = rest.split_once('.').map_or(rest, |_| rest);
    // A resource is `package/interface.resource@version`, and it is not an interface.
    if interface.rsplit_once('/').is_some_and(|(_, name)| name.contains('.')) {
        return None;
    }
    Some((interface, version))
}

/// The tier of an import, for the supervisor's "is this served?" question (`imports.rs`). `None`
/// when it is not a WASI interface this table knows - the caller decides what to do with that.
pub fn tier_of(import: &str) -> Option<Tier> {
    spec_of(import).map(|(row, version)| tier_for(row, version))
}

/// The tier of *this spelling*: a preview-2 import may be linked even when the 0.3 one is not
/// ([`Spec::tier_p2`]).
fn tier_for(row: &Spec, version: &str) -> Tier {
    match row.tier_p2 {
        Some(tier) if version.starts_with("0.2.") => tier,
        _ => row.tier,
    }
}

/// Does this node serve the interface at all (tier A or B, and the runtime can link it)?
pub fn serves(import: &str) -> bool {
    match spec_of(import) {
        Some((row, version)) => tier_for(row, version) != Tier::Never && row.served,
        None => false,
    }
}

/// One granted directory: a host path the operator named, a guest path the component asks for, and
/// whether writes are allowed inside it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FsDir {
    pub host: String,
    pub guest: String,
    pub write: bool,
}

/// What one component may reach through WASI, after the manifest grant and the node policy.
///
/// Built once per run (`run_once`). Empty field == that interface is not linked, and a component that
/// imports it is refused with `wasi_import_not_granted` before wasm is instantiated.
pub struct Scope {
    pub component: String,
    pub fs: Vec<FsDir>,
    pub env: Vec<(String, String)>,
    pub stdin: bool,
    pub net: Vec<Net>,
    pub net_bind: Vec<Net>,
    pub tcp: bool,
    pub udp: bool,
    pub dns: bool,
    pub keyvalue: bool,
    /// The non-secret config this component was granted, as JSON text (what `wa:kernel/config`
    /// answers from). `None` means the interface is not linked.
    pub config: Option<String>,
}

/// A granted address pattern, parsed once: `host:port` where `host` may be `*`, `*.suffix`, a literal
/// IP or a hostname, and `port` may be `*`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Net {
    pub host: String,
    pub port: u16,
    pub text: String,
}

impl Net {
    /// `127.0.0.1:8080`, `*.whatsapp.net:443`, `127.0.0.1:*`, `localhost:9`.
    pub fn parse(text: &str) -> Option<Net> {
        let text = text.trim().to_ascii_lowercase();
        let (host, port) = text.rsplit_once(':')?;
        let host = host.trim_start_matches('[').trim_end_matches(']');
        if host.is_empty() || host.len() > 255 {
            return None;
        }
        let port = if port == "*" { 0 } else { port.parse::<u16>().ok()? };
        Some(Net { host: host.to_string(), port, text })
    }

    /// Does the host part of this grant name `ip`? `*` is every address, a `*.suffix` pattern matches
    /// the suffix and its subdomains, everything else is an exact IP literal (which is all a WASI
    /// socket check ever sees - `Scope::build` refuses a name here).
    pub fn covers_ip(&self, ip: std::net::IpAddr) -> bool {
        let ip = ip.to_string().to_ascii_lowercase();
        let host = self.host.as_str();
        match host.strip_prefix("*.") {
            Some(suffix) => ip == suffix || ip.ends_with(&format!(".{suffix}")),
            None => host == "*" || host == ip,
        }
    }

    /// Does this grant cover `addr` for an outbound connect? Host and port both, unless the grant
    /// named a wildcard port.
    pub fn covers(&self, addr: &SocketAddr) -> bool {
        (self.port == 0 || self.port == addr.port()) && self.covers_ip(addr.ip())
    }

    /// Does this grant cover a **bind** on `addr`? The same, except that binding an ephemeral port
    /// (`:0`) is covered by any grant that names the address: the OS picks the port, not the grant.
    pub fn covers_bind(&self, addr: &SocketAddr) -> bool {
        self.covers_ip(addr.ip()) && (self.port == 0 || self.port == addr.port() || addr.port() == 0)
    }
}

/// The one question this module asks of a policy layer: may this component have that scope element,
/// and (for a refusal the manifest made before the engine was consulted) write the record.
///
/// It is a trait so a test can assert the decisions and their audit lines without the process-wide
/// node policy - a unit test must not write to a node's audit trail, and "which records does a plan
/// produce" is exactly what the tests below check. [`NodeGate`] is the real one.
pub trait Gate {
    fn allow(&self, component: &str, capability: &str, target: Option<&str>) -> bool;
    fn deny(&self, component: &str, capability: &str, target: Option<&str>, reason: &str);
}

/// The node's policy: `node_policy::check` for the question (which audits a policy-mode decision and
/// a manifest-mode one for a sensitive capability), `node_policy::record_deny` for a refusal the
/// manifest made first.
pub struct NodeGate;

impl Gate for NodeGate {
    fn allow(&self, component: &str, capability: &str, target: Option<&str>) -> bool {
        match wa_governance::node_policy::check(component, capability, target) {
            Decision::Allow => true,
            // The check itself has already written the audit record and the operator's log line.
            _ => false,
        }
    }
    fn deny(&self, component: &str, capability: &str, target: Option<&str>, reason: &str) {
        wa_governance::node_policy::record_deny(component, capability, target, reason);
    }
}

fn declared(manifest: &serde_json::Value, key: &str) -> bool {
    let caps = manifest.get("capabilities");
    match key {
        "storage" | "stt" | "stdin" | "dns" | "config" | "udp" | "nn" => caps.and_then(|c| c.get(key)).and_then(serde_json::Value::as_bool) == Some(true),
        "dirs" | "env" | "net" | "net_bind" | "http" => caps.and_then(|c| c.get(key)).and_then(serde_json::Value::as_array).is_some_and(|list| !list.is_empty()),
        _ => false,
    }
}

/// Is this *element* declared by the manifest (a directory's guest path, an environment variable
/// name)? `components::Grant::check` already refuses a grant beyond the manifest; this repeats the
/// membership test for the two lists whose elements are the scope, so `Scope::build` is honest when
/// called on its own (the tests do, and so would a future caller).
fn declares(manifest: &serde_json::Value, key: &str, value: &str) -> bool {
    manifest
        .get("capabilities")
        .and_then(|c| c.get(key))
        .and_then(serde_json::Value::as_array)
        .is_some_and(|list| list.iter().filter_map(serde_json::Value::as_str).any(|item| item == value))
}

fn absolute(host: &str) -> bool {
    let bytes = host.as_bytes();
    // A Windows drive root (`C:/...`, `C:\...`); the backslash is written as a character code so
    // this line does not have to be escaped differently in every editor.
    let drive = bytes.len() > 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' && (bytes[2] == b'/' || bytes[2] == 92);
    host.starts_with('/') || drive
}

/// A host path a preopen must never be: a filesystem root, or the node's own home/state/component
/// directories or anything containing them.
fn forbidden_dir(host: &str) -> Option<&'static str> {
    let path = std::path::Path::new(host);
    // A filesystem root has no normal component: `/`, `C:/`, `//?/C:/` (on Windows `/` is not
    // "absolute", so this has to come first).
    if !path.components().any(|part| matches!(part, std::path::Component::Normal(_))) {
        return Some("filesystem_root");
    }
    // The same two spellings `components::Grant` accepts: `/...` and `C:/...` (a Windows absolute
    // path), so a grant cannot pass the parser and fail here for a spelling difference.
    if !absolute(host) {
        return Some("not_absolute");
    }
    let normalised = host.replace('\\', "/").trim_end_matches('/').to_ascii_lowercase();
    let roots: Vec<(String, &'static str)> = [
        (wa_host_support::paths::component_dir().to_string_lossy().to_string(), "component_dir"),
        (wa_governance::store::state_root().to_string_lossy().to_string(), "state_root"),
        (std::env::var("WASM_AGENT_HOME").unwrap_or_default(), "node_home"),
        (std::env::var("HOME").unwrap_or_default(), "user_home"),
        (std::env::var("USERPROFILE").unwrap_or_default(), "user_home"),
    ]
    .into_iter()
    .filter(|(p, _)| p.len() > 1)
    .map(|(p, why)| (p.replace('\\', "/").trim_end_matches('/').to_ascii_lowercase(), why))
    .collect();
    for (root, why) in roots {
        // Granting the directory itself, or anything above it, exposes it: `C:/Users/u` contains
        // `C:/Users/u/.wasm-agent`. A preopen *inside* the node home is a different question, and the
        // policy rule - not this check - is where an operator says yes to one.
        if normalised == root || root.starts_with(&format!("{normalised}/")) {
            return Some(why);
        }
    }
    if normalised.contains("..") {
        return Some("relative_segments");
    }
    None
}

impl Scope {
    /// Read the manifest grant, filter it through the node policy, and record every decision.
    pub fn build(installed: &Installed, grant: &Grant) -> Scope {
        Scope::build_with(installed, grant, &NodeGate)
    }

    /// `build` with the policy layer passed in, so a test can drive the decisions and read the
    /// records without a node policy on the machine.
    pub fn build_with(installed: &Installed, grant: &Grant, gate: &dyn Gate) -> Scope {
        let name = installed.name.clone();
        let manifest = &installed.manifest;
        let mut scope = Scope {
            component: name.clone(),
            fs: Vec::new(),
            env: Vec::new(),
            stdin: false,
            net: Vec::new(),
            net_bind: Vec::new(),
            tcp: false,
            udp: false,
            dns: false,
            keyvalue: false,
            config: None,
        };

        // Filesystem: one decision per preopen, named by its *guest* path (the host path is the
        // operator's; the audit trail digests it like every other target).
        for dir in &grant.dirs {
            if let Some(why) = forbidden_dir(&dir.host) {
                gate.deny(&name, "wasi.filesystem", Some(&dir.guest), why);
                continue;
            }
            if !declares(manifest, "dirs", &dir.guest) {
                gate.deny(&name, "wasi.filesystem", Some(&dir.guest), "manifest_not_declared");
                continue;
            }
            if gate.allow(&name, "wasi.filesystem", Some(&dir.guest)) {
                scope.fs.push(FsDir { host: dir.host.clone(), guest: dir.guest.clone(), write: dir.write });
            }
        }

        // Environment: the grant lists *names*. The value is read from the node's environment only
        // for a name the policy allowed, and never reaches the log.
        for (key, host_name) in &grant.env {
            if !declares(manifest, "env", key) {
                gate.deny(&name, "wasi.env", Some(key), "manifest_not_declared");
                continue;
            }
            if gate.allow(&name, "wasi.env", Some(key)) {
                scope.env.push((key.clone(), host_name.clone()));
            }
        }

        // stdin: a manifest capability with no scope; the host hands an empty pipe, never its own.
        // A capability the artifact did not declare is not a decision to record: the record for a
        // component asking for it anyway is `wasi.import` in `check_imports`. Only a declared-and-
        // refused one is a refusal worth a line here.
        if declared(manifest, "stdin") {
            scope.stdin = gate.allow(&name, "wasi.stdin", None);
        }

        // Sockets: one decision per granted address, so "which addresses" is in the trail.
        for addr in &grant.net {
            if !declared(manifest, "net") {
                gate.deny(&name, "wasi.sockets", Some(addr), "manifest_not_declared");
                continue;
            }
            let Some(net) = Net::parse(addr) else {
                gate.deny(&name, "wasi.sockets", Some(addr), "invalid_address");
                continue;
            };
            // A `wasi:sockets` check sees an IP address, not a name (the guest resolves first, if it
            // is granted `dns`), so a hostname in this grant could never match anything. Refusing it
            // is the honest answer: an operator who wants a name writes `wa:kernel/http`'s grant,
            // which does see the URL.
            if net.host != "*" && net.host.parse::<std::net::IpAddr>().is_err() {
                gate.deny(&name, "wasi.sockets", Some(addr), "address_not_an_ip");
                continue;
            }
            if gate.allow(&name, "wasi.sockets", Some(addr)) {
                scope.net.push(net);
            }
        }
        // Inbound: only what the manifest names in `net_bind`, and only with a policy rule.
        if let Some(list) = manifest.get("capabilities").and_then(|c| c.get("net_bind")).and_then(serde_json::Value::as_array) {
            for addr in list.iter().filter_map(serde_json::Value::as_str) {
                let Some(net) = Net::parse(addr) else {
                    gate.deny(&name, "net.bind", Some(addr), "invalid_address");
                    continue;
                };
                if gate.allow(&name, "net.bind", Some(addr)) {
                    scope.net_bind.push(net);
                }
            }
        }
        scope.tcp = !scope.net.is_empty() || !scope.net_bind.is_empty();
        // UDP rides on the same grant: an operator who granted an address granted the address.
        scope.udp = scope.tcp && manifest.get("capabilities").and_then(|c| c.get("udp")).and_then(serde_json::Value::as_bool) != Some(false);

        if declared(manifest, "dns") && gate.allow(&name, "wasi.sockets", Some("dns")) {
            scope.dns = true;
        }

        // Keyvalue: the component's own kv namespace, so `storage` is the gate it already has.
        if declared(manifest, "storage") {
            scope.keyvalue = gate.allow(&name, "wasi.keyvalue", None);
        }

        // Config: the granted, non-secret configuration object. `wasi.config` asks once whether the
        // interface exists; every read is `config.read` at the call site.
        if declared(manifest, "config") && gate.allow(&name, "wasi.config", None) {
            scope.config = Some(grant.config.clone().unwrap_or_else(|| "{}".into()));
        }
        scope
    }

    /// What to link, derived from the scope above. Kept separate so a test can assert the mapping
    /// without instantiating anything.
    pub fn plan(&self) -> Plan {
        Plan {
            filesystem: !self.fs.is_empty(),
            environment: !self.env.is_empty(),
            stdin: self.stdin,
            // `ip-name-lookup` speaks the `types` records, so a DNS grant links the socket types too;
            // `allow_tcp` stays `Scope::tcp`, which a DNS-only grant does not set.
            sockets: self.tcp || self.dns,
            dns: self.dns,
            keyvalue: self.keyvalue,
            config: self.config.is_some(),
        }
    }

    /// One line per granted interface, for the component's log at start (the audit trail carries the
    /// decisions; this is what a person reading `services logs` sees).
    pub fn describe(&self) -> Vec<String> {
        let mut out = Vec::new();
        if !self.fs.is_empty() {
            let dirs: Vec<String> = self.fs.iter().map(|d| format!("{}:{}", d.guest, if d.write { "rw" } else { "ro" })).collect();
            out.push(format!("wasi filesystem {}", dirs.join(",")));
        }
        if !self.env.is_empty() {
            let names: Vec<&str> = self.env.iter().map(|(k, _)| k.as_str()).collect();
            out.push(format!("wasi environment {names:?}"));
        }
        if self.stdin {
            out.push("wasi stdin".into());
        }
        if !self.net.is_empty() || self.dns {
            let addrs: Vec<&str> = self.net.iter().map(|n| n.text.as_str()).collect();
            out.push(format!("wasi sockets net={addrs:?} dns={} udp={}", self.dns, self.udp));
        }
        if self.keyvalue {
            out.push("wasi keyvalue".into());
        }
        if self.config.is_some() {
            out.push("wasi config".into());
        }
        out
    }
}

/// Which interfaces this runner will link for one component.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Plan {
    pub filesystem: bool,
    pub environment: bool,
    pub stdin: bool,
    pub sockets: bool,
    pub dns: bool,
    pub keyvalue: bool,
    pub config: bool,
}

impl Plan {
    /// Is this interface (its table name, without a version) linked?
    pub fn has(&self, interface: &str) -> bool {
        match interface {
            "wasi:filesystem/types" | "wasi:filesystem/preopens" => self.filesystem,
            "wasi:cli/environment" => self.environment,
            "wasi:cli/stdin" => self.stdin,
            "wasi:sockets/types" | "wasi:sockets/network" | "wasi:sockets/instance-network" | "wasi:sockets/tcp" | "wasi:sockets/tcp-create-socket"
            | "wasi:sockets/udp" | "wasi:sockets/udp-create-socket" => self.sockets,
            "wasi:sockets/ip-name-lookup" => self.dns,
            "wa:kernel/keyvalue" => self.keyvalue,
            "wa:kernel/config" => self.config,
            _ => false,
        }
    }
}

/// The decision for one import of a component, as a reason word when it is refused.
///
/// `Ok` means "the linker has it"; `Err` is `import_not_granted` (tier B, not in the plan) or
/// `interface_never_served` (tier C, or the runtime cannot link it) or `interface_unknown` (a
/// `wasi:` package this node has no row for - which is a refusal, not a guess).
pub fn decide(import: &str, plan: &Plan) -> Result<(), &'static str> {
    let Some((row, version)) = spec_of(import) else {
        return Err("interface_unknown");
    };
    match tier_for(row, version) {
        Tier::Always => Ok(()),
        Tier::Never => Err("interface_never_served"),
        Tier::Granted => {
            if !row.served {
                Err("interface_unavailable")
            } else if plan.has(row.interface) {
                Ok(())
            } else {
                Err("import_not_granted")
            }
        }
    }
}

/// Check every `wasi:` and `wa:kernel/` WASI-shaped import of a component against the scope, in the
/// order the component wrote them, and return the first refusal as `<reason>:<interface>`.
///
/// Refusals are audited here (tier C ones too): "a component imported an interface it may never have"
/// is exactly the event an operator wants in the trail, and the reason word says which rule said no.
pub fn check_imports(imports: &[String], scope: &Scope, plan: &Plan) -> Result<(), String> {
    check_imports_with(imports, scope, plan, &NodeGate)
}

/// `check_imports` with the policy layer passed in (the tests use an in-memory one).
pub fn check_imports_with(imports: &[String], scope: &Scope, plan: &Plan, gate: &dyn Gate) -> Result<(), String> {
    for import in imports {
        // Only interfaces this table knows are ours to judge; `wa:kernel/websocket` and the preview-2
        // io package are the rest of the runner's business.
        let reason = match spec_of(import) {
            Some(_) => match decide(import, plan) {
                Ok(()) => continue,
                Err(reason) => reason,
            },
            None if import.starts_with("wasi:") => "interface_unknown",
            None => continue,
        };
        // A refusal is evidence: who asked for an interface it may not have, and which rule said no.
        gate.deny(&scope.component, "wasi.import", Some(import), reason);
        return Err(format!("wasi_import_{reason}:{import}"));
    }
    Ok(())
}

/// The socket address check the host installs for one component: every connect, bind, listen and
/// datagram is asked here first (`wasmtime_wasi::WasiCtxBuilder::socket_addr_check`), which is the
/// only place a WASI 0.3 socket can be scoped - `wasmtime` asks this same check for the sockets the
/// p3 interfaces create.
///
/// A rule that refuses returns `false` from the closure, which the guest sees as
/// `error-code::access-denied`; the decision and the address are in the audit trail under
/// `net.dial`/`net.bind` (the same capability names the `wa:kernel` path uses, so one operator view
/// reads both contracts).
pub struct SocketRule {
    pub component: String,
    pub net: Vec<Net>,
    pub bind: Vec<Net>,
    pub gate: Arc<dyn Gate + Send + Sync>,
}

impl SocketRule {
    /// The answer for one address and use: `(permitted, scoped)`. `scoped == false` is the implicit
    /// wildcard bind the OS performs during `connect`/`listen`: allowed whenever any scope exists and
    /// never audited, because a granted address already implies it.
    ///
    /// Every scoped refusal is recorded, whether the *grant* or the *policy* refused it: an operator
    /// reading the trail sees "this component tried to reach 10.0.0.1:443" (`target_not_allowed`),
    /// which is the event they care about, and the guest sees `access-denied`.
    pub fn answer(&self, addr: SocketAddr, use_: SocketAddrUse) -> (bool, bool) {
        let implicit = addr.port() == 0 && addr.ip().is_unspecified() && matches!(use_, SocketAddrUse::TcpBind | SocketAddrUse::UdpBind);
        if implicit {
            return (!self.net.is_empty() || !self.bind.is_empty(), false);
        }
        match use_ {
            SocketAddrUse::TcpConnect | SocketAddrUse::UdpSend => {
                if !self.net.iter().any(|net| net.covers(&addr)) {
                    return self.refuse("net.dial", &addr);
                }
                (self.gate.allow(&self.component, "net.dial", Some(&addr.to_string())), true)
            }
            SocketAddrUse::TcpBind | SocketAddrUse::TcpListen | SocketAddrUse::UdpBind => {
                // Inbound is loopback-only unless the manifest named the exact address, and the port
                // has to be one the grant names (or an ephemeral one the OS picks).
                let named = self.bind.iter().any(|bind| bind.covers(&addr));
                let loopback = addr.ip().is_loopback() && self.net.iter().any(|net| net.covers_bind(&addr));
                if !named && !loopback {
                    return self.refuse("net.bind", &addr);
                }
                (self.gate.allow(&self.component, "net.bind", Some(&addr.to_string())), true)
            }
            // A client accepted on a listener that was itself checked, and a datagram from a peer of a
            // bound socket: the address that decided was the bind.
            SocketAddrUse::TcpAccept | SocketAddrUse::UdpReceive => (true, false),
        }
    }

    fn refuse(&self, capability: &str, addr: &SocketAddr) -> (bool, bool) {
        self.gate.deny(&self.component, capability, Some(&addr.to_string()), "target_not_allowed");
        (false, true)
    }
}

/// Build the WASI context for one run: the same grants `docs/GRANT-POLICY.md` describes, applied to
/// the state `wasmtime-wasi` reads.
///
/// Nothing is inherited: no environment, no argv but the component's own name, an empty stdin unless
/// the grant names it (stdout/stderr are the component's log, installed by the caller), and a socket
/// check that answers from the scope. A component given no filesystem grant has no preopens at all, so
/// even the interface's `preopens` call answers with an empty list - and that interface is not linked
/// in that case, which is the stronger statement.
pub fn configure(builder: &mut WasiCtxBuilder, scope: &Scope, log: Option<std::fs::File>) -> Result<(), String> {
    builder.args(&[scope.component.as_str()]);
    if let Some(clone) = log {
        builder.stdout(wasmtime_wasi::cli::OutputFile::new(clone));
    }
    for (key, host_name) in &scope.env {
        if let Ok(value) = std::env::var(host_name) {
            builder.env(key, &value);
        }
    }
    if scope.stdin {
        // An empty pipe, never the node's own stdin: a service is not a terminal, and handing it the
        // operator's input would be a capability nobody granted.
        builder.stdin(wasmtime_wasi::p2::pipe::MemoryInputPipe::new(Vec::new()));
    }
    for dir in &scope.fs {
        let perms = if dir.write { wasmtime_wasi::FsPerms::ReadWrite } else { wasmtime_wasi::FsPerms::ReadOnly };
        builder.preopened_dir(&dir.host, &dir.guest, perms).map_err(|error| format!("preopen_failed:{}:{error}", dir.guest))?;
    }
    builder.allow_tcp(scope.tcp);
    builder.allow_udp(scope.udp);
    builder.allow_ip_name_lookup(scope.dns);
    let rule = Arc::new(SocketRule {
        component: scope.component.clone(),
        net: scope.net.clone(),
        bind: scope.net_bind.clone(),
        gate: Arc::new(NodeGate),
    });
    builder.socket_addr_check(move |addr, use_| {
        let rule = rule.clone();
        Box::pin(async move {
            let (permitted, scoped) = rule.answer(addr, use_);
            if scoped && !permitted {
                // A refusal is already in the audit trail (or was never a policy question); the
                // operator's log gets one line per address per run, not per packet.
                eprintln!("[wasi] {} refused socket {:?} {:?}", rule.component, addr, use_);
            }
            permitted
        })
    });
    Ok(())
}

/// Link the WASI interfaces the plan names, both versions: preview-2 spellings (`@0.2.0`, what a
/// `std`-built component imports) and WASI 0.3 spellings (`@0.3.0`, what a native-async guest
/// imports). Anything else is deliberately absent from the linker - a component that imports it was
/// refused by `check_imports` before it got here.
pub fn link(linker: &mut wasmtime::component::Linker<crate::service_components_v2::State>, plan: &Plan) -> wasmtime::Result<()> {
    /// `wasi:io`'s data projection (the resource table), spelled here because `wasmtime-wasi-io` keeps
    /// its own marker private and `WasiView` does not imply `IoView`.
    struct IoTable;
    impl wasmtime::component::HasData for IoTable {
        type Data<'a> = &'a mut wasmtime::component::ResourceTable;
    }
    use crate::service_components_v2::State;
    use wasmtime_wasi::cli::{WasiCli, WasiCliView};
    use wasmtime_wasi::clocks::{WasiClocks, WasiClocksView};
    use wasmtime_wasi::filesystem::{WasiFilesystem, WasiFilesystemView};
    use wasmtime_wasi::random::WasiRandom;
    use wasmtime_wasi::WasiView;
    use wasmtime_wasi::sockets::{WasiSockets, WasiSocketsView};
    // The generated bindings keep their per-package modules at `bindings::{cli,clocks,...}` (the
    // `wasi::` level is flattened by the re-export), so each family is named once here.
    use wasmtime_wasi::p2::bindings as bin2;
    use wasmtime_wasi::p3::bindings as bin3;

    // ---- tier A: always ------------------------------------------------------------------------
    bin3::clocks::types::add_to_linker::<_, WasiClocks>(linker, State::clocks)?;
    bin3::clocks::monotonic_clock::add_to_linker::<_, WasiClocks>(linker, State::clocks)?;
    bin3::clocks::system_clock::add_to_linker::<_, WasiClocks>(linker, State::clocks)?;
    bin3::random::random::add_to_linker::<_, WasiRandom>(linker, |s| s.ctx().ctx.random())?;
    bin3::random::insecure::add_to_linker::<_, WasiRandom>(linker, |s| s.ctx().ctx.random())?;
    bin3::random::insecure_seed::add_to_linker::<_, WasiRandom>(linker, |s| s.ctx().ctx.random())?;
    bin3::cli::exit::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin3::cli::stdout::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin3::cli::stderr::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin3::cli::terminal_input::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin3::cli::terminal_output::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin3::cli::terminal_stdin::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin3::cli::terminal_stdout::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin3::cli::terminal_stderr::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin2::clocks::wall_clock::add_to_linker::<_, WasiClocks>(linker, State::clocks)?;
    bin2::clocks::monotonic_clock::add_to_linker::<_, WasiClocks>(linker, State::clocks)?;
    bin2::random::random::add_to_linker::<_, WasiRandom>(linker, |s| s.ctx().ctx.random())?;
    bin2::random::insecure::add_to_linker::<_, WasiRandom>(linker, |s| s.ctx().ctx.random())?;
    bin2::random::insecure_seed::add_to_linker::<_, WasiRandom>(linker, |s| s.ctx().ctx.random())?;
    bin2::cli::exit::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin2::cli::stdout::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    // The two preview-2 cli interfaces that are linked for every component: a `std`-built component
    // imports them whether or not it uses them, and with no grant the environment list is empty and
    // stdin is an empty pipe ([`Spec::tier_p2`]).
    bin2::cli::environment::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin2::cli::stdin::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin2::cli::stderr::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin2::cli::terminal_input::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin2::cli::terminal_output::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin2::cli::terminal_stdin::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin2::cli::terminal_stdout::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    bin2::cli::terminal_stderr::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    // `wasi:io` is the preview-2 transport a component gets no capability from (a stream only
    // exists once another interface made one), so it is linked for every component that speaks
    // preview 2. `wasmtime_wasi_io`'s own aggregate linker needs `IoView`, which `WasiView` does not
    // imply, so the three interfaces are added directly against the context's resource table.
    wasmtime_wasi_io::bindings::wasi::io::error::add_to_linker::<_, IoTable>(linker, |s| s.ctx().table)?;
    wasmtime_wasi_io::bindings::wasi::io::poll::add_to_linker::<_, IoTable>(linker, |s| s.ctx().table)?;
    wasmtime_wasi_io::bindings::wasi::io::streams::add_to_linker::<_, IoTable>(linker, |s| s.ctx().table)?;

    // ---- tier B: only what the plan names ------------------------------------------------------
    if plan.filesystem {
        bin3::filesystem::types::add_to_linker::<_, WasiFilesystem>(linker, State::filesystem)?;
        bin3::filesystem::preopens::add_to_linker::<_, WasiFilesystem>(linker, State::filesystem)?;
        bin2::filesystem::types::add_to_linker::<_, WasiFilesystem>(linker, State::filesystem)?;
        bin2::filesystem::preopens::add_to_linker::<_, WasiFilesystem>(linker, State::filesystem)?;
    }
    if plan.environment {
        bin3::cli::environment::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    }
    if plan.stdin {
        bin3::cli::stdin::add_to_linker::<_, WasiCli>(linker, State::cli)?;
    }
    if plan.sockets {
        bin3::sockets::types::add_to_linker::<_, WasiSockets>(linker, State::sockets)?;
        bin2::sockets::network::add_to_linker::<_, WasiSockets>(linker, &Default::default(), State::sockets)?;
        bin2::sockets::instance_network::add_to_linker::<_, WasiSockets>(linker, State::sockets)?;
        bin2::sockets::tcp::add_to_linker::<_, WasiSockets>(linker, State::sockets)?;
        bin2::sockets::tcp_create_socket::add_to_linker::<_, WasiSockets>(linker, State::sockets)?;
        bin2::sockets::udp::add_to_linker::<_, WasiSockets>(linker, State::sockets)?;
        bin2::sockets::udp_create_socket::add_to_linker::<_, WasiSockets>(linker, State::sockets)?;
    }
    if plan.dns {
        bin3::sockets::ip_name_lookup::add_to_linker::<_, WasiSockets>(linker, State::sockets)?;
        bin2::sockets::ip_name_lookup::add_to_linker::<_, WasiSockets>(linker, State::sockets)?;
    }
    Ok(())
}


#[cfg(test)]
mod tests {
    use super::*;

    /// A gate that allows everything, for the rules that are about *scope* rather than policy.
    struct AllowAll;

    impl Gate for AllowAll {
        fn allow(&self, _: &str, _: &str, _: Option<&str>) -> bool {
            true
        }
        fn deny(&self, _: &str, _: &str, _: Option<&str>, _: &str) {}
    }

    /// A gate that records every question and every record it is asked to write, so a test can
    /// assert the decisions (and their wording) without a node policy on the machine - a unit test
    /// must never write to a node's audit trail.
    #[derive(Default)]
    struct Recording {
        records: std::sync::Mutex<Vec<String>>,
        refuse: Option<&'static str>,
    }

    impl Recording {
        fn refusing(capability: &'static str) -> Recording {
            Recording { records: std::sync::Mutex::new(Vec::new()), refuse: Some(capability) }
        }
        fn records(&self) -> Vec<String> {
            self.records.lock().unwrap_or_else(|e| e.into_inner()).clone()
        }
    }

    impl Gate for Recording {
        fn allow(&self, component: &str, capability: &str, target: Option<&str>) -> bool {
            let permitted = self.refuse != Some(capability);
            self.records.lock().unwrap_or_else(|e| e.into_inner()).push(format!(
                "{} {component} {capability} {}",
                if permitted { "allow" } else { "refuse" },
                target.unwrap_or("-")
            ));
            permitted
        }
        fn deny(&self, component: &str, capability: &str, target: Option<&str>, reason: &str) {
            self.records.lock().unwrap_or_else(|e| e.into_inner()).push(format!(
                "deny {component} {capability} {} {reason}",
                target.unwrap_or("-")
            ));
        }
    }

    /// The document and the table are the same list. A row added to the code without its line in
    /// `docs/WASI-INTERFACES.md` (or a row edited in one place only) fails here, which is the only
    /// thing keeping "the answer is in the docs" true.
    #[test]
    fn the_document_lists_every_interface_the_code_knows() {
        let doc = include_str!("../../../docs/WASI-INTERFACES.md");
        for row in TABLE {
            let line = doc
                .lines()
                .find(|line| line.starts_with(&format!("| `{}`", row.interface)))
                .unwrap_or_else(|| panic!("{} has no row in docs/WASI-INTERFACES.md", row.interface));
            let cells: Vec<&str> = line.split('|').map(|cell| cell.trim().trim_matches('`')).collect();
            assert_eq!(cells[2], row.tier.as_str(), "{} tier", row.interface);
            // Inline code markers are formatting: the words are what has to match.
            assert_eq!(cells[6].replace('`', ""), row.note.replace('`', ""), "{}: the note column must be the table's note", row.interface);
            let served = if row.served { "yes" } else { "no" };
            assert_eq!(cells[5], served, "{} served", row.interface);
            if row.tier == Tier::Granted {
                assert_eq!(cells[3], row.manifest_key, "{} manifest key", row.interface);
                assert_eq!(cells[4], row.capability, "{} policy capability", row.interface);
            }
        }
        // And the other direction: a row deleted from the code but left in the doc.
        for line in doc.lines().filter(|line| line.starts_with("| `wasi:") || line.starts_with("| `wa:")) {
            let name = line.split('`').nth(1).unwrap_or_default();
            assert!(TABLE.iter().any(|row| row.interface == name), "docs/WASI-INTERFACES.md lists {name}, the code does not");
        }
    }

    /// A version this node does not serve is not served, and a resource is not an interface.
    #[test]
    fn the_table_reads_import_names_the_way_the_component_writes_them() {
        assert_eq!(spec_of("wasi:cli/stdout@0.3.0").map(|(row, _)| row.interface), Some("wasi:cli/stdout"));
        assert_eq!(spec_of("wasi:filesystem/preopens@0.2.0").map(|(row, version)| (row.tier, version)), Some((Tier::Granted, "0.2.0")));
        assert_eq!(spec_of("wa:kernel/keyvalue@0.2.0").map(|(row, _)| row.tier), Some(Tier::Granted));
        // `wasi:tls/*` is a whole package: any interface in it is tier C.
        assert_eq!(spec_of("wasi:tls/certificate@0.1.0").map(|(row, _)| row.tier), Some(Tier::Never));
        // A resource (`package/interface.resource@version`) is not an interface.
        assert!(spec_of("wa:kernel/websocket.socket@0.2.0").is_none());
        assert!(spec_of("wa:kernel").is_none());
        assert!(serves("wasi:clocks/monotonic-clock@0.3.0"));
        assert!(serves("wasi:filesystem/types@0.3.0"));
        assert!(!serves("wasi:tls/certificate@0.1.0"));
        assert!(!serves("wasi:http/types@0.2.0"), "no wasi:http crate at wasmtime 50");
        assert!(!serves("wasi:nn/inference@0.3.0"));
    }

    /// The address allowlist: exact host:port, a `*.suffix` name, a `host:*` port, and the refusals a
    /// scope escape depends on (another host, another port, a name that merely contains the suffix).
    #[test]
    fn a_granted_address_covers_only_what_it_names() {
        let net = |text: &str| Net::parse(text).unwrap_or_else(|| panic!("{text} parses"));
        let covers = |pattern: &str, addr: &str| net(pattern).covers(&addr.parse().expect("a socket address"));
        assert!(covers("127.0.0.1:8080", "127.0.0.1:8080"));
        assert!(!covers("127.0.0.1:8080", "127.0.0.1:8081"), "another port is another address");
        assert!(!covers("127.0.0.1:8080", "127.0.0.2:8080"), "another host is another address");
        assert!(!covers("127.0.0.1:8080", "10.0.0.1:8080"));
        assert!(covers("127.0.0.1:*", "127.0.0.1:9"));
        assert!(covers("*:443", "93.184.216.34:443"));
        assert!(!covers("127.0.0.1:8080", "93.184.216.34:8080"));
        // A `wasi:sockets` check is handed an `IpAddr`, so a hostname entry is refused at grant time
        // (`address_not_an_ip`) rather than never matching: `Net` still parses it, so the refusal can
        // name what was written.
        let named = Net::parse("*.whatsapp.net:443").unwrap();
        assert_ne!(named.host, "*");
        assert!(named.host.parse::<std::net::IpAddr>().is_err());
        assert!(Net::parse("[::1]:9").is_some(), "an IPv6 literal is written with brackets");
        assert!(Net::parse("no-port").is_none());
        assert!(Net::parse("127.0.0.1:not-a-port").is_none());
    }

    /// The socket check itself, without a guest: outbound only for a granted address, inbound only on
    /// loopback or an explicitly named bind address.
    #[test]
    fn the_socket_rule_scopes_outbound_and_inbound() {
        let rule = SocketRule {
            component: "unit-test".into(),
            net: vec![Net::parse("127.0.0.1:8080").unwrap(), Net::parse("127.0.0.1:*").unwrap()],
            bind: vec![Net::parse("0.0.0.0:9000").unwrap()],
            gate: Arc::new(AllowAll),
        };
        let addr = |text: &str| text.parse::<SocketAddr>().expect("an address");
        assert!(rule.answer(addr("127.0.0.1:8080"), SocketAddrUse::TcpConnect).0);
        assert!(rule.answer(addr("127.0.0.1:8081"), SocketAddrUse::TcpConnect).0, "a granted host:* covers every port on it");
        let refused = rule.answer(addr("127.0.0.2:9"), SocketAddrUse::TcpConnect);
        assert_eq!(refused, (false, true), "another host is refused, and the refusal is a scoped decision");
        // An implicit bind (the wildcard with port 0 that the OS performs during connect) is not a
        // scope: a granted address already implies it.
        assert_eq!(rule.answer(addr("0.0.0.0:0"), SocketAddrUse::TcpBind), (true, false));
        // Explicit inbound: loopback on a granted port, or the exact address the manifest named.
        assert!(rule.answer(addr("127.0.0.1:8081"), SocketAddrUse::TcpBind).0);
        assert!(rule.answer(addr("0.0.0.0:9000"), SocketAddrUse::TcpBind).0, "named in net_bind");
        assert!(!rule.answer(addr("0.0.0.0:9001"), SocketAddrUse::TcpBind).0, "a public bind nobody asked for");
        assert!(!rule.answer(addr("192.168.1.5:8080"), SocketAddrUse::TcpListen).0, "inbound is loopback unless named");
        // An accepted client was decided by the bind.
        assert_eq!(rule.answer(addr("203.0.113.7:5555"), SocketAddrUse::TcpAccept), (true, false));
        // With no grant at all nothing is reachable, not even the implicit bind.
        let empty = SocketRule { component: "unit-test".into(), net: Vec::new(), bind: Vec::new(), gate: Arc::new(AllowAll) };
        // A rule the policy denies is refused even when the address is granted (`net.dial`).
        let denied = SocketRule {
            component: "unit-test".into(),
            net: vec![Net::parse("127.0.0.1:8080").unwrap()],
            bind: Vec::new(),
            gate: Arc::new(Recording::refusing("net.dial")),
        };
        assert_eq!(denied.answer(addr("127.0.0.1:8080"), SocketAddrUse::TcpConnect), (false, true), "a policy refusal wins over a granted address");
        assert_eq!(empty.answer(addr("0.0.0.0:0"), SocketAddrUse::TcpBind), (false, false));
        assert!(!empty.answer(addr("127.0.0.1:1"), SocketAddrUse::TcpConnect).0);
    }

    /// A preopen may never be a filesystem root, the node's home/state/component directory, or a
    /// directory that contains one.
    #[test]
    fn a_preopen_is_never_a_root_or_the_node_home() {
        assert_eq!(forbidden_dir("/"), Some("filesystem_root"));
        assert_eq!(forbidden_dir("/srv/wa/data"), None, "an ordinary directory is fine");
        assert_eq!(forbidden_dir("relative/dir"), Some("not_absolute"));
        let home = std::env::var("WASM_AGENT_HOME").unwrap_or_else(|_| std::env::var("HOME").unwrap_or_default());
        if home.len() > 1 {
            assert!(forbidden_dir(&home).is_some(), "the node home itself");
            let parent = std::path::Path::new(&home).parent().map(|p| p.to_string_lossy().to_string()).unwrap_or_default();
            if parent.len() > 1 {
                assert!(forbidden_dir(&parent).is_some(), "a directory that contains the node home");
            }
        }
        // A directory *inside* the node home is a different question: the policy decides, not this
        // check (an operator may grant `~/.wasm-agent/components/x/data` on purpose).
        assert_eq!(forbidden_dir(&format!("{}/components/x/data", wa_host_support::paths::component_dir().to_string_lossy())), None);
    }

    /// What a set of grants links. This is the mapping `run_once` asks for, tested without a guest.
    #[test]
    fn the_plan_follows_the_grant() {
        let scope = Scope {
            component: "unit".into(),
            fs: Vec::new(),
            env: Vec::new(),
            stdin: false,
            net: Vec::new(),
            net_bind: Vec::new(),
            tcp: false,
            udp: false,
            dns: false,
            keyvalue: false,
            config: None,
        };
        assert_eq!(scope.plan(), Plan::default(), "no grant, no tier B interface");
        let granted = Scope {
            fs: vec![FsDir { host: "/srv/d".into(), guest: "/data".into(), write: false }],
            env: vec![("WA_MODE".into(), "WA_MODE".into())],
            stdin: true,
            net: vec![Net::parse("127.0.0.1:9").unwrap()],
            tcp: true,
            keyvalue: true,
            config: Some("{}".into()),
            ..scope
        };
        let plan = granted.plan();
        assert!(plan.has("wasi:filesystem/types") && plan.has("wasi:filesystem/preopens"));
        assert!(plan.has("wasi:cli/environment") && plan.has("wasi:cli/stdin"));
        assert!(plan.has("wasi:sockets/types") && !plan.has("wasi:sockets/ip-name-lookup"), "dns is its own grant");
        assert!(plan.has("wa:kernel/keyvalue") && plan.has("wa:kernel/config"));
    }

    /// The import check: tier A always, tier B only when granted, tier C and unknown packages never.
    /// The words here are the ones a component's `last_exit` and its log will show.
    #[test]
    fn an_import_is_refused_by_name_and_reason() {
        let scope = Scope {
            component: "unit".into(),
            fs: Vec::new(),
            env: Vec::new(),
            stdin: false,
            net: Vec::new(),
            net_bind: Vec::new(),
            tcp: false,
            udp: false,
            dns: false,
            keyvalue: false,
            config: None,
        };
        let plan = scope.plan();
        let names = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<String>>();
        let gate = Recording::default();
        let check = |imports: &[&str], plan: &Plan| check_imports_with(&names(imports), &scope, plan, &gate);
        // Tier A needs no grant.
        assert_eq!(check(&["wasi:clocks/monotonic-clock@0.3.0", "wasi:random/random@0.3.0"], &plan), Ok(()));
        assert!(gate.records().is_empty(), "a tier A import is not a policy decision");
        // Tier B without its grant: named, with the reason.
        assert_eq!(
            check(&["wasi:filesystem/preopens@0.3.0"], &plan),
            Err("wasi_import_import_not_granted:wasi:filesystem/preopens@0.3.0".to_string())
        );
        // Tier C: never, for any component.
        assert_eq!(
            check(&["wasi:tls/certificate@0.1.0"], &plan),
            Err("wasi_import_interface_never_served:wasi:tls/certificate@0.1.0".to_string())
        );
        // A WASI package this node has no row for is a refusal, not a guess.
        assert_eq!(
            check(&["wasi:async/future@0.1.0"], &plan),
            Err("wasi_import_interface_unknown:wasi:async/future@0.1.0".to_string())
        );
        // One audit record per refusal, with the interface and the reason word.
        assert_eq!(
            gate.records(),
            vec![
                "deny unit wasi.import wasi:filesystem/preopens@0.3.0 import_not_granted".to_string(),
                "deny unit wasi.import wasi:tls/certificate@0.1.0 interface_never_served".to_string(),
                "deny unit wasi.import wasi:async/future@0.1.0 interface_unknown".to_string(),
            ]
        );
        // A `wa:kernel` interface this table does not decide is left to the runner (it links it).
        assert_eq!(check(&["wa:kernel/kv@0.2.0", "wa:kernel/log@0.2.0"], &plan), Ok(()));
        // Granted, it is served.
        let granted = Scope { env: vec![("WA_MODE".into(), "WA_MODE".into())], ..scope };
        let plan = granted.plan();
        assert_eq!(check_imports_with(&names(&["wasi:cli/environment@0.3.0"]), &granted, &plan, &gate), Ok(()));
    }

    /// `Scope::build` against a manifest and a grant, with the policy layer replaced by a recorder:
    /// one question per scope element, a refusal (with its reason) for a host path that is never a
    /// preopen, a hostname refused as a WASI socket scope, and the scope it ends up with.
    #[test]
    fn a_grant_becomes_a_scope_with_one_recorded_decision_per_element() {
        let installed = Installed {
            name: "unit".into(),
            sha256: String::new(),
            bytes: Vec::new(),
            manifest: serde_json::json!({"capabilities": {
                "dirs": ["/data", "/other"],
                "env": ["WA_MODE"],
                "net": ["127.0.0.1:*", "example.com:443"],
                "stdin": true,
                "storage": true,
                "config": true
            }}),
        };
        let grant = Grant::from_request(&serde_json::json!({
            "dirs": [
                {"host": "/", "guest": "/root"},
                {"host": "/srv/data", "guest": "/data", "write": true}
            ],
            "env": {"WA_MODE": "WA_MODE", "WA_SECRET": "WA_SECRET"},
            "net": ["127.0.0.1:9", "example.com:443"],
            "config": {"present": "yes", "count": 2}
        }))
        .expect("a valid request");
        // `Grant::check` is what refuses a grant beyond the manifest; `build_with` assumes it passed,
        // except for `env`, where an undeclared *name* is refused per name below.
        let gate = Recording::default();
        let scope = Scope::build_with(&installed, &grant, &gate);
        assert_eq!(
            gate.records(),
            vec![
                "deny unit wasi.filesystem /root filesystem_root",
                "allow unit wasi.filesystem /data",
                "allow unit wasi.env WA_MODE",
                "deny unit wasi.env WA_SECRET manifest_not_declared",
                "allow unit wasi.stdin -",
                "allow unit wasi.sockets 127.0.0.1:9",
                "deny unit wasi.sockets example.com:443 address_not_an_ip",
                "allow unit wasi.keyvalue -",
                "allow unit wasi.config -",
            ]
        );
        assert_eq!(scope.fs, vec![FsDir { host: "/srv/data".into(), guest: "/data".into(), write: true }]);
        assert_eq!(scope.env, vec![("WA_MODE".to_string(), "WA_MODE".to_string())]);
        assert!(scope.stdin && scope.keyvalue);
        assert!(scope.tcp && !scope.dns, "tcp from the address grant, dns only with its own");
        assert_eq!(scope.net.len(), 1);
        assert_eq!(scope.config.as_deref(), Some(r#"{"count":2,"present":"yes"}"#));
        // The plan is exactly what the surviving scope names, and nothing more.
        let plan = scope.plan();
        assert!(plan.filesystem && plan.environment && plan.stdin && plan.sockets && plan.keyvalue && plan.config);
        assert!(!plan.dns);
    }

    /// A policy that refuses one capability drops that scope element (and not the others), so a node
    /// can narrow a grant to nothing without the component being told a half-truth.
    #[test]
    fn a_policy_refusal_drops_only_what_it_names() {
        let installed = Installed {
            name: "unit".into(),
            sha256: String::new(),
            bytes: Vec::new(),
            manifest: serde_json::json!({"capabilities": {"env": ["WA_MODE"], "dirs": ["/data"]}}),
        };
        let grant = Grant::from_request(&serde_json::json!({
            "dirs": [{"host": "/srv/data", "guest": "/data"}],
            "env": {"WA_MODE": "WA_MODE"}
        }))
        .unwrap();
        let gate = Recording::refusing("wasi.filesystem");
        let scope = Scope::build_with(&installed, &grant, &gate);
        assert!(scope.fs.is_empty(), "the preopen was refused");
        assert_eq!(scope.env.len(), 1, "the environment grant is untouched");
        assert!(!scope.plan().filesystem);
        // And a component that imports the refused interface is then refused by name.
        let refusal = check_imports_with(&["wasi:filesystem/types@0.3.0".to_string()], &scope, &scope.plan(), &gate);
        assert_eq!(refusal, Err("wasi_import_import_not_granted:wasi:filesystem/types@0.3.0".to_string()));
    }
}
