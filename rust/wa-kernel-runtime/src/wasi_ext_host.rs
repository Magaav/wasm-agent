//! `wa:kernel/keyvalue` and `wa:kernel/config`: the `wasi:keyvalue` and `wasi:config` shapes, served
//! over what the kernel already owns - this component's kv namespace and the non-secret config it was
//! granted (`docs/WASI-INTERFACES.md`, tier B).
//!
//! Why not the proposals themselves: `wasmtime` 50 ships no `wasi:keyvalue` and no `wasi:config`
//! crate (`wasmtime-wasi` 50 is clocks, random, cli, filesystem, sockets; `wasmtime-wasi-nn` stops at
//! 37), so a component that imports those packages is refused before it runs
//! (`wasi_import_interface_unknown`) rather than silently given nothing. The *shape* is what a port of
//! a component written against the proposal needs: `get`/`set`/`delete`/`exists`/`list-keys`.
//!
//! Two properties are deliberate and both are tested:
//!
//! * **One key space.** The keys are the bytes of `wa:kernel/kv`, in the same namespace, behind the
//!   same `__wa/` guard: a component cannot use the WASI spelling to reach a key its `kv` calls
//!   cannot, and an operator's `kv.read`/`kv.write` rules govern both. The capability names are the
//!   ones the kv path already uses, so one audit vocabulary covers both interfaces.
//! * **No key text or value in a log line.** A refusal names the key in the error the guest sees (it
//!   asked for it) and the audit record digests the target like every other one.
//!
//! The bindings are generated from `wit/kernel-v2`'s `keyvalue-config` world, which imports exactly
//! these two interfaces: the service runner owns the rest, and a second copy of a resource type would
//! be a second, subtly different contract.
use crate::guest_kv;
use crate::service_components_v2::State;
use wa_governance::node_telemetry::HostCallGuard;
use wa_grant_policy::Decision;

wasmtime::component::bindgen!({
    path: "../../wit/kernel-v2",
    world: "keyvalue-config",
});

use wa::kernel::types::Error as KError;

/// The keyvalue interface has no resources, so its plain `Host` trait is empty - but the generated
/// linker still asks for it beside `HostWithStore`, exactly as the runner implements
/// `wa::kernel::websocket::Host` for its socket resource.
impl wa::kernel::keyvalue::Host for State {}

/// The most a single key may be, so one call cannot grow the namespace's page size without bound.
const KEY_MAX: usize = 512;
/// The most keys one `list-keys` call returns (`kv.scan` clamps the same way, this is the guest-facing
/// promise and it is smaller: the WASI shape returns names, not entries).
const KEYS_MAX: u32 = 256;

fn key_bytes(key: &str) -> Result<Vec<u8>, KError> {
    let bytes = key.as_bytes();
    if bytes.is_empty() {
        return Err(KError::Refused("empty_key".into()));
    }
    if bytes.len() > KEY_MAX {
        return Err(KError::Refused("key_too_long".into()));
    }
    Ok(bytes.to_vec())
}

fn kv_error(error: String) -> KError {
    if error == "storage not declared" || error == guest_kv::RESERVED {
        KError::Refused(error)
    } else {
        KError::Failed(error)
    }
}

/// The policy gate for one key operation: the same capability names and the same target spelling the
/// `wa:kernel/kv` host uses, so one rule governs both interfaces and the audit trail reads as one.
fn gate(name: &str, capability: &str, target: &str) -> Result<(), KError> {
    match wa_governance::node_policy::check(name, capability, Some(target)) {
        Decision::Allow => Ok(()),
        Decision::RateLimited { retry_after_ms, .. } if retry_after_ms < 1_000 => Err(KError::Again),
        other => Err(KError::Refused(other.reason_str().to_string())),
    }
}

impl wa::kernel::keyvalue::HostWithStore<State> for State {
    async fn get(store: &wasmtime::component::Accessor<State, Self>, key: String) -> Result<Option<Vec<u8>>, KError> {
        let name = store.with(|mut access| access.get().name.clone());
        let mut call = HostCallGuard::start(&name, "keyvalue.get");
        let out = (|| {
            let bytes = key_bytes(&key)?;
            if guest_kv::is_reserved(&bytes) {
                // A host-owned key is not-found, exactly as `wa:kernel/kv` answers it.
                return Ok(None);
            }
            gate(&name, "kv.read", &key)?;
            store.with(|mut access| access.get().kv.get(bytes).map_err(kv_error))
        })();
        call.outcome(&out);
        out
    }

