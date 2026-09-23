//! WASM tool plugins.
//!
//! Each `*.wasm` in the plugin directory is a core module exporting a tiny ABI:
//!
//!   memory                                  (exported linear memory)
//!   alloc(len: i32) -> i32                  (guest allocates `len` bytes)
//!   describe() -> i64                        (packed ptr<<32 | len, JSON)
//!   call(ptr: i32, len: i32) -> i64          (packed ptr<<32 | len, JSON)
//!   free(ptr: i32, len: i32)                 (optional, releases returned JSON)
//!
//! `describe` returns `{"name","description","parameters"}`; `call` receives the
//! tool arguments as JSON and returns JSON. The Lua core sees plugins as tools,
//! so a plugin is just another capability behind the same `host.*` surface.
//! `"surface":"internal"` keeps a deterministic plugin callable by trusted Lua
//! without advertising it as a model tool. The default remains `"tool"`.
use anyhow::{anyhow, Result};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use wasmtime::{Engine, Instance, Memory, Module, Store, TypedFunc};

struct Plugin {
    name: String,
    description: String,
    parameters: Value,
    internal: bool,
    store: Store<()>,
    memory: Memory,
    alloc: TypedFunc<i32, i32>,
    call: TypedFunc<(i32, i32), i64>,
    free: Option<TypedFunc<(i32, i32), ()>>,
}

pub struct PluginRegistry {
    engine: Engine,
    plugins: Vec<Plugin>,
}

fn read_packed(
    memory: &Memory,
    store: &mut Store<()>,
    packed: i64,
    free: Option<&TypedFunc<(i32, i32), ()>>,
) -> Result<String> {
    let pointer = ((packed >> 32) & 0xffff_ffff) as u32 as usize;
    let length = (packed & 0xffff_ffff) as u32 as usize;
    let mut buffer = vec![0u8; length];
    memory.read(&*store, pointer, &mut buffer)?;
    if let Some(free) = free {
        free.call(store, (pointer as i32, length as i32))?;
    }
    Ok(String::from_utf8_lossy(&buffer).to_string())
}

impl PluginRegistry {
    pub fn load(directory: &Path) -> Self {
        let engine = Engine::default();
        let mut plugins = Vec::new();
        if let Ok(entries) = std::fs::read_dir(directory) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|e| e.to_str()) != Some("wasm") {
                    continue;
                }
                match Self::load_one(&engine, &path) {
                    Ok(plugin) => plugins.push(plugin),
                    Err(error) => eprintln!("[plugin] {} skipped: {error}", path.display()),
                }
            }
        }
        plugins.sort_by(|a, b| a.name.cmp(&b.name));
        PluginRegistry { engine, plugins }
    }

    fn load_one(engine: &Engine, path: &Path) -> Result<Plugin> {
        let module = Module::from_file(engine, path)?;
        let mut store = Store::new(engine, ());
        let instance = Instance::new(&mut store, &module, &[])?;
        let memory = instance
            .get_memory(&mut store, "memory")
            .ok_or_else(|| anyhow!("module does not export memory"))?;
        let alloc = instance.get_typed_func::<i32, i32>(&mut store, "alloc")?;
        let describe = instance.get_typed_func::<(), i64>(&mut store, "describe")?;
        let call = instance.get_typed_func::<(i32, i32), i64>(&mut store, "call")?;
        let free = if instance.get_func(&mut store, "free").is_some() {
            Some(instance.get_typed_func::<(i32, i32), ()>(&mut store, "free")?)
        } else {
            None
        };
        let packed = describe.call(&mut store, ())?;
        let text = read_packed(&memory, &mut store, packed, free.as_ref())?;
        let info: Value = serde_json::from_str(&text)?;
        let name = info
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("plugin")
            .to_string();
        let description = info
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let parameters = info
            .get("parameters")
            .cloned()
            .unwrap_or_else(|| json!({"type": "object"}));
        let internal = match info
            .get("surface")
            .and_then(Value::as_str)
            .unwrap_or("tool")
        {
            "tool" => false,
            "internal" => true,
            other => return Err(anyhow!("invalid plugin surface: {other}")),
        };
        Ok(Plugin {
            name,
            description,
            parameters,
            internal,
            store,
            memory,
            alloc,
            call,
            free,
        })
    }

    /// JSON `[{name, description, parameters}, ...]` for the model tool list.
    pub fn describe_all(&self) -> Value {
        Value::Array(
            self.plugins
                .iter()
                .filter(|plugin| !plugin.internal)
                .map(|plugin| {
                    json!({
                        "name": plugin.name,
                        "description": plugin.description,
                        "parameters": plugin.parameters,
                    })
                })
                .collect(),
        )
    }

    pub fn has(&self, name: &str) -> bool {
        self.plugins.iter().any(|plugin| plugin.name == name)
    }

    pub fn invoke(&mut self, name: &str, arguments_json: &str) -> Result<String> {
        let plugin = self
            .plugins
            .iter_mut()
            .find(|plugin| plugin.name == name)
            .ok_or_else(|| anyhow!("plugin_not_found:{name}"))?;
        let bytes = arguments_json.as_bytes();
        let pointer = plugin.alloc.call(&mut plugin.store, bytes.len() as i32)?;
        plugin
            .memory
            .write(&mut plugin.store, pointer as usize, bytes)?;
        let packed = plugin
            .call
            .call(&mut plugin.store, (pointer, bytes.len() as i32))?;
        read_packed(
            &plugin.memory,
            &mut plugin.store,
            packed,
            plugin.free.as_ref(),
        )
    }
}

pub fn plugin_dir() -> PathBuf {
    if let Ok(path) = std::env::var("WASM_AGENT_PLUGINS") {
        return PathBuf::from(path);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".into());
    PathBuf::from(home).join(".wasm-agent").join("plugins")
}
