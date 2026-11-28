//! Hosting the WhatsApp archive component: the kernel answers the two imports its world declares.
//!
//! WHY THIS LIVES HERE (28/11, the archive half of `_orch/move-list.md`). The archive's operations need two
//! things from outside - the store an index lives behind (`Kv`) and the keystore's keyless seal/open
//! (`Sealer`) - and both lived in the host crate, which is why the archive was compiled into the node. The
//! component (`rust/components/whatsapp-archive`, world `archive-component`) declares exactly those two as
//! IMPORTS; this module is the other side of them, and it is the same shape `sandbox_host.rs` established for
//! codemode: the kernel hosts the component and ASKS the caller for the answers, deciding nothing itself.
//!
//! The caller installs one [`ArchiveHost`] and calls [`serve`]. A node with no host installed cannot answer an
//! archive question and says so, rather than falling back in-process.
use serde_json::{json, Value};
use std::sync::OnceLock;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Config as WasmConfig, Engine, Store, StoreLimits, StoreLimitsBuilder};
use wasmtime_wasi::{WasiCtx, WasiCtxBuilder, WasiCtxView, WasiView};

wasmtime::component::bindgen!({
    path: "../../wit/archive",
    world: "archive-component",
});

use wa::archive::{sealer, store};

/// The installed name this host serves (`<components>/whatsapp-archive.wasm`).
pub const COMPONENT: &str = "whatsapp-archive";

/// What the host asks the caller: the archive library's own two traits, in the same shape.
pub trait ArchiveHost {
    fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, String>;
    fn set(&self, key: &[u8], value: &[u8]) -> Result<(), String>;
    fn del(&self, key: &[u8]) -> Result<(), String>;
    fn scan(&self, prefix: &[u8], cursor: Option<Vec<u8>>, limit: usize) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String>;
    fn seal(&self, context: &str, plaintext: &[u8]) -> Result<Vec<u8>, String>;
    fn open(&self, context: &str, sealed: &[u8]) -> Result<Vec<u8>, String>;
}

static HOST: OnceLock<Box<dyn ArchiveHost + Send + Sync>> = OnceLock::new();

/// Install the store and the sealer this process answers the component with. First install wins.
pub fn set_host(host: Box<dyn ArchiveHost + Send + Sync>) {
    let _ = HOST.set(host);
}

pub fn host_installed() -> bool {
    HOST.get().is_some()
}

fn missing() -> String {
    "archive_host_absent: no store/sealer installed in this process".to_string()
}

struct Bridges {
    wasi: WasiCtx,
    limits: StoreLimits,
    table: ResourceTable,
}

impl WasiView for Bridges {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView { ctx: &mut self.wasi, table: &mut self.table }
    }
}

impl wasmtime::component::HasData for Bridges {
    type Data<'a> = &'a mut Bridges;
}

impl store::Host for Bridges {
    fn get(&mut self, key: Vec<u8>) -> Result<Option<Vec<u8>>, String> {
        match HOST.get() {
            Some(host) => host.get(&key),
            None => Err(missing()),
        }
    }

    fn set(&mut self, key: Vec<u8>, value: Vec<u8>) -> Result<(), String> {
        match HOST.get() {
            Some(host) => host.set(&key, &value),
            None => Err(missing()),
        }
    }

    fn del(&mut self, key: Vec<u8>) -> Result<(), String> {
        match HOST.get() {
            Some(host) => host.del(&key),
            None => Err(missing()),
        }
    }

    fn scan(&mut self, prefix: Vec<u8>, cursor: Option<Vec<u8>>, limit: u32) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
        match HOST.get() {
            Some(host) => host.scan(&prefix, cursor, limit as usize),
            None => Err(missing()),
        }
    }
}

impl sealer::Host for Bridges {
    fn seal(&mut self, context: String, plaintext: Vec<u8>) -> Result<Vec<u8>, String> {
        match HOST.get() {
            Some(host) => host.seal(&context, &plaintext),
            None => Err(missing()),
        }
    }

    fn open(&mut self, context: String, sealed: Vec<u8>) -> Result<Vec<u8>, String> {
        match HOST.get() {
            Some(host) => host.open(&context, &sealed),
            None => Err(missing()),
        }
    }
}

fn engine() -> Result<Engine, String> {
    static ENGINE: OnceLock<Engine> = OnceLock::new();
    if let Some(engine) = ENGINE.get() {
        return Ok(engine.clone());
    }
    let mut config = WasmConfig::new();
    config.wasm_component_model(true);
    let engine = Engine::new(&config).map_err(|error| format!("archive_engine:{error}"))?;
    let _ = ENGINE.set(engine.clone());
    Ok(engine)
}

