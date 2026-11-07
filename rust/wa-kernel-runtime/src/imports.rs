//! What a component imports, and what therefore has to be running before it may start
//! (`docs/KERNEL.md`, lesson 3: "start by imports").
//!
//! A definition's position in a configuration file means nothing. What decides whether a component
//! can start is the set of interfaces it imports: each one is either served by the kernel (the
//! runner links it) or exported by a **running provider component**. This module answers three
//! questions, and nothing else:
//!
//! 1. [`of_bytes`] / [`of_installed`]: which interfaces does this artifact import and export? Read
//!    from the artifact's own type (compiled once, then cached by pin), never from a manifest field
//!    an operator could get wrong.
//! 2. [`Interfaces::external`]: which of those imports no kernel interface serves - i.e. the ones a
//!    provider has to be running for.
//! 3. [`Interfaces::waiting_for`]: the first unserved import, named exactly as the component wrote it
//!    (`wa:vision/text-reader@0.1.0`), which is what `services status` prints as
//!    `waiting for <interface>`.
//!
//! Three contracts exist side by side and the artifact's imports say which one it speaks:
//!
//! | artifact | imports look like | runner |
//! | --- | --- | --- |
//! | wasip1 core module | modules `wasi_snapshot_preview1`, `wa_sock`, `wa_ws`, `wa_http`, `wa_kv`, `wa_ctl` | `services.rs` (`run_once`) |
//! | component, `wa:kernel@0.1.0` | `wa:kernel/kv@0.1.0`, `wasi:io/streams@0.2.3` | `service_components.rs` |
//! | component, `wa:kernel@0.2.0` | `wa:kernel/kv@0.2.0`, `wasi:clocks/monotonic-clock@0.3.0` | `service_components_v2.rs` |
//!
//! **Exact versions.** `wa:kernel/kv@0.1.0` and `@0.2.0` are different interfaces served by different
//! runners; a component that asks for a version nobody serves waits (and says which) instead of being
//! started against a contract it was not built for. That is the same rule the transactional install
//! applies to a manifest's `state_version`.
//!
//! The risk this module carries, named: the kernel-served set is a constant, so a new interface added
//! to `wit/kernel` without a line here would show up as "waiting for" rather than as a start. The
//! drift test below reads the WIT files and fails when the two disagree, so the constant cannot rot
//! silently.

use crate::components::Installed;
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::sync::{Mutex, OnceLock};

/// Which contract the artifact speaks, and therefore which runner serves it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Contract {
    /// A `wasm32-wasip1` core module (`_start`), the Go-era runner.
    Wasip1,
    /// A component exporting the 0.1 `service` world (polling).
    V1,
    /// A component importing `wa:kernel/*@0.2.0` (WASI 0.3, native async).
    V2,
}

impl Contract {
    pub fn as_str(&self) -> &'static str {
        match self {
            Contract::Wasip1 => "wasip1",
            Contract::V1 => "wa:kernel@0.1",
            Contract::V2 => "wa:kernel@0.2",
        }
    }
}

/// Interfaces the two component runners link. Both link WASI preview 2; only the 0.2 runner links the
/// WASI 0.3 timer a 0.2 guest awaits (`wasmtime_wasi::p3::clocks`).
const KERNEL_V1: &[&str] = &["types", "websocket", "http", "speech", "kv", "lifecycle", "log", "credentials"];
const KERNEL_V2: &[&str] = &["types", "websocket", "http", "speech", "kv", "lifecycle", "log", "credentials"];
/// Interfaces the 0.2 runner serves that no world *requires*: a component may import them, and the
/// service world does not list them because a world's imports are obligations (`wit/kernel-v2`).
/// `keyvalue`/`config` are wa's `wasi:keyvalue`/`wasi:config` shapes (`docs/WASI-INTERFACES.md`,
/// tier B), so a component built against the proposal's shape can import them and be started.
/// `drain` is the cooperative hot swap (`docs/SERVICE-COMPONENTS.md`, "A swap waits for the work in
/// flight"): importing it *is* the declaration that this component finishes its job before it
/// stops, which is what lets a swap tell a drainable instance from one to stop immediately.
const KERNEL_V2_OPTIONAL: &[&str] = &["keyvalue", "config", "drain"];
/// The modules a wasip1 service may import from the host (`services.rs::linker`).
const WASIP1_HOST_MODULES: &[&str] = &["wasi_snapshot_preview1", "wa_sock", "wa_ws", "wa_http", "wa_kv", "wa_ctl"];
/// Provider packages the kernel itself serves beside `wa:kernel` (`bus_host`, `queue_host`).
const KERNEL_PROVIDER_PACKAGES: &[(&str, &str)] = &[("wa:bus", "0.1.0"), ("wa:queue", "0.1.0")];