    async fn set(store: &wasmtime::component::Accessor<State, Self>, key: String, value: Vec<u8>) -> Result<(), KError> {
        let name = store.with(|mut access| access.get().name.clone());
        let mut call = HostCallGuard::start(&name, "keyvalue.set");
        let out = (|| {
            let bytes = key_bytes(&key)?;
            if guest_kv::is_reserved(&bytes) {
                return Err(KError::Refused(guest_kv::RESERVED.to_string()));
            }
            gate(&name, "kv.write", &key)?;
            store.with(|mut access| access.get().kv.set(bytes, value).map_err(kv_error))
        })();
        call.outcome(&out);
        out
    }

    async fn delete(store: &wasmtime::component::Accessor<State, Self>, key: String) -> Result<(), KError> {
        let name = store.with(|mut access| access.get().name.clone());
        let mut call = HostCallGuard::start(&name, "keyvalue.delete");
        let out = (|| {
            let bytes = key_bytes(&key)?;
            if guest_kv::is_reserved(&bytes) {
                return Err(KError::Refused(guest_kv::RESERVED.to_string()));
            }
            gate(&name, "kv.write", &key)?;
            store.with(|mut access| access.get().kv.delete(bytes).map_err(kv_error))
        })();
        call.outcome(&out);
        out
    }

    async fn exists(store: &wasmtime::component::Accessor<State, Self>, key: String) -> Result<bool, KError> {
        let name = store.with(|mut access| access.get().name.clone());
        let mut call = HostCallGuard::start(&name, "keyvalue.exists");
        let out = (|| {
            let bytes = key_bytes(&key)?;
            if guest_kv::is_reserved(&bytes) {
                return Ok(false);
            }
            gate(&name, "kv.read", &key)?;
            store.with(|mut access| Ok(access.get().kv.get(bytes).map_err(kv_error)?.is_some()))
        })();
        call.outcome(&out);
        out
    }

    async fn list_keys(store: &wasmtime::component::Accessor<State, Self>, prefix: String, limit: u32) -> Result<Vec<String>, KError> {
        let name = store.with(|mut access| access.get().name.clone());
        let mut call = HostCallGuard::start(&name, "keyvalue.list_keys");
        let out = (|| {
            let prefix_bytes = prefix.as_bytes().to_vec();
            // A scan of a host-owned prefix is an empty page, not a refusal: the empty prefix stays a
            // scan of the guest's own data (`wit/kernel-v2/kernel.wit`, `kv.scan`).
            if guest_kv::is_reserved(&prefix_bytes) {
                return Ok(Vec::new());
            }
            gate(&name, "kv.read", &prefix)?;
            let limit = limit.clamp(1, KEYS_MAX);
            store.with(|mut access| {
                let rows = access.get().kv.scan(prefix_bytes, None, limit).map_err(kv_error)?;
                Ok(rows.into_iter().filter_map(|(key, _)| String::from_utf8(key).ok()).collect::<Vec<String>>())
            })
        })();
        call.outcome(&out);
        out
    }
}

impl wa::kernel::config::Host for State {
    /// One granted key. The value is data the operator wrote into the definition's `config` object, so
    /// it is not a secret - but the read is still a capability an operator can refuse, and it is
    /// audited as `config.read` (not sensitive by default: it is the component's own configuration).
    fn get(&mut self, key: String) -> Result<Option<String>, KError> {
        let mut call = HostCallGuard::start(&self.name, "config.get");
        let out = (|| {
            let Some(text) = self.config.as_deref() else {
                return Err(KError::Refused("config not declared".into()));
            };
            gate(&self.name, "config.read", &key)?;
            let parsed: serde_json::Value = serde_json::from_str(text).map_err(|e| KError::Failed(e.to_string()))?;
            Ok(parsed.get(&key).map(|value| match value {
                serde_json::Value::String(text) => text.clone(),
                other => other.to_string(),
            }))
        })();
        call.outcome(&out);
        out
    }

    /// Every granted key as one JSON object, bounded by the grant's own 64 KiB limit (`components.rs`
    /// refuses a bigger config), so the guest cannot be handed more than the operator wrote.
    fn get_all(&mut self) -> Result<String, KError> {
        let mut call = HostCallGuard::start(&self.name, "config.get_all");
        let out = (|| {
            let Some(text) = self.config.as_deref() else {
                return Err(KError::Refused("config not declared".into()));
            };
            gate(&self.name, "config.read", "*")?;
            let parsed: serde_json::Value = serde_json::from_str(text).map_err(|e| KError::Failed(e.to_string()))?;
            Ok(if parsed.is_object() { parsed.to_string() } else { "{}".to_string() })
        })();
        call.outcome(&out);
        out
    }
}

/// Link the two interfaces into the runner's linker. Called from
/// `service_components_v2::run_once` only when the component's plan names them.
pub fn link(linker: &mut wasmtime::component::Linker<State>) -> wasmtime::Result<()> {
    wa::kernel::keyvalue::add_to_linker::<State, State>(linker, |s| s)?;
    wa::kernel::config::add_to_linker::<State, State>(linker, |s| s)?;
    Ok(())
}