/// One archive question, answered by the installed component.
///
/// `wasm` is the artifact's bytes: the caller resolved them (the node's component directory, a development
/// override), so this module never reads a path of its own.
pub fn serve(wasm: &[u8], request: &str) -> Result<String, String> {
    if !host_installed() {
        return Err(missing());
    }
    let engine = engine()?;
    let component = Component::new(&engine, wasm).map_err(|error| format!("archive_compile:{error}"))?;
    let mut store = Store::new(
        &engine,
        Bridges {
            wasi: WasiCtxBuilder::new().build(),
            limits: StoreLimitsBuilder::new().memory_size(64 << 20).build(),
            table: ResourceTable::new(),
        },
    );
    store.limiter(|host| &mut host.limits);
    let mut linker: Linker<Bridges> = Linker::new(&engine);
    wasmtime_wasi::p2::add_to_linker_sync(&mut linker).map_err(|error| format!("archive_link_wasi:{error}"))?;
    store::add_to_linker::<Bridges, Bridges>(&mut linker, |host| host).map_err(|error| format!("archive_link_store:{error}"))?;
    sealer::add_to_linker::<Bridges, Bridges>(&mut linker, |host| host).map_err(|error| format!("archive_link_sealer:{error}"))?;
    let bindings = ArchiveComponent::instantiate(&mut store, &component, &linker)
        .map_err(|error| format!("archive_instantiate:{error}"))?;
    let control = bindings.wa_archive_control();
    control.call_serve(&mut store, request).map_err(|error| format!("archive_failed:{error}"))
}

/// The answer as JSON, or the failure in the same shape every other door uses.
pub fn answer(wasm: &[u8], request: &str) -> Value {
    match serve(wasm, request) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_else(|error| json!({"ok": false, "error": format!("archive_answer_invalid:{error}")})),
        Err(error) => json!({"ok": false, "error": error}),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use std::path::PathBuf;
    use std::sync::Mutex;

    /// The smallest host the archive needs: a map and a seal that is reversible but not secret. Enough to
    /// prove the two imports are answered and that the component's answer is the library's.
    #[derive(Default)]
    struct Memory(Mutex<BTreeMap<Vec<u8>, Vec<u8>>>);

    impl ArchiveHost for Memory {
        fn get(&self, key: &[u8]) -> Result<Option<Vec<u8>>, String> {
            Ok(self.0.lock().unwrap().get(key).cloned())
        }
        fn set(&self, key: &[u8], value: &[u8]) -> Result<(), String> {
            self.0.lock().unwrap().insert(key.to_vec(), value.to_vec());
            Ok(())
        }
        fn del(&self, key: &[u8]) -> Result<(), String> {
            self.0.lock().unwrap().remove(key);
            Ok(())
        }
        fn scan(&self, prefix: &[u8], cursor: Option<Vec<u8>>, limit: usize) -> Result<Vec<(Vec<u8>, Vec<u8>)>, String> {
            let map = self.0.lock().unwrap();
            Ok(map
                .iter()
                .filter(|(key, _)| key.starts_with(prefix))
                .filter(|(key, _)| cursor.as_ref().map(|after| key.as_slice() > after.as_slice()).unwrap_or(true))
                .take(limit)
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect())
        }
        fn seal(&self, context: &str, plaintext: &[u8]) -> Result<Vec<u8>, String> {
            let mut out = context.as_bytes().to_vec();
            out.push(0);
            out.extend_from_slice(plaintext);
            Ok(out)
        }
        fn open(&self, context: &str, sealed: &[u8]) -> Result<Vec<u8>, String> {
            let mut wanted = context.as_bytes().to_vec();
            wanted.push(0);
            sealed.strip_prefix(wanted.as_slice()).map(|body| body.to_vec())
                .ok_or_else(|| "wrong context".to_string())
        }
    }

    fn artifact() -> Option<Vec<u8>> {
        let dir = std::env::var("WA_COMPONENTS_DIR").ok().map(PathBuf::from)
            .or_else(|| std::env::var("HOME").ok().map(|home| PathBuf::from(home).join(".wasm-agent/components")))?;
        std::fs::read(dir.join("whatsapp-archive.wasm")).ok()
    }

    #[test]
    fn the_component_answers_the_pure_rules_and_the_store_backed_one() {
        let Some(wasm) = artifact() else {
            eprintln!("skip the_component_answers...: no whatsapp-archive.wasm installed");
            return;
        };
        set_host(Box::new(Memory::default()));
        // A name rule, straight from the library.
        let named = answer(&wasm, r#"{"op":"file_name","args":{"month":"2026-11"}}"#);
        assert_eq!(named["ok"], json!(true), "{named}");
        assert!(named["name"].as_str().unwrap().contains("2026-11"), "{named}");
        // A seal context, which is what a body is bound to.
        let context = answer(&wasm, r#"{"op":"seal_context","args":{"month":"2026-11"}}"#);
        assert!(context["context"].as_str().unwrap().contains("2026-11"), "{context}");
        // The store-backed op: an empty store has nothing due a decade ago.
        let due = answer(&wasm, r#"{"op":"due","args":{"now_ms":1000,"keep_days":30}}"#);
        assert_eq!(due["ok"], json!(true), "{due}");
        assert_eq!(due["month"], Value::Null, "an empty store has no month to cut: {due}");
        // And a month the caller names is due when it is older than the window.
        let is_due = answer(&wasm, r#"{"op":"is_due","args":{"month":"2020-01","now_ms":1764547200000,"keep_days":30}}"#);
        assert_eq!(is_due["due"], json!(true), "{is_due}");
    }
}