/// Is this import name served by the kernel for this contract?
pub fn kernel_serves(import: &str, contract: Contract) -> bool {
    match contract {
        Contract::Wasip1 => WASIP1_HOST_MODULES.contains(&import),
        Contract::V1 | Contract::V2 => {
            // `wasi:` is the kernel's own business in both runners. The 0.3 clock is the one interface
            // only the async runner links, so a 0.1 component that imported it would be started and
            // fail to link; naming it here keeps that a "waiting" answer instead.
            if import.starts_with("wasi:") {
                let v3 = import.contains("@0.3.");
                if contract != Contract::V2 {
                    return !v3;
                }
                // The 0.2 runner links WASI one interface at a time under the grant policy
                // (`docs/WASI-INTERFACES.md`), so "the kernel serves this" is exactly "the table has
                // it at tier A or B and this wasmtime can link it". A tier C interface is *never*
                // served: saying otherwise would make a component importing `wasi:tls` start and
                // then fail to link, instead of waiting with the interface named.
                return crate::wasi_grants::serves(import);
            }
            let (package, rest) = import.split_once('/').unwrap_or((import, ""));
            let (rest, version) = rest.rsplit_once('@').unwrap_or((rest, ""));
            if package == "wa:kernel" {
                let served = if contract == Contract::V2 { KERNEL_V2 } else { KERNEL_V1 };
                let expected = if contract == Contract::V2 { "0.2.0" } else { "0.1.0" };
                let optional = contract == Contract::V2 && KERNEL_V2_OPTIONAL.contains(&rest);
                return version == expected && (served.contains(&rest) || optional);
            }
            KERNEL_PROVIDER_PACKAGES.iter().any(|(name, v)| *name == package && version == *v)
        }
    }
}

/// What one artifact imports and exports, and the contract its imports imply.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Interfaces {
    pub contract: Contract,
    pub imports: BTreeSet<String>,
    pub exports: BTreeSet<String>,
}

impl Interfaces {
    /// The imports no kernel interface serves: the ones a provider has to be running for.
    pub fn external(&self) -> BTreeSet<String> {
        self.imports.iter().filter(|name| !kernel_serves(name, self.contract)).cloned().collect()
    }

    /// The imports that `served` does not cover, in the order the component wrote them. Empty means
    /// "everything it needs is here".
    pub fn waiting_for(&self, served: &BTreeSet<String>) -> Vec<String> {
        self.external().into_iter().filter(|name| !served.contains(name)).collect()
    }

    /// The exports a consumer could import: `wa:vision/text-reader@0.1.0` and friends.
    ///
    /// Not all exports are offers: WASI, the C ABI a core module exposes, and the kernel's own entry
    /// point (`wa:kernel/service`, which every service exports and no other component imports) are
    /// the artifact's obligations, not capabilities. Offering them as "served" would let a component
    /// start on the strength of a name that provides nothing.
    pub fn provides(&self) -> BTreeSet<String> {
        self.exports
            .iter()
            .filter(|name| {
                !name.starts_with("wasi:") && !name.starts_with("wa:kernel/") && !name.starts_with("cabi") && !name.starts_with('_')
            })
            .cloned()
            .collect()
    }

    pub fn to_json(&self) -> Value {
        json!({
            "contract": self.contract.as_str(),
            "imports": self.imports.iter().cloned().collect::<Vec<_>>(),
            "exports": self.exports.iter().cloned().collect::<Vec<_>>(),
            "external": self.external().into_iter().collect::<Vec<_>>(),
        })
    }
}

/// Read the interfaces of an artifact, from the artifact.
///
/// A component is compiled on the async-capable engine (it compiles both contracts; the type is read
/// from the compiled component, never from a run). A core module is parsed only. Both are cheap for a
/// small artifact and cached by pin for a large one ([`of_installed`]).
pub fn of_bytes(bytes: &[u8]) -> Result<Interfaces> {
    if crate::service_components::is_component(bytes) {
        let engine = crate::service_components_v2::engine().map_err(|e| anyhow!("engine_failed:{e}"))?;
        // The same compiled component the runner will get, keyed by the same pin: reading the interface
        // list must not pay for a second compilation of an 8 MB artifact (or skip the disk cache the
        // node already paid for).
        let digest: String = ring::digest::digest(&ring::digest::SHA256, bytes).as_ref().iter().map(|b| format!("{b:02x}")).collect();
        let component = crate::components::compiled(&engine, &digest, bytes).map_err(|e| anyhow!("compile_failed:{e}"))?;
        let ty = component.component_type();
        let imports: BTreeSet<String> = ty.imports(&engine).map(|(name, _)| name.to_string()).collect();
        let exports: BTreeSet<String> = ty.exports(&engine).map(|(name, _)| name.to_string()).collect();
        let contract = if imports.iter().any(|name| name.starts_with("wa:kernel/") && name.ends_with("@0.2.0")) {
            Contract::V2
        } else {
            Contract::V1
        };
        return Ok(Interfaces { contract, imports, exports });
    }
    let engine = crate::components::engine().map_err(|e| anyhow!("engine_failed:{e}"))?;
    let module = wasmtime::Module::new(&engine, bytes).map_err(|e| anyhow!("compile_failed:{e}"))?;
    let imports: BTreeSet<String> = module.imports().map(|import| import.module().to_string()).collect();
    let exports: BTreeSet<String> = module.exports().map(|export| export.name().to_string()).collect();
    Ok(Interfaces { contract: Contract::Wasip1, imports, exports })
}

/// `of_bytes` for an installed component, cached by pin: the same bytes answer the same interfaces, so
/// a supervisor that re-plans on every start does not recompile an 8 MB component each time.
pub fn of_installed(installed: &Installed) -> Result<Interfaces> {
    static CACHE: OnceLock<Mutex<std::collections::HashMap<String, Interfaces>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(std::collections::HashMap::new()));
    if let Some(found) = cache.lock().map_err(|_| anyhow!("interfaces_cache_poisoned"))?.get(&installed.sha256) {
        return Ok(found.clone());
    }
    let interfaces = of_bytes(&installed.bytes)?;
    cache.lock().map_err(|_| anyhow!("interfaces_cache_poisoned"))?.insert(installed.sha256.clone(), interfaces.clone());
    Ok(interfaces)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn set(names: &[&str]) -> BTreeSet<String> {
        names.iter().map(|n| n.to_string()).collect()
    }

    #[test]
    fn the_kernel_serves_exactly_the_versions_its_runners_link() {
        // 0.1 and 0.2 are different interfaces; asking for the wrong one is a wait, not a start.
        assert!(kernel_serves("wa:kernel/kv@0.1.0", Contract::V1));
        assert!(!kernel_serves("wa:kernel/kv@0.1.0", Contract::V2));
        assert!(kernel_serves("wa:kernel/kv@0.2.0", Contract::V2));
        assert!(!kernel_serves("wa:kernel/kv@0.2.0", Contract::V1));
        // A resource of an interface is not an interface.
        assert!(!kernel_serves("wa:kernel/websocket.socket@0.1.0", Contract::V1));
        // WASI preview 2 in both runners; the 0.3 timer only in the async one.
        assert!(kernel_serves("wasi:io/streams@0.2.3", Contract::V1));
        assert!(kernel_serves("wasi:cli/environment@0.2.3", Contract::V2));
        assert!(kernel_serves("wasi:clocks/monotonic-clock@0.3.0", Contract::V2));
        assert!(!kernel_serves("wasi:clocks/monotonic-clock@0.3.0", Contract::V1));
        // The tier table decides for a 0.2 component: A and B are served (a grant is a separate
        // question), C is never - so a component importing one waits instead of failing to link.
        assert!(kernel_serves("wasi:filesystem/preopens@0.3.0", Contract::V2));
        assert!(kernel_serves("wasi:sockets/types@0.3.0", Contract::V2));
        assert!(!kernel_serves("wasi:tls/*@0.1.0", Contract::V2));
        assert!(!kernel_serves("wasi:http/outgoing-handler@0.2.0", Contract::V2), "no wasi:http crate at wasmtime 50");
        assert!(!kernel_serves("wasi:logging/logging@0.1.0", Contract::V2));
        assert!(!kernel_serves("wasi:not-a-package/thing@0.1.0", Contract::V2));
        // wa's own `wasi:keyvalue`/`wasi:config` shapes are served by the 0.2 runner only.
        assert!(kernel_serves("wa:kernel/keyvalue@0.2.0", Contract::V2));
        assert!(kernel_serves("wa:kernel/config@0.2.0", Contract::V2));
        assert!(!kernel_serves("wa:kernel/keyvalue@0.2.0", Contract::V1));
        // The drain is optional and 0.2-only: a component that does not import it is stopped
        // immediately, and a 0.1 component waits for a start like any other unserved import.
        assert!(kernel_serves("wa:kernel/drain@0.2.0", Contract::V2));
        assert!(!kernel_serves("wa:kernel/drain@0.2.0", Contract::V1));
        assert!(!kernel_serves("wa:kernel/drain@0.1.0", Contract::V2));
        // The kernel's own providers, and the wasip1 host modules.
        assert!(kernel_serves("wa:bus/publisher@0.1.0", Contract::V2));
        assert!(kernel_serves("wa:queue/worker@0.1.0", Contract::V1));
        assert!(!kernel_serves("wa:queue/worker@0.9.0", Contract::V1));
        for module in ["wasi_snapshot_preview1", "wa_sock", "wa_ws", "wa_http", "wa_kv", "wa_ctl"] {
            assert!(kernel_serves(module, Contract::Wasip1), "{module}");
        }
        assert!(!kernel_serves("wa_vision", Contract::Wasip1));
        // A provider interface is nobody's kernel import: it has to be running.
        assert!(!kernel_serves("wa:vision/text-reader@0.1.0", Contract::V1));
        assert!(!kernel_serves("wa:speech/recognizer@0.1.0", Contract::V2));
    }

    #[test]
    fn waiting_for_names_the_first_unserved_import_and_ignores_what_the_kernel_serves() {
        let interfaces = Interfaces {
            contract: Contract::V2,
            imports: set(&["wa:kernel/kv@0.2.0", "wasi:clocks/monotonic-clock@0.3.0", "wa:vision/text-reader@0.1.0"]),
            exports: set(&["wa:kernel/service@0.2.0", "wasi:cli/run@0.2.3"]),
        };
        assert_eq!(interfaces.external(), set(&["wa:vision/text-reader@0.1.0"]));
        assert_eq!(interfaces.waiting_for(&BTreeSet::new()), vec!["wa:vision/text-reader@0.1.0".to_string()]);
        assert!(interfaces.waiting_for(&set(&["wa:vision/text-reader@0.1.0"])).is_empty());
        // A provider is what a consumer can import; WASI and the entry point are not offers.
        assert_eq!(interfaces.provides(), BTreeSet::new());
    }

    /// The constant above against the contract it describes: a new interface in `wit/kernel` that
    /// nobody added to `KERNEL_V1`/`KERNEL_V2` shows up here, not as a mystery wait on a node.
    #[test]
    fn the_served_interface_lists_match_the_wit_worlds() {
        fn world_imports(path: &str, world: &str) -> BTreeSet<String> {
            let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
            let mut inside = false;
            let mut out = BTreeSet::new();
            for line in text.lines() {
                let line = line.trim();
                if let Some(rest) = line.strip_prefix("world ") {
                    inside = rest.trim_end_matches('{').trim() == world;
                    continue;
                }
                if !inside {
                    continue;
                }
                if line == "}" {
                    break;
                }
                if let Some(rest) = line.strip_prefix("import ") {
                    let name = rest.trim_end_matches(';').trim();
                    // `import kv;` is `wa:kernel/kv@<package version>`; a fully-qualified import is
                    // WASI's and is checked by `kernel_serves` directly.
                    if !name.contains(':') {
                        out.insert(name.to_string());
                    }
                }
            }
            out
        }
        let v1 = world_imports("../../wit/kernel/kernel.wit", "service-component");
        let v2 = world_imports("../../wit/kernel-v2/kernel.wit", "service-component");
        assert_eq!(v1, KERNEL_V1.iter().map(|s| s.to_string()).collect::<BTreeSet<_>>(), "wit/kernel/kernel.wit world service-component");
        assert_eq!(v2, KERNEL_V2.iter().map(|s| s.to_string()).collect::<BTreeSet<_>>(), "wit/kernel-v2/kernel.wit world service-component");
        for name in &v1 {
            assert!(kernel_serves(&format!("wa:kernel/{name}@0.1.0"), Contract::V1), "{name}");
        }
        for name in &v2 {
            assert!(kernel_serves(&format!("wa:kernel/{name}@0.2.0"), Contract::V2), "{name}");
        }
    }

    #[test]
    fn a_core_module_is_read_the_same_way_and_counts_its_host_modules_as_served() {
        let bytes = crate::test_wasm::core_module(&[("wa_sock", "connect"), ("wa_vision", "read")], true);
        let interfaces = of_bytes(&bytes).expect("a hand-built module parses");
        assert_eq!(interfaces.contract, Contract::Wasip1);
        assert_eq!(interfaces.imports, set(&["wa_sock", "wa_vision"]));
        assert!(interfaces.exports.contains("_start"));
        assert_eq!(interfaces.waiting_for(&BTreeSet::new()), vec!["wa_vision".to_string()]);
    }

    #[test]
    fn an_artifact_that_does_not_compile_is_a_refusal_not_an_empty_set() {
        let error = of_bytes(b"\0asm\x01\0\0\0\xff\xff").unwrap_err().to_string();
        assert!(error.contains("compile_failed"), "{error}");
    }
}
